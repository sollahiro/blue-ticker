// edinet_documents の一覧走査用の軽量射影。
// ingest は sec_code / 書類種別 / 府令 / 提出日時 / doc_id しか使わないため、
// 提出者名・期間・概要などの全カラムを毎回転送しない。

import Fluent
import Foundation

/// `EdinetDocument` と同じ表の、候補選定に使う列だけ。
final class EdinetDocumentListing: Model, @unchecked Sendable {
    static let schema = EdinetDocument.schema

    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

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
