import Foundation

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let redirectDelegate: AccessRedirectDelegate?
    private let cache: ResponseCache
    private let hapis: HAPISConsumerClient
    private var pinnedCodes: Set<String> = []

    init(
        session: URLSession? = nil, cache: ResponseCache = .shared, hapis: HAPISConsumerClient? = nil
    ) {
        self.cache = cache
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            let delegate = AccessRedirectDelegate()
            redirectDelegate = delegate
            self.session = URLSession(
                configuration: config, delegate: delegate, delegateQueue: nil)
        }
        decoder = JSONDecoder()
        self.hapis = hapis ?? HAPISConsumerClient(
            issuerURL: { APIConfiguration.hapisIssuerURL },
            session: URLSession(configuration: .ephemeral),
            store: Self.makeTokenStore()
        )
    }

    func clearHAPISConsumerToken() async {
        await hapis.invalidate()
    }

    private static func makeTokenStore() -> any HAPISTokenStoring {
        #if canImport(Security)
            return KeychainHAPISTokenStore()
        #else
            return InMemoryHAPISTokenStore()
        #endif
    }

    func setPinnedCodes(_ codes: Set<String>) {
        pinnedCodes = codes
    }

    func pinCode(_ code: String) {
        pinnedCodes.insert(code)
    }

    func unpinCode(_ code: String) {
        pinnedCodes.remove(code)
    }

    func searchCompanies(query: String) async throws -> [CompanyHit] {
        var components = URLComponents(url: path("v1/companies"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw APIClientError.badURL }
        return try await get(url)
    }

    func feedUpdates() async throws -> FeedUpdatesResponse {
        try await get(path("v1/feed/updates"))
    }

    /// 未設定・Worker 未到達の 503 は空ランキングとして扱う。
    func feedTrend() async throws -> FeedTrendResponse {
        do {
            return try await get(path("v1/feed/trend"))
        } catch APIClientError.http(let status, _) where status == 503 {
            return FeedTrendResponse(schemaVersion: 1, date: "", days: 7, items: [])
        }
    }

    func cachedFinancials(code: String) async -> FinancialsResponse? {
        await peek(path("v1/companies/\(code)/financials"))
    }

    func cachedWaterfall(code: String) async -> FinancialsResponse? {
        await peek(path("v1/companies/\(code)/waterfall"))
    }

    func cachedOverview(code: String) async -> CompanyOverviewResponse? {
        await peek(path("v1/companies/\(code)/overview"))
    }

    func financials(code: String) async throws -> FinancialsResponse {
        try await get(path("v1/companies/\(code)/financials"), cacheTTL: ttl(for: code))
    }

    func waterfall(code: String) async throws -> FinancialsResponse {
        try await get(path("v1/companies/\(code)/waterfall"), cacheTTL: ttl(for: code))
    }

    func overview(code: String) async throws -> CompanyOverviewResponse {
        try await get(path("v1/companies/\(code)/overview"), cacheTTL: ttl(for: code))
    }

    func prefetchAnalysis(codes: [String]) async {
        for code in codes {
            _ = try? await financials(code: code)
            _ = try? await waterfall(code: code)
            _ = try? await overview(code: code)
        }
    }

    private func ttl(for code: String) -> TimeInterval {
        pinnedCodes.contains(code) ? ResponseCache.watchlistTTL : ResponseCache.analysisTTL
    }

    private func path(_ suffix: String) -> URL {
        APIConfiguration.baseURL.appending(path: suffix)
    }

    private func peek<T: Decodable>(_ url: URL) async -> T? {
        let key = ResponseCache.key(for: url)
        guard let data = await cache.load(key: key, maxAge: nil) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ url: URL, cacheTTL: TimeInterval? = nil) async throws -> T {
        let key = ResponseCache.key(for: url)
        if let cacheTTL, let data = await cache.load(key: key, maxAge: cacheTTL),
            let decoded = try? decoder.decode(T.self, from: data)
        {
            return decoded
        }
        do {
            let data = try await fetchData(url)
            do {
                let decoded = try decoder.decode(T.self, from: data)
                if cacheTTL != nil {
                    await cache.store(key: key, data: data)
                }
                return decoded
            } catch {
                throw APIClientError.decoding(error)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let clientError = error as? APIClientError, case .http(let status, _) = clientError,
                status == 404
            {
                if cacheTTL != nil {
                    await cache.remove(key: key)
                }
                throw clientError
            }
            if cacheTTL != nil, let data = await cache.load(key: key, maxAge: nil),
                let decoded = try? decoder.decode(T.self, from: data)
            {
                return decoded
            }
            throw error
        }
    }

    private func fetchData(_ url: URL, hapisRemintAttempted: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 段階 A: `api.sollahiro.com` だけ Access Cookie。段階 B stub: HAPIS ゲートウェイだけ
        // 制御面で mint した consumer JWT を Bearer に付ける（ハードコードしない）。
        // loopback / LAN `http` はどちらも付けない。
        if AccessSession.usesAccess(url) {
            if let jwt = AccessSession.jwt(for: url) {
                if AccessSession.isExpired(jwt) {
                    AccessSession.clear(for: url)
                    throw APIClientError.needsAccessLogin
                }
                request.setValue(
                    "\(AccessSession.cookieName)=\(jwt)", forHTTPHeaderField: "Cookie")
            }
        } else if APIConfiguration.usesHAPISConsumer(url) {
            do {
                request = try await hapis.authorize(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw APIClientError.hapisUnavailable
            }
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIClientError.transport(error)
        }
        let http = response as? HTTPURLResponse
        if let http, AccessChallenge.isChallenge(http) {
            throw APIClientError.needsAccessLogin
        }
        let status = http?.statusCode ?? 0
        if status == 401, APIConfiguration.usesHAPISConsumer(url), !hapisRemintAttempted {
            let expired = GatewayErrorBody.parse(data)?.isTokenExpired == true
            if expired || request.value(forHTTPHeaderField: "Authorization") != nil {
                do {
                    _ = try await hapis.forceRemint()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw APIClientError.hapisUnavailable
                }
                return try await fetchData(url, hapisRemintAttempted: true)
            }
        }
        if status == 404 {
            let message = httpErrorMessage(data, fallback: "見つかりません")
            throw APIClientError.http(status: 404, message: message)
        }
        if status == 503 {
            let message = httpErrorMessage(data, fallback: "サービスを利用できません")
            throw APIClientError.http(status: 503, message: message)
        }
        guard (200..<300).contains(status) else {
            let message = httpErrorMessage(data, fallback: "HTTP \(status)")
            throw APIClientError.http(status: status, message: message)
        }
        return data
    }

    private func httpErrorMessage(_ data: Data, fallback: String) -> String {
        if let body = GatewayErrorBody.parse(data), let message = body.message, !message.isEmpty {
            return message
        }
        return (try? decoder.decode(APIErrorBody.self, from: data))?.error ?? fallback
    }
}
