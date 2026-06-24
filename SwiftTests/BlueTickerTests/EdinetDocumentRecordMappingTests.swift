import Foundation
import Testing

@testable import BlueTickerCore

/// mapEdinetDocumentRecords の仕様: seed 種別フィルタ・docID 重複排除・日付正規化・空文字 nil 化。
@Suite struct EdinetDocumentRecordMappingTests {
    private func doc(
        _ docID: String, docType: String, edinet: String = "E00001",
        sec: String? = "72030", periodEnd: String? = "2025-03-31"
    ) -> [String: Any] {
        var d: [String: Any] = [
            "docID": docID,
            "docTypeCode": docType,
            "edinetCode": edinet,
            "filerName": "テスト株式会社",
            "submitDateTime": "2025-06-20 09:00",
        ]
        if let sec { d["secCode"] = sec }
        if let periodEnd { d["periodEnd"] = periodEnd }
        return d
    }

    @Test func keepsOnlySeedDocTypes() {
        let docs = [
            doc("S1", docType: "120"),  // 有報: 採用
            doc("S2", docType: "350"),  // 大量保有報告書: 除外
            doc("S3", docType: "160"),  // 半期: 採用
        ]
        let ids = mapEdinetDocumentRecords(docs).map(\.docID)
        #expect(ids == ["S1", "S3"])
    }

    @Test func deduplicatesByDocID() {
        let docs = [doc("S1", docType: "120"), doc("S1", docType: "120")]
        #expect(mapEdinetDocumentRecords(docs).count == 1)
    }

    @Test func normalizesPeriodDateAndDropsEmptyStrings() {
        let docs = [doc("S1", docType: "120", sec: "  ", periodEnd: "20250331")]
        let record = try! #require(mapEdinetDocumentRecords(docs).first)
        #expect(record.periodEnd == "2025-03-31")  // YYYYMMDD → YYYY-MM-DD
        #expect(record.secCode == nil)  // 空白のみ → nil
    }

    @Test func skipsEntriesWithoutDocID() {
        let docs = [["docTypeCode": "120", "edinetCode": "E1"] as [String: Any]]
        #expect(mapEdinetDocumentRecords(docs).isEmpty)
    }
}
