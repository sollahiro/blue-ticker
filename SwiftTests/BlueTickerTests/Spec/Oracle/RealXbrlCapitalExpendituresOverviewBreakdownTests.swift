// 実 EDINET XBRL キャッシュ（analysis_cache）での内訳回帰（SPEC_ORACLE の L1 実行器）。
// 対象企業は各 @Test にハードコード。共有モックは RealXbrlBreakdownSupport.swift。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlCapitalExpendituresOverviewBreakdownTests {

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

    private static func factsAndLabels(_ docID: String) -> (facts: [BreakdownFact], labels: [String: String]) {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        return (facts, XBRLUtils.breakdownMemberLabels(in: dir))
    }

    private static let overviewTag = "CapitalExpendituresOverviewOfCapitalExpendituresEtc"

    /// 富士フイルム: Overview タグに報告セグメント＋未配賦＋無dimension合計。
    @Test func fujifilmOverviewSegmentFactsReconstructBreakdown() async throws {
        guard await Self.ensureAvailable("S100W3XJ") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W3XJ")
        let overviewFacts = facts.filter { $0.tag == Self.overviewTag }
        #expect(overviewFacts.count == 7)

        let snapshot = try #require(
            BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                facts: facts, labelsByTag: labels))
        #expect(snapshot.denominatorTag == Self.overviewTag)
        #expect(snapshot.denominator == 532_138_000_000)
        #expect(snapshot.sourceKind == "xbrl_facts")
        #expect(snapshot.needsReview == false)

        let healthcare = try #require(
            snapshot.rows.first { $0.labelRaw == "HealthcareReportableSegmentsMember" })
        #expect(healthcare.amount == 448_362_000_000)
        #expect(healthcare.rowKind == "segment")
        #expect(healthcare.label == "ヘルスケア")

        let imaging = try #require(
            snapshot.rows.first { $0.labelRaw == "ImagingReportableSegmentsMember" })
        #expect(imaging.amount == 15_447_000_000)

        let reportable = try #require(
            snapshot.rows.first { $0.labelRaw == "ReportableSegmentsMember" })
        #expect(reportable.amount == 529_533_000_000)
        #expect(reportable.rowKind == "subtotal")

        let unallocated = try #require(
            snapshot.rows.first { $0.labelRaw == "UnallocatedAmountsAndEliminationMember" })
        #expect(unallocated.amount == 2_605_000_000)
        #expect(unallocated.rowKind == "reconciling")

        let entity = try #require(
            snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entity.amount == 532_138_000_000)
        #expect(entity.rowKind == "subtotal")
    }

    /// キヤノン: Overview タグに4事業＋その他及び全社＋無dimension合計。
    @Test func canonOverviewSegmentFactsReconstructBreakdown() async throws {
        guard await Self.ensureAvailable("S100XTLJ") else { return }
        let (facts, labels) = Self.factsAndLabels("S100XTLJ")
        let overviewFacts = facts.filter { $0.tag == Self.overviewTag }
        #expect(overviewFacts.count == 6)

        let snapshot = try #require(
            BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                facts: facts, labelsByTag: labels))
        #expect(snapshot.denominatorTag == Self.overviewTag)
        #expect(snapshot.denominator == 211_673_000_000)
        #expect(snapshot.sourceKind == "xbrl_facts")
        #expect(snapshot.needsReview == false)

        let printing = try #require(
            snapshot.rows.first { $0.labelRaw == "PrintingBusinessUnitReportableSegmentsMember" })
        #expect(printing.amount == 66_669_000_000)
        #expect(printing.label == "プリンティングビジネスユニット")

        let otherAndCorporate = try #require(
            snapshot.rows.first { $0.labelRaw == "OtherAndCorporateMember" })
        #expect(otherAndCorporate.amount == 80_042_000_000)
        #expect(otherAndCorporate.rowKind == "segment")

        let entity = try #require(
            snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entity.amount == 211_673_000_000)
        #expect(entity.rowKind == "subtotal")
    }

    /// facts 経路の合計は HTML（notes）経路の合計と一致する。
    @Test func usGaapOverviewFactsMatchHtmlPathwayTotals() async throws {
        for docID in ["S100W3XJ", "S100XTLJ"] {
            guard await Self.ensureAvailable(docID) else { return }
            let dir = Self.xbrlDir(docID)
            let (facts, labels) = Self.factsAndLabels(docID)
            let factsSnap = try #require(
                BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                    facts: facts, labelsByTag: labels))
            guard case .resolved(let payload, _, _) =
                StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: dir),
                let segments = payload.capexSegments,
                let htmlSnap = BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                    segments: segments)
            else {
                Issue.record("\(docID): HTML Capex Overview が解決できない")
                return
            }
            #expect(factsSnap.denominator == htmlSnap.denominator, "\(docID)")
            #expect(factsSnap.needsReview == false, "\(docID)")
            #expect(htmlSnap.needsReview == false, "\(docID)")
        }
    }
}

// smoke 固定11社での employees 軸実データゴールデン（2026-08-12 目視確認済み）。
// キャッシュは `tmp_cache/edinet/`（`SmokeCacheSupport.cacheDir`）。全社 `NumberOfEmployees`
// の事業セグメント dimension 付き fact から内訳を組み立て、denominator は非dimension の
// 全社合計（`smoke/smoke_expected` の employees.current と一致）。11社すべて
// needsReview=false・sum(rows)==denominator・denominatorTag=NumberOfEmployees。
// オークマのみ報告セグメントが地域軸（日本/米州/欧州/アジア・パシフィック）。

