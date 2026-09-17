// Screen 検索用 Read Model（BLT-49）: company_financials の最新 FY を 1 社 1 行の型付き列で持つ。
// company_financials UPSERT 成功後に派生更新する（Screen 失敗で ingest は落とさない）。
// `blt-server screen-rebuild` で全件再生成できる。公開契約は `ScreenContract.swift`。

import BlueTickerCore
import Fluent
import Foundation

final class ScreenIndex: Model, @unchecked Sendable {
    static let schema = "screen_index"

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "name")
    var name: String

    @Field(key: "market")
    var market: String

    @Field(key: "sector")
    var sector: String

    @Field(key: "period_end")
    var periodEnd: String

    @OptionalField(key: "sales")
    var sales: Double?

    @OptionalField(key: "operating_margin")
    var operatingMargin: Double?

    @OptionalField(key: "roic")
    var roic: Double?

    @OptionalField(key: "roe")
    var roe: Double?

    @OptionalField(key: "net_de")
    var netDe: Double?

    /// 物理テーブルには旧 `sales_growth` / `gross_profit_margin` が nullable で残る（削除しない）。
    /// Model には載せず、許可リスト・書き込み・GET /v1/screen からも除外する。
    @OptionalField(key: "sales_cagr_3y")
    var salesCagr3y: Double?

    /// 派生契約の版（`screenIndexVersion`）。GET /v1/screen には出さない。
    /// NULL は未投影。公開床の financials は次回 ingest で投影する（現行 fin-vN 一致は問わない）。
    @OptionalField(key: "cache_version")
    var cacheVersion: String?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    func apply(_ row: ScreenRow) {
        id = row.code
        name = row.name
        market = row.market
        sector = row.sector
        periodEnd = row.periodEnd
        sales = row[.sales]
        operatingMargin = row[.operatingMargin]
        roic = row[.roic]
        roe = row[.roe]
        netDe = row[.netDe]
        salesCagr3y = row[.salesCagr3y]
        cacheVersion = screenIndexVersion
    }

    func toRow() -> ScreenRow {
        var metrics: [ScreenMetric: Double] = [:]
        for metric in ScreenMetric.allCases {
            if let value = self[metric] { metrics[metric] = value }
        }
        return ScreenRow(
            code: id ?? "", name: name, market: market, sector: sector, periodEnd: periodEnd,
            metrics: metrics)
    }

    subscript(_ metric: ScreenMetric) -> Double? {
        switch metric {
        case .sales: return sales
        case .operatingMargin: return operatingMargin
        case .roic: return roic
        case .roe: return roe
        case .netDe: return netDe
        case .salesCagr3y: return salesCagr3y
        }
    }

    /// 指標 → 列 KeyPath（フィルタ・ソートで使う）。
    static func field(_ metric: ScreenMetric) -> KeyPath<ScreenIndex, OptionalFieldProperty<ScreenIndex, Double>> {
        switch metric {
        case .sales: return \.$sales
        case .operatingMargin: return \.$operatingMargin
        case .roic: return \.$roic
        case .roe: return \.$roe
        case .netDe: return \.$netDe
        case .salesCagr3y: return \.$salesCagr3y
        }
    }
}
