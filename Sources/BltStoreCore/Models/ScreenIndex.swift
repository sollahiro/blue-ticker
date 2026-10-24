// Screen 検索用 Read Model（BLT-49）: company_financials の最新 FY を 1 社 1 行の型付き列で持つ。
// company_financials UPSERT 成功後に派生更新する（Screen 失敗で ingest は落とさない）。
// `blt-ingest screen-rebuild` で全件再生成できる。公開契約は `ScreenContract.swift`。

import BlueTickerCore
import FluentKit
import Foundation

package final class ScreenIndex: Model, @unchecked Sendable {
    package static let schema = "screen_index"

    @ID(custom: "code", generatedBy: .user)
    package var id: String?

    @Field(key: "name")
    package var name: String

    @Field(key: "market")
    package var market: String

    @Field(key: "sector")
    package var sector: String

    @Field(key: "period_end")
    package var periodEnd: String

    @OptionalField(key: "sales")
    package var sales: Double?

    @OptionalField(key: "operating_margin")
    package var operatingMargin: Double?

    @OptionalField(key: "roic")
    package var roic: Double?

    @OptionalField(key: "roe")
    package var roe: Double?

    @OptionalField(key: "net_de")
    package var netDe: Double?

    /// 物理テーブルには旧 `sales_growth` / `gross_profit_margin` が nullable で残る（削除しない）。
    /// Model には載せず、許可リスト・書き込み・GET /v1/screen からも除外する。
    @OptionalField(key: "sales_cagr_3y")
    package var salesCagr3y: Double?

    // screen-v3（高CF・高効率・改善・高還元）。定義・null 方針は `ScreenContract.swift`。
    // screen-v4 で `payout_ratio` を最新 FY 単年から直近 3 期算術平均へ差し替え。

    @OptionalField(key: "cfo")
    package var cfo: Double?

    @OptionalField(key: "cfo_margin")
    package var cfoMargin: Double?

    @OptionalField(key: "fcf")
    package var fcf: Double?

    /// 改善プリセット（3 期年平均変化幅 pp/年）。物理テーブルには旧 `operating_margin_yoy` /
    /// `roic_yoy` が nullable で残る（削除しない）。Model・許可リスト・GET /v1/screen からは除外する。
    @OptionalField(key: "operating_margin_cagr_3y")
    package var operatingMarginCagr3y: Double?

    @OptionalField(key: "roic_cagr_3y")
    package var roicCagr3y: Double?

    @OptionalField(key: "payout_ratio")
    package var payoutRatio: Double?

    /// 直近 3 期の年次配当性向（古→新）。許可リスト外の表示列。screen-v4。
    @OptionalField(key: "payout_ratio_y1")
    package var payoutRatioY1: Double?

    @OptionalField(key: "payout_ratio_y2")
    package var payoutRatioY2: Double?

    @OptionalField(key: "payout_ratio_y3")
    package var payoutRatioY3: Double?

    /// 派生契約の版（`screenIndexVersion`）。GET /v1/screen には出さない。
    /// NULL は未投影。公開床の financials は次回 ingest で投影する（現行 fin-vN 一致は問わない）。
    @OptionalField(key: "cache_version")
    package var cacheVersion: String?

    @Timestamp(key: "updated_at", on: .update)
    package var updatedAt: Date?

    package init() {}

    package func apply(_ row: ScreenRow) {
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
        cfo = row[.cfo]
        cfoMargin = row[.cfoMargin]
        fcf = row[.fcf]
        operatingMarginCagr3y = row[.operatingMarginCagr3y]
        roicCagr3y = row[.roicCagr3y]
        payoutRatio = row[.payoutRatio]
        payoutRatioY1 = row.payoutRatio3y[0]
        payoutRatioY2 = row.payoutRatio3y[1]
        payoutRatioY3 = row.payoutRatio3y[2]
        cacheVersion = screenIndexVersion
    }

    package func toRow() -> ScreenRow {
        var metrics: [ScreenMetric: Double] = [:]
        for metric in ScreenMetric.allCases {
            if let value = self[metric] { metrics[metric] = value }
        }
        return ScreenRow(
            code: id ?? "", name: name, market: market, sector: sector, periodEnd: periodEnd,
            metrics: metrics, payoutRatio3y: [payoutRatioY1, payoutRatioY2, payoutRatioY3])
    }

    package subscript(_ metric: ScreenMetric) -> Double? {
        switch metric {
        case .sales: return sales
        case .operatingMargin: return operatingMargin
        case .roic: return roic
        case .roe: return roe
        case .netDe: return netDe
        case .salesCagr3y: return salesCagr3y
        case .cfo: return cfo
        case .cfoMargin: return cfoMargin
        case .fcf: return fcf
        case .operatingMarginCagr3y: return operatingMarginCagr3y
        case .roicCagr3y: return roicCagr3y
        case .payoutRatio: return payoutRatio
        }
    }

    /// 指標 → 列 KeyPath（フィルタ・ソートで使う）。
    package static func field(_ metric: ScreenMetric) -> KeyPath<ScreenIndex, OptionalFieldProperty<ScreenIndex, Double>> {
        switch metric {
        case .sales: return \.$sales
        case .operatingMargin: return \.$operatingMargin
        case .roic: return \.$roic
        case .roe: return \.$roe
        case .netDe: return \.$netDe
        case .salesCagr3y: return \.$salesCagr3y
        case .cfo: return \.$cfo
        case .cfoMargin: return \.$cfoMargin
        case .fcf: return \.$fcf
        case .operatingMarginCagr3y: return \.$operatingMarginCagr3y
        case .roicCagr3y: return \.$roicCagr3y
        case .payoutRatio: return \.$payoutRatio
        }
    }
}
