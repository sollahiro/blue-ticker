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

    @Test func multipleTakesLatestFirst() {
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

    @Test func overlayPrecedenceReplacesMatchingCells() {
        let base: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 100, "Prior1YearDuration": 90],
        ]
        let overlay: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 110],
        ]
        let merged = overlayKeyedFacts(base: base, overlay: overlay)
        #expect(merged["NetSales"]?["CurrentYearDuration"] == 110)
        #expect(merged["NetSales"]?["Prior1YearDuration"] == 90)
    }

    @Test func overlayKeepsItemsAbsentFromPartialCorrection() {
        let base: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 100],
            "OperatingIncome": ["CurrentYearDuration": 20],
        ]
        let overlay: [String: [String: Double]] = [
            "NetSales": ["CurrentYearDuration": 105],
        ]
        let merged = overlayKeyedFacts(base: base, overlay: overlay)
        #expect(merged["NetSales"]?["CurrentYearDuration"] == 105)
        #expect(merged["OperatingIncome"]?["CurrentYearDuration"] == 20)
    }

    @Test func overlayMultipleCorrectionsLatestWins() {
        let base: [String: [String: Double]] = ["NetSales": ["CurrentYearDuration": 100]]
        let first = overlayKeyedFacts(
            base: base, overlay: ["NetSales": ["CurrentYearDuration": 110]])
        let second = overlayKeyedFacts(
            base: first, overlay: ["NetSales": ["CurrentYearDuration": 120]])
        #expect(second["NetSales"]?["CurrentYearDuration"] == 120)
    }

    @Test func overlayReplacesRowMemberTableAsUnit() {
        let nameTag =
            "NameOfSecuritiesDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestmentReportingCompany"
        let base: [String: [String: String]] = [
            nameTag: [
                "CurrentYearInstant_Row1Member": "原本A",
                "CurrentYearInstant_Row2Member": "原本B",
                "CurrentYearInstant_Row3Member": "原本C",
            ],
            "NetSales": ["CurrentYearDuration": "keep"],
        ]
        let overlay: [String: [String: String]] = [
            nameTag: [
                "CurrentYearInstant_Row1Member": "訂正A",
                "CurrentYearInstant_Row2Member": "訂正B",
            ],
        ]
        let merged = overlayKeyedFacts(base: base, overlay: overlay)
        #expect(merged[nameTag]?.count == 2)
        #expect(merged[nameTag]?["CurrentYearInstant_Row1Member"] == "訂正A")
        #expect(merged[nameTag]?["CurrentYearInstant_Row2Member"] == "訂正B")
        #expect(merged[nameTag]?["CurrentYearInstant_Row3Member"] == nil)
        #expect(merged["NetSales"]?["CurrentYearDuration"] == "keep")
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
            materialize: { original, overlays in
                Issue.record("parse失敗の訂正を materialize してはいけない: \(overlays)")
                return original
            })
        #expect(chosen == originalURL)
    }

    @Test func resolveAnnualXbrlDirectoryAppliesParseableCorrectionsOldestFirst() async {
        let originalURL = URL(fileURLWithPath: "/tmp/orig")
        let wrzh = URL(fileURLWithPath: "/tmp/wrzh")
        let x7dx = URL(fileURLWithPath: "/tmp/x7dx")
        let merged = URL(fileURLWithPath: "/tmp/merged")
        let box = OverlayCapture()
        let chosen = await resolveAnnualXbrlDirectory(
            originalDocID: "S100W0S7",
            correctionDocIDs: ["S100X7DX", "S100WRZH"],
            download: { id in
                switch id {
                case "S100X7DX": return x7dx
                case "S100WRZH": return wrzh
                default: return originalURL
                }
            },
            parses: { $0 != URL(fileURLWithPath: "/tmp/broken") },
            materialize: { original, overlays in
                box.overlays = overlays
                #expect(original == originalURL)
                return merged
            })
        #expect(chosen == merged)
        #expect(box.overlays == [wrzh, x7dx])
    }

    @Test func resolveAnnualXbrlDirectorySkipsUnparseableThenOverlaysRest() async {
        let originalURL = URL(fileURLWithPath: "/tmp/orig")
        let wrzh = URL(fileURLWithPath: "/tmp/wrzh")
        let merged = URL(fileURLWithPath: "/tmp/merged")
        let box = OverlayCapture()
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
            parses: { $0 == wrzh || $0 == originalURL },
            materialize: { _, overlays in
                box.overlays = overlays
                return merged
            })
        #expect(chosen == merged)
        #expect(box.overlays == [wrzh])
    }

    @Test func resolveAnnualXbrlDirectoryNoneUsesOriginal() async {
        let originalURL = URL(fileURLWithPath: "/tmp/orig")
        let chosen = await resolveAnnualXbrlDirectory(
            originalDocID: "S100W0S7",
            correctionDocIDs: [],
            download: { _ in originalURL },
            parses: { _ in true },
            materialize: { original, overlays in
                #expect(overlays.isEmpty)
                return original
            })
        #expect(chosen == originalURL)
    }

    @Test func periodEndFromDocDescriptionTakesLastWesternDate() {
        #expect(
            periodEndFromDocDescription("訂正有価証券報告書－第23期(2024/04/01－2025/03/31)")
                == "2025-03-31")
        #expect(periodEndFromDocDescription("有価証券報告書") == nil)
    }

    @Test func isRowMemberContextDetectsPolicyHoldingAndDividends() {
        #expect(isRowMemberContext("CurrentYearInstant_Row12Member"))
        #expect(isRowMemberContext("FilingDateInstant_Row1Member"))
        #expect(!isRowMemberContext("CurrentYearInstant"))
        #expect(!isRowMemberContext("CurrentYearDuration_ReportableSegmentMember"))
    }
}

private final class OverlayCapture: @unchecked Sendable {
    var overlays: [URL] = []
}
