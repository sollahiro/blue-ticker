// 銘柄 Overview 取り込み: 会社1社分の短い会社説明（CompanyOverviewPayload）= 1 行。
// Filing 公開 `texts` には載せない。company_icons / company_financials と同じ「会社1社=1行」。
// 生成は最新有報の「事業の内容」。由来 doc_id は列として持ち、同一 code は上書きする。
// 生成は LLM（`source=llm`）。入力が空で applicable=false の行は `not_applicable`。
// ingest stage は `overviews`。serving / 別 EP は未配線。スキーマは CreateCompanyOverviews。

import BlueTickerCore
import Fluent
import Foundation

/// 会社1社分の Overview。証券コードを主キー（user 生成）とする。
final class CompanyOverview: Model, @unchecked Sendable {
    static let schema = "company_overviews"

    /// 4 桁証券コード（例: 7203）。
    @ID(custom: "code", generatedBy: .user)
    var id: String?

    /// 生成に使った EDINET docID（最新有報）。skip 判定と由来表示用。
    @Field(key: "doc_id")
    var docID: String

    /// 提出日時（EDINET の submitDateTime 文字列）。由来書類の鮮度。
    @Field(key: "submit_date_time")
    var submitDateTime: String

    /// 生成結果（CompanyOverviewPayload）。JSONB（SQLite では TEXT）。
    @Field(key: "payload")
    var payload: CompanyOverviewPayload

    /// payload.needsReview の複製。JSONB を掘らずに再処理キューを引くためのトップレベル列。
    @Field(key: "needs_review")
    var needsReview: Bool

    /// 解決経路（`llm` | `not_applicable`）。
    @Field(key: "source")
    var source: String

    /// 生入力（事業の内容本文）のみのハッシュ。プロンプト/モデルは含めない。
    @Field(key: "content_hash")
    var contentHash: String

    /// 契約スキーマ版（`companyOverviewCacheVersion`）。
    @Field(key: "cache_version")
    var cacheVersion: String

    /// 対象外だった理由（`source == not_applicable` の行にのみ設定）。
    @OptionalField(key: "not_applicable_reason")
    var notApplicableReason: String?

    /// 最終更新時刻（正規化・upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        code: String, docID: String, submitDateTime: String, payload: CompanyOverviewPayload,
        contentHash: String, cacheVersion: String = companyOverviewCacheVersion
    ) {
        self.id = code
        self.docID = docID
        self.submitDateTime = submitDateTime
        self.payload = payload
        self.needsReview = payload.needsReview
        self.source = payload.source
        self.contentHash = contentHash
        self.cacheVersion = cacheVersion
        self.notApplicableReason = payload.notApplicableReason
    }
}
