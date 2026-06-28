// 半期 Stage 4: 企業1社分の計算済み半期財務サマリ（公開契約 HalfFinancialsResponse）= 1 行。
// HalfYearAnalyzer（FY/2Q から H1/H2 を導出・waterfall）を含む高コスト計算を ingest 時に済ませて
// 格納し、REST の half-financials read 経路は EDINET 取得・XBRL パースなしで返せる（OOM 回避）。
//
// company_financials（通期 Stage 4）と別テーブル。cache_version は通期と独立した
// companyHalfFinancialsCacheVersion に連動する（半期計算ロジック変更時のみバンプ）。
// 公開契約は response の中身（HalfFinancialsResponse）側であり、本テーブルはサーバー内部スキーマ。

import BlueTickerCore
import Fluent
import Foundation

/// 企業1社分の計算済み半期財務サマリ。証券コード（4 桁）を主キー（user 生成）とする。
final class CompanyHalfFinancials: Model, @unchecked Sendable {
    static let schema = "company_half_financials"

    /// 証券コード（4 桁、例: 7203）。REST の {code} と一致。
    @ID(custom: "code", generatedBy: .user)
    var id: String?

    /// 計算済み半期財務サマリ（公開契約 HalfFinancialsResponse）。JSONB（SQLite では TEXT）。
    @Field(key: "response")
    var response: HalfFinancialsResponse

    /// 計算時の companyHalfFinancialsCacheVersion。読込時に照合し、不一致なら再計算する。
    @Field(key: "cache_version")
    var cacheVersion: String

    /// 計算時に要求した年数。これ未満の要求は満たせるが、超える要求は再計算が必要。
    @Field(key: "requested_years")
    var requestedYears: Int

    /// 最終更新時刻（計算・upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}
