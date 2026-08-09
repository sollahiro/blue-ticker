import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case httpError(status: Int, message: String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "不正なURLです"
        case .httpError(let status, let message): return "\(message) (HTTP \(status))"
        case .decodingFailed: return "レスポンスの解析に失敗しました"
        }
    }
}

/// blt-server REST `/v1` クライアント。既定はローカル無認証サーバー（`127.0.0.1:3000`、
/// シミュレータのループバック経由）。本番接続時は Cloudflare Access の認証まわりが別途必要
/// （iOS SSO は roadmap 未着手、`docs/ios-app-concept.md`）。
struct APIClient {
    var baseURL: URL

    static let local = APIClient(baseURL: URL(string: "http://127.0.0.1:3000")!)

    func searchCompanies(query: String) async throws -> [CompanySearchResult] {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/companies"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw APIError.invalidURL }
        return try await get(url)
    }

    func waterfall(code: String, years: Int = 6) async throws -> WaterfallResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/companies/\(code)/waterfall"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "years", value: String(years))]
        guard let url = components?.url else { throw APIError.invalidURL }
        return try await get(url)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw APIError.decodingFailed }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError.httpError(status: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed
        }
    }
}

/// `{"error": "...", "status": N}` エラー封筒（Routes.swift `errorResponse` と対応）。
private struct ErrorEnvelope: Decodable {
    var error: String
    var status: Int
}
