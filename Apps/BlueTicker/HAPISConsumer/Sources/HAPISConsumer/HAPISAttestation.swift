import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if os(iOS)
import DeviceCheck
#endif

/// Debug は stub mint（Simulator / `ATTEST_MODE=stub`）。Release は App Attest を sessions に載せる。
/// 本番 `ATTEST_MODE=enforce` の切替はこのクライアントでは行わない。
enum HAPISAttestClientMode: String, Sendable, Equatable {
    case stub
    case appAttest

    static var compileDefault: HAPISAttestClientMode {
        #if DEBUG
            return .stub
        #else
            return .appAttest
        #endif
    }

    static func make(
        mode: HAPISAttestClientMode,
        service: any HAPISAppAttestServicing = SystemHAPISAppAttestService(),
        keyStore: any HAPISAttestKeyStoring = HAPISAttestKeyStores.make()
    ) -> any HAPISAttestationProviding {
        switch mode {
        case .stub:
            return HAPISStubAttestationProvider()
        case .appAttest:
            return HAPISAppAttestProvider(service: service, keyStore: keyStore)
        }
    }
}

protocol HAPISAttestationProviding: Sendable {
    /// この provider が sessions に載せるクライアント側の mint 形態。
    /// サーバーの `attest_mode` は live stub でも `stub` のままなので、局所 provenance には使わない。
    var clientMode: HAPISAttestClientMode { get }

    /// stub は `nil`（sessions ボディ `{}`、challenge は取らない）。
    /// App Attest は `fetchChallenge` して attestation または assertion を返す。
    func payloadForMint(
        issuer: URL,
        fetchChallenge: @escaping @Sendable () async throws -> HAPISChallenge
    ) async throws -> HAPISAttestationPayload?

    /// sessions が受理されたあとだけ呼ぶ。これ以前の鍵は assertion に使わない。
    func noteMintAccepted(issuer: URL) async throws
}

extension HAPISAttestationProviding {
    var clientMode: HAPISAttestClientMode { .stub }
    func noteMintAccepted(issuer: URL) async throws {}
}

struct HAPISAttestationPayload: Encodable, Equatable, Sendable {
    var keyId: String
    var attestation: String?
    var assertion: String?
    var challenge: String
    var clientData: String?

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case attestation
        case assertion
        case challenge
        case clientData = "client_data"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyId, forKey: .keyId)
        try container.encode(challenge, forKey: .challenge)
        try container.encodeIfPresent(attestation, forKey: .attestation)
        try container.encodeIfPresent(assertion, forKey: .assertion)
        try container.encodeIfPresent(clientData, forKey: .clientData)
    }
}

/// `ATTEST_MODE=stub`。challenge は送らず、mint ボディは `{}`。緊急トークンも出さない。
struct HAPISStubAttestationProvider: HAPISAttestationProviding {
    func payloadForMint(
        issuer: URL,
        fetchChallenge: @escaping @Sendable () async throws -> HAPISChallenge
    ) async throws -> HAPISAttestationPayload? {
        nil
    }
}

protocol HAPISAppAttestServicing: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

struct SystemHAPISAppAttestService: HAPISAppAttestServicing {
    var isSupported: Bool {
        #if os(iOS)
            DCAppAttestService.shared.isSupported
        #else
            false
        #endif
    }

    func generateKey() async throws -> String {
        #if os(iOS)
            do {
                return try await DCAppAttestService.shared.generateKey()
            } catch {
                throw HAPISAppAttestProvider.mapServiceError(error)
            }
        #else
            throw HAPISConsumerError.attestUnavailable
        #endif
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if os(iOS)
            do {
                return try await DCAppAttestService.shared.attestKey(
                    keyId, clientDataHash: clientDataHash)
            } catch {
                throw HAPISAppAttestProvider.mapServiceError(error)
            }
        #else
            throw HAPISConsumerError.attestUnavailable
        #endif
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if os(iOS)
            do {
                return try await DCAppAttestService.shared.generateAssertion(
                    keyId, clientDataHash: clientDataHash)
            } catch {
                throw HAPISAppAttestProvider.mapServiceError(error)
            }
        #else
            throw HAPISConsumerError.attestUnavailable
        #endif
    }
}

/// 初回: 新しい challenge の JSON `{"challenge":…}` を SHA256 して `attestKey`。
/// 以降: 毎回新しい challenge を取って同じ JSON で `generateAssertion`。
/// 鍵は sessions 受理まで未登録。未対応環境では stub に落とさない。
struct HAPISAppAttestProvider: HAPISAttestationProviding {
    let service: any HAPISAppAttestServicing
    let keyStore: any HAPISAttestKeyStoring
    var clientMode: HAPISAttestClientMode { .appAttest }

    func payloadForMint(
        issuer: URL,
        fetchChallenge: @escaping @Sendable () async throws -> HAPISChallenge
    ) async throws -> HAPISAttestationPayload? {
        guard service.isSupported else {
            throw HAPISConsumerError.attestUnavailable
        }
        if let record = try keyStore.load(issuer: issuer), record.registered {
            do {
                let challenge = try await fetchChallenge()
                return try await assertionPayload(keyId: record.keyId, challenge: challenge)
            } catch HAPISConsumerError.attestInvalidKey {
                keyStore.clear(issuer: issuer)
            } catch {
                throw error
            }
        }
        let challenge = try await fetchChallenge()
        return try await attestationPayload(challenge: challenge, issuer: issuer)
    }

