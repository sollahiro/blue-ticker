import Foundation

struct CompanyHit: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var sector: String?
    var market: String?
    var location: String?
    var iconURL: String?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, sector, market, location
        case iconURL = "icon_url"
    }
}

struct FeedUpdatesResponse: Codable {
    var schemaVersion: Int
    var date: String
    var days: Int
    var items: [FeedUpdateItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case date, days, items
    }
}

struct FeedUpdateItem: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var docId: String
    var docType: String
    var docTypeLabel: String
    var fyEnd: String
    var submittedAt: String
    var sector: String?
    var iconURL: String?

    var id: String { docId }

    enum CodingKeys: String, CodingKey {
        case code, name, sector
        case docId = "doc_id"
        case docType = "doc_type"
        case docTypeLabel = "doc_type_label"
        case fyEnd = "fy_end"
        case submittedAt = "submitted_at"
        case iconURL = "icon_url"
    }
}

struct FeedTrendResponse: Codable {
    var schemaVersion: Int
    var date: String
    var days: Int
    var items: [FeedTrendItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case date, days, items
    }
}

struct FeedTrendItem: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var count: Int
    var sector: String?
    var iconURL: String?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, count, sector
        case iconURL = "icon_url"
    }
}

struct FinancialsResponse: Codable {
    var schemaVersion: Int
    var code: String
    var name: String
    var sector: String
    var market: String
    var currency: String
    var unit: String
    var years: [FinancialsYear]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code, name, sector, market, currency, unit, years
    }
}

/// 公開 JSON の手書き。Summary（`/financials`）は水準値、Waterfall（`/waterfall`）はそれに増減分解を足す。
/// Core の内部型はコピーしない。画面が読むキーだけ持つ。
struct FinancialsYear: Codable, Hashable, Identifiable {
    var fyEnd: String?
    var financialPeriod: String?
    var docId: String?

    var sales: Double?
    var grossProfit: Double?
    var grossProfitMargin: Double?
    var sga: Double?
    var operatingProfit: Double?
    var operatingMargin: Double?
    var netProfit: Double?
    var roic: Double?
    var roe: Double?
    var nopatMargin: Double?
    var investedCapitalTurnover: Double?
    var netMargin: Double?
    var assetTurnover: Double?
    var financialLeverage: Double?
    var netDe: Double?
    var netCash: Double?
    var cfo: Double?
    var cfi: Double?
    var capex: Double?
    var totalAssets: Double?
    var currentAssets: Double?
    var nonCurrentAssets: Double?
    var currentLiabilities: Double?
    var netAssets: Double?
    /// 最新 FY の Summary 一株当たり当期純利益。単位は円/株（本表の百万円ではない）。
    var eps: Double?
    /// 最新 FY の Summary 一株当たり純資産。単位は円/株。
    var bps: Double?

    var businessProfit: Double?
    var businessProfitMargin: Double?
    var businessProfitChange: Double?
    var salesChangeImpact: Double?
    var grossMarginChangeImpact: Double?
    var sgaChangeImpact: Double?
    var roicDelta: Double?
    var roicMarginEffect: Double?
    var roicTurnoverEffect: Double?
    var roeDelta: Double?
    var roeNetMarginEffect: Double?
    var roeAssetTurnoverEffect: Double?
    var roeLeverageEffect: Double?

    var id: String { fyEnd ?? docId ?? financialPeriod ?? "" }

    enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case financialPeriod = "financial_period"
        case docId = "doc_id"
        case sales
        case grossProfit = "gross_profit"
        case grossProfitMargin = "gross_profit_margin"
        case sga
        case operatingProfit = "operating_profit"
        case operatingMargin = "operating_margin"
        case netProfit = "net_profit"
        case roic, roe
        case nopatMargin = "nopat_margin"
        case investedCapitalTurnover = "invested_capital_turnover"
        case netMargin = "net_margin"
        case assetTurnover = "asset_turnover"
        case financialLeverage = "financial_leverage"
        case netDe = "net_de"
        case netCash = "net_cash"
        case cfo
        case cfi
        case capex
        case totalAssets = "total_assets"
        case currentAssets = "current_assets"
        case nonCurrentAssets = "non_current_assets"
        case currentLiabilities = "current_liabilities"
        case netAssets = "net_assets"
        case eps
        case bps
        case businessProfit = "business_profit"
        case businessProfitMargin = "business_profit_margin"
        case businessProfitChange = "business_profit_change"
        case salesChangeImpact = "sales_change_impact"
        case grossMarginChangeImpact = "gross_margin_change_impact"
        case sgaChangeImpact = "sga_change_impact"
        case roicDelta = "roic_delta"
        case roicMarginEffect = "roic_margin_effect"
        case roicTurnoverEffect = "roic_turnover_effect"
        case roeDelta = "roe_delta"
        case roeNetMarginEffect = "roe_net_margin_effect"
        case roeAssetTurnoverEffect = "roe_asset_turnover_effect"
        case roeLeverageEffect = "roe_leverage_effect"
    }
}

struct CompanyOverviewResponse: Codable {
    var schemaVersion: Int
    var code: String
    var overview: String
    var docId: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code, overview
        case docId = "doc_id"
    }
}

struct ScreenResponse: Codable {
    var items: [ScreenItem]
    var returned: Int
    var matched: Int
    var sort: ScreenSort
}

struct ScreenSort: Codable, Equatable {
    var key: String
    var order: String
}

