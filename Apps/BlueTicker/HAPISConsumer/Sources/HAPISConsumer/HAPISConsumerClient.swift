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
    private var inFlight: Task<String, Error>?
    private var epoch = 0
    private var remintEpoch: Int?
    private let controlPlaneAttempts = 3

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
        try await coalescedResolve()
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
        epoch += 1
        remintEpoch = nil
        store.clear(issuer: issuerURL())
        inFlight = nil
    }

    @discardableResult
    func forceRemint() async throws -> String {
        if let remintEpoch, remintEpoch == epoch, let inFlight {
            return try await inFlight.value
        }
        epoch += 1
        let ticket = epoch
        remintEpoch = ticket
        store.clear(issuer: issuerURL())
        let task = Task {
            try await self.resolveToken(ticket: ticket)
        }
        inFlight = task
        let result = await task.result
        if epoch == ticket {
            inFlight = nil
            remintEpoch = nil
        }
        return try result.get()
    }

    func storedToken() throws -> HAPISConsumerToken? {
        try store.load(issuer: issuerURL())
    }

    private func coalescedResolve() async throws -> String {
        if let inFlight {
            return try await inFlight.value
        }
        let ticket = epoch
        let task = Task {
            try await self.resolveToken(ticket: ticket)
        }
        inFlight = task
        let result = await task.result
        if epoch == ticket {
            inFlight = nil
        }
        return try result.get()
    }

    private func resolveToken(ticket: Int) async throws -> String {
        try Task.checkCancellation()
        guard ticket == epoch else { throw CancellationError() }
        let issuer = issuerURL()
        let now = clock.now
        if let stored = try store.load(issuer: issuer) {
            if stored.isExpired(at: now) {
                store.clear(issuer: issuer)
                return try await mint(ticket: ticket)
            }
            if stored.needsRefresh(at: now) {
                do {
                    return try await refresh(stored.token, ticket: ticket)
                } catch HAPISConsumerError.tokenExpired {
                    store.clear(issuer: issuer)
                    return try await mint(ticket: ticket)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if stored.isExpired(at: clock.now) {
                        throw error
                    }
                    return stored.token
                }
            }
            return stored.token
        }
        return try await mint(ticket: ticket)
    }

    private func mint(ticket: Int) async throws -> String {
        try Task.checkCancellation()
        guard ticket == epoch else { throw CancellationError() }
        let issuer = issuerURL()
        let token = try await withControlPlaneRetry {
            try Task.checkCancellation()
            guard ticket == self.epoch else { throw CancellationError() }
            var request = URLRequest(url: try self.endpoint("v1/consumer/sessions", issuer: issuer))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload = try await self.attestation.payloadForMint(issuer: issuer) {
                try await self.fetchChallenge(issuer: issuer, ticket: ticket)
            }
            request.httpBody = try HAPISJSON.encoder.encode(HAPISMintRequest(attest: payload))
            let data = try await self.controlPlaneDataOnce(request, expected: [201, 200])
            do {
                let decoded = try HAPISJSON.decoder.decode(
                    HAPISConsumerTokenResponse.self, from: data)
                return try decoded.materialize(now: self.clock.now)
            } catch let error as HAPISConsumerError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw HAPISConsumerError.decoding(error.localizedDescription)
            }
        }
        guard ticket == epoch else { throw CancellationError() }
        try store.save(token, issuer: issuer)
        try await attestation.noteMintAccepted(issuer: issuer)
        return token.token
    }

    private func fetchChallenge(issuer: URL, ticket: Int) async throws -> HAPISChallenge {
        try Task.checkCancellation()
        guard ticket == epoch else { throw CancellationError() }
        var request = URLRequest(url: try endpoint("v1/consumer/challenge", issuer: issuer))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let challengeRequest = request
        return try await withControlPlaneRetry {
            try Task.checkCancellation()
            guard ticket == self.epoch else { throw CancellationError() }
            let data = try await self.controlPlaneDataOnce(challengeRequest, expected: [200])
            do {
                let decoded = try HAPISJSON.decoder.decode(HAPISChallenge.self, from: data)
                let trimmed = decoded.challenge.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw HAPISConsumerError.decoding("challenge が空です")
                }
                return HAPISChallenge(
                    challenge: trimmed, expiresIn: decoded.expiresIn, expiresAt: decoded.expiresAt)
            } catch let error as HAPISConsumerError {
                throw error
            } catch {
                throw HAPISConsumerError.decoding(error.localizedDescription)
            }
        }
    }

    private func refresh(_ token: String, ticket: Int) async throws -> String {
        try Task.checkCancellation()
        guard ticket == epoch else { throw CancellationError() }
        let issuer = issuerURL()
        var request = URLRequest(url: try endpoint("v1/consumer/token/refresh", issuer: issuer))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let refreshed = try await send(request, expected: [200])
        guard ticket == epoch else { throw CancellationError() }
        try store.save(refreshed, issuer: issuer)
        return refreshed.token
    }

    private func send(_ request: URLRequest, expected: Set<Int>) async throws -> HAPISConsumerToken
    {
        try await withControlPlaneRetry {
            let data = try await self.controlPlaneDataOnce(request, expected: expected)
            do {
                let decoded = try HAPISJSON.decoder.decode(
                    HAPISConsumerTokenResponse.self, from: data)
                return try decoded.materialize(now: self.clock.now)
            } catch let error as HAPISConsumerError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw HAPISConsumerError.decoding(error.localizedDescription)
            }
        }
    }

    private func withControlPlaneRetry<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error = HAPISConsumerError.transport("empty")
        for attempt in 1...controlPlaneAttempts {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HAPISConsumerError {
                switch error {
                case .tokenExpired, .attestUnavailable:
                    throw error
                case .http(let status, _, _) where (400..<500).contains(status):
                    throw error
                default:
                    lastError = error
                    if attempt == controlPlaneAttempts {
                        throw error
                    }
                }
            } catch {
                lastError = error
                if attempt == controlPlaneAttempts {
                    throw error
                }
            }
        }
        throw lastError
    }

    private func controlPlaneDataOnce(_ request: URLRequest, expected: Set<Int>) async throws
        -> Data
    {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as HAPISConsumerError {
            throw error
        } catch {
            throw HAPISConsumerError.transport(error.localizedDescription)
        }
        if !expected.contains(response.statusCode) {
            throw HAPISConsumerError.from(status: response.statusCode, data: data)
        }
        return data
    }

    private func endpoint(_ suffix: String, issuer: URL) throws -> URL {
        guard let origin = HAPISIssuer.origin(of: issuer) else {
            throw HAPISConsumerError.decoding("発行者 URL は https origin である必要があります")
        }
        return origin.appending(path: suffix)
    }
}
