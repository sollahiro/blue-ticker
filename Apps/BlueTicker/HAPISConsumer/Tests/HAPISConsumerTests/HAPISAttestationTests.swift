import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import HAPISConsumer

@Suite(.serialized)
struct HAPISAttestationTests {
    private let issuer = URL(string: "https://hapis.example.test")!

    @Test func stubMintDoesNotFetchChallengeAndPostsEmptyObject() async throws {
        let http = MockHAPISHTTP()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.hasSuffix("/v1/consumer/challenge") {
                Issue.record("stub mint must not fetch challenge")
                return (500, #"{"error":{"code":"unexpected"}}"#)
            }
            if request.httpMethod == "POST", path.hasSuffix("/v1/consumer/sessions") {
                #expect(jsonObject(request.httpBody)?.isEmpty == true)
                return (201, tokenJSON(token: "stub-token", now: Date(), refreshIn: 3300, expiresIn: 3600))
            }
            Issue.record("unexpected \(request.httpMethod ?? "?") \(path)")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISStubAttestationProvider()
        )
        #expect(try await client.validToken() == "stub-token")
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/challenge") }.isEmpty)
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/sessions") }.count == 1)
    }

    @Test func appAttestFirstMintFetchesChallengeAndSendsAttestation() async throws {
        let challenge = Data(repeating: 0, count: 32).hapisBase64URLEncoded
        let http = MockHAPISHTTP()
        let keys = InMemoryHAPISAttestKeyStore()
        let service = MockHAPISAppAttestService()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.hasSuffix("/v1/consumer/challenge") {
                return (200, challengeJSON(challenge))
            }
            if request.httpMethod == "POST", path.hasSuffix("/v1/consumer/sessions") {
                guard let attest = attestObject(request.httpBody) else {
                    Issue.record("sessions body missing attest")
                    return (500, #"{"error":{"code":"unexpected"}}"#)
                }
                #expect(attest["key_id"] as? String == "test-key-id")
                #expect(attest["challenge"] as? String == challenge)
                #expect(attest["attestation"] as? String == Data("attest-cbor".utf8).hapisBase64URLEncoded)
                #expect(attest["assertion"] == nil)
                let clientData = attest["client_data"] as? String
                if let expected = try? HAPISAppAttestClientData.json(challenge: challenge) {
                    #expect(clientData == String(data: expected, encoding: .utf8))
                }
                return (201, tokenJSON(token: "attest-token", now: Date(), refreshIn: 3300, expiresIn: 3600))
            }
            Issue.record("unexpected \(request.httpMethod ?? "?") \(path)")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISAppAttestProvider(service: service, keyStore: keys)
        )
        #expect(try await client.validToken() == "attest-token")
        #expect(try keys.load(issuer: issuer)?.keyId == "test-key-id")
        #expect(try keys.load(issuer: issuer)?.registered == true)
        #expect(try keys.load(issuer: issuer)?.attested == true)
        #expect(service.generateKeyCount == 1)
        #expect(service.attestCalls.count == 1)
        #expect(service.assertionCalls.isEmpty)
        let expectedHash = HAPISSHA256.hash(try HAPISAppAttestClientData.json(challenge: challenge))
        #expect(service.attestCalls[0].hash == expectedHash)
        #expect(http.calls.map(\.path).filter { $0.hasSuffix("/v1/consumer/challenge") }.count == 1)
        #expect(http.calls.map(\.path).filter { $0.hasSuffix("/v1/consumer/sessions") }.count == 1)
    }

