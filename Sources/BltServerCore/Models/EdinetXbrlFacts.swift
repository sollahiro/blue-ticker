// Stage 3: 書類1件分の XBRL 数値 RAW（パース済み fact インデックス）= 1 行。
// Stage 4 は書類単位に全 fact をまとめて読んで計算するため、書類単位の JSONB 1 セルに格納する。
// 公開契約は financials レスポンス側であり、本テーブルはサーバー内部スキーマ（後で柔軟に変更可）。
//
// EDINET XBRL のパース（XbrlFactIndex → 本ペイロード）は Stage 2/3 取り込みタスクで追加する。
// ここではスキーマ定義のみを置く。

import BlueTickerCore
import Fluent
import Foundation

/// 書類1件分のパース済み数値 fact。docID を主キー（user 生成）とする。
final class EdinetXbrlFacts: Model, @unchecked Sendable {
    static let schema = "edinet_xbrl_facts"

    /// EDINET docID（edinet_documents と対応する論理参照）。一意。
    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    /// パース済み fact インデックス（tag → contextRef → fact）。JSONB（SQLite では TEXT）。
    @Field(key: "facts")
    var facts: XbrlFactIndexPayload

    /// パース時の xbrlFactsCacheVersion。読み込み時に照合し、不一致なら再パースする（derived キャッシュと同思想）。
    /// blueTickerVersion とは独立し、パース／スキーマ変更時のみバンプする（月内 Micro バンプで再 ingest を走らせない）。
    @Field(key: "cache_version")
    var cacheVersion: String

    /// 最終更新時刻（パース・upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}
