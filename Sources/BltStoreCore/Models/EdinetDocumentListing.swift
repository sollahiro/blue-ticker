// edinet_documents の一覧走査用の軽量射影。
// ingest は sec_code / edinet_code / 書類種別 / 府令 / 提出日時 / period_end / doc_id を使う。
// 提出者名・期間・概要などの全カラムを毎回転送しない。
// `sec_code` が空のときは `edinet_code` を master の上場証券コードへ写して候補にする。

import FluentKit
import Foundation

/// `EdinetDocument` と同じ表の、候補選定に使う列だけ。
package final class EdinetDocumentListing: Model, @unchecked Sendable {
    package static let schema = EdinetDocument.schema

    @ID(custom: "doc_id", generatedBy: .user)
    package var id: String?

    @Field(key: "edinet_code")
    package var edinetCode: String

    @OptionalField(key: "sec_code")
    package var secCode: String?

    @OptionalField(key: "doc_type_code")
    package var docTypeCode: String?

    @OptionalField(key: "ordinance_code")
    package var ordinanceCode: String?

    @Field(key: "submit_date_time")
    package var submitDateTime: String

    /// 財務取り込みの縮小ガード（発行体の最新有報 period_end）用。
    @OptionalField(key: "period_end")
    package var periodEnd: String?

    package init() {}
}
