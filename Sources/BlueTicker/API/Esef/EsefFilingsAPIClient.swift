import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// filings.xbrl.org への HTTP 取得境界（テスト差し替え用）。
protocol EsefHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionEsefHTTPTransport: EsefHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

enum EsefFilingsAPIError: Error, Equatable {
    case invalidURL
    case httpStatus(Int)
    case decoding(String)
}

/// filings.xbrl.org JSON:API クライアント（Region EU · Source ESEF）。
/// REST/MCP には未配線。Meta Search / 将来の sync が使う。
actor EsefFilingsAPIClient {
    private let apiBase: URL
    private let filesBase: URL
    private let transport: any EsefHTTPTransport
    private let userAgent: String

    init(
        apiBase: URL = URL(string: "https://filings.xbrl.org/api")!,
        filesBase: URL = URL(string: "https://filings.xbrl.org")!,
        transport: any EsefHTTPTransport = URLSessionEsefHTTPTransport(),
        userAgent: String = "BlueTicker-EU-ESEF/0.1"
    ) {
        self.apiBase = apiBase
        self.filesBase = filesBase
        self.transport = transport
        self.userAgent = userAgent
    }

    struct EntityPage: Sendable {
        var entities: [EsefEntity]
        var totalCount: Int
    }

    func fetchEntities(pageSize: Int = 200, pageNumber: Int = 1) async throws -> EntityPage {
        let payload = try await getJSON(
            path: "entities",
            query: [
                "page[size]": String(pageSize),
                "page[number]": String(pageNumber),
            ]
        )
        let entities = decodeEntities(from: payload)
        let total = (payload["meta"] as? [String: Any])?["count"] as? Int ?? entities.count
        return EntityPage(entities: entities, totalCount: total)
    }

    /// `filter[identifier]=` 完全一致。
    func fetchEntity(identifier: String) async throws -> EsefEntity? {
        let payload = try await getJSON(
            path: "entities",
            query: [
                "filter[identifier]": identifier,
                "page[size]": "5",
            ]
        )
        return decodeEntities(from: payload).first
    }

    /// `filter[name]=` 完全一致（API は部分一致を提供しない）。
    func fetchEntity(exactName: String) async throws -> EsefEntity? {
        let payload = try await getJSON(
            path: "entities",
            query: [
                "filter[name]": exactName,
                "page[size]": "5",
            ]
        )
        return decodeEntities(from: payload).first
    }

    func fetchFiling(fxoId: String) async throws -> (filing: EsefFilingRef, entity: EsefEntity?)? {
        let payload = try await getJSON(
            path: "filings",
            query: [
                "filter[fxo_id]": fxoId,
                "include": "entity",
                "page[size]": "1",
            ]
        )
        guard let row = (payload["data"] as? [[String: Any]])?.first else { return nil }
        let attrs = row["attributes"] as? [String: Any] ?? [:]
        let filing = EsefFilingRef(
            fxoId: attrs["fxo_id"] as? String ?? fxoId,
            country: attrs["country"] as? String ?? "",
            periodEnd: attrs["period_end"] as? String ?? "",
            jsonURL: absolutize(attrs["json_url"] as? String),
            packageURL: absolutize(attrs["package_url"] as? String),
            reportURL: absolutize(attrs["report_url"] as? String)
        )
        let entity = resolveIncludedEntity(payload: payload, filingRow: row)
        return (filing, entity)
    }

    /// 全 entity をページング取得（Meta マスター構築用）。
    func fetchAllEntities(pageSize: Int = 200) async throws -> [EsefEntity] {
        var page = 1
        var all: [EsefEntity] = []
        var total = Int.max
        while all.count < total {
            let batch = try await fetchEntities(pageSize: pageSize, pageNumber: page)
            total = batch.totalCount
            if batch.entities.isEmpty { break }
            all.append(contentsOf: batch.entities)
            page += 1
            if page > 10_000 { break }
        }
        return all
    }

    private func getJSON(path: String, query: [String: String]) async throws -> [String: Any] {
        guard var components = URLComponents(
            url: apiBase.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw EsefFilingsAPIError.invalidURL
        }
        // Linux Foundation は percentEncodedQuery に生の `[]` を拒否する。
        // `page%5Bsize%5D` 形式は filings.xbrl.org が受理する（実測済み）。
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw EsefFilingsAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.api+json, application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EsefFilingsAPIError.httpStatus(http.statusCode)
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw EsefFilingsAPIError.decoding("root is not object")
        }
        return dict
    }

    private func decodeEntities(from payload: [String: Any]) -> [EsefEntity] {
        guard let data = payload["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { row in
            let attrs = row["attributes"] as? [String: Any] ?? [:]
            guard let identifier = attrs["identifier"] as? String,
                  let name = attrs["name"] as? String
            else { return nil }
            return EsefEntity(identifier: identifier, name: name)
        }
    }

    private func resolveIncludedEntity(
        payload: [String: Any],
        filingRow: [String: Any]
    ) -> EsefEntity? {
        let entityRel = (filingRow["relationships"] as? [String: Any])?["entity"] as? [String: Any]
        let entityId = (entityRel?["data"] as? [String: Any])?["id"] as? String
        let included = payload["included"] as? [[String: Any]] ?? []
        for row in included where (row["type"] as? String) == "entity" {
            if let entityId, (row["id"] as? String) != entityId { continue }
            let attrs = row["attributes"] as? [String: Any] ?? [:]
            guard let identifier = attrs["identifier"] as? String,
                  let name = attrs["name"] as? String
            else { continue }
            return EsefEntity(identifier: identifier, name: name)
        }
        return nil
    }

    private func absolutize(_ pathOrURL: String?) -> String? {
        guard let pathOrURL, !pathOrURL.isEmpty else { return nil }
        if pathOrURL.hasPrefix("http://") || pathOrURL.hasPrefix("https://") {
            return pathOrURL
        }
        let base = filesBase.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if pathOrURL.hasPrefix("/") {
            return base + pathOrURL
        }
        return base + "/" + pathOrURL
    }
}
