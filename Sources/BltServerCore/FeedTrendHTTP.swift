// Feed Trend の Analytics Engine Worker への HTTP 送受信。
// origin 非依存（URL + Bearer）。失敗しても API は落とさない。Vapor 非依存。

import BlueTickerCore
import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol FeedTrendSink: Sendable {
    func record(_ event: FeedTrendEvent)
}

protocol FeedTrendQueryClient: Sendable {
    var isConfigured: Bool { get }
    func fetchRanking(days: Int, limit: Int, code: String?) async throws -> FeedTrendRanking
}

struct NoopFeedTrendSink: FeedTrendSink {
    func record(_ event: FeedTrendEvent) {}
}

struct UnconfiguredFeedTrendQueryClient: FeedTrendQueryClient {
    var isConfigured: Bool { false }
    func fetchRanking(days _: Int, limit _: Int, code _: String?) async throws -> FeedTrendRanking {
        throw FeedTrendQueryError.unconfigured
    }
}

enum FeedTrendQueryError: Error {
    case unconfigured
    case status(Int)
    case decode
}

/// テスト注入用。`record` は同期（リクエスト経路で待たない HTTP sink とは別）。
final class RecordingFeedTrendSink: FeedTrendSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FeedTrendEvent] = []
    var events: [FeedTrendEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func record(_ event: FeedTrendEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

struct StubFeedTrendQueryClient: FeedTrendQueryClient {
    var isConfigured: Bool
    var ranking: FeedTrendRanking
    var error: FeedTrendQueryError?

    init(
        ranking: FeedTrendRanking,
        isConfigured: Bool = true,
        error: FeedTrendQueryError? = nil
    ) {
        self.ranking = ranking
        self.isConfigured = isConfigured
        self.error = error
    }

    func fetchRanking(days _: Int, limit _: Int, code _: String?) async throws -> FeedTrendRanking {
        if let error { throw error }
        return ranking
    }
}

struct HTTPFeedTrendSink: FeedTrendSink, @unchecked Sendable {
    let endpoint: URL
    let token: String
    let session: URLSession

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any FeedTrendSink {
        guard let base = feedTrendBaseURL(environment),
            let token = feedTrendToken(environment)
        else { return NoopFeedTrendSink() }
        guard let endpoint = feedTrendJoinURL(base, path: "ingest") else {
            return NoopFeedTrendSink()
        }
        return HTTPFeedTrendSink(endpoint: endpoint, token: token)
    }

    init(endpoint: URL, token: String, session: URLSession = feedTrendIngestSession) {
        self.endpoint = endpoint
        self.token = token
        self.session = session
    }

    func record(_ event: FeedTrendEvent) {
        let object = event.jsonObject()
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        let endpoint = endpoint
        let token = token
        let session = session
        Task.detached {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            request.timeoutInterval = 2
            _ = try? await session.data(for: request)
        }
    }
}

struct HTTPFeedTrendQueryClient: FeedTrendQueryClient, @unchecked Sendable {
    let endpoint: URL
    let token: String
    let session: URLSession
    var isConfigured: Bool { true }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any FeedTrendQueryClient {
        guard let base = feedTrendBaseURL(environment),
            let token = feedTrendToken(environment),
            let endpoint = feedTrendJoinURL(base, path: "trend")
        else { return UnconfiguredFeedTrendQueryClient() }
        return HTTPFeedTrendQueryClient(endpoint: endpoint, token: token)
    }

    init(endpoint: URL, token: String, session: URLSession = feedTrendQuerySession) {
        self.endpoint = endpoint
        self.token = token
        self.session = session
    }

    func fetchRanking(days: Int, limit: Int, code: String?) async throws -> FeedTrendRanking {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw FeedTrendQueryError.unconfigured
        }
        var items = [
            URLQueryItem(name: "days", value: String(days)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        components.queryItems = items
        guard let url = components.url else { throw FeedTrendQueryError.unconfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw FeedTrendQueryError.status(status) }
        do {
            return try decodeFeedTrendRanking(from: data)
        } catch {
            throw FeedTrendQueryError.decode
        }
    }
}

enum FeedTrendServeResult {
    case ok([String: Any])
    case badRequest(String)
    case unavailable
}

func serveFeedTrend(
    limit: Int, days: Int, codeParam: FeedTrendCodeParam,
    client: any FeedTrendQueryClient, logger: Logger, now: Date = Date()
) async -> FeedTrendServeResult {
    let code: String?
    switch codeParam {
    case .omitted:
        code = nil
    case .valid(let value):
        code = value
    case .invalid:
        return .badRequest("code は4桁の銘柄コードです")
    }
    guard client.isConfigured else { return .unavailable }
    do {
        let ranking = try await client.fetchRanking(days: days, limit: limit, code: code)
        let names = await feedTrendCompanyNames(for: ranking.items.map(\.code))
        return .ok(
            assembleFeedTrend(ranking: ranking, names: names, days: days, code: code, now: now))
    } catch {
        logger.warning("Feed trend の取得に失敗: \(error)")
        return .unavailable
    }
}

func feedTrendBaseURL(_ environment: [String: String]) -> String? {
    let raw = environment["BLT_FEED_TREND_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return nil }
    return raw
}

func feedTrendToken(_ environment: [String: String]) -> String? {
    let raw = environment["BLT_FEED_TREND_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return nil }
    return raw
}

func feedTrendJoinURL(_ base: String, path: String) -> URL? {
    let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return URL(string: "\(trimmed)/\(path)")
}

private let feedTrendIngestSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    config.timeoutIntervalForResource = 2
    config.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: config)
}()

private let feedTrendQuerySession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 8
    return URLSession(configuration: config)
}()