    @Test func subsequentMintSendsAssertionWithClientData() async throws {
        let challenge = Data(repeating: 1, count: 32).hapisBase64URLEncoded
        let http = MockHAPISHTTP()
        let keys = InMemoryHAPISAttestKeyStore()
        try keys.save(
            HAPISAttestKeyRecord(keyId: "stored-key", registered: true, attested: true),
            issuer: issuer)
        let service = MockHAPISAppAttestService()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.hasSuffix("/v1/consumer/challenge") {
                return (200, challengeJSON(challenge))
            }
            if request.httpMethod == "POST", path.hasSuffix("/v1/consumer/sessions") {
                guard let attest = attestObject(request.httpBody) else {
                    Issue.record("sessions body missing attest")
                    return (500, #"{"error":{"code":"unexpected"}}"#)
                }
                #expect(attest["key_id"] as? String == "stored-key")
                #expect(attest["challenge"] as? String == challenge)
                #expect(attest["assertion"] as? String == Data("assert-cbor".utf8).hapisBase64URLEncoded)
                #expect(attest["attestation"] == nil)
                let clientData = attest["client_data"] as? String
                #expect(clientData?.contains(challenge) == true)
                if let expected = try? HAPISAppAttestClientData.json(challenge: challenge) {
                    #expect(clientData == String(data: expected, encoding: .utf8))
                }
                return (201, tokenJSON(token: "assert-token", now: Date(), refreshIn: 3300, expiresIn: 3600))
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISAppAttestProvider(service: service, keyStore: keys)
        )
        #expect(try await client.validToken() == "assert-token")
        #expect(service.generateKeyCount == 0)
        #expect(service.attestCalls.isEmpty)
        #expect(service.assertionCalls.count == 1)
        #expect(service.assertionCalls[0].keyId == "stored-key")
        let expectedHash = HAPISSHA256.hash(try HAPISAppAttestClientData.json(challenge: challenge))
        #expect(service.assertionCalls[0].hash == expectedHash)
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/token/refresh") }.isEmpty)
    }

    @Test func invalidKeyFallsBackToNewAttestation() async throws {
        let assertionChallenge = Data(repeating: 2, count: 32).hapisBase64URLEncoded
        let attestChallenge = Data(repeating: 3, count: 32).hapisBase64URLEncoded
        let http = MockHAPISHTTP()
        let keys = InMemoryHAPISAttestKeyStore()
        try keys.save(
            HAPISAttestKeyRecord(keyId: "dead-key", registered: true, attested: true),
            issuer: issuer)
        let service = MockHAPISAppAttestService()
        service.assertionError = HAPISConsumerError.attestInvalidKey
        let challenges = Counter()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/consumer/challenge") {
                let n = challenges.increment()
                return (200, challengeJSON(n == 1 ? assertionChallenge : attestChallenge))
            }
            if path.hasSuffix("/v1/consumer/sessions") {
                guard let attest = attestObject(request.httpBody) else {
                    Issue.record("sessions body missing attest")
                    return (500, #"{"error":{"code":"unexpected"}}"#)
                }
                #expect(attest["key_id"] as? String == "test-key-id")
                #expect(attest["attestation"] != nil)
                #expect(attest["assertion"] == nil)
                #expect(attest["challenge"] as? String == attestChallenge)
                if let expected = try? HAPISAppAttestClientData.json(challenge: attestChallenge) {
                    #expect(attest["client_data"] as? String == String(data: expected, encoding: .utf8))
                }
                return (201, tokenJSON(token: "reattest-token", now: Date(), refreshIn: 3300, expiresIn: 3600))
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISAppAttestProvider(service: service, keyStore: keys)
        )
        #expect(try await client.validToken() == "reattest-token")
        #expect(try keys.load(issuer: issuer)?.keyId == "test-key-id")
        #expect(try keys.load(issuer: issuer)?.registered == true)
        #expect(service.generateKeyCount == 1)
        #expect(service.assertionCalls.count == 1)
        #expect(service.attestCalls.count == 1)
        #expect(service.assertionCalls[0].hash == HAPISSHA256.hash(try HAPISAppAttestClientData.json(challenge: assertionChallenge)))
        #expect(service.attestCalls[0].hash == HAPISSHA256.hash(try HAPISAppAttestClientData.json(challenge: attestChallenge)))
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/challenge") }.count == 2)
    }

    @Test func unsupportedAppAttestDoesNotFallBackToStub() async throws {
        let http = MockHAPISHTTP()
        http.handler = { _ in
            Issue.record("unsupported attest must not hit control plane")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let service = MockHAPISAppAttestService()
        service.isSupported = false
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISAppAttestProvider(
                service: service, keyStore: InMemoryHAPISAttestKeyStore())
        )
        await #expect(throws: HAPISConsumerError.attestUnavailable) {
            _ = try await client.validToken()
        }
        #expect(http.calls.isEmpty)
    }

