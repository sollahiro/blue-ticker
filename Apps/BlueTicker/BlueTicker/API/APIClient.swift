import Foundation

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let redirectDelegate: AccessRedirectDelegate?
    private let cache: ResponseCache
    private let hapis: HAPISConsumerClient
    private let originGate: HAPISOriginGate
    private var pinnedCodes: Set<String> = []
    private var inFlightGets: [String: Task<Data, Error>] = [:]

    init(
        session: URLSession? = nil,
        cache: ResponseCache = .shared,
        hapis: HAPISConsumerClient? = nil,
        originGate: HAPISOriginGate = HAPISOriginGate()
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
        self.originGate = originGate
        self.hapis = hapis ?? HAPISConsumerClient(
            issuerURL: { APIConfiguration.hapisIssuerURL },
            session: URLSession(configuration: .ephemeral),
            store: Self.makeTokenStore(),
            attestation: HAPISAttestClientMode.make(
                mode: APIConfiguration.hapisAttestClientMode
            )
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

    /// `GET /v1/screen`。検索はキャッシュしない。業種 0 件は全業種。2 件以上は完全一致を順に叩き、ROIC 降順で 50 件にまとめる（サーバーは `sector` 1 件）。
    func screen(sectors: [String], filters: [ScreenMetricFilter]) async throws -> ScreenResponse {
        let targets: [String?] =
            sectors.isEmpty ? [nil] : sectors.map { Optional($0) }
        if targets.count == 1 {
            return try await screenOnce(sector: targets[0], filters: filters)
        }
        var byCode: [String: ScreenItem] = [:]
        var matched = 0
        var sort = ScreenSort(key: "roic", order: "desc")
        for sector in targets {
            let page = try await screenOnce(sector: sector, filters: filters)
            matched += page.matched
            sort = page.sort
            for item in page.items where byCode[item.code] == nil {
                byCode[item.code] = item
            }
        }
        let items = Array(
            byCode.values.sorted { ($0.roic ?? -.infinity) > ($1.roic ?? -.infinity) }.prefix(50))
        return ScreenResponse(
            items: items, returned: items.count, matched: matched, sort: sort)
    }

    private func screenOnce(sector: String?, filters: [ScreenMetricFilter]) async throws
        -> ScreenResponse
    {
        var items = [
            URLQueryItem(name: "sort", value: "roic"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        if let sector, !sector.isEmpty {
            items.append(URLQueryItem(name: "sector", value: sector))
        }
        for filter in filters {
            if let min = filter.min {
                items.append(URLQueryItem(name: "\(filter.key)_min", value: Self.queryNumber(min)))
            }
            if let max = filter.max {
                items.append(URLQueryItem(name: "\(filter.key)_max", value: Self.queryNumber(max)))
            }
        }
        var components = URLComponents(url: path("v1/screen"), resolvingAgainstBaseURL: false)
        components?.queryItems = items
        guard let url = components?.url else { throw APIClientError.badURL }
        return try await get(url)
    }

    private static func queryNumber(_ value: Double) -> String {
        if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
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
            guard !Task.isCancelled else { return }
            if await originGate.isCoolingDown() { return }
            if await prefetchFailedRateLimit({
                let _: FinancialsResponse = try await get(
                    path("v1/companies/\(code)/financials"),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
            if await prefetchFailedRateLimit({
                let _: FinancialsResponse = try await get(
                    path("v1/companies/\(code)/waterfall"),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
            if await prefetchFailedRateLimit({
                let _: CompanyOverviewResponse = try await get(
                    path("v1/companies/\(code)/overview"),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
        }
    }

    private func prefetchFailedRateLimit(_ run: () async throws -> Void) async -> Bool {
        do {
            try await run()
            return false
        } catch is CancellationError {
            return true
        } catch APIClientError.http(let status, _) where status == 429 {
            return true
        } catch {
            return false
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

    private func get<T: Decodable>(
        _ url: URL,
        cacheTTL: TimeInterval? = nil,
        hapisClass: HAPISOriginGate.RequestClass = .interactive
    ) async throws -> T {
        let key = ResponseCache.key(for: url)
        if let cacheTTL, let data = await cache.load(key: key, maxAge: cacheTTL),
            let decoded = try? decoder.decode(T.self, from: data)
        {
            return decoded
        }
        do {
            let data = try await fetchCoalesced(url, hapisClass: hapisClass)
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
            if let clientError = error as? APIClientError, case .http(let status, _) = clientError {
                if status == 404 {
                    if cacheTTL != nil {
                        await cache.remove(key: key)
                    }
                    throw clientError
                }
                // 429 を stale cache で握りつぶすと先読みが止まらない。
                if status == 429 {
                    throw clientError
                }
            }
            if cacheTTL != nil, let data = await cache.load(key: key, maxAge: nil),
                let decoded = try? decoder.decode(T.self, from: data)
            {
                return decoded
            }
            throw error
        }
    }

    private func fetchCoalesced(
        _ url: URL,
        hapisClass: HAPISOriginGate.RequestClass
    ) async throws -> Data {
        let key = "\(ResponseCache.key(for: url))|\(hapisClass)"
        if let existing = inFlightGets[key] {
            return try await existing.value
        }
        let task = Task {
            try await self.fetchWithGate(url, hapisClass: hapisClass)
        }
        inFlightGets[key] = task
        do {
            let data = try await task.value
            inFlightGets[key] = nil
            return data
        } catch {
            inFlightGets[key] = nil
            throw error
        }
    }

    /// HAPIS は同時 1 本。interactive の 429 はクールダウンのあと 1 回だけやり直す。
    private func fetchWithGate(
        _ url: URL,
        hapisClass: HAPISOriginGate.RequestClass
    ) async throws -> Data {
        guard APIConfiguration.usesHAPISConsumer(url) else {
            return try await fetchData(url, hapisClass: hapisClass)
        }
        do {
            return try await originGate.withTurn(hapisClass) {
                try await self.fetchData(url, hapisClass: hapisClass)
            }
        } catch APIClientError.http(let status, _) where status == 429 && hapisClass == .interactive {
            try await originGate.waitTurn(.interactive)
            return try await originGate.withTurn(hapisClass) {
                try await self.fetchData(url, hapisClass: hapisClass)
            }
        }
    }

    private func fetchData(
        _ url: URL,
        hapisRemintAttempted: Bool = false,
        hapisClass: HAPISOriginGate.RequestClass = .interactive
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 段階 A: `api.sollahiro.com` だけ Access Cookie。段階 B: HAPIS ゲートウェイだけ
        // 制御面で mint した consumer JWT を Bearer に付ける（ハードコードしない）。
        // Debug は stub mint、Release は App Attest。loopback / LAN `http` はどちらも付けない。
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
            try Task.checkCancellation()
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
            if GatewayErrorBody.parse(data)?.isTokenExpired == true {
                do {
                    _ = try await hapis.forceRemint()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw APIClientError.hapisUnavailable
                }
                return try await fetchData(
                    url, hapisRemintAttempted: true, hapisClass: hapisClass)
            }
        }
        if status == 429 {
            if APIConfiguration.usesHAPISConsumer(url) {
                await originGate.noteRateLimited(
                    retryAfterSeconds: HAPISRetryAfter.seconds(
                        from: http?.value(forHTTPHeaderField: "Retry-After"))
                )
            }
            let message = httpErrorMessage(data, fallback: "HTTP 429")
            throw APIClientError.http(status: 429, message: message)
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
