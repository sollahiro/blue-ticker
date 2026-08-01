import Foundation
import Testing

@testable import BlueTickerCore

/// filingsList の仕様: 提出日時降順・docID 重複排除・直近 maxYears 年度窓・最大 50 件・スキーマ。
/// 書類同期 DB read 経路（getFilingsFromRecords）の純粋部分。ライブ経路と同一の filing スキーマを返す。
@Suite struct FilingsListTests {
    private func rec(
        _ docID: String, docType: String = "120",
        periodEnd: String? = "2025-03-31", submit: String = "2025-06-20 09:00",
        desc: String? = "有価証券報告書"
    ) -> EdinetDocumentRecord {
        EdinetDocumentRecord(
            docID: docID, edinetCode: "E00001", secCode: "85910", filerName: "テスト",
            docTypeCode: docType, ordinanceCode: nil, formCode: nil,
            periodStart: nil, periodEnd: periodEnd, submitDateTime: submit, docDescription: desc)
    }

    @Test func sortsBySubmitDateTimeDescending() {
        let list = filingsList(
            from: [
                rec("A", submit: "2023-06-20 09:00"),
                rec("C", submit: "2025-06-20 09:00"),
                rec("B", submit: "2024-06-20 09:00"),
            ], maxYears: 10)
        #expect(list.map { $0["doc_id"] as? String } == ["C", "B", "A"])
    }

    @Test func deduplicatesByDocID() {
        let list = filingsList(from: [rec("A"), rec("A")], maxYears: 10)
        #expect(list.count == 1)
    }

    @Test func keepsOnlyRecentMaxYearsByPeriodEnd() {
        // 最新の期末年 2025 を起点に maxYears=2 → 2024・2025 のみ残す（2022 は窓外）。
        let list = filingsList(
            from: [
                rec("Y2025", periodEnd: "2025-03-31", submit: "2025-06-01 09:00"),
                rec("Y2024", periodEnd: "2024-03-31", submit: "2024-06-01 09:00"),
                rec("Y2022", periodEnd: "2022-03-31", submit: "2022-06-01 09:00"),
            ], maxYears: 2)
        #expect(list.map { $0["doc_id"] as? String } == ["Y2025", "Y2024"])
    }

    @Test func capsAtFiftyDocuments() {
        let many = (0..<60).map { rec("D\($0)", submit: String(format: "2025-06-%02d 09:00", ($0 % 28) + 1)) }
        #expect(filingsList(from: many, maxYears: 10).count == 50)
    }

    @Test func producesPublicFilingSchema() {
        let list = filingsList(
            from: [rec("S1", docType: "120", periodEnd: "2025-03-31", submit: "2025-06-20 09:00")],
            maxYears: 5)
        let row = try! #require(list.first)
        #expect(row["doc_id"] as? String == "S1")
        #expect(row["doc_type"] as? String == "120")
        #expect(row["doc_type_label"] as? String == "有価証券報告書")
        #expect(row["fy_end"] as? String == "2025-03")  // YYYY-MM へ切り詰め
        #expect(row["submitted_at"] as? String == "2025-06-20 09:00")
    }

    // 種別コード → ラベルの全対応。140=四半期・160=半期（Api.docTypeQuarterlyReport /
    // docTypeHalfYearReport と同じ対応）。ラベル逆転の回帰を防ぐ。
    @Test func labelsMatchDocTypeCodes() {
        #expect(docTypeLabel("120") == "有価証券報告書")
        #expect(docTypeLabel("130") == "訂正有価証券報告書")
        #expect(docTypeLabel("140") == "四半期報告書")
        #expect(docTypeLabel("150") == "訂正四半期報告書")
        #expect(docTypeLabel("160") == "半期報告書")
        #expect(docTypeLabel("170") == "訂正半期報告書")
        #expect(docTypeLabel("999") == nil)
    }

    @Test func unknownDocTypeFallsBackToDescription() {
        let list = filingsList(
            from: [rec("S1", docType: "999", desc: "その他の書類")], maxYears: 5)
        #expect(list.first?["doc_type_label"] as? String == "その他の書類")
    }

    // 簡易セマンティクス（確定）: DB read 経路は各書類の period_end をそのまま fy_end とする。
    // 旧四半期(140) は 2Q 末、訂正(130) は自身の period_end を返す（ライブ経路の親 FY 末への
    // 正規化は再現しない＝意図的な差分。schema 変更回避）。この契約を回帰で固定する。
    @Test func quarterlyAndAmendmentUseOwnPeriodEndAsFyEnd() {
        let list = filingsList(
            from: [
                rec("Q140", docType: "140", periodEnd: "2024-09-30", submit: "2024-11-10 09:00"),
                rec("A130", docType: "130", periodEnd: "2024-12-31", submit: "2025-01-15 09:00"),
            ], maxYears: 5)
        let byID = Dictionary(uniqueKeysWithValues: list.compactMap { row -> (String, String)? in
            guard let id = row["doc_id"] as? String, let fy = row["fy_end"] as? String else { return nil }
            return (id, fy)
        })
        #expect(byID["Q140"] == "2024-09")  // 2Q 末（通期期末へ正規化しない）
        #expect(byID["A130"] == "2024-12")  // 訂正は自身の period_end
    }
}
