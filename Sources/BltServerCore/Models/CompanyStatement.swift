// Statement 取り込み: 有報1件分の抽出済み BS/PL/CF（StatementYear）= 1 行。
// company_filing_sections（有報セクション取り込み）と同じ「1書類=1行」設計（docs/statement-normalization-concept.md
// 「実装方針」2）。抽出は決定論のみ（LLM 不要）のため、company_breakdowns のような
// needs_review/source/content_hash 列は持たない。
//
// 過去書類も保持するため docID を主キーにする。read-by-code のため code（4 桁）と
// submit_date_time（最新選択・複数年度の並び替え）を別カラムに持つ。cache_version は
// statementCacheVersion（blueTickerVersion 非連動）。

import BlueTickerCore
import Fluent
import Foundation

/// 有報1件分の抽出済み BS/PL/CF。EDINET docID を主キー（user 生成）とする。
final class CompanyStatement: Model, @unchecked Sendable {
    static let schema = "company_statements"

    /// EDINET docID（例: S100XXXX）。抽出元書類。
    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    /// 4 桁証券コード（例: 7203）。read-by-code の突き合わせに使う。
    @Field(key: "code")
    var code: String

    /// 提出日時（EDINET の submitDateTime 文字列）。同一 code の最新書類選択・複数年度の並び替えに使う。
    @Field(key: "submit_date_time")
    var submitDateTime: String

    /// 抽出済み BS/PL/CF（StatementYear）。JSONB（SQLite では TEXT）。
    @Field(key: "payload")
    var payload: StatementYear

    /// 抽出時の statementCacheVersion。読込・取り込みで照合し、不一致なら再抽出する。
    @Field(key: "cache_version")
    var cacheVersion: String

    /// 最終更新時刻（抽出・upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}
