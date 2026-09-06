// Screen（Summary 横断検索、BLT-49）の公開契約。
//
// `company_financials` の最新 FY を 1 社 1 行へ投影した検索用 Read Model（Neon `screen_index`）の
// 行定義と、REST `GET /v1/screen` のクエリ解析。`company_financials` の契約は複製しない。
// 数値キーは Summary `years[]` の公開キーのうち Screen が受け付ける許可リストだけ。
// `sales_growth` は Summary に無い派生列（最新 FY と直前 FY の売上高から ingest 時に計算）。
//
// Foundation のみ依存（NIO/Vapor 非依存）。

import Foundation

/// Screen の数値指標（許可リスト）。rawValue が REST クエリ名・応答キー・`screen_index` 列名。
public enum ScreenMetric: String, CaseIterable, Sendable {
    /// 売上高（百万円）。
    case sales
    /// 売上高増加率（%、最新 FY ÷ 直前 FY − 1）。直前 FY が無い・0 以下なら null。
    case salesGrowth = "sales_growth"
    /// 売上高総利益率（%）。
    case grossProfitMargin = "gross_profit_margin"
    /// 営業利益率（%、開示営業利益 ÷ 売上高）。
    case operatingMargin = "operating_margin"
    /// ROIC（%）。
    case roic
    /// ROE（%）。
    case roe
    /// ネット D/E（倍）。
    case netDe = "net_de"
}

/// `screen_index` 1 行（1 社の最新 FY）。
public struct ScreenRow: Sendable, Equatable {
    public var code: String
    public var name: String
    public var market: String
    public var sector: String
    /// 最新 FY の `fy_end`。
    public var periodEnd: String
    public var metrics: [ScreenMetric: Double]

    public init(
        code: String, name: String, market: String, sector: String, periodEnd: String,
        metrics: [ScreenMetric: Double]
    ) {
        self.code = code
        self.name = name
        self.market = market
        self.sector = sector
        self.periodEnd = periodEnd
        self.metrics = metrics
    }

    public subscript(_ metric: ScreenMetric) -> Double? { metrics[metric] }
}

extension FinancialsResponse {
    /// 最新 FY（`fy_end` 最大）を Screen 行へ投影する。母集団は上場（`market` 非空）のみ。
    /// `years` が空・`fy_end` 無し・`market` 空（notApplicable プレースホルダ）は nil。
    public func screenRow() -> ScreenRow? {
        guard !market.isEmpty else { return nil }
        let dated = years.compactMap { year in year.fyEnd.map { ($0, year) } }
            .sorted { $0.0 > $1.0 }
        guard let (periodEnd, latest) = dated.first else { return nil }
        let prior = dated.dropFirst().first?.1

        var metrics: [ScreenMetric: Double] = [:]
        func put(_ metric: ScreenMetric, _ value: Double?) {
            if let value, value.isFinite { metrics[metric] = value }
        }
        put(.sales, latest.sales)
        if let cur = latest.sales, let prev = prior?.sales, prev > 0 {
            put(.salesGrowth, (cur / prev - 1) * 100)
        }
        put(.grossProfitMargin, latest.grossProfitMargin)
        put(.operatingMargin, latest.operatingMargin)
        put(.roic, latest.roic)
        put(.roe, latest.roe)
        put(.netDe, latest.netDe)
        return ScreenRow(
            code: code, name: name, market: market, sector: sector, periodEnd: periodEnd,
            metrics: metrics)
    }
}

// MARK: - クエリ

/// 1 指標の数値範囲（両端含む。片側のみ可）。
public struct ScreenRange: Sendable, Equatable {
    public var min: Double?
    public var max: Double?
    public init(min: Double?, max: Double?) {
        self.min = min
        self.max = max
    }
}

public enum ScreenSortOrder: String, Sendable {
    case asc
    case desc
}

/// `GET /v1/screen` の解析済みクエリ。
public struct ScreenQuery: Sendable, Equatable {
    /// `sector=` 完全一致（省略時は全業種）。
    public var sector: String?
    /// `{metric}_min` / `{metric}_max`。対象指標が null の行は落とす（0 扱いにしない）。
    public var ranges: [ScreenMetric: ScreenRange]
    /// `sort=`（既定 `roic`）。null の行は結果に載せない。
    public var sort: ScreenMetric
    /// `order=`（既定 `desc`）。
    public var order: ScreenSortOrder
    /// `limit=`（既定 `Api.screenLimitDefault`、上限 `Api.screenLimitMax`）。
    public var limit: Int

