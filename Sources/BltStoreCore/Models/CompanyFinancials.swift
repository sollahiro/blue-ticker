// 財務取り込み: 企業1社分の計算済み財務サマリ（公開契約 FinancialsResponse）= 1 行。
// HTML 依存抽出・waterfall を含む高コスト計算を ingest 時に済ませて格納し、
// REST の financials read 経路は EDINET 取得・XBRL パースなしで返せるようにする（OOM 回避）。
//
// edinet_xbrl_facts（XBRL 数値 RAW RAW）とは別物。こちらは 財務取り込み derived（計算結果）であり、
// cache_version は companyFinancialsCacheVersion（blueTickerVersion 非連動）に連動する。
// 計算ロジック変更時のみバンプし、月内 Micro バンプで全社再計算を強制しない（XBRL 数値 RAW と同思想）。
// 公開契約は response の中身（FinancialsResponse）側であり、本テーブルはサーバー内部スキーマ。

import BlueTickerCore
import FluentKit
import Foundation

/// 企業1社分の計算済み財務サマリ。証券コード（4 桁）を主キー（user 生成）とする。
package final class CompanyFinancials: Model, @unchecked Sendable {
    package static let schema = "company_financials"

    /// 証券コード（4 桁、例: 7203）。REST の {code} と一致。
    @ID(custom: "code", generatedBy: .user)
    package var id: String?

    /// 計算済み財務サマリ（公開契約 FinancialsResponse）。JSONB（SQLite では TEXT）。
    @Field(key: "response")
    package var response: FinancialsResponse

    /// 計算時の companyFinancialsCacheVersion。読込時に照合し、不一致なら再計算する（derived キャッシュ）。
    /// 正本抽出世代のずれは `assemblyFingerprint` で見る（`fin-vN` とは独立）。
    @Field(key: "cache_version")
    package var cacheVersion: String

    /// 計算時に要求した年数。これ未満の要求は満たせるが、超える要求は再計算が必要。
    @Field(key: "requested_years")
    package var requestedYears: Int

    /// 計算の基にした書類集合（`Api.financialsFreshnessDocTypes`）の max(submitDateTime)。
    /// 次回 ingest でこれより新しい提出があれば再計算する（high-water 鮮度トリガー）。
    /// 既存行は NULL（マイグレーション後の初回 ingest で一度だけ再計算される）。
    @OptionalField(key: "high_water")
    package var highWater: String?

    /// 組立時の正本 `cache_version` 指紋（`financialsAssemblyFingerprint`）。
    /// statement / notes / breakdown の抽出世代が変わったら `fin-vN` を上げなくても再組立する。
    /// マイグレーションは既存行を現行指紋で埋める（この列追加だけでは全件再計算しない）。
    @OptionalField(key: "assembly_fingerprint")
    package var assemblyFingerprint: String?

    /// Summary `sga` の Jev 監査。公開契約 `/financials` には出さない。
    @OptionalField(key: "llm_audit")
    package var llmAudit: FinancialsLlmAuditPayload?

    /// 最終更新時刻（計算・upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    package var updatedAt: Date?

    package init() {}
}
