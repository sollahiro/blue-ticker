// 書類同期: EDINET 書類一覧の 1 件 = 1 行。
// ファイルキャッシュ（document_indexes/doc_index_<year>.json の documents[]）の DB 版。
// 公開契約は financials レスポンス側であり、本テーブルはサーバー内部スキーマ（後で柔軟に変更可）。
//
// EDINET レスポンスの dict → 本モデルへの変換（日付正規化を含む）は書き込み配線タスクで追加する。
// ここではスキーマ定義のみを置く。

import Fluent
import Foundation

/// EDINET 書類メタ 1 件。docID を主キー（user 生成）とする。
final class EdinetDocument: Model, @unchecked Sendable {
    static let schema = "edinet_documents"

    /// EDINET docID（例: S100XXXX）。一意。
    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    /// 提出者 EDINET コード。
    @Field(key: "edinet_code")
    var edinetCode: String

    /// 証券コード（5 桁）。非上場提出者では null。
    @OptionalField(key: "sec_code")
    var secCode: String?

    /// 提出者名。
    @Field(key: "filer_name")
    var filerName: String

    /// 書類種別コード（有報・半期・訂正の判別に使用）。EDINET 側で null になりうる。
    @OptionalField(key: "doc_type_code")
    var docTypeCode: String?

    /// 府令コード。
    @OptionalField(key: "ordinance_code")
    var ordinanceCode: String?

    /// 様式コード。
    @OptionalField(key: "form_code")
    var formCode: String?

    /// 対象期間の期首（YYYY-MM-DD）。
    @OptionalField(key: "period_start")
    var periodStart: String?

    /// 対象期間の期末（YYYY-MM-DD）。年度ソートに使用。
    @OptionalField(key: "period_end")
    var periodEnd: String?

    /// 提出日時（EDINET の submitDateTime 文字列）。
    @Field(key: "submit_date_time")
    var submitDateTime: String

    /// 書類概要（filings 表示用）。
    @OptionalField(key: "doc_description")
    var docDescription: String?

    /// 最終更新時刻（同期で upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}
