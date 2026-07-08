import Foundation

/// Stage 1 同期用の正規化済み EDINET 書類メタ 1 件。
/// ファサードが EDINET の動的 JSON（[String: Any]）を正規化してこの型で返し、
/// BltServerCore 側が DB モデル（EdinetDocument）へ写す。日付は YYYY-MM-DD（規約）。
public struct EdinetDocumentRecord: Sendable, Codable, Equatable {
    public let docID: String
    public let edinetCode: String
    public let secCode: String?
    public let filerName: String
    public let docTypeCode: String?
    public let ordinanceCode: String?
    public let formCode: String?
    public let periodStart: String?
    public let periodEnd: String?
    public let submitDateTime: String
    public let docDescription: String?

    public init(
        docID: String,
        edinetCode: String,
        secCode: String?,
        filerName: String,
        docTypeCode: String?,
        ordinanceCode: String?,
        formCode: String?,
        periodStart: String?,
        periodEnd: String?,
        submitDateTime: String,
        docDescription: String?
    ) {
        self.docID = docID
        self.edinetCode = edinetCode
        self.secCode = secCode
        self.filerName = filerName
        self.docTypeCode = docTypeCode
        self.ordinanceCode = ordinanceCode
        self.formCode = formCode
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.submitDateTime = submitDateTime
        self.docDescription = docDescription
    }
}

/// Stage 1 同期の EDINET 取得結果。取得失敗日を高水位計算に渡す。
public struct Stage1FetchResult: Sendable, Equatable {
    public let records: [EdinetDocumentRecord]
    /// getDocumentsForDateRange で nil になった日（YYYY-MM-DD）。
    public let failedDates: [String]

    public init(records: [EdinetDocumentRecord], failedDates: [String]) {
        self.records = records
        self.failedDates = failedDates
    }
}
