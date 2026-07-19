// Stage 6: 書類1件・軸1つ分の正規化済み事業別/地域別売上スナップショット（BreakdownSnapshotPayload）= 1 行。
// docs/segment-normalization-concept.md「今後の検討事項5」参照。company_filing_sections（Stage 5,
// 生のsegments/geography表）とは別テーブル — LLM 経由の行（source != xbrl_facts）は
// content_hash + needs_review でのみ再計算し、cache_version バンプでの全件再計算対象にしない
// ため（decisive/deterministic 経路と再計算経済性が違う。今後の検討事項8）。
//
// 主キーは "doc_id#axis" の合成文字列（例: "S100XTLJ#business"）。本プロジェクトの既存テーブルは
// すべて単一 String ID の慣習（company_filing_sections 等）のため、複合IDではなくこの合成キーで揃える。
// axis が not_found（欠測）の場合は行自体を作らない（欠ける軸は出さない。今後の検討事項3参照）。

import BlueTickerCore
import Fluent
import Foundation

final class CompanySegmentBreakdown: Model, @unchecked Sendable {
    static let schema = "company_segment_breakdowns"

    /// "\(docID)#\(axis)"。`compositeID(docID:axis:)` で構成する。
    @ID(custom: "id", generatedBy: .user)
    var id: String?

    /// EDINET docID。抽出元書類。
    @Field(key: "doc_id")
    var docID: String

    /// "business" | "geography"。
    @Field(key: "axis")
    var axis: String

    /// 4 桁証券コード（read-by-code の突き合わせに使う。company_filing_sections と同じ非正規化）。
    @Field(key: "code")
    var code: String

    /// 提出日時（EDINET の submitDateTime 文字列）。同一 code の最新書類選択に使う。
    @Field(key: "submit_date_time")
    var submitDateTime: String

    /// 正規化済みスナップショット（BreakdownSnapshotPayload）。JSONB（SQLite では TEXT）。
    @Field(key: "payload")
    var payload: BreakdownSnapshotPayload

    /// payload.needsReview の複製。JSONB を掘らずに再処理キューを引くためのトップレベル列。
    @Field(key: "needs_review")
    var needsReview: Bool

    /// 解決経路（"xbrl_facts" | "html_table_llm" | "revenue_recognition_llm"）。
    /// `SegmentBusinessBreakdownResolver` の判断結果（監査・再計算方針の分岐に使う）。
    @Field(key: "source")
    var source: String

    /// 生入力（SegmentResult/収益認識断片）+ 採用した分母のみのハッシュ。プロンプト/モデル/
    /// スキーマは含めない（含めるとプロンプト微修正のたびに正しい行まで再計算対象になってしまう）。
    /// LLM 経由の行の再計算スキップ判定に使う（content_hash 一致 かつ needs_review=false ならスキップ）。
    @Field(key: "content_hash")
    var contentHash: String

    /// 契約スキーマ版（`segmentBreakdownCacheVersion`）。破壊的な契約変更のときのみバンプする。
    @Field(key: "cache_version")
    var cacheVersion: String

    /// LLM 経由の行にのみ添える軽量な監査情報（どの表・期間列・単位を採用したか）。
    /// 生レスポンス全文のログ化は別途未着手（今後の検討事項8）。xbrl_facts 経由の行は nil。
    @OptionalField(key: "llm_audit")
    var llmAudit: LLMBreakdownAuditPayload?

    /// 最終更新時刻（正規化・upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    /// id・doc_id・axis を同時に設定する。3つを個別に代入すると呼び出し側の規律だけに
    /// 依存して食い違う余地がある（Fable監査指摘）ため、この便利イニシャライザ経由を基本にする。
    convenience init(docID: String, axis: String) {
        self.init()
        self.id = Self.compositeID(docID: docID, axis: axis)
        self.docID = docID
        self.axis = axis
    }

    /// "doc_id#axis" 合成主キー。呼び出し側は必ずこの関数経由で id を組み立てること
    /// （直接文字列結合すると区切り文字の扱いがブレる）。
    static func compositeID(docID: String, axis: String) -> String {
        "\(docID)#\(axis)"
    }
}
