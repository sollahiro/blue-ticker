// Feed Trend の公開 JSON 組み立てと、origin が Worker へ送る匿名イベントの正規化。
// ネットワーク・DB 非依存。書き込み先（Analytics Engine）は BltServerCore / Worker 側。

import Foundation

/// Trend が数える MCP / REST ツール。healthz・skills・feed・EU preview は含めない。
public let feedTrendRecordedTools: Set<String> = [
    "search_companies",
    "get_filings",
    "get_financial_summary",
    "get_waterfall",
    "get_filing_content",
    "get_breakdown",
    "get_statement",
    "get_statement_notes",
]

/// `surface` の許可値。ホスト名ではなく origin が明示する（MCP はすべて `POST /`）。
public let feedTrendSurfaces: Set<String> = ["rest", "mcp"]

/// Worker / origin が共有する 1 イベント。IP・ユーザー・cookie は持たない。
public struct FeedTrendEvent: Sendable, Equatable {
    public var surface: String
    public var tool: String
    public var code: String?
    public var q: String?

    public init(surface: String, tool: String, code: String? = nil, q: String? = nil) {
        self.surface = surface
        self.tool = tool
        self.code = code
        self.q = q
    }

    /// ingest JSON。空の code / q はキーごと省略する。
    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["surface": surface, "tool": tool]
        if let code, !code.isEmpty { object["code"] = code }
        if let q, !q.isEmpty { object["q"] = q }
        return object
    }
}

/// 銘柄コードのヒット件数。
public struct FeedTrendBucket: Sendable, Equatable {
    public var code: String
    public var count: Int
    public init(code: String, count: Int) {
        self.code = code
        self.count = count
    }
}

/// ツール / surface / クエリ別の件数。
public struct FeedTrendLabelCount: Sendable, Equatable {
    public var label: String
    public var count: Int
    public init(label: String, count: Int) {
        self.label = label
        self.count = count
    }
}

/// Worker `GET /trend` のデコード結果。
public struct FeedTrendRanking: Sendable, Equatable {
    public var items: [FeedTrendBucket]
    public var byTool: [FeedTrendLabelCount]
    public var bySurface: [FeedTrendLabelCount]
    public var byQuery: [FeedTrendLabelCount]
    public init(
        items: [FeedTrendBucket],
        byTool: [FeedTrendLabelCount] = [],
        bySurface: [FeedTrendLabelCount] = [],
        byQuery: [FeedTrendLabelCount] = []
    ) {
        self.items = items
        self.byTool = byTool
        self.bySurface = bySurface
        self.byQuery = byQuery
    }
}

/// Trend 未設定・Worker 失敗時の公開メッセージ（REST 503 / MCP isError）。
public let feedTrendUnavailableMessage = "検索トレンドに接続できません"

/// 4 文字の銘柄コード（数字または英数字。例: 7203 / 477A）。それ以外は nil。
public func feedTrendTickerCode(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 4 else { return nil }
    let upper = trimmed.uppercased()
    guard upper.unicodeScalars.allSatisfy({ feedTrendTickerScalars.contains($0) }) else {
        return nil
    }
    return upper
}

/// クエリ `code`。省略は nil、不正は `.invalid`。
public enum FeedTrendCodeParam: Equatable, Sendable {
    case omitted
    case valid(String)
    case invalid
}

public func parseFeedTrendCodeParam(_ raw: String?) -> FeedTrendCodeParam {
    guard let raw else { return .omitted }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .omitted }
    if let code = feedTrendTickerCode(trimmed) { return .valid(code) }
    return .invalid
}

/// 許可されたツールだけイベントにする。検索は `q` が 4 文字コードなら `code` にも載せる。
public func makeFeedTrendEvent(
    surface: String, tool: String, code: String? = nil, q: String? = nil
) -> FeedTrendEvent? {
    guard feedTrendSurfaces.contains(surface) else { return nil }
    guard feedTrendRecordedTools.contains(tool) else { return nil }
    let query = tool == "search_companies" ? feedTrendQueryString(q) : nil
    let ticker: String?
    if tool == "search_companies" {
        ticker = feedTrendTickerCode(code) ?? feedTrendTickerCode(query)
    } else {
        ticker = feedTrendTickerCode(code)
    }
    return FeedTrendEvent(surface: surface, tool: tool, code: ticker, q: query)
}

/// Worker JSON をランキングへ。キー欠落は空配列。
public func decodeFeedTrendRanking(from data: Data) throws -> FeedTrendRanking {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FeedTrendRankingDecodeError.notObject
    }
    let items = decodeBuckets(object["items"])
    return FeedTrendRanking(
        items: items,
        byTool: decodeLabeled(object["by_tool"], key: "tool"),
        bySurface: decodeLabeled(object["by_surface"], key: "surface"),
        byQuery: decodeLabeled(object["by_query"], key: "q")
    )
}

public enum FeedTrendRankingDecodeError: Error {
    case notObject
}

/// マスター CSV から会社名を引く（未知 code は載せない）。
public func feedTrendCompanyNames(for codes: [String]) async -> [String: String] {
    var names: [String: String] = [:]
    for code in codes {
        if let stock = await masterDataManager.getByCode(code) {
            names[code] = stock.coName
        }
    }
    return names
}

/// ランキング JSON。`names` は code → 会社名（未知は空文字）。REST の `icon_url` は載せない。
public func assembleFeedTrend(
    ranking: FeedTrendRanking, names: [String: String], days: Int, code: String?,
    now: Date = Date()
) -> [String: Any] {
    var json: [String: Any] = [
        "schema_version": Api.feedTrendSchemaVersion,
        "date": feedDateString(now),
        "days": days,
        "items": ranking.items.map { bucket -> [String: Any] in
            [
                "code": bucket.code,
                "name": names[bucket.code] ?? "",
                "count": bucket.count,
            ]
        },
    ]
    if let code {
        json["code"] = code
        json["by_tool"] = ranking.byTool.map { ["tool": $0.label, "count": $0.count] as [String: Any] }
        json["by_surface"] = ranking.bySurface.map {
            ["surface": $0.label, "count": $0.count] as [String: Any]
        }
        json["by_query"] = ranking.byQuery.map { ["q": $0.label, "count": $0.count] as [String: Any] }
    }
    return json
}

func feedTrendQueryString(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count <= Api.feedTrendQueryMaxLength { return trimmed }
    return String(trimmed.prefix(Api.feedTrendQueryMaxLength))
}

private let feedTrendTickerScalars = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

private func decodeBuckets(_ raw: Any?) -> [FeedTrendBucket] {
    guard let rows = raw as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
        guard let code = feedTrendTickerCode(row["code"] as? String) else { return nil }
        return FeedTrendBucket(code: code, count: decodeCount(row["count"]))
    }
}

private func decodeLabeled(_ raw: Any?, key: String) -> [FeedTrendLabelCount] {
    guard let rows = raw as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
        guard let label = row[key] as? String, !label.isEmpty else { return nil }
        return FeedTrendLabelCount(label: label, count: decodeCount(row["count"]))
    }
}

private func decodeCount(_ raw: Any?) -> Int {
    if let int = raw as? Int { return max(int, 0) }
    if let double = raw as? Double { return max(Int(double.rounded()), 0) }
    if let string = raw as? String, let int = Int(string) { return max(int, 0) }
    return 0
}
