// Screen（Summary 横断検索、BLT-49）の公開契約。
//
// `company_financials` の最新 FY を 1 社 1 行へ投影した検索用 Read Model（Neon `screen_index`）の
// 行定義と、REST `GET /v1/screen` のクエリ解析。`company_financials` の契約は複製しない。
// 数値キーは Summary `years[]` の公開キーのうち Screen が受け付ける許可リストだけ。
// `sales_cagr_3y` は Summary `years[]` に無い派生列（最新から売上 > 0 の 3 期・同一 fy_end は先勝ち）。
// 行の `cache_version` に `screenIndexVersion` を刻む。公開床の financials は次回 ingest で投影（現行 fin-vN 一致は問わない）。
// YoY（`sales_growth`）は許可リストに載せない。CAGR / YoY を Summary `years[]` に足さない。
//
// screen-v3（高CF・高効率・改善・高還元プリセット用の指標追加）:
// - `cfo` / `cfo_margin` / `fcf` は高CF向け。`fcf` = cfo − capex（Summary の
//   `cfc`（= cfo + cfi）とは別定義なので混同しない）。
// - `operating_margin_yoy` / `roic_yoy` は改善向けの前年差（pp）。
// - `payout_ratio` は高還元向け。定義: SS 配当額（`dividend_ss`、当期帰属）÷ 親会社
//   帰属純利益 ×100。CF `dividend_paid_cf` は支払時点の実績で期ズレするため不採用。赤字期
//   （net_profit ≤ 0）と配当行が無い期は null（無配と未抽出を区別しない）。記念・特別配当は
//   区別しない（SS 合計のまま）。プリセットの閾値は契約外（実装時に決める）。
//
// Foundation のみ依存（NIO/Vapor 非依存）。

import Foundation

/// `screen_index` 派生契約。列・許可リスト・CAGR 定義が変わったときだけバンプ。`fin-vN` 非連動。
/// 初稿（YoY `sales_growth`）を v1、3 期売上 CAGR への切替を v2、
/// 高CF・高効率・改善・高還元向けの 6 指標追加（cfo・cfo_margin・fcf・前年差 2 軸・payout_ratio）を v3 とする。
public let screenIndexVersion = "screen-v3"

/// Screen の数値指標（許可リスト）。rawValue が REST クエリ名・応答キー・`screen_index` 列名。
public enum ScreenMetric: String, CaseIterable, Sendable {
    /// 売上高（百万円）。サイズ用。iOS プリセットでは使わない。
    case sales
    /// 営業利益率（%、開示営業利益 ÷ 売上高）。
    case operatingMargin = "operating_margin"
    /// ROIC（%）。
    case roic
    /// ROE（%）。API は残す。iOS プリセットでは絞らない。
    case roe
    /// ネット D/E（倍）。
    case netDe = "net_de"
    /// 3 期売上 CAGR（%、売上 > 0 の直近 3 期・2 年間）。足りなければ null。
    case salesCagr3y = "sales_cagr_3y"
    /// 営業CF（百万円）。最新 FY の Summary `cfo`。高CF・サイズ用。
    case cfo
    /// 営業CFマージン（%、cfo ÷ sales ×100）。sales > 0 と cfo があるときだけ。
    case cfoMargin = "cfo_margin"
    /// FCF（百万円、cfo − capex）。Summary `cfc`（= cfo + cfi）とは別定義。両方あるときだけ。
    case fcf
    /// 営業利益率の前年差（pp、最新期 − 直前の一意期）。どちらか欠測なら null（新規上場は CAGR と同じく null）。
    case operatingMarginYoy = "operating_margin_yoy"
    /// ROIC の前年差（pp）。`operating_margin_yoy` と同じ走査・null 方針。
    case roicYoy = "roic_yoy"
    /// 配当性向（%、SS 配当額 ÷ 親会社帰属純利益 ×100）。net_profit > 0 かつ dividend_ss があるときだけ。
    case payoutRatio = "payout_ratio"

    /// 結果行に常に載せる指標（iOS core4）。フィルタ未使用でも null を返す。
    /// screen-v3 の新指標は core に足さない（フィルタ / ソートで使ったときだけ投影）。
    public static let coreDisplayMetrics: [ScreenMetric] = [
        .roic, .operatingMargin, .salesCagr3y, .netDe,
    ]
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
        // 同一 fy_end は配列順の先勝ちで 1 期にしてから降順化する。sort は同キーで
        // 不安定なので、並べ替え後に重複除去すると latest / 直前期の選ばれ方が揺れる
        // （配信側 `uniquedByFyEnd` と同じ規則）。
        var seenFyEnd = Set<String>()
        let dated = years.compactMap { year in year.fyEnd.map { ($0, year) } }
            .filter { seenFyEnd.insert($0.0).inserted }
            .sorted { $0.0 > $1.0 }
        guard let (periodEnd, latest) = dated.first else { return nil }

        var metrics: [ScreenMetric: Double] = [:]
        func put(_ metric: ScreenMetric, _ value: Double?) {
            if let value, value.isFinite { metrics[metric] = value }
        }
        put(.sales, latest.sales)
        put(.operatingMargin, latest.operatingMargin)
        put(.roic, latest.roic)
        put(.roe, latest.roe)
        put(.netDe, latest.netDe)
        put(.salesCagr3y, salesCagr3y(from: dated.map(\.1)))

