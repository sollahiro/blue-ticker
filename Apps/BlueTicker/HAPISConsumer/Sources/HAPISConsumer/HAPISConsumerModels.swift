import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HAPIS ゲートウェイへ短命匿名トークンを付ける対象か。loopback / LAN `http` と Access 本番は対象外。
/// 比較は https origin（host + 非既定 port）。host 部分一致や別ポートには付けない。
enum HAPISConsumerAuth {
    static func applies(to url: URL, gatewayBases: [URL]) -> Bool {
        guard let requestOrigin = HAPISIssuer.origin(of: url) else {
            return false
        }
        return gatewayBases.contains { HAPISIssuer.origin(of: $0) == requestOrigin }
    }
}

/// 発行者は https origin（scheme + host + 非既定 port）。path / query は使わない。
enum HAPISIssuer {
    static func origin(of url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.lowercased()
        if let port = url.port, port != 443 {
            components.port = port
        }
        return components.url
    }

    static func storageAccount(for issuer: URL) -> String {
        guard let origin = origin(of: issuer) else {
            return issuer.host?.lowercased() ?? "issuer"
        }
        if let port = origin.port {
            return "\(origin.host ?? "issuer"):\(port)"
        }
        return origin.host ?? "issuer"
    }
}

struct HAPISConsumerToken: Codable, Equatable, Sendable {
    var token: String
    var tokenType: String
    var expiresAt: Date
    var refreshAt: Date
    var subject: String?
    var attestMode: String?

    func isExpired(at now: Date) -> Bool {
        expiresAt <= now
    }

    func needsRefresh(at now: Date) -> Bool {
        !isExpired(at: now) && refreshAt <= now
    }
}

struct HAPISConsumerTokenResponse: Decodable, Sendable {
    var token: String
    var tokenType: String?
    var expiresIn: Int?
    var expiresAt: Date?
    var refreshAt: Date?
    var refreshIn: Int?
    var ttlSeconds: Int?
    var subject: String?
    var attestMode: String?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case refreshAt = "refresh_at"
        case refreshIn = "refresh_in"
        case ttlSeconds = "ttl_seconds"
        case subject
        case attestMode = "attest_mode"
    }

    func materialize(now: Date) throws -> HAPISConsumerToken {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HAPISConsumerError.decoding("token が空です")
        }
        let ttl = TimeInterval(ttlSeconds ?? expiresIn ?? 3600)
        let expires = expiresAt ?? now.addingTimeInterval(ttl)
        let refreshLead = TimeInterval(refreshIn ?? max(0, (expiresIn ?? Int(ttl)) - 300))
        let refresh = refreshAt ?? now.addingTimeInterval(refreshLead)
        return HAPISConsumerToken(
            token: trimmed,
            tokenType: tokenType ?? "Bearer",
            expiresAt: expires,
            refreshAt: min(refresh, expires),
            subject: subject,
            attestMode: attestMode
        )
    }
}

struct HAPISChallenge: Decodable, Equatable, Sendable {
    var challenge: String
    var expiresIn: Int?
    var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case challenge
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
    }

    /// GET `/v1/consumer/challenge` は 32 バイトの base64url。読めなければ UTF-8。
    var challengeBytes: Data {
        Data.hapisBase64URL(challenge) ?? Data(challenge.utf8)
    }
}

struct HAPISMintRequest: Encodable, Sendable {
    var attest: HAPISAttestationPayload?

    enum CodingKeys: String, CodingKey {
        case attest
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let attest {
            try container.encode(attest, forKey: .attest)
        }
    }
}

enum HAPISJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseISO8601(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "ISO8601 として読めません: \(raw)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func parseISO8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }
}

/// BLT `{ "error": "…" }` と HAPIS `{ "error": { "code", "message" } }` の両方。
struct GatewayErrorBody: Decodable, Sendable {
    var error: GatewayErrorValue?
    var status: Int?

    var code: String? { error?.code }
    var message: String? { error?.message }

    static func parse(_ data: Data) -> GatewayErrorBody? {
        try? JSONDecoder().decode(GatewayErrorBody.self, from: data)
    }

    /// 期限切れは `token_expired`。文言に expired が含まれる unauthorized も同様に扱う。
    var isTokenExpired: Bool {
        let code = (self.code ?? "").lowercased()
        if code == "token_expired" {
            return true
        }
        let message = (self.message ?? "").lowercased()
        return message.contains("token_expired") || message.contains("expired")
    }
}

enum GatewayErrorValue: Decodable, Sendable {
    case string(String)
    case object(code: String?, message: String?)

    var code: String? {
        switch self {
        case .string:
            return nil
        case .object(let code, _):
            return code
        }
    }

    var message: String? {
        switch self {
        case .string(let value):
            return value
        case .object(_, let message):
            return message
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        struct Object: Decodable {
            var code: String?
            var message: String?
        }
        let object = try container.decode(Object.self)
        self = .object(code: object.code, message: object.message)
    }
}

enum HAPISConsumerError: LocalizedError, Equatable {
    case decoding(String)
    case http(status: Int, code: String?, message: String)
    case tokenExpired
    case transport(String)
    case attestUnavailable
    case attestInvalidKey
    case attestFailed(String)

    static func == (lhs: HAPISConsumerError, rhs: HAPISConsumerError) -> Bool {
        switch (lhs, rhs) {
        case (.decoding(let a), .decoding(let b)):
            return a == b
        case (.http(let s1, let c1, let m1), .http(let s2, let c2, let m2)):
            return s1 == s2 && c1 == c2 && m1 == m2
        case (.tokenExpired, .tokenExpired):
            return true
        case (.transport(let a), .transport(let b)):
            return a == b
        case (.attestUnavailable, .attestUnavailable):
            return true
        case (.attestInvalidKey, .attestInvalidKey):
            return true
        case (.attestFailed(let a), .attestFailed(let b)):
            return a == b
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .decoding:
            return "一時的に更新できません"
        case .http(_, _, let message):
            return message.isEmpty ? "一時的に更新できません" : message
        case .tokenExpired:
            return "一時的に更新できません"
        case .transport:
            return "一時的に更新できません"
        case .attestUnavailable, .attestInvalidKey, .attestFailed:
            return "一時的に更新できません"
        }
    }

    static func from(status: Int, data: Data) -> HAPISConsumerError {
        let body = GatewayErrorBody.parse(data)
        if status == 401, body?.isTokenExpired == true {
            return .tokenExpired
        }
        return .http(
            status: status, code: body?.code, message: body?.message ?? "HTTP \(status)")
    }
}

protocol HAPISClock: Sendable {
    var now: Date { get }
}

struct SystemHAPISClock: HAPISClock {
    var now: Date { Date() }
}

final class MutableHAPISClock: HAPISClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(now: Date) {
        _now = now
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _now
        }
        set {
            lock.lock()
            _now = newValue
            lock.unlock()
        }
    }
}

protocol HAPISHTTPPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHAPISHTTP: HAPISHTTPPerforming {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HAPISConsumerError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HAPISConsumerError.transport("HTTP 応答ではありません")
        }
        return (data, http)
    }
}
