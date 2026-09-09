import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import HAPISConsumer

@Suite(.serialized)
struct HAPISConsumerClientTests {
    private let issuer = URL(string: "https://hapis.example.test")!
    private let gateway = URL(string: "https://gateway.example.test")!

    @Test func mintStoresTokenAndAuthorizeSetsBearerHeader() async throws {
        let http = MockHAPISHTTP()
        let store = InMemoryHAPISTokenStore()
        http.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/v1/consumer/sessions") {
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return (201, tokenJSON(token: "minted-token", now: Date(), refreshIn: 3300, expiresIn: 3600))
            }
            Issue.record("unexpected \(request.httpMethod ?? "?") \(path)")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: store,
            clock: SystemHAPISClock()
        )

        var request = URLRequest(url: gateway.appending(path: "v1/companies"))
        request = try await client.authorize(request)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer minted-token")
        let stored = try store.load(issuer: issuer)
        #expect(stored?.token == "minted-token")
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/sessions") }.count == 1)
    }

    @Test func refreshBeforeExpiryPostsRefreshWithCurrentBearer() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableHAPISClock(now: now)
        let http = MockHAPISHTTP()
        let store = InMemoryHAPISTokenStore()
        try store.save(
            HAPISConsumerToken(
                token: "old-token",
                tokenType: "Bearer",
                expiresAt: now.addingTimeInterval(3600),
                refreshAt: now.addingTimeInterval(100),
                subject: "stub:old",
                attestMode: "stub"
            ),
            issuer: issuer
        )
        http.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/v1/consumer/token/refresh") {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
                return (
                    200,
                    tokenJSON(
                        token: "refreshed-token", now: now.addingTimeInterval(400), refreshIn: 3300,
                        expiresIn: 3600)
                )
            }
            Issue.record("unexpected \(request.httpMethod ?? "?") \(path)")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: store,
            clock: clock
        )

        #expect(try await client.validToken() == "old-token")
        #expect(http.calls.isEmpty)

        clock.now = now.addingTimeInterval(120)
        #expect(try await client.validToken() == "refreshed-token")
        #expect(try store.load(issuer: issuer)?.token == "refreshed-token")
        #expect(http.calls.map(\.path).filter { $0.hasSuffix("/v1/consumer/token/refresh") }.count == 1)
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/sessions") }.isEmpty)
    }

    @Test func remintsWhenStoredTokenExpired() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableHAPISClock(now: now)
        let http = MockHAPISHTTP()
        let store = InMemoryHAPISTokenStore()
        try store.save(
            HAPISConsumerToken(
                token: "expired-token",
                tokenType: "Bearer",
                expiresAt: now.addingTimeInterval(-10),
                refreshAt: now.addingTimeInterval(-310),
                subject: "stub:expired",
                attestMode: "stub"
            ),
            issuer: issuer
        )
        http.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/v1/consumer/sessions") {
                return (201, tokenJSON(token: "new-token", now: now, refreshIn: 3300, expiresIn: 3600))
            }
            Issue.record("refresh must not run for an already-expired token")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: store,
            clock: clock
        )

        var request = URLRequest(url: gateway.appending(path: "v1/companies"))
        request = try await client.authorize(request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
        #expect(try store.load(issuer: issuer)?.token == "new-token")
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/sessions") }.count == 1)
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/token/refresh") }.isEmpty)
    }

    @Test func remintsWhenRefreshReturnsTokenExpired() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableHAPISClock(now: now)
        let http = MockHAPISHTTP()
        let store = InMemoryHAPISTokenStore()
        try store.save(
            HAPISConsumerToken(
                token: "stale-token",
                tokenType: "Bearer",
                expiresAt: now.addingTimeInterval(60),
                refreshAt: now.addingTimeInterval(-1),
                subject: "stub:stale",
                attestMode: "stub"
            ),
            issuer: issuer
        )
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/consumer/token/refresh") {
                return (401, #"{"error":{"code":"token_expired","message":"token expired"}}"#)
            }
            if path.hasSuffix("/v1/consumer/sessions") {
                return (201, tokenJSON(token: "reminted-token", now: now, refreshIn: 3300, expiresIn: 3600))
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: store,
            clock: clock
        )

        #expect(try await client.validToken() == "reminted-token")
        #expect(http.calls.map(\.path).contains { $0.hasSuffix("/v1/consumer/token/refresh") })
        #expect(http.calls.map(\.path).contains { $0.hasSuffix("/v1/consumer/sessions") })
    }

    @Test func urlProtocolMintThenAuthenticatedGatewayRequest() async throws {
        let minted = tokenJSON(token: "proto-token", now: Date(), refreshIn: 3300, expiresIn: 3600)
        MockURLProtocol.router = { request in
            let path = request.url?.path ?? ""
            let host = request.url?.host ?? ""
            if host == "hapis.example.test", path.hasSuffix("/v1/consumer/sessions") {
                return MockURLProtocol.Stub(status: 201, body: minted)
            }
            if host == "gateway.example.test" {
                let auth = request.value(forHTTPHeaderField: "Authorization")
                #expect(auth == "Bearer proto-token")
                return MockURLProtocol.Stub(
                    status: 200, body: #"[{"code":"7203","name":"トヨタ自動車株式会社"}]"#)
            }
            return MockURLProtocol.Stub(status: 404, body: #"{"error":{"code":"not_found"}}"#)
        }
        defer { MockURLProtocol.router = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let store = InMemoryHAPISTokenStore()
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            session: session,
            store: store
        )

        var request = URLRequest(url: gateway.appending(path: "v1/companies"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request = try await client.authorize(request)
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("7203") == true)
        #expect(try store.load(issuer: issuer)?.token == "proto-token")
    }

    @Test func loopbackAndAccessHostsDoNotUseConsumerAuth() {
        let gateway = URL(string: "https://hapis-blue-ticker-production.sollahiro.workers.dev")!
        #expect(
            HAPISConsumerAuth.applies(
                to: URL(string: "https://hapis-blue-ticker-production.sollahiro.workers.dev/v1/companies")!,
                gatewayBases: [gateway]
            ))
        #expect(
            !HAPISConsumerAuth.applies(
                to: URL(string: "http://127.0.0.1:3000/v1/companies")!,
                gatewayBases: [gateway]
            ))
        #expect(
            !HAPISConsumerAuth.applies(
                to: URL(string: "http://192.168.1.8:3000/v1/companies")!,
                gatewayBases: [gateway]
            ))
        #expect(
            !HAPISConsumerAuth.applies(
                to: URL(string: "https://api.sollahiro.com/v1/companies")!,
                gatewayBases: [gateway]
            ))
        let preview = URL(string: "https://hapis-blue-ticker-preview.sollahiro.workers.dev")!
        #expect(
            !HAPISConsumerAuth.applies(
                to: URL(string: "https://hapis-blue-ticker-preview.sollahiro.workers.dev/v1/companies")!,
                gatewayBases: [gateway]
            ))
        #expect(
            HAPISConsumerAuth.applies(
                to: URL(string: "https://hapis-blue-ticker-preview.sollahiro.workers.dev/v1/companies")!,
                gatewayBases: [preview]
            ))
        #expect(
            !HAPISConsumerAuth.applies(
                to: URL(string: "https://hapis.sollahiro.workers.dev/v1/consumer/sessions")!,
                gatewayBases: [gateway]
            ))
        #expect(HAPISIssuer.origin(of: URL(string: "http://hapis.example.test")!) == nil)
        #expect(
            HAPISIssuer.origin(of: URL(string: "https://hapis.example.test/v1/foo?x=1")!)
                == URL(string: "https://hapis.example.test"))
    }

    @Test func concurrentValidTokenMintsOnce() async throws {
        let http = MockHAPISHTTP()
        let store = InMemoryHAPISTokenStore()
        let sessions = Counter()
        http.delayNanoseconds = 80_000_000
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/consumer/sessions") {
                sessions.increment()
                return (201, tokenJSON(token: "shared-token", now: Date(), refreshIn: 3300, expiresIn: 3600))
            }
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: store,
            clock: SystemHAPISClock()
        )
        async let a = client.validToken()
        async let b = client.validToken()
        async let c = client.validToken()
        let tokens = try await [a, b, c]
        #expect(Set(tokens) == ["shared-token"])
        #expect(sessions.value == 1)
    }

    @Test func refreshTransportFailureKeepsUnexpiredToken() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableHAPISClock(now: now)
        let http = MockHAPISHTTP()
        let store = InMemoryHAPISTokenStore()
        try store.save(
            HAPISConsumerToken(
                token: "still-valid",
                tokenType: "Bearer",
                expiresAt: now.addingTimeInterval(3600),
                refreshAt: now.addingTimeInterval(-1),
                subject: "stub:still",
                attestMode: "stub"
            ),
            issuer: issuer
        )
        http.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/consumer/token/refresh") {
                return (503, #"{"error":{"code":"unavailable"}}"#)
            }
            Issue.record("must not remint while stored token is unexpired")
            return (500, #"{"error":{"code":"unexpected"}}"#)
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: store,
            clock: clock
        )
        #expect(try await client.validToken() == "still-valid")
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/token/refresh") }.count == 3)
        #expect(http.calls.filter { $0.path.hasSuffix("/v1/consumer/sessions") }.isEmpty)
    }

    @Test func issuerChangeDoesNotReuseOtherIssuerToken() async throws {
        let store = InMemoryHAPISTokenStore()
        let issuerA = URL(string: "https://issuer-a.example.test")!
        let issuerB = URL(string: "https://issuer-b.example.test")!
        let now = Date()
        try store.save(
            HAPISConsumerToken(
                token: "token-a",
                tokenType: "Bearer",
                expiresAt: now.addingTimeInterval(3600),
                refreshAt: now.addingTimeInterval(3300),
                subject: "stub:a",
                attestMode: "stub"
            ),
            issuer: issuerA
        )
        let issuerRef = IssuerRef(issuerA)
        let http = MockHAPISHTTP()
        http.handler = { request in
            #expect(request.url?.host == "issuer-b.example.test")
            return (201, tokenJSON(token: "token-b", now: Date(), refreshIn: 3300, expiresIn: 3600))
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuerRef.url },
            http: http,
            store: store,
            clock: SystemHAPISClock()
        )
        #expect(try await client.validToken() == "token-a")
        issuerRef.url = issuerB
        #expect(try await client.validToken() == "token-b")
        #expect(try store.load(issuer: issuerA)?.token == "token-a")
        #expect(try store.load(issuer: issuerB)?.token == "token-b")
    }

    @Test func cancelledMintSurfacesCancellationError() async throws {
        let http = MockHAPISHTTP()
        http.throwsCancellation = true
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock()
        )
        await #expect(throws: CancellationError.self) {
            _ = try await client.validToken()
        }
    }

    @Test func urlSessionCancelledErrorIsNotTransport() async throws {
        MockURLProtocol.failWith = URLError(.cancelled)
        defer {
            MockURLProtocol.failWith = nil
            MockURLProtocol.router = nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let http = URLSessionHAPISHTTP(session: session)
        var request = URLRequest(url: issuer.appending(path: "v1/consumer/sessions"))
        request.httpMethod = "POST"
        await #expect(throws: CancellationError.self) {
            _ = try await http.data(for: request)
        }
    }

    @Test func mintRetriesTransientControlPlaneFailures() async throws {
        let http = MockHAPISHTTP()
        let attempts = Counter()
        http.handler = { request in
            guard (request.url?.path ?? "").hasSuffix("/v1/consumer/sessions") else {
                return (500, #"{"error":{"code":"unexpected"}}"#)
            }
            let n = attempts.increment()
            if n < 3 {
                return (503, #"{"error":{"code":"unavailable"}}"#)
            }
            return (201, tokenJSON(token: "after-retry", now: Date(), refreshIn: 3300, expiresIn: 3600))
        }
        let client = HAPISConsumerClient(
            issuerURL: { issuer },
            http: http,
            store: InMemoryHAPISTokenStore(),
            clock: SystemHAPISClock()
        )
        #expect(try await client.validToken() == "after-retry")
        #expect(attempts.value == 3)
    }
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

final class MockHAPISHTTP: HAPISHTTPPerforming, @unchecked Sendable {
    struct Call: Sendable {
        var method: String
        var path: String
        var authorization: String?
    }

    private(set) var calls: [Call] = []
    var delayNanoseconds: UInt64 = 0
    var throwsCancellation = false
    var handler: @Sendable (URLRequest) -> (Int, String) = { _ in
        (500, #"{"error":{"code":"unset"}}"#)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if throwsCancellation {
            throw CancellationError()
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        calls.append(
            Call(
                method: request.httpMethod ?? "GET",
                path: request.url?.path ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
        )
        let (status, json) = handler(request)
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), response)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

final class IssuerRef: @unchecked Sendable {
    var url: URL
    init(_ url: URL) { self.url = url }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var body: String
    }

    nonisolated(unsafe) static var router: (@Sendable (URLRequest) -> Stub)?
    nonisolated(unsafe) static var failWith: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let failWith = Self.failWith {
            client?.urlProtocol(self, didFailWithError: failWith)
            return
        }
        guard let router = Self.router else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = router(request)
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