    @Test func refreshStillSkipsChallengeAndSessions() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableHAPISClock(now: now)
        let http = MockHAPISHTTP()
        let store = InMemoryHAPISTokenStore()
        try store.save(
            HAPISConsumerToken(
                token: "old-token",
                tokenType: "Bearer",
                expiresAt: now.addingTimeInterval(3600),
                refreshAt: now.addingTimeInterval(-1),
                subject: "app_attest:stored",
                attestMode: "stub"
            ),
            issuer: issuer
        )
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/consumer/token/refresh") {
                return (
                    200,
                    tokenJSON(
                        token: "refreshed-token", now: now.addingTimeInterval(400), refreshIn: 3300,
                        expiresIn: 3600)
                )
            }
            Issue.record("refresh must not mint or challenge")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let service = MockHAPISAppAttestService()
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: store,
            clock: clock,
            attestation: HAPISAppAttestProvider(
                service: service, keyStore: InMemoryHAPISAttestKeyStore())
        )
        #expect(try await client.validToken() == "refreshed-token")
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/token/refresh") }.count == 1)
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/sessions") }.isEmpty)
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/challenge") }.isEmpty)
        #expect(service.generateKeyCount == 0)
    }

    @Test func factoryStubDoesNotUseAppAttestService() {
        let provider = HAPISAttestClientMode.make(
            mode: .stub, service: MockHAPISAppAttestService())
        #expect(provider is HAPISStubAttestationProvider)
        let attest = HAPISAttestClientMode.make(
            mode: .appAttest, service: MockHAPISAppAttestService())
        #expect(attest is HAPISAppAttestProvider)
        #if DEBUG
            #expect(HAPISAttestClientMode.compileDefault == .stub)
        #else
            #expect(HAPISAttestClientMode.compileDefault == .appAttest)
        #endif
    }

    @Test func sha256MatchesFIPSVectors() {
        #expect(
            HAPISSHA256.portable(Data()).map { String(format: "%02x", $0) }.joined()
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(
            HAPISSHA256.portable(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(HAPISSHA256.hash(Data()) == HAPISSHA256.portable(Data()))
        #expect(HAPISSHA256.hash(Data("abc".utf8)) == HAPISSHA256.portable(Data("abc".utf8)))
    }

    @Test func mintRequestEncodesAttestEvidenceAndOmitsNilFields() throws {
        let payload = HAPISAttestationPayload(
            keyId: "kid",
            attestation: "att",
            assertion: nil,
            challenge: "chg",
            clientData: "{\"challenge\":\"chg\"}"
        )
        let encoded = try HAPISJSON.encoder.encode(HAPISMintRequest(attest: payload))
        let root = try #require(jsonObject(encoded))
        let attest = try #require(root["attest"] as? [String: Any])
        #expect(attest["key_id"] as? String == "kid")
        #expect(attest["attestation"] as? String == "att")
        #expect(attest["challenge"] as? String == "chg")
        #expect(attest["client_data"] as? String == "{\"challenge\":\"chg\"}")
        #expect(attest["assertion"] == nil)
        let stub = try HAPISJSON.encoder.encode(HAPISMintRequest(attest: nil))
        #expect(String(data: stub, encoding: .utf8) == "{}")
        let bound = try HAPISAppAttestClientData.bind(challenge: "chg")
        #expect(bound.clientData == "{\"challenge\":\"chg\"}")
        #expect(bound.hash == HAPISSHA256.hash(Data("{\"challenge\":\"chg\"}".utf8)))
    }

    @Test func attestKeyFailureKeepsPendingKeyForAttestation() async throws {
        let challenge = Data(repeating: 6, count: 32).hapisBase64URLEncoded
        let http = MockHAPISHTTP()
        let keys = InMemoryHAPISAttestKeyStore()
        let service = MockHAPISAppAttestService()
        service.attestError = HAPISConsumerError.attestFailed("simulated")
        http.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.hasSuffix("/v1/consumer/challenge") {
                return (200, challengeJSON(challenge))
            }
            Issue.record("attestKey failure must not POST sessions")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISAppAttestProvider(service: service, keyStore: keys)
        )
        await #expect(throws: HAPISConsumerError.attestFailed("simulated")) {
            _ = try await client.validToken()
        }
        #expect(try keys.load(issuer: issuer)?.keyId == "test-key-id")
        #expect(try keys.load(issuer: issuer)?.registered == false)
        #expect(try keys.load(issuer: issuer)?.attested == false)
        #expect(service.generateKeyCount == 1)
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/sessions") }.isEmpty)

        service.attestError = nil
        http.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.hasSuffix("/v1/consumer/challenge") {
                return (200, challengeJSON(challenge))
            }
            if request.httpMethod == "POST", path.hasSuffix("/v1/consumer/sessions") {
                let attest = attestObject(request.httpBody)
                #expect(attest?["key_id"] as? String == "test-key-id")
                #expect(attest?["attestation"] != nil)
                #expect(attest?["assertion"] == nil)
                return (201, tokenJSON(token: "recovered", now: Date(), refreshIn: 3300, expiresIn: 3600))
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        #expect(try await client.validToken() == "recovered")
        #expect(service.generateKeyCount == 1)
        #expect(try keys.load(issuer: issuer)?.registered == true)
    }

    @Test func sessionsFailureDoesNotMarkKeyAssertionReady() async throws {
        let challenge = Data(repeating: 7, count: 32).hapisBase64URLEncoded
        let http = MockHAPISHTTP()
        let keys = InMemoryHAPISAttestKeyStore()
        let service = MockHAPISAppAttestService()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/consumer/challenge") {
                return (200, challengeJSON(challenge))
            }
            if path.hasSuffix("/v1/consumer/sessions") {
                return (503, #"{"error":{"code":"unavailable"}}"#)
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISAppAttestProvider(service: service, keyStore: keys)
        )
        await #expect(throws: HAPISConsumerError.self) {
            _ = try await client.validToken()
        }
        #expect(try keys.load(issuer: issuer)?.registered == false)
        #expect(try keys.load(issuer: issuer)?.attested == true)

        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/consumer/challenge") {
                return (200, challengeJSON(challenge))
            }
            if path.hasSuffix("/v1/consumer/sessions") {
                let attest = attestObject(request.httpBody)
                #expect(attest?["attestation"] != nil)
                #expect(attest?["assertion"] == nil)
                return (201, tokenJSON(token: "after-sessions-fail", now: Date(), refreshIn: 3300, expiresIn: 3600))
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        #expect(try await client.validToken() == "after-sessions-fail")
        #expect(try keys.load(issuer: issuer)?.registered == true)
        #expect(service.assertionCalls.isEmpty)
    }

    @Test func mintRetriesSessionsWithFreshChallenge() async throws {
        let challenge1 = Data(repeating: 8, count: 32).hapisBase64URLEncoded
        let challenge2 = Data(repeating: 9, count: 32).hapisBase64URLEncoded
        let challenges = Counter()
        let sessions = Counter()
        let http = MockHAPISHTTP()
        let keys = InMemoryHAPISAttestKeyStore()
        let service = MockHAPISAppAttestService()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/consumer/challenge") {
                let n = challenges.increment()
                return (200, challengeJSON(n == 1 ? challenge1 : challenge2))
            }
            if path.hasSuffix("/v1/consumer/sessions") {
                let n = sessions.increment()
                let attest = attestObject(request.httpBody)
                if n == 1 {
                    #expect(attest?["challenge"] as? String == challenge1)
                    return (503, #"{"error":{"code":"unavailable"}}"#)
                }
                #expect(attest?["challenge"] as? String == challenge2)
                #expect(attest?["attestation"] != nil)
                return (
                    201,
                    tokenJSON(token: "fresh-evidence", now: Date(), refreshIn: 3300, expiresIn: 3600)
                )
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISAppAttestProvider(service: service, keyStore: keys)
        )
        #expect(try await client.validToken() == "fresh-evidence")
        #expect(challenges.value >= 2)
        #expect(sessions.value == 2)
        #expect(service.attestCalls.count == 2)
        #expect(service.generateKeyCount == 2)
    }

    @Test func issuerChangeDuringChallengeKeepsOneOrigin() async throws {
        let issuerA = URL(string: "https://issuer-a.example.test")!
        let issuerB = URL(string: "https://issuer-b.example.test")!
        let issuerRef = IssuerRef(issuerA)
        let challenge = Data(repeating: 10, count: 32).hapisBase64URLEncoded
        let http = MockHAPISHTTP()
        let keys = InMemoryHAPISAttestKeyStore()
        let service = MockHAPISAppAttestService()
        http.handler = { request in
            let host = request.url?.host ?? ""
            let path = request.url?.path ?? ""
            #expect(host == "issuer-a.example.test")
            if path.hasSuffix("/v1/consumer/challenge") {
                issuerRef.url = issuerB
                return (200, challengeJSON(challenge))
            }
            if path.hasSuffix("/v1/consumer/sessions") {
                return (
                    201,
                    tokenJSON(token: "origin-a", now: Date(), refreshIn: 3300, expiresIn: 3600)
                )
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuerRef.url },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock(),
            attestation: HAPISAppAttestProvider(service: service, keyStore: keys)
        )
        #expect(try await client.validToken() == "origin-a")
        #expect(try keys.load(issuer: issuerA)?.keyId == "test-key-id")
        #expect(try keys.load(issuer: issuerB) == nil)
        #expect(http.calls.allSatisfy { $0.host == "issuer-a.example.test" })
    }

    @Test func legacyKeyIdIsUnregisteredAndUnattested() {
        let record = HAPISAttestKeyRecordCodec.decode(Data("legacy-key".utf8))
        #expect(record == HAPISAttestKeyRecord(keyId: "legacy-key", registered: false, attested: false))
        #expect(HAPISIssuer.attestKeyAccount(for: issuer).hasPrefix("hapis.example.test|"))
        #if DEBUG
            #expect(HAPISIssuer.attestEnvironment == "development")
        #else
            #expect(HAPISIssuer.attestEnvironment == "production")
        #endif
        #expect(HAPISIssuer.storageAccount(for: issuer) == "hapis.example.test")
        #expect(HAPISIssuer.attestKeyAccount(for: issuer) != HAPISIssuer.storageAccount(for: issuer))
    }
}

