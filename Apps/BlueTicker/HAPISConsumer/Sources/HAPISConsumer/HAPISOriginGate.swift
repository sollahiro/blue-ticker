import Foundation

/// HAPIS ゲートウェイ（＝上流 `api.*`）向けのクライアント側スロットリング。
/// 先読みは間引き、429 のあとは interactive も含めて待つ。loopback には使わない。
/// ゲートウェイへは同時に 1 本だけ出す（起動時 Feed と条件検索が並走して 429 にならないようにする）。
public actor HAPISOriginGate {
    public enum RequestClass: Sendable, Equatable {
        /// Feed / 検索 / 銘柄を開いたとき。429 クールダウンだけ待つ。
        case interactive
        /// ウォッチリスト先読み。リクエスト間を空ける。
        case prefetch
    }

    /// origin は HAPIS の 60/分より短い。先読みを約 15/分に抑える。
    public static let prefetchSpacing: TimeInterval = 4
    public static let defaultCooldown: TimeInterval = 20
    public static let maxCooldown: TimeInterval = 120

    private var cooldownUntil = Date.distantPast
    private var nextPrefetchAt = Date.distantPast
    private var occupied = false
    private var occupancyWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
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
        while true {
            try Task.checkCancellation()
            let instant = now()
            var target = cooldownUntil
            if requestClass == .prefetch {
                target = max(target, nextPrefetchAt)
            }
            let delay = target.timeIntervalSince(instant)
            if delay > 0.01 {
                try await sleep(delay)
                continue
            }
            break
        }
        if requestClass == .prefetch {
            nextPrefetchAt = now().addingTimeInterval(Self.prefetchSpacing)
        }
    }

    /// 1 本分のゲートウェイ枠を取って `operation` を走らせる。終了まで次は待たされる。
    public func withTurn<T: Sendable>(
        _ requestClass: RequestClass,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquireSlot(requestClass)
        do {
            let value = try await operation()
            releaseSlot()
            return value
        } catch {
            releaseSlot()
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

    private func acquireSlot(_ requestClass: RequestClass) async throws {
        while true {
            try await waitTurn(requestClass)
            if occupied {
                try await waitForOccupancy()
                continue
            }
            occupied = true
            return
        }
    }

    private func waitForOccupancy() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                occupancyWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelOccupancy(id) }
        }
    }

    private func cancelOccupancy(_ id: UUID) {
        if let index = occupancyWaiters.firstIndex(where: { $0.id == id }) {
            occupancyWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func releaseSlot() {
        occupied = false
        guard !occupancyWaiters.isEmpty else { return }
        occupancyWaiters.removeFirst().continuation.resume()
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