    public init(
        sector: String? = nil, ranges: [ScreenMetric: ScreenRange] = [:],
        sort: ScreenMetric = .roic, order: ScreenSortOrder = .desc,
        limit: Int = Api.screenLimitDefault
    ) {
        self.sector = sector
        self.ranges = ranges
        self.sort = sort
        self.order = order
        self.limit = limit
    }

    /// 応答 `items[]` に載せる数値キー（フィルタと sort に使ったもの。sort は常に含む）。
    public var projectedMetrics: [ScreenMetric] {
        ScreenMetric.allCases.filter { $0 == sort || ranges[$0] != nil }
    }
}

/// `GET /v1/screen` クエリ文字列（キー→値）を解析する。不正値は理由付きで失敗（呼び出し側は 400）。
public func parseScreenQuery(_ raw: [String: String]) -> Result<ScreenQuery, ScreenQueryError> {
    var query = ScreenQuery()
    var unknown: [String] = []
    for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch key {
        case "sector":
            query.sector = trimmed.isEmpty ? nil : trimmed
        case "sort":
            guard let metric = ScreenMetric(rawValue: trimmed) else {
                return .failure(.invalidValue(key: key, value: value))
            }
            query.sort = metric
        case "order":
            guard let order = ScreenSortOrder(rawValue: trimmed.lowercased()) else {
                return .failure(.invalidValue(key: key, value: value))
            }
            query.order = order
        case "limit":
            guard let limit = Int(trimmed), limit >= 1 else {
                return .failure(.invalidValue(key: key, value: value))
            }
            query.limit = Swift.min(limit, Api.screenLimitMax)
        default:
            if let (metric, isMin) = screenRangeKey(key) {
                if trimmed.isEmpty { continue }
                guard let number = Double(trimmed), number.isFinite else {
                    return .failure(.invalidValue(key: key, value: value))
                }
                var range = query.ranges[metric] ?? ScreenRange(min: nil, max: nil)
                if isMin { range.min = number } else { range.max = number }
                query.ranges[metric] = range
            } else {
                unknown.append(key)
            }
        }
    }
    if !unknown.isEmpty { return .failure(.unknownKeys(unknown.sorted())) }
    for (metric, range) in query.ranges {
        if let lo = range.min, let hi = range.max, lo > hi {
            return .failure(.emptyRange(metric))
        }
    }
    return .success(query)
}

/// `sales_min` → (`.sales`, true)、`net_de_max` → (`.netDe`, false)。該当しなければ nil。
private func screenRangeKey(_ key: String) -> (ScreenMetric, Bool)? {
    for metric in ScreenMetric.allCases {
        if key == "\(metric.rawValue)_min" { return (metric, true) }
        if key == "\(metric.rawValue)_max" { return (metric, false) }
    }
    return nil
}

public enum ScreenQueryError: Error, Sendable, Equatable {
    case unknownKeys([String])
    case invalidValue(key: String, value: String)
    case emptyRange(ScreenMetric)

    public var message: String {
        switch self {
        case .unknownKeys(let keys):
            return "screen に不明なクエリキーがあります: \(keys.joined(separator: ", "))"
        case .invalidValue(let key, let value):
            return "\(key) の値が不正です: \(value)"
        case .emptyRange(let metric):
            return "\(metric.rawValue)_min が \(metric.rawValue)_max を超えています"
        }
    }
}

// MARK: - 応答

/// `GET /v1/screen` 応答。`items` は AND を通った行だけ（条件ごとの真偽は返さない）。
/// `matched` は LIMIT 前の件数。
public func screenResponseJSON(
    rows: [ScreenRow], matched: Int, query: ScreenQuery
) -> [String: Any] {
    let projected = query.projectedMetrics
    let items: [[String: Any]] = rows.map { row in
        var item: [String: Any] = [
            "code": row.code,
            "name": row.name,
            "market": row.market,
            "sector": row.sector,
            "period_end": row.periodEnd,
        ]
        for metric in projected {
            item[metric.rawValue] = row[metric].map { $0 as Any } ?? NSNull()
        }
        return item
    }
    return [
        "items": items,
        "returned": items.count,
        "matched": matched,
        "sort": ["key": query.sort.rawValue, "order": query.order.rawValue],
    ]
}
