import Foundation

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        decoder = JSONDecoder()
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

    func financials(code: String) async throws -> FinancialsResponse {
        try await get(path("v1/companies/\(code)/financials"))
    }

    func waterfall(code: String) async throws -> FinancialsResponse {
        try await get(path("v1/companies/\(code)/waterfall"))
    }

    func overview(code: String) async throws -> CompanyOverviewResponse {
        try await get(path("v1/companies/\(code)/overview"))
    }

    private func path(_ suffix: String) -> URL {
        APIConfiguration.baseURL.appending(path: suffix)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            let message = (try? decoder.decode(APIErrorBody.self, from: data))?.error
                ?? "見つかりません"
            throw APIClientError.http(status: 404, message: message)
        }
        if status == 503 {
            let message = (try? decoder.decode(APIErrorBody.self, from: data))?.error
                ?? "サービスを利用できません"
            throw APIClientError.http(status: 503, message: message)
        }
        guard (200..<300).contains(status) else {
            let message = (try? decoder.decode(APIErrorBody.self, from: data))?.error
                ?? "HTTP \(status)"
            throw APIClientError.http(status: status, message: message)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decoding(error)
        }
    }
}
