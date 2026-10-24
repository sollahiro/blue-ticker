// 関係取り込み: 書類 1 件の相手 1 件 = 1 行（顧客・関係会社・親会社等・出資先・大株主）。
// 会社ごとに最新有報 1 件の行だけを持つ（新しい有報で書き換わるのはその会社の行だけ。逆引き専用の行は作らない）。
// `kind = none` の行は節の状態（省略・表なし・要素なし・タグなし）だけを持ち、「省略」と「未抽出」を区別する。
// ingest stage は `relations`。公開 REST は `GET /v1/companies/{code}/relations`。スキーマは CreateCompanyRelations。

import BlueTickerCore
import Fluent
import Foundation

final class CompanyRelation: Model, @unchecked Sendable {
    static let schema = "company_relations"

    @ID(key: .id)
    var id: UUID?

    /// 提出会社の 4 桁証券コード。
    @Field(key: "code")
    var code: String

    @Field(key: "doc_id")
    var docID: String

    @Field(key: "submit_date_time")
    var submitDateTime: String

    /// 当期末（`YYYY-MM-DD`）。取れなければ null。
    @OptionalField(key: "fy_end")
    var fyEnd: String?

    /// `main_customers` / `affiliated_entities` / `parent_company_info` / `policy_holdings` / `major_shareholders`。
    @Field(key: "section")
    var section: String

    /// `customer` / `parent` / `subsidiary` / `affiliate` / `other_related` / `investee` /
    /// `major_shareholder` / `unclassified` / `none`。
    @Field(key: "kind")
    var kind: String

    /// 節内の出現順（0 始まり）。
    @Field(key: "position")
    var position: Int

    @Field(key: "name_raw")
    var nameRaw: String

    /// 照合用の正規化名（`RelationNameNormalizer`）。
    @Field(key: "name_norm")
    var nameNorm: String

    @OptionalField(key: "amount_yen")
    var amountYen: Double?

    @OptionalField(key: "segment_label")
    var segmentLabel: String?

    @OptionalField(key: "voting_ratio")
    var votingRatio: Double?

    @OptionalField(key: "voting_ratio_indirect")
    var votingRatioIndirect: Double?

    @OptionalField(key: "voting_ratio_close_parties")
    var votingRatioCloseParties: Double?

    /// 相手が上場なら 4 桁コード（`via_listed_parent` は親のコード）。
    @OptionalField(key: "related_code")
    var relatedCode: String?

    /// 名前解決の結果（`relationResolution*`）。`kind = none` は null。
    @OptionalField(key: "resolution")
    var resolution: String?

    /// 解決したときの名簿の指紋（`RelationNameDirectory.fingerprint`）。今の名簿とずれた行は解き直す。
    @OptionalField(key: "resolver_key")
    var resolverKey: String?

    @Field(key: "needs_review")
    var needsReview: Bool

    /// `rule` / `jev`（区分を誰が決めたか）。
    @Field(key: "decided_by")
    var decidedBy: String

    @OptionalField(key: "shares")
    var shares: Double?

    @OptionalField(key: "book_value_yen")
    var bookValueYen: Double?

    @OptionalField(key: "purpose")
    var purpose: String?

    @OptionalField(key: "is_deemed")
    var isDeemed: Bool?

    @OptionalField(key: "holder")
    var holder: String?

    /// 大株主の所有割合（XBRL の値。0.128 = 12.8%）。
    @OptionalField(key: "ratio")
    var ratio: Double?

    /// 大株主の順位（1 始まり）。
    @OptionalField(key: "rank")
    var rank: Int?

    /// 大株主の住所（保存のみ。応答に載せない）。
    @OptionalField(key: "address")
    var address: String?

    /// `kind = none` の行の状態（`omitted` / `no_table` / `not_found` / `no_tags` / `untagged_table`）。
    @OptionalField(key: "section_status")
    var sectionStatus: String?

    /// 訂正 overlay 回帰の warning（付いた書類の行は公開しない）。
    @OptionalField(key: "warning")
    var warning: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        code: String, docID: String, submitDateTime: String, fyEnd: String?,
        draft: CompanyRelationDraft, warning: String?,
        cacheVersion: String = companyRelationsCacheVersion
    ) {
        self.code = code
        self.docID = docID
        self.submitDateTime = submitDateTime
        self.fyEnd = fyEnd
        self.section = draft.section
        self.kind = draft.kind
        self.position = draft.position
        self.nameRaw = draft.nameRaw
        self.nameNorm = relationNameNorm(nameRaw: draft.nameRaw, kind: draft.kind)
        self.amountYen = draft.amountYen
        self.segmentLabel = draft.segmentLabel
        self.votingRatio = draft.votingRatio
        self.votingRatioIndirect = draft.votingRatioIndirect
        self.votingRatioCloseParties = draft.votingRatioCloseParties
        self.relatedCode = nil
        self.resolution = nil
        self.resolverKey = nil
        self.needsReview = draft.needsReview
        self.decidedBy = draft.decidedBy
        self.shares = draft.shares
        self.bookValueYen = draft.bookValueYen
        self.purpose = draft.purpose
        self.isDeemed = draft.isDeemed
        self.holder = draft.holder
        self.ratio = draft.ratio
        self.rank = draft.rank
        self.address = draft.address
        self.sectionStatus = draft.sectionStatus
        self.warning = warning
        self.cacheVersion = cacheVersion
    }
}

/// 格納行の `name_norm`。大株主だけ末尾の名義表記の括弧を外す。
func relationNameNorm(nameRaw: String, kind: String) -> String {
    RelationNameNormalizer.normalize(nameRaw, stripsTrailingParenthesis: kind == relationKindMajorShareholder)
}
