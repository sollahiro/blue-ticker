// 財務諸表注記取り込み: 書類1件・note_type1つ分の財務諸表注記（StatementNotePayload）= 1 行。
// 財務諸表注記取り込み実装計画（stateful-tickling-ritchie plan）・docs/statement.md
// 「statement-notes（今後）」参照。company_statements（Statement取り込み 本体）とは別テーブル
// （バージョニング独立・課金境界をエンドポイント単位で分離するため）。
//
// 主キーは "doc_id#note_type" の合成文字列。company_breakdowns（内訳取り込み）と同じ設計
// （本プロジェクトの既存テーブルは単一 String ID の慣習のため、複合IDではなくこの合成キーで揃える）。

import BlueTickerCore
import Fluent
import Foundation

final class CompanyStatementNote: Model, @unchecked Sendable {
    static let schema = "company_statement_notes"

    /// "\(docID)#\(noteType)"。`compositeID(docID:noteType:)` で構成する。
    @ID(custom: "id", generatedBy: .user)
    var id: String?

    /// EDINET docID。抽出元書類。
    @Field(key: "doc_id")
    var docID: String

    /// 注記種別（`statementNoteType*` 定数のいずれか）。
    @Field(key: "note_type")
    var noteType: String

    /// 4 桁証券コード（read-by-code の突き合わせに使う。company_breakdowns と同じ非正規化）。
    @Field(key: "code")
    var code: String

    /// 提出日時（EDINET の submitDateTime 文字列）。同一 code の最新書類選択に使う。
    @Field(key: "submit_date_time")
    var submitDateTime: String

    /// 正規化済み注記データ（StatementNotePayload）。JSONB（SQLite では TEXT）。
    @Field(key: "payload")
    var payload: StatementNotePayload

    /// payload.needsReview の複製。JSONB を掘らずに再処理キューを引くためのトップレベル列。
    @Field(key: "needs_review")
    var needsReview: Bool

    /// 解決経路（"xbrl_facts" | "llm" | "not_applicable"）。
    @Field(key: "source")
    var source: String

    /// 生入力のみのハッシュ（プロンプト/モデル/スキーマは含めない）。LLM 経由の行の
    /// 再計算スキップ判定に使う（content_hash 一致 かつ needs_review=false ならスキップ）。
    @Field(key: "content_hash")
    var contentHash: String

    /// 契約スキーマ版（note_type別: `statementNoteCacheVersion(forType:)`）。
    /// 当該 note_type の決定的経路の破壊的変更のときのみバンプする。
    @Field(key: "cache_version")
    var cacheVersion: String

    /// 対象外だった理由（`source == statementNoteSourceNotApplicable` の行にのみ設定）。
    @OptionalField(key: "not_applicable_reason")
    var notApplicableReason: String?

    /// 最終更新時刻（正規化・upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    /// id・doc_id・note_type を同時に設定する。3つを個別に代入すると呼び出し側の規律だけに
    /// 依存して食い違う余地があるため、この便利イニシャライザ経由を基本にする。
    convenience init(docID: String, noteType: String) {
        self.init()
        self.id = Self.compositeID(docID: docID, noteType: noteType)
        self.docID = docID
        self.noteType = noteType
    }

    /// "doc_id#note_type" 合成主キー。呼び出し側は必ずこの関数経由で id を組み立てること
    /// （直接文字列結合すると区切り文字の扱いがブレる）。
    static func compositeID(docID: String, noteType: String) -> String {
        "\(docID)#\(noteType)"
    }
}
