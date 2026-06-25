// Stage 4: 企業1社分の計算済み財務サマリ（公開契約 FinancialsResponse）= 1 行。
// HTML 依存抽出・waterfall を含む高コスト計算を ingest 時に済ませて格納し、
// REST の financials read 経路は EDINET 取得・XBRL パースなしで返せるようにする（OOM 回避）。
//
// edinet_xbrl_facts（Stage 3 RAW）とは別物。こちらは Stage 4 derived（計算結果）であり、
// cache_version は blueTickerVersion に連動する（計算ロジック変更で再計算させる）。
// 公開契約は response の中身（FinancialsResponse）側であり、本テーブルはサーバー内部スキーマ。

import BlueTickerCore
import Fluent
import Foundation

/// 企業1社分の計算済み財務サマリ。証券コード（4 桁）を主キー（user 生成）とする。
final class CompanyFinancials: Model, @unchecked Sendable {
    static let schema = "company_financials"

    /// 証券コード（4 桁、例: 7203）。REST の {code} と一致。
    @ID(custom: "code", generatedBy: .user)
    var id: String?

    /// 計算済み財務サマリ（公開契約 FinancialsResponse）。JSONB（SQLite では TEXT）。
    @Field(key: "response")
    var response: FinancialsResponse

    /// 計算時の blueTickerVersion。読込時に照合し、不一致なら再計算する（derived キャッシュ）。
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
