// 銘柄 Overview 取り込み: 有報1件分の短い会社説明（CompanyOverviewPayload）= 1 行。
// Filing 公開 `texts` には載せない。company_filing_sections と同じ「1書類=1行」。
// 生成は LLM（`source=llm`）。入力が空で applicable=false の行は `not_applicable`。
// ingest stage / serving / 別 EP は未配線。スキーマだけ先に置く。

import BlueTickerCore
import Fluent
import Foundation

/// 有報1件分の Overview。EDINET docID を主キー（user 生成）とする。
final class CompanyOverview: Model, @unchecked Sendable {
    static let schema = "company_overviews"

    /// EDINET docID（例: S100XXXX）。抽出元書類。
    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    /// 4 桁証券コード（例: 7203）。read-by-code の突き合わせに使う。
    @Field(key: "code")
    var code: String

    /// 提出日時（EDINET の submitDateTime 文字列）。同一 code の最新書類選択に使う。
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
        docID: String, code: String, submitDateTime: String, payload: CompanyOverviewPayload,
        contentHash: String, cacheVersion: String = companyOverviewCacheVersion
    ) {
        self.id = docID
        self.code = code
        self.submitDateTime = submitDateTime
        self.payload = payload
        self.needsReview = payload.needsReview
        self.source = payload.source
        self.contentHash = contentHash
        self.cacheVersion = cacheVersion
        self.notApplicableReason = payload.notApplicableReason
    }
}