        // screen-v3。直前期は dated（重複除去済み）の次の要素（暦の連続性は要求しない）。
        let previous = dated.count > 1 ? dated[1].1 : nil
        put(.cfo, latest.cfo)
        put(.cfoMargin, cfoMargin(cfo: latest.cfo, sales: latest.sales))
        put(.fcf, freeCashFlow(cfo: latest.cfo, capex: latest.capex))
        put(.operatingMarginYoy, yoyDelta(latest.operatingMargin, previous?.operatingMargin))
        put(.roicYoy, yoyDelta(latest.roic, previous?.roic))
        put(.payoutRatio, payoutRatio(dividend: latest.dividendSs, netProfit: latest.netProfit))
        return ScreenRow(
            code: code, name: name, market: market, sector: sector, periodEnd: periodEnd,
            metrics: metrics)
    }
}

/// 営業CFマージン（%、cfo ÷ sales ×100）。sales ≤ 0・欠測・非有限なら nil。
private func cfoMargin(cfo: Double?, sales: Double?) -> Double? {
    guard let cfo, let sales, sales > 0, cfo.isFinite, sales.isFinite else { return nil }
    let margin = cfo / sales * 100
    return margin.isFinite ? margin : nil
}

/// FCF（百万円、cfo − capex。Summary `capex` は投資額・正）。両方有限のときだけ。
private func freeCashFlow(cfo: Double?, capex: Double?) -> Double? {
    guard let cfo, let capex, cfo.isFinite, capex.isFinite else { return nil }
    return cfo - capex
}

/// 前年差（pp、最新期 − 直前期）。どちらか欠測・非有限なら nil。
private func yoyDelta(_ latest: Double?, _ previous: Double?) -> Double? {
    guard let latest, let previous, latest.isFinite, previous.isFinite else { return nil }
    return latest - previous
}

/// 配当性向（%、SS 配当額 ÷ 親会社帰属純利益 ×100）。
/// net_profit ≤ 0（赤字期は性向を定義しない）・dividend 欠測（無配 / 未抽出を区別しない）・
/// 非有限なら nil。記念・特別配当は区別しない。
private func payoutRatio(dividend: Double?, netProfit: Double?) -> Double? {
    guard let dividend, let netProfit, netProfit > 0, dividend.isFinite, netProfit.isFinite
    else { return nil }
    let ratio = dividend / netProfit * 100
    return ratio.isFinite ? ratio : nil
}

/// 最新 Summary 年から売上 > 0 の直近 3 期を取り、2 年間の CAGR% = `((latest/oldest)^(1/2) - 1) * 100`。
/// `fy_end` 降順で見て売上 ≤ 0 / 欠測の期は飛ばす。同一 `fy_end` は先勝ちで 1 期（配信側 `uniquedByFyEnd` と同じ）。
/// 3 期に満たない・非有限なら nil。`years[]` には書き戻さない。
private func salesCagr3y(from years: [FinancialsYear]) -> Double? {
    let positive = years.compactMap { year -> (String, Double)? in
        guard let fyEnd = year.fyEnd, let sales = year.sales, sales > 0, sales.isFinite else {
            return nil
        }
        return (fyEnd, sales)
    }
    .sorted { $0.0 > $1.0 }
    var seen = Set<String>()
    let unique = positive.filter { seen.insert($0.0).inserted }
    guard unique.count >= 3 else { return nil }
    let newest = unique[0].1
    let oldest = unique[2].1
    let percent = ((newest / oldest).squareRoot() - 1) * 100
    return percent.isFinite ? percent : nil
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
    /// `sector=` の完全一致業種（複数指定は OR。空は全業種）。カンマ区切り・キー重複の両方を受理する。
    public var sectors: [String]
    /// 単一業種の後方互換ビュー（複数指定・未指定は nil）。新規コードは `sectors` を使う。
    public var sector: String? { sectors.count == 1 ? sectors.first : nil }
    /// `{metric}_min` / `{metric}_max`。対象指標が null の行は落とす（0 扱いにしない）。
    public var ranges: [ScreenMetric: ScreenRange]
    /// `sort=`（既定 `roic`）。null の行は結果に載せない。
    public var sort: ScreenMetric
    /// `order=`（既定 `desc`）。
    public var order: ScreenSortOrder
    /// `limit=`（既定 `Api.screenLimitDefault`、上限 `Api.screenLimitMax`）。
    public var limit: Int

    public init(
        sectors: [String] = [], ranges: [ScreenMetric: ScreenRange] = [:],
        sort: ScreenMetric = .roic, order: ScreenSortOrder = .desc,
        limit: Int = Api.screenLimitDefault
    ) {
        self.sectors = sectors
        self.ranges = ranges
        self.sort = sort
        self.order = order
        self.limit = limit
    }

    /// 応答 `items[]` に載せる数値キー（core4 + フィルタと sort に使ったもの）。
    public var projectedMetrics: [ScreenMetric] {
        ScreenMetric.allCases.filter { metric in
            metric == sort || ranges[metric] != nil
                || ScreenMetric.coreDisplayMetrics.contains(metric)
        }
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
            // `sector=A,B` と `sector=A&sector=B`（呼び出し側でカンマ連結済み）の両方を OR に展開する。
            for part in trimmed.split(separator: ",") {
                let sector = part.trimmingCharacters(in: .whitespaces)
                if !sector.isEmpty, !query.sectors.contains(sector) {
                    query.sectors.append(sector)
                }
            }
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
