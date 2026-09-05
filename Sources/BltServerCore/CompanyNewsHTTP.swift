// 銘柄ニュース（Brave News Search）の HTTP クライアントと serve。
// origin 非依存（URL + X-Subscription-Token）。Vapor 非依存。

import BlueTickerCore
import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol CompanyNewsClient: Sendable {
    var isConfigured: Bool { get }
    func search(query: String, limit: Int) async throws -> CompanyNewsPage
}

struct UnconfiguredCompanyNewsClient: CompanyNewsClient {
    var isConfigured: Bool { false }
    func search(query _: String, limit _: Int) async throws -> CompanyNewsPage {
        throw CompanyNewsQueryError.unconfigured
    }
}

enum CompanyNewsQueryError: Error {
    case unconfigured
    case status(Int)
    case decode
}

struct StubCompanyNewsClient: CompanyNewsClient {
    var isConfigured: Bool
    var page: CompanyNewsPage
    var error: CompanyNewsQueryError?

    init(
        page: CompanyNewsPage,
        isConfigured: Bool = true,
        error: CompanyNewsQueryError? = nil
    ) {
        self.page = page
        self.isConfigured = isConfigured
        self.error = error
    }

    func search(query _: String, limit _: Int) async throws -> CompanyNewsPage {
        if let error { throw error }
        return page
    }
}

struct HTTPCompanyNewsClient: CompanyNewsClient, @unchecked Sendable {
    let endpoint: URL
    let token: String
    let session: URLSession
    var isConfigured: Bool { true }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any CompanyNewsClient {
        guard let token = companyNewsToken(environment),
            let endpoint = companyNewsSearchURL(environment)
        else { return UnconfiguredCompanyNewsClient() }
        return HTTPCompanyNewsClient(endpoint: endpoint, token: token)
    }

    init(endpoint: URL, token: String, session: URLSession = companyNewsSession) {
        self.endpoint = endpoint
        self.token = token
        self.session = session
    }

    func search(query: String, limit: Int) async throws -> CompanyNewsPage {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw CompanyNewsQueryError.unconfigured
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "country", value: "JP"),
            URLQueryItem(name: "search_lang", value: "jp"),
            URLQueryItem(name: "ui_lang", value: "ja-JP"),
            URLQueryItem(name: "count", value: String(limit)),
            URLQueryItem(name: "freshness", value: "pw"),
            URLQueryItem(name: "spellcheck", value: "true"),
            URLQueryItem(name: "text_decorations", value: "false"),
        ]
        guard let url = components.url else { throw CompanyNewsQueryError.unconfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CompanyNewsQueryError.status(status) }
        do {
            return try decodeBraveNewsSearch(from: data)
        } catch {
            throw CompanyNewsQueryError.decode
        }
    }
}

enum CompanyNewsServeResult {
    case ok([String: Any])
    case badRequest(String)
    case notFound(String)
    case unavailable
}

func serveCompanyNews(
    codeRaw: String,
    limit: Int,
    client: any CompanyNewsClient,
    logger: Logger,
    now: Date = Date()
) async -> CompanyNewsServeResult {
    guard let code = feedTrendTickerCode(codeRaw) else {
        return .badRequest("code は4桁の銘柄コードです")
    }
    guard client.isConfigured else { return .unavailable }
    guard let company = await companyNewsResolvedCompany(for: code) else {
        return .notFound("銘柄が見つかりません")
    }
    let query = companyNewsSearchQuery(name: company.name, code: code)
    do {
        let page = try await client.search(query: query, limit: limit)
        let items = Array(page.items.prefix(limit))
        return .ok(
            assembleCompanyNews(
                code: code,
                name: company.name,
                query: page.query.isEmpty ? query : page.query,
                items: items,
                now: now))
    } catch {
        logger.warning("Company news の取得に失敗: \(error)")
        return .unavailable
    }
}

func companyNewsToken(_ environment: [String: String]) -> String? {
    let raw = environment["BLT_NEWS_CURATION_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return nil }
    return raw
}

func companyNewsSearchURL(_ environment: [String: String]) -> URL? {
    let baseRaw = environment["BLT_NEWS_CURATION_BASE_URL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = (baseRaw?.isEmpty == false ? baseRaw! : Api.braveNewsSearchBaseURL)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return URL(string: "\(base)/v1/news/search")
}

private let companyNewsSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 12
    return URLSession(configuration: config)
}()