private func challengeJSON(_ challenge: String) -> String {
    "{\"challenge\":\"\(challenge)\",\"expires_in\":300,\"expires_at\":\"2026-09-09T16:00:00.000Z\"}"
}

private func tokenJSON(token: String, now: Date, refreshIn: Int, expiresIn: Int) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expires = formatter.string(from: now.addingTimeInterval(TimeInterval(expiresIn)))
    let refresh = formatter.string(from: now.addingTimeInterval(TimeInterval(refreshIn)))
    return """
        {"token":"\(token)","token_type":"Bearer","expires_in":\(expiresIn),"expires_at":"\(expires)","refresh_at":"\(refresh)","refresh_in":\(refreshIn),"ttl_seconds":\(expiresIn),"subject":"stub:test","attest_mode":"stub"}
        """
}

private func jsonObject(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func attestObject(_ data: Data?) -> [String: Any]? {
    jsonObject(data)?["attest"] as? [String: Any]
}

final class MockHAPISAppAttestService: HAPISAppAttestServicing, @unchecked Sendable {
    var isSupported = true
    var generateKeyResult = "test-key-id"
    var attestResult = Data("attest-cbor".utf8)
    var assertionResult = Data("assert-cbor".utf8)
    var generateKeyCount = 0
    var attestCalls: [(keyId: String, hash: Data)] = []
    var assertionCalls: [(keyId: String, hash: Data)] = []
    var assertionError: Error?
    var attestError: Error?

    func generateKey() async throws -> String {
        generateKeyCount += 1
        return generateKeyResult
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        attestCalls.append((keyId, clientDataHash))
        if let attestError {
            throw attestError
        }
        return attestResult
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        assertionCalls.append((keyId, clientDataHash))
        if let assertionError {
            throw assertionError
        }
        return assertionResult
    }
}