struct ScreenItem: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var market: String?
    var sector: String?
    var periodEnd: String?
    var sales: Double?
    var operatingMargin: Double?
    var roic: Double?
    var roe: Double?
    var netDe: Double?
    var salesCagr3y: Double?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, market, sector, sales, roic, roe
        case periodEnd = "period_end"
        case operatingMargin = "operating_margin"
        case netDe = "net_de"
        case salesCagr3y = "sales_cagr_3y"
    }
}

struct ScreenMetricFilter: Sendable, Hashable {
    var key: String
    var min: Double?
    var max: Double?
}

/// 条件検索の 6 プリセット。閾値は整数（ネット D/E は 1 桁）で `GET /v1/screen` に載せる。
/// 高CF・改善・高還元は screen-v3 の派生指標（BLT-73・75・76）。高効率案（BLT-74）は優良と
/// 重複するため採用しない。高還元の配当性向 40〜60% は暫定。
enum ScreenPreset: String, CaseIterable, Identifiable, Hashable {
    case quality = "優良"
    case growth = "成長"
    case healthyGrowth = "安定"
    case highCf = "高CF"
    case improving = "改善"
    case highPayout = "高還元"

    var id: String { rawValue }
    var title: String { rawValue }

    /// 行の説明文。1 行に収まる短さ（15 字前後）。
    var descriptionText: String {
        switch self {
        case .quality: "高収益で財務が健全な企業"
        case .growth: "利益を出しながら急成長する企業"
        case .healthyGrowth: "財務健全で安定成長する企業"
        case .highCf: "キャッシュを多く生み出す企業"
        case .improving: "収益性が改善している企業"
        case .highPayout: "配当による還元が手厚い企業"
        }
    }

    var filters: [ScreenMetricFilter] {
        switch self {
        case .quality:
            [
                ScreenMetricFilter(key: "roic", min: 10, max: nil),
                ScreenMetricFilter(key: "operating_margin", min: 8, max: nil),
                ScreenMetricFilter(key: "net_de", min: nil, max: 0.5),
            ]
        case .growth:
            [
                ScreenMetricFilter(key: "sales_cagr_3y", min: 10, max: nil),
                ScreenMetricFilter(key: "operating_margin", min: 5, max: nil),
                ScreenMetricFilter(key: "roic", min: 8, max: nil),
            ]
        case .healthyGrowth:
            [
                ScreenMetricFilter(key: "sales_cagr_3y", min: 5, max: nil),
                ScreenMetricFilter(key: "roic", min: 12, max: nil),
                ScreenMetricFilter(key: "net_de", min: nil, max: 0.3),
            ]
        case .highCf:
            // `fcf` の min は包含比較（>=）なので「FCF > 0」は fcf_min=0 で近似する。
            [
                ScreenMetricFilter(key: "cfo_margin", min: 10, max: nil),
                ScreenMetricFilter(key: "fcf", min: 0, max: nil),
                ScreenMetricFilter(key: "roic", min: 8, max: nil),
            ]
        case .improving:
            // CAGR（3 期年平均変化幅 pp/年）で持続的な改善を拾う。前年差版は 1 年のブレを拾いすぎるため不採用。
            // 変化幅だけだと赤字からの回復が上位を占めるため、到達水準を ROIC≥8% で縛る。
            [
                ScreenMetricFilter(key: "operating_margin_cagr_3y", min: 3, max: nil),
                ScreenMetricFilter(key: "roic_cagr_3y", min: 2, max: nil),
                ScreenMetricFilter(key: "roic", min: 8, max: nil),
            ]
        case .highPayout:
            [
                ScreenMetricFilter(key: "payout_ratio", min: 40, max: 60),
            ]
        }
    }

    /// `GET /v1/screen` の `sort` に載せる指標。サーバーはソート指標が null の行を落とすため、
    /// フィルタで要求していない指標をソートに使うと暗黙の絞り込みになる。各プリセットが
    /// 必ず非 null にする指標を選ぶ。
    var sortMetric: String {
        switch self {
        case .quality, .growth, .healthyGrowth, .highCf:
            "roic"
        case .improving:
            "roic_cagr_3y"
        case .highPayout:
            "payout_ratio"
        }
    }

    /// プリセット条件の短い言い換え（スコアではない）。脚注 / セクション footer 用。
    var reasonText: String {
        switch self {
        case .quality:
            "ROIC≥10% · 営業利益率≥8% · ネットD/E≤0.5倍"
        case .growth:
            "売上CAGR≥10% · 営業利益率≥5% · ROIC≥8%"
        case .healthyGrowth:
            "売上CAGR≥5% · ROIC≥12% · ネットD/E≤0.3倍"
        case .highCf:
            "営業CFマージン≥10% · FCF>0 · ROIC≥8%"
        case .improving:
            "営業利益率+3pp/年 · ROIC+2pp/年（3期CAGR） · ROIC≥8%"
        case .highPayout:
            "配当性向40〜60%（暫定）"
        }
    }
}

struct ScreenQuery: Hashable {
    var sectors: [String]
    var preset: ScreenPreset
}

struct APIErrorBody: Codable {
    var error: String?
    var status: Int?
}

enum APIClientError: LocalizedError {
    case badURL
    case http(status: Int, message: String)
    case decoding(Error)
    case transport(Error)
    case needsAccessLogin
    case hapisUnavailable

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "API の URL が不正です"
        case .http(let status, let message):
            if status == 429 {
                return "アクセスが集中しています。少し待ってから再度お試しください"
            }
            return message
        case .decoding:
            return "応答の形式を解釈できません"
        case .transport(let error):
            return error.localizedDescription
        case .needsAccessLogin:
            return "Cloudflare Access のログインが必要です。ファンドの開発ラボからログインしてください"
        case .hapisUnavailable:
            return "一時的に更新できません"
        }
    }
}
