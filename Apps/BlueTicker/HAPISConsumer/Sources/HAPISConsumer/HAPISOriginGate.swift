import Foundation

/// HAPIS ゲートウェイ（＝上流 `api.*`）向けのクライアント側スロットリング。
/// 先読みは間引き、429 のあとは interactive も含めて待つ。loopback には使わない。
/// interactive は少数を並列に出し（銘柄面の financials / overview / waterfall が直列にならないようにする）、
/// prefetch は interactive が居ないときだけ 1 本ずつ出す。HAPIS の制限は 60/分のレートなので、
/// 数本の並列は問題にならない。
public actor HAPISOriginGate {
    public enum RequestClass: Sendable, Equatable {
        /// Feed / 検索 / 銘柄を開いたとき。429 クールダウンだけ待つ。
        case interactive
        /// ウォッチリスト先読み。リクエスト間を空け、interactive に道を譲る。
        case prefetch
    }

    /// interactive の同時本数。銘柄面は 3 本（financials / overview / waterfall）を同時に出す。
    public static let interactiveConcurrency = 3
    /// origin は HAPIS の 60/分より短い。先読みを約 15/分に抑える。
    public static let prefetchSpacing: TimeInterval = 4
    /// 最後の interactive からこの時間は先読みを出さない（操作中の帯域を先読みに取られないようにする）。
    public static let prefetchQuietPeriod: TimeInterval = 2
    public static let defaultCooldown: TimeInterval = 20
    public static let maxCooldown: TimeInterval = 120

    private var cooldownUntil = Date.distantPast
    private var nextPrefetchAt = Date.distantPast
    private var lastInteractiveAt = Date.distantPast
    private var interactiveInFlight = 0
    private var interactivePending = 0
    private var prefetchInFlight = 0
    private var slotWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            guard seconds > 0.01 else { return }
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public func isCoolingDown() -> Bool {
        now() < cooldownUntil
    }

    /// クールダウン / 先読み間隔だけ待つ。スロットは取らない。
    public func waitTurn(_ requestClass: RequestClass) async throws {
        try await waitClear(requestClass)
        if requestClass == .prefetch {
            nextPrefetchAt = now().addingTimeInterval(Self.prefetchSpacing)
        }
    }

    /// ゲートウェイ枠を取って `operation` を走らせる。
    /// interactive は `interactiveConcurrency` まで並列。prefetch は他が何も流れていないときだけ。
    public func withTurn<T: Sendable>(
        _ requestClass: RequestClass,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquireSlot(requestClass)
        do {
            let value = try await operation()
            releaseSlot(requestClass)
            return value
        } catch {
            releaseSlot(requestClass)
            throw error
        }
    }

    public func noteRateLimited(retryAfterSeconds: TimeInterval?) {
        let seconds = min(
            max(retryAfterSeconds ?? Self.defaultCooldown, 5),
            Self.maxCooldown
        )
        let until = now().addingTimeInterval(seconds)
        cooldownUntil = until
        nextPrefetchAt = until
    }

    /// クールダウン（と prefetch の間隔・静穏期間）が明けるまで眠る。予約はしない。
    private func waitClear(_ requestClass: RequestClass) async throws {
        while true {
            try Task.checkCancellation()
            let instant = now()
            var target = cooldownUntil
            if requestClass == .prefetch {
                target = max(target, nextPrefetchAt)
                target = max(target, lastInteractiveAt.addingTimeInterval(Self.prefetchQuietPeriod))
            }
            let delay = target.timeIntervalSince(instant)
            if delay > 0.01 {
                try await sleep(delay)
                continue
            }
            return
        }
    }

    private func acquireSlot(_ requestClass: RequestClass) async throws {
        if requestClass == .interactive {
            interactivePending += 1
        }
        defer {
            if requestClass == .interactive {
                interactivePending -= 1
            }
        }
        while true {
            try await waitClear(requestClass)
            if canStart(requestClass) {
                start(requestClass)
                return
            }
            try await waitForSlot()
        }
    }

    private func canStart(_ requestClass: RequestClass) -> Bool {
        switch requestClass {
        case .interactive:
            return interactiveInFlight + prefetchInFlight < Self.interactiveConcurrency
        case .prefetch:
            return interactiveInFlight == 0 && prefetchInFlight == 0 && interactivePending == 0
        }
    }

    private func start(_ requestClass: RequestClass) {
        switch requestClass {
        case .interactive:
            interactiveInFlight += 1
            lastInteractiveAt = now()
        case .prefetch:
            prefetchInFlight += 1
            nextPrefetchAt = now().addingTimeInterval(Self.prefetchSpacing)
        }
    }

    /// 空きが出るまで止まる。起こされたら呼び出し側が条件を再確認する。
    private func waitForSlot() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                slotWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelSlotWait(id) }
        }
    }

    private func cancelSlotWait(_ id: UUID) {
        if let index = slotWaiters.firstIndex(where: { $0.id == id }) {
            slotWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    /// 全員を起こして条件を再確認させる。先頭だけ起こすと、その 1 本が間隔待ちで眠っている間に
    /// 空いたスロットが誰にも使われない。
    private func releaseSlot(_ requestClass: RequestClass) {
        switch requestClass {
        case .interactive:
            interactiveInFlight -= 1
            lastInteractiveAt = now()
        case .prefetch:
            prefetchInFlight -= 1
        }
        let waiters = slotWaiters
        slotWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}

public enum HAPISRetryAfter {
    /// `Retry-After` の秒数。整数秒を優先し、HTTP-date なら残り秒。
    public static func seconds(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return nil
        }
        if let value = TimeInterval(raw) {
            return value
        }
        guard let date = httpDate(raw) else { return nil }
        return date.timeIntervalSince(now)
    }

    private static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}
