// 非 loopback bind の無認証起動をプロセス開始時に拒否する（fail-closed）。
// origin はトークンを検証しない（docs/api-auth.md）。公開到達はエッジ / HAPIS 側。
// Access / HAPIS の認証ミドルウェアは載せない。HAPIS 専用 env も持たない。

import Foundation

/// 非 loopback bind での無認証起動をプロセス開始時に拒否する（fail-closed）。
/// origin はトークンを検証しない（`docs/api-auth.md`）。公開到達はエッジ / HAPIS 側。
/// このガードは「listen してよいか」だけを見る。Access / HAPIS の認証ミドルウェアは載せない。
enum OriginUnauthenticatedBindGuard {
    enum Decision: Equatable {
        case allow
        case refuse(message: String)
    }

    /// - Parameters:
    ///   - host: `--host` / `BLT_HOST` の bind アドレス
    ///   - cfAccessTeamDomain: `CF_ACCESS_TEAM_DOMAIN`（非空なら段階 A・エッジ信頼として許可）
    ///   - allowUnauthenticated: `BLT_ALLOW_UNAUTHENTICATED`（`1` のときだけ明示 opt-in）
    static func evaluate(
        host: String,
        cfAccessTeamDomain: String?,
        allowUnauthenticated: String?
    ) -> Decision {
        if isLoopbackBind(host) { return .allow }
        if isNonEmpty(cfAccessTeamDomain) { return .allow }
        if trimmed(allowUnauthenticated) == "1" { return .allow }
        return .refuse(
            message:
                "非 loopback バインド (\(host)) では無認証起動できません。"
                + "CF_ACCESS_TEAM_DOMAIN を設定するか、明示的に BLT_ALLOW_UNAUTHENTICATED=1 を指定してください。\n"
        )
    }

    /// `127.0.0.1` / `localhost` / `::1` および IPv4 loopback 全体（127.0.0.0/8）。
    /// DNS は使わない（bind リテラルの判定。`0.0.0.0` を loopback と誤らないため）。
    static func isLoopbackBind(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.isEmpty { return false }
        if h == "localhost" || h == "::1" || h == "[::1]" { return true }
        if let first = ipv4FirstOctet(h), first == 127 { return true }
        return false
    }

    private static func isNonEmpty(_ value: String?) -> Bool {
        !trimmed(value).isEmpty
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ipv4FirstOctet(_ host: String) -> UInt8? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets[0]
    }
}
