// edinet_documents の一覧走査用の軽量射影。
// ingest は sec_code / edinet_code / 書類種別 / 府令 / 提出日時 / doc_id を使う。
// 提出者名・期間・概要などの全カラムを毎回転送しない。
// `sec_code` が空のときは `edinet_code` を master の上場証券コードへ写して候補にする。

import Fluent
import Foundation

/// `EdinetDocument` と同じ表の、候補選定に使う列だけ。
final class EdinetDocumentListing: Model, @unchecked Sendable {
    static let schema = EdinetDocument.schema

    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    @Field(key: "edinet_code")
    var edinetCode: String

    @OptionalField(key: "sec_code")
    var secCode: String?

    @OptionalField(key: "doc_type_code")
    var docTypeCode: String?

    @OptionalField(key: "ordinance_code")
    var ordinanceCode: String?

    @Field(key: "submit_date_time")
    var submitDateTime: String

    init() {}
}
