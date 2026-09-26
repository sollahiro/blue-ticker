import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct XbrlAmendmentSourceTests {
    private func original(
        docID: String = "S100W0S7",
        edinet: String = "E03614",
        periodEnd: String = "2025-03-31"
    ) -> XbrlSourceDocument {
        XbrlSourceDocument(
            docID: docID, docTypeCode: Api.docTypeAnnualReport, edinetCode: edinet,
            periodStart: "2024-04-01", periodEnd: periodEnd,
            submitDateTime: "2025-06-20 15:37",
            docDescription: "有価証券報告書－第23期(2024/04/01－2025/03/31)")
    }

    private func correction(
        docID: String,
        parent: String? = "S100W0S7",
        edinet: String = "E03614",
        periodEnd: String? = nil,
        submit: String,
        desc: String = "訂正有価証券報告書－第23期(2024/04/01－2025/03/31)"
    ) -> XbrlSourceDocument {
        XbrlSourceDocument(
            docID: docID, docTypeCode: Api.docTypeAmendment, parentDocID: parent,
            edinetCode: edinet, periodEnd: periodEnd, submitDateTime: submit,
            docDescription: desc)
    }

    @Test func noneWhenNoCorrections() {
        #expect(matchingXbrlCorrections(original: original(), corrections: []).isEmpty)
        #expect(
            preferredCorrectionDocIDsByOriginal(originals: [original()], corrections: []).isEmpty)
    }

    @Test func oneMatchingCorrection() {
        let wrzh = correction(docID: "S100WRZH", submit: "2025-09-30 15:38")
        let ids = matchingXbrlCorrections(original: original(), corrections: [wrzh]).map(\.docID)
        #expect(ids == ["S100WRZH"])
    }

    @Test func multipleTakesLatest() {
        let wrzh = correction(docID: "S100WRZH", submit: "2025-09-30 15:38")
        let later = correction(docID: "S100X7DX", submit: "2025-11-28 14:52")
        let ids = matchingXbrlCorrections(original: original(), corrections: [wrzh, later]).map(
            \.docID)
        #expect(ids == ["S100X7DX", "S100WRZH"])
    }

    @Test func mismatchedPeriodIsRejectedEvenWithParent() {
        let otherYear = correction(
            docID: "S100X7DT", parent: "S100W0S7", periodEnd: "2023-03-31",
            submit: "2025-11-28 14:35",
            desc: "訂正有価証券報告書－第21期(2022/04/01－2023/03/31)")
        #expect(
            matchingXbrlCorrections(original: original(), corrections: [otherYear]).isEmpty)
    }

    @Test func differentParentIsRejectedEvenWithSamePeriodText() {
        let otherParent = correction(
            docID: "S100X7DV", parent: "S100TPKY", submit: "2025-11-28 14:45",
            desc: "訂正有価証券報告書－第22期(2023/04/01－2024/03/31)")
        #expect(
            matchingXbrlCorrections(original: original(), corrections: [otherParent]).isEmpty)
    }

    @Test func descriptionPeriodMatchesWhenParentIsMissing() {
        let wrzh = correction(docID: "S100WRZH", parent: nil, submit: "2025-09-30 15:38")
        let ids = matchingXbrlCorrections(original: original(), corrections: [wrzh]).map(\.docID)
        #expect(ids == ["S100WRZH"])
    }

    @Test func otherCompanyIsRejected() {
        let other = correction(
            docID: "S100ZZZZ", edinet: "E99999", submit: "2025-09-30 15:38")
        #expect(matchingXbrlCorrections(original: original(), corrections: [other]).isEmpty)
    }

    @Test func resolveAnnualXbrlDirectoryFallsBackWhenParseFails() async {
        let originalURL = URL(fileURLWithPath: "/tmp/orig")
        let chosen = await resolveAnnualXbrlDirectory(
            originalDocID: "S100W0S7",
            correctionDocIDs: ["S100WRZH"],
            download: { id in
                id == "S100WRZH" ? URL(fileURLWithPath: "/tmp/corr") : originalURL
            },
            parses: { _ in false },
            isFullReplacement: { _ in true })
        #expect(chosen == originalURL)
    }

    @Test func resolveAnnualXbrlDirectorySkipsNonReplacementThenTakesLatestEligible() async {
        let wrzh = URL(fileURLWithPath: "/tmp/wrzh")
        let originalURL = URL(fileURLWithPath: "/tmp/orig")
        let chosen = await resolveAnnualXbrlDirectory(
            originalDocID: "S100W0S7",
            correctionDocIDs: ["S100X7DX", "S100WRZH"],
            download: { id in
                switch id {
                case "S100X7DX": return URL(fileURLWithPath: "/tmp/x7dx")
                case "S100WRZH": return wrzh
                default: return originalURL
                }
            },
            parses: { _ in true },
            isFullReplacement: { $0 == wrzh })
        #expect(chosen == wrzh)
    }

    @Test func resolveAnnualXbrlDirectoryNoneUsesOriginal() async {
        let originalURL = URL(fileURLWithPath: "/tmp/orig")
        let chosen = await resolveAnnualXbrlDirectory(
            originalDocID: "S100W0S7",
            correctionDocIDs: [],
            download: { _ in originalURL },
            parses: { _ in true },
            isFullReplacement: { _ in true })
        #expect(chosen == originalURL)
    }

    @Test func xbrlPackageIsFullReplacementDetectsPhrase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xbrl-amend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("note.htm")
        try Data("訂正理由：XBRLデータのみの訂正であるため、記載内容に訂正はありません。".utf8).write(to: html)
        #expect(xbrlPackageIsFullReplacement(dir))

        try Data("通常の記載内容の訂正です。".utf8).write(to: html)
        #expect(!xbrlPackageIsFullReplacement(dir))
    }

    @Test func periodEndFromDocDescriptionTakesLastWesternDate() {
        #expect(
            periodEndFromDocDescription("訂正有価証券報告書－第23期(2024/04/01－2025/03/31)")
                == "2025-03-31")
        #expect(periodEndFromDocDescription("有価証券報告書") == nil)
    }
}
