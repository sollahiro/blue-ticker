import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HAPIS 制御面で consumer JWT を mint / refresh する。blt-server には送らない。
/// トークンは発行応答からだけ取る。`HAPIS_API_TOKEN` や固定 Bearer は使わない。
actor HAPISConsumerClient {
    private let issuerURL: @Sendable () -> URL
    private let http: any HAPISHTTPPerforming
    private let store: any HAPISTokenStoring
    private let clock: any HAPISClock
    private let attestation: any HAPISAttestationProviding

    init(
        issuerURL: @escaping @Sendable () -> URL,
        http: any HAPISHTTPPerforming,
        store: any HAPISTokenStoring,
        clock: any HAPISClock = SystemHAPISClock(),
        attestation: any HAPISAttestationProviding = HAPISStubAttestationProvider()
    ) {
        self.issuerURL = issuerURL
        self.http = http
        self.store = store
        self.clock = clock
        self.attestation = attestation
    }

    init(
        issuerURL: @escaping @Sendable () -> URL,
        session: URLSession,
        store: any HAPISTokenStoring,
        clock: any HAPISClock = SystemHAPISClock(),
        attestation: any HAPISAttestationProviding = HAPISStubAttestationProvider()
    ) {
        self.init(
            issuerURL: issuerURL,
            http: URLSessionHAPISHTTP(session: session),
            store: store,
            clock: clock,
            attestation: attestation
        )
    }

    func validToken() async throws -> String {
        let now = clock.now
        if let stored = try store.load() {
            if stored.isExpired(at: now) {
                store.clear()
                return try await mint()
            }
            if stored.needsRefresh(at: now) {
                do {
                    return try await refresh(stored.token)
                } catch HAPISConsumerError.tokenExpired {
                    store.clear()
                    return try await mint()
                }
            }
            return stored.token
        }
        return try await mint()
    }

    func authorizationHeaderValue() async throws -> String {
        let token = try await validToken()
        return "Bearer \(token)"
    }

    func authorize(_ request: URLRequest) async throws -> URLRequest {
        var copy = request
        copy.setValue(try await authorizationHeaderValue(), forHTTPHeaderField: "Authorization")
        return copy
    }

    func invalidate() {
        store.clear()
    }

    @discardableResult
    func forceRemint() async throws -> String {
        store.clear()
        return try await mint()
    }

    func storedToken() throws -> HAPISConsumerToken? {
        try store.load()
    }

    private func mint() async throws -> String {
        var request = URLRequest(url: endpoint("v1/consumer/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = try await attestation.payloadForMint()
        request.httpBody = try HAPISJSON.encoder.encode(HAPISMintRequest(attest: payload))
        let token = try await send(request, expected: [201, 200])
        try store.save(token)
        return token.token
    }

    private func refresh(_ token: String) async throws -> String {
        var request = URLRequest(url: endpoint("v1/consumer/token/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let refreshed = try await send(request, expected: [200])
        try store.save(refreshed)
        return refreshed.token
    }

    private func send(_ request: URLRequest, expected: Set<Int>) async throws -> HAPISConsumerToken
    {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch let error as HAPISConsumerError {
            throw error
        } catch {
            throw HAPISConsumerError.transport(error.localizedDescription)
        }
        if !expected.contains(response.statusCode) {
            throw HAPISConsumerError.from(status: response.statusCode, data: data)
        }
        do {
            let decoded = try HAPISJSON.decoder.decode(HAPISConsumerTokenResponse.self, from: data)
            return try decoded.materialize(now: clock.now)
        } catch let error as HAPISConsumerError {
            throw error
        } catch {
            throw HAPISConsumerError.decoding(error.localizedDescription)
        }
    }

    private func endpoint(_ suffix: String) -> URL {
        issuerURL().appending(path: suffix)
    }
}
