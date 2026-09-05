// 銘柄ニュース（Brave News Search）の公開 JSON 組み立てと正規化。
// ネットワーク非依存。HTTP クライアントは BltServerCore。

import Foundation

/// ニュース応答の公開契約バージョン。
public let companyNewsUnavailableMessage = "ニュース検索に接続できません"

/// Brave / モック共通の 1 件。
public struct CompanyNewsItem: Sendable, Equatable {
    public var title: String
    public var url: String
    public var source: String?
    public var age: String?
    public var publishedAt: String?
    public var description: String?
    public var thumbnailURL: String?

    public init(
        title: String,
        url: String,
        source: String? = nil,
        age: String? = nil,
        publishedAt: String? = nil,
        description: String? = nil,
        thumbnailURL: String? = nil
    ) {
        self.title = title
        self.url = url
        self.source = source
        self.age = age
        self.publishedAt = publishedAt
        self.description = description
        self.thumbnailURL = thumbnailURL
    }
}

/// Brave News Search のデコード結果。
public struct CompanyNewsPage: Sendable, Equatable {
    public var query: String
    public var items: [CompanyNewsItem]

    public init(query: String, items: [CompanyNewsItem]) {
        self.query = query
        self.items = items
    }
}

public enum CompanyNewsDecodeError: Error {
    case notObject
}

/// Brave `GET /v1/news/search` JSON を公開アイテムへ。キー欠落は省略。
public func decodeBraveNewsSearch(from data: Data) throws -> CompanyNewsPage {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CompanyNewsDecodeError.notObject
    }
    let queryObject = object["query"] as? [String: Any]
    let query = (queryObject?["original"] as? String)
        ?? (queryObject?["altered"] as? String)
        ?? ""
    let rows = object["results"] as? [[String: Any]] ?? []
    let items = rows.compactMap(decodeBraveNewsResult)
    return CompanyNewsPage(query: query, items: items)
}

/// 検索クエリ用の社名。法人格「株式会社」を落とし、空なら code を返す。
public func companyNewsSearchQuery(name: String, code: String) -> String {
    let stripped = name
        .replacingOccurrences(of: "株式会社", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if stripped.isEmpty { return code }
    return stripped
}

/// `limit` クエリ。省略時・不正は既定、上限で切る。
public func parseCompanyNewsLimit(_ raw: Int?) -> Int {
    guard let raw else { return Api.companyNewsLimitDefault }
    return min(max(raw, 1), Api.companyNewsLimitMax)
}

/// マスター CSV から銘柄を解決する（未知 code は nil）。
public func companyNewsResolvedCompany(for code: String) async -> (code: String, name: String)? {
    guard let stock = await masterDataManager.getByCode(code) else { return nil }
    return (code, stock.coName)
}

/// 公開 REST JSON。`items` は Brave 由来の要約。
public func assembleCompanyNews(
    code: String,
    name: String,
    query: String,
    items: [CompanyNewsItem],
    now: Date = Date()
) -> [String: Any] {
    [
        "schema_version": Api.companyNewsSchemaVersion,
        "date": feedDateString(now),
        "code": code,
        "name": name,
        "query": query,
        "items": items.map { item -> [String: Any] in
            var row: [String: Any] = [
                "title": item.title,
                "url": item.url,
            ]
            if let source = item.source, !source.isEmpty { row["source"] = source }
            if let age = item.age, !age.isEmpty { row["age"] = age }
            if let publishedAt = item.publishedAt, !publishedAt.isEmpty {
                row["published_at"] = publishedAt
            }
            if let description = item.description, !description.isEmpty {
                row["description"] = description
            }
            if let thumbnailURL = item.thumbnailURL, !thumbnailURL.isEmpty {
                row["thumbnail_url"] = thumbnailURL
            }
            return row
        },
    ]
}

private func decodeBraveNewsResult(_ row: [String: Any]) -> CompanyNewsItem? {
    guard let title = nonEmptyString(row["title"]),
        let url = nonEmptyString(row["url"])
    else { return nil }
    let profile = row["profile"] as? [String: Any]
    let thumbnail = row["thumbnail"] as? [String: Any]
    return CompanyNewsItem(
        title: title,
        url: url,
        source: nonEmptyString(row["source"]) ?? nonEmptyString(profile?["name"]),
        age: nonEmptyString(row["age"]),
        publishedAt: nonEmptyString(row["page_age"]),
        description: nonEmptyString(row["description"]),
        thumbnailURL: nonEmptyString(thumbnail?["src"]) ?? nonEmptyString(thumbnail?["original"])
    )
}

private func nonEmptyString(_ raw: Any?) -> String? {
    guard let value = raw as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