    func noteMintAccepted(issuer: URL) async throws {
        guard var record = try keyStore.load(issuer: issuer) else { return }
        record.registered = true
        try keyStore.save(record, issuer: issuer)
    }

    private func attestationPayload(challenge: HAPISChallenge, issuer: URL) async throws
        -> HAPISAttestationPayload
    {
        let bound = try HAPISAppAttestClientData.bind(challenge: challenge.challenge)
        let keyId = try await keyIdForAttestation(issuer: issuer)
        do {
            let attestation = try await service.attestKey(keyId, clientDataHash: bound.hash)
            try keyStore.save(
                HAPISAttestKeyRecord(keyId: keyId, registered: false, attested: true),
                issuer: issuer)
            return HAPISAttestationPayload(
                keyId: keyId,
                attestation: attestation.hapisBase64URLEncoded,
                assertion: nil,
                challenge: challenge.challenge,
                clientData: bound.clientData
            )
        } catch HAPISConsumerError.attestInvalidKey {
            keyStore.clear(issuer: issuer)
            throw HAPISConsumerError.attestInvalidKey
        } catch {
            throw error
        }
    }

    /// 未登録で未 attest の鍵だけ再利用。`attestKey` 済みは Apple が再 attest できないので捨てて作り直す。
    private func keyIdForAttestation(issuer: URL) async throws -> String {
        if let pending = try keyStore.load(issuer: issuer), !pending.registered, !pending.attested {
            return pending.keyId
        }
        let keyId = try await service.generateKey()
        try keyStore.save(
            HAPISAttestKeyRecord(keyId: keyId, registered: false, attested: false), issuer: issuer)
        return keyId
    }

    private func assertionPayload(keyId: String, challenge: HAPISChallenge) async throws
        -> HAPISAttestationPayload
    {
        let bound = try HAPISAppAttestClientData.bind(challenge: challenge.challenge)
        let assertion = try await service.generateAssertion(keyId, clientDataHash: bound.hash)
        return HAPISAttestationPayload(
            keyId: keyId,
            attestation: nil,
            assertion: assertion.hapisBase64URLEncoded,
            challenge: challenge.challenge,
            clientData: bound.clientData
        )
    }

    static func mapServiceError(_ error: Error) -> HAPISConsumerError {
        #if os(iOS)
            if let dc = error as? DCError {
                switch dc.code {
                case .invalidKey, .invalidInput:
                    return .attestInvalidKey
                case .serverUnavailable:
                    return .transport("app attest unavailable")
                default:
                    return .attestFailed(dc.localizedDescription)
                }
            }
        #endif
        if let hapis = error as? HAPISConsumerError {
            return hapis
        }
        return .attestFailed(error.localizedDescription)
    }
}

/// `client_data` は challenge を埋め込んだ UTF-8 JSON `{"challenge":"<GET /v1/consumer/challenge>"}`。
/// `attestKey` / `generateAssertion` の hash は常にこのバイト列の SHA256。Team / Bundle は載せない。
enum HAPISAppAttestClientData {
    struct Binding: Equatable, Sendable {
        var clientData: String
        var hash: Data
    }

    static func json(challenge: String) throws -> Data {
        try HAPISJSON.encoder.encode(["challenge": challenge])
    }

    static func bind(challenge: String) throws -> Binding {
        let data = try json(challenge: challenge)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HAPISConsumerError.decoding("client_data を UTF-8 にできません")
        }
        return Binding(clientData: text, hash: HAPISSHA256.hash(data))
    }
}

enum HAPISSHA256 {
    static func hash(_ data: Data) -> Data {
        #if canImport(CryptoKit)
            Data(CryptoKit.SHA256.hash(data: data))
        #else
            portable(data)
        #endif
    }

    static func portable(_ message: Data) -> Data {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
            0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
            0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
            0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
            0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
            0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
            0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
            0xc67178f2,
        ]
        var bytes = [UInt8](message)
        let bitCount = UInt64(message.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        bytes.append(contentsOf: withUnsafeBytes(of: bitCount.bigEndian, Array.init))
        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = chunkStart + i * 4
                w[i] =
                    UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8
                    | UInt32(bytes[o + 3])
            }
            for i in 16..<64 {
                let s0 =
                    rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 =
                    rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0]
            var b = h[1]
            var c = h[2]
            var d = h[3]
            var e = h[4]
            var f = h[5]
            var g = h[6]
            var hh = h[7]
            for i in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] &+= a
            h[1] &+= b
            h[2] &+= c
            h[3] &+= d
            h[4] &+= e
            h[5] &+= f
            h[6] &+= g
            h[7] &+= hh
        }
        var out = Data(capacity: 32)
        for value in h {
            withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    private static func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

extension Data {
    var hapisBase64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static func hapisBase64URL(_ string: String) -> Data? {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = padded.count % 4
        if pad > 0 {
            padded += String(repeating: "=", count: 4 - pad)
        }
        return Data(base64Encoded: padded)
    }
}
