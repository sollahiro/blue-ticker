import Foundation

/// HAPIS ゲートウェイ（＝上流 `api.*`）向けのクライアント側スロットリング。
/// 先読みは間引き、429 のあとは interactive も含めて待つ。loopback には使わない。
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

    public func noteRateLimited(retryAfterSeconds: TimeInterval?) {
        let seconds = min(
            max(retryAfterSeconds ?? Self.defaultCooldown, 5),
            Self.maxCooldown
        )
        let until = now().addingTimeInterval(seconds)
        cooldownUntil = until
        nextPrefetchAt = until
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
