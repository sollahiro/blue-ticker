// 実 EDINET XBRL：当期の報告セグメント売上 member が 2 以上なら専用タグを信じない。
// 7063 S100P97P / 1711 S100RADQ / 2321 S100YNI3 は 2 セグメント。
// 5125 S100UGFD は当期タグ＋当期 member 0 で単一。9853 S100LST1 は Prior タグ＋当期 member 0 で単一。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct RealXbrlCurrentYearSingleSegmentTests {

    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard cacheAvailable(docID) else {
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func segmentLabels(_ snapshot: BreakdownSnapshot) -> Set<String> {
        Set(
            snapshot.rows.filter { $0.rowKind == "segment" }.flatMap { row -> [String] in
                [row.labelRaw, row.label].compactMap { $0 }
            })
    }

    private func noteContext() -> BltServerContext {
        BltServerContext(
            apiKey: "test", cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    /// 7063 S100P97P: Prior 専用タグの定型文が残るが、当期は MX / EX の 2 報告セグメント。
    @Test func birdman7063S100P97PBuildsMXAndEXNotSingleSegmentDisclosed() async throws {
        guard await Self.ensureAvailable("S100P97P") else { return }
        let dir = Self.xbrlDir("S100P97P")
        let members = BreakdownExtractor.currentYearReportableOperatingSegmentSalesMembers(xbrlDir: dir)
        #expect(members.count >= 2)
        let joined = members.joined(separator: " ").uppercased()
        #expect(joined.contains("MX"))
        #expect(joined.contains("EX"))
        #expect(BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir) == nil)
        #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == nil)
        #expect(
            !BreakdownExtractor.dedicatedTagDisagreesWithCurrentYearReportableSegments(xbrlDir: dir))

        let extracted = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
        let sales = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(
            xbrlDir: dir, tables: extracted.tables).value
        let gate = await noteContext().segmentsAfterNoteDecision(
            axis: .business, docID: "S100P97P", extracted: extracted, xbrlDir: dir,
            consolidatedSales: sales, labelsByTag: [:])
        let kept = try #require(gate.extracted)
        #expect(gate.outcome.omissionReason != breakdownNotApplicableSingleSegmentDisclosed)

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: kept, consolidatedSales: sales)
        let snap = try #require(snapshot)
        #expect(source == .xbrlFacts)
        let labels = Self.segmentLabels(snap)
        let labelBlob = labels.joined(separator: " ").uppercased()
        #expect(labelBlob.contains("MX"))
        #expect(labelBlob.contains("EX"))
        #expect(snap.rows.filter { $0.rowKind == "segment" }.count >= 2)
        #expect(
            !BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                snapshot: snap,
                dedicatedTagText: BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(
                    xbrlDir: dir).any,
                currentYearReportableSalesMemberCount: members.count))
    }

    /// 1711 S100RADQ: 当期の報告セグメントが 2 以上。専用タグがあっても single_segment_disclosed にしない。
    @Test func code1711S100RADQBuildsTwoSegmentsNotSingleSegmentDisclosed() async throws {
        try await expectTwoCurrentYearReportableSegments(docID: "S100RADQ")
    }

    /// 2321 S100YNI3: 当期の報告セグメントが 2 以上。顧客表があっても公開内訳は 2 セグメント。
    @Test func code2321S100YNI3BuildsTwoSegmentsNotSingleSegmentDisclosed() async throws {
        try await expectTwoCurrentYearReportableSegments(docID: "S100YNI3")
    }

    /// 5125 S100UGFD: 当期コンテキストの専用タグがあり、当期の報告セグメント売上 member は 0。
    @Test func code5125S100UGFDStaysSingleSegmentFromCurrentYearTag() async throws {
        guard await Self.ensureAvailable("S100UGFD") else { return }
        let dir = Self.xbrlDir("S100UGFD")
        #expect(
            BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: dir)
                == 0)
        let current = try #require(
            BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(xbrlDir: dir).currentYear)
        #expect(!current.isEmpty)
        #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == current)
        let extracted = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
        let gate = await noteContext().segmentsAfterNoteDecision(
            axis: .business, docID: "S100UGFD", extracted: extracted, xbrlDir: dir,
            consolidatedSales: nil, labelsByTag: [:])
        #expect(gate.extracted == nil)
        #expect(gate.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
    }

    /// 9853 S100LST1: 専用タグは Prior のみ。当期 member は 0 なので省略のまま。
    @Test func code9853S100LST1StaysSingleSegmentFromPriorTag() async throws {
        guard await Self.ensureAvailable("S100LST1") else { return }
        let dir = Self.xbrlDir("S100LST1")
        let texts = BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(xbrlDir: dir)
        #expect(texts.currentYear == nil)
        #expect(texts.any != nil)
        #expect(
            BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: dir)
                == 0)
        #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == texts.any)
        let extracted = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
        let gate = await noteContext().segmentsAfterNoteDecision(
            axis: .business, docID: "S100LST1", extracted: extracted, xbrlDir: dir,
            consolidatedSales: nil, labelsByTag: [:])
        #expect(gate.extracted == nil)
        #expect(gate.outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
    }

    /// Prod の v15 `single_segment_disclosed` 173 件を再分類する。
    /// `BLT_VERIFY_V15_SINGLE_SEGMENT=1` と `BLT_V15_SINGLE_SEGMENT_DOCS`（code/doc_id JSON）があるときだけ走る。
    @Test func v15SingleSegmentDisclosedDocsStaySingleExcept7063S100P97P() async throws {
        guard ProcessInfo.processInfo.environment["BLT_VERIFY_V15_SINGLE_SEGMENT"] == "1" else {
            return
        }
        guard let listPath = ProcessInfo.processInfo.environment["BLT_V15_SINGLE_SEGMENT_DOCS"] else {
            Issue.record("BLT_V15_SINGLE_SEGMENT_DOCS is required")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: listPath))
        let rows = try JSONDecoder().decode([V15SingleSegmentDoc].self, from: data)
        #expect(rows.count == 173)
        var flipped: [String] = []
        for row in rows {
            guard await Self.ensureAvailable(row.docID) else {
                Issue.record("missing XBRL for \(row.code) \(row.docID)")
                continue
            }
            let dir = Self.xbrlDir(row.docID)
            let count = BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(
                xbrlDir: dir)
            let is7063P97P = row.code == "7063" && row.docID == "S100P97P"
            if is7063P97P {
                #expect(count >= 2)
                #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == nil)
            } else if count >= 2 {
                flipped.append("\(row.code) \(row.docID) count=\(count)")
            }
        }
        #expect(flipped.isEmpty, "unexpected flips: \(flipped.joined(separator: ", "))")
    }

    private func expectTwoCurrentYearReportableSegments(docID: String) async throws {
        guard await Self.ensureAvailable(docID) else { return }
        let dir = Self.xbrlDir(docID)
        let count = BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(
            xbrlDir: dir)
        #expect(count >= 2)
        #expect(BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: dir) == nil)

        let extracted = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
        let sales = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(
            xbrlDir: dir, tables: extracted.tables).value
        let gate = await noteContext().segmentsAfterNoteDecision(
            axis: .business, docID: docID, extracted: extracted, xbrlDir: dir,
            consolidatedSales: sales, labelsByTag: [:])
        let kept = try #require(gate.extracted)
        #expect(gate.outcome.omissionReason != breakdownNotApplicableSingleSegmentDisclosed)

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: kept, consolidatedSales: sales)
        if let snap = snapshot {
            #expect(snap.axis == breakdownAxisProductService)
            #expect(snap.rows.filter { $0.rowKind == "segment" }.count >= 2)
            #expect(
                !BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                    snapshot: snap,
                    dedicatedTagText: BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(
                        xbrlDir: dir).currentYear
                        ?? BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(xbrlDir: dir).any,
                    currentYearReportableSalesMemberCount: count))
        } else {
            #expect(kept.method == "xbrl_facts" || !kept.tables.isEmpty)
            #expect(
                !BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                    snapshot: nil,
                    dedicatedTagText: BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(
                        xbrlDir: dir).currentYear
                        ?? BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(xbrlDir: dir).any,
                    currentYearReportableSalesMemberCount: count))
        }
        _ = source
    }
}

private struct V15SingleSegmentDoc: Decodable {
    let code: String
    let docID: String

    enum CodingKeys: String, CodingKey {
        case code
        case docID = "doc_id"
    }
}
