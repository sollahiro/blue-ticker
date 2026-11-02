// 業種 KPI 取り込み: 書類 1 件・業種グループ 1 つ分のスナップショット = 1 行。
// company_breakdowns / company_statement_notes と同じ「合成 String ID + JSONB payload」。
// 公開 REST は無い。ステップ 1 は銀行の XBRL 数値だけ。

import BlueTickerCore
import FluentKit
import Foundation

package final class IndustryKpiFact: Model, @unchecked Sendable {
    package static let schema = "industry_kpi_facts"

    /// "\(docID)#\(industryGroup)"。`compositeID(docID:industryGroup:)` で構成する。
    @ID(custom: "id", generatedBy: .user)
    package var id: String?

    @Field(key: "doc_id")
    package var docID: String

    @Field(key: "industry_group")
    package var industryGroup: String

    @Field(key: "code")
    package var code: String

    @Field(key: "submit_date_time")
    package var submitDateTime: String

    @Field(key: "payload")
    package var payload: IndustryKpiSnapshotPayload

    @Field(key: "needs_review")
    package var needsReview: Bool

    @Field(key: "source")
    package var source: String

    @Field(key: "content_hash")
    package var contentHash: String

    @Field(key: "cache_version")
    package var cacheVersion: String

    @OptionalField(key: "not_applicable_reason")
    package var notApplicableReason: String?

    @Timestamp(key: "updated_at", on: .update)
    package var updatedAt: Date?

    package init() {}

    package convenience init(docID: String, industryGroup: String) {
        self.init()
        self.id = Self.compositeID(docID: docID, industryGroup: industryGroup)
        self.docID = docID
        self.industryGroup = industryGroup
    }

    package static func compositeID(docID: String, industryGroup: String) -> String {
        "\(docID)#\(industryGroup)"
    }
}
