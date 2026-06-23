// REST API のパスルーティングと HTTP ステータス決定（トランスポート層）。
// データ取得は BltServerContext ファサードへ委譲し、その結果を HTTP レスポンスへ変換する。

import BlueTickerCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - RESTRouter

/// iOS app など HTTP クライアント向けの REST API ルーター。
struct RESTRouter: Sendable {
    let context: BltServerContext

    func handle(method: String, path: String, queryParams: [String: String], body: Data?) async -> RESTResult {
        guard method.uppercased() == "GET" else {
            return .error(statusCode: 405, message: "Method not allowed")
        }
        return convert(await route(path: path, queryParams: queryParams))
    }

    private func route(path: String, queryParams: [String: String]) async -> BltServerResponse {
        if path == "/v1/companies" {
            return await context.searchCompanies(q: queryParams["q"] ?? "")
        }
        if let code = segment(of: path, between: "/v1/companies/", and: "/filings") {
            return await context.getFilings(code: code, maxYears: Int(queryParams["max_years"] ?? "5") ?? 5)
        }
        if let code = segment(of: path, between: "/v1/companies/", and: "/financials") {
            return await context.getFinancials(code: code, years: Int(queryParams["years"] ?? "5") ?? 5)
        }
        if let code = segment(of: path, between: "/v1/companies/", and: "/filing-content") {
            let sections = queryParams["sections"].map { $0.split(separator: ",").map(String.init) }
            return await context.getFilingContent(code: code, docId: queryParams["doc_id"], sections: sections)
        }
        if let sector = segment(of: path, between: "/v1/sectors/", and: "/companies") {
            return await context.searchBySector(sector: sector, limit: Int(queryParams["limit"] ?? "20") ?? 20)
        }
        return .notFound("Not found: \(path)")
    }

    private func convert(_ response: BltServerResponse) -> RESTResult {
        switch response {
        case .ok(let value):
            return .json(value)
        case .notFound(let message):
            return .error(statusCode: 404, message: message)
        case .upstreamFailure(let message):
            return .error(statusCode: 502, message: message)
        }
    }

    /// `/v1/companies/7203/filings` → segment(between:"/v1/companies/", and:"/filings") → "7203"
    private func segment(of path: String, between prefix: String, and suffix: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let raw = String(path[start..<end])
        return raw.removingPercentEncoding ?? raw
    }
}
