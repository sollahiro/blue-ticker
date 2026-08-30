// 実 EDINET XBRL キャッシュ（analysis_cache）での内訳回帰（SPEC_ORACLE の L1 実行器）。
// 対象企業は各 @Test にハードコード。共有モックは RealXbrlBreakdownSupport.swift。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct SmokeGoodwillBreakdownTests {

    private static let xbrlRoot = SmokeCacheSupport.cacheDir

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID])
        guard FileManager.default.fileExists(atPath: xbrlDir(docID).path) else {
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

    private static func resolveGoodwill(docID: String) -> BreakdownSnapshot? {
        let (facts, labels) = factsAndLabels(docID)
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir(docID), nilAsZero: false)
        let totalItem = resolveItem(fieldSetFromInstant(allTagElements), tags: Xbrl.goodwillSegmentTags)
        return BreakdownNormalizer.normalizeGoodwill(
            facts: facts, total: totalItem.current, totalTag: totalItem.tag,
            axis: breakdownAxisGoodwill, labelsByTag: labels)
    }

    private static func expectGoodwillResolved(
        docID: String, total: Double, totalTag: String,
        rows: [(labelRaw: String, amount: Double, rowKind: String)]
    ) async throws {
        guard await ensureAvailable(docID) else { return }
        let snapshot = try #require(resolveGoodwill(docID: docID))
        #expect(snapshot.axis == breakdownAxisGoodwill)
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.denominatorTag == totalTag)
        #expect(snapshot.denominator == total)
        #expect(snapshot.rows.count == rows.count)
        for expected in rows {
            let row = try #require(snapshot.rows.first { $0.labelRaw == expected.labelRaw })
            #expect(row.amount == expected.amount)
            #expect(row.rowKind == expected.rowKind)
        }
    }

    private static func expectGoodwillNotFound(docID: String) async throws {
        guard await ensureAvailable(docID) else { return }
        #expect(resolveGoodwill(docID: docID) == nil)
    }

    @Test func ajinomotoGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100VXJA")
    }

    @Test func nichireiGoodwillSplitsAcrossLogisticsAndProcessedFoods() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100VYA0", total: 7_356_000_000, totalTag: "Goodwill",
            rows: [
                ("LogisticsReportableSegmentsMember", 6_604_000_000, "segment"),
                ("MarineProductsReportableSegmentsMember", 0, "segment"),
                ("MeatAndPoultryProductsReportableSegmentsMember", 0, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    0, "segment"),
                ("ProcessedFoodsReportableSegmentsMember", 751_000_000, "segment"),
                ("RealEstateReportableSegmentsMember", 0, "segment"),
                ("ReportableSegmentsMember", 7_356_000_000, "subtotal"),
                ("TotalOfReportableSegmentsAndOthersMember", 7_356_000_000, "subtotal"),
                ("UnallocatedAmountsAndEliminationMember", 0, "reconciling"),
            ])
    }

    @Test func azPlanningGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100VU4O")
    }

    @Test func fujifilmGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100W3XJ")
    }

    @Test func okumaGoodwillAllInEuropeSegment() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100W043", total: 1_053_000_000, totalTag: "Goodwill",
            rows: [
                ("AmericasReportableSegmentsMember", 0, "segment"),
                ("AsiaAndPacificReportableSegmentsMember", 0, "segment"),
                ("EuropeReportableSegmentsMember", 1_053_000_000, "segment"),
                ("JapanReportableSegmentsMember", 0, "segment"),
                ("UnallocatedAmountsAndEliminationMember", 0, "reconciling"),
            ])
    }

    @Test func kubotaGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100XR0M")
    }

    @Test func suzukiGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100W4MT")
    }

    @Test func tohoRemacGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100XRD8")
    }

    @Test func canonGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100XTLJ")
    }

    @Test func mufgGoodwillMatchesBalanceSheetTotal() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100W4FB", total: 530_386_000_000, totalTag: "Goodwill",
            rows: [
                ("AssetManagementAndInvestorServicesBusinessGroupMember", 369_353_000_000, "segment"),
                ("CommercialBankingAndWealthManagementBusinessGroupMember", 0, "segment"),
                ("GlobalCommercialBankingBusinessGroupMember", 50_834_000_000, "segment"),
                ("GlobalCorporateAndInvestmentBankingBusinessGroupMember", 35_146_000_000, "segment"),
                ("GlobalMarketsBusinessGroupMember", 0, "segment"),
                ("JapaneseCorporateAndInvestmentBankingBusinessGroupMember", 254_000_000, "segment"),
                ("OtherMember", 0, "segment"),
                ("RetailAndDigitalBusinessGroupMember", 74_797_000_000, "segment"),
                ("TotalMember", 530_386_000_000, "subtotal"),
                ("TotalOfCustomerBusinessUnitMember", 530_386_000_000, "subtotal"),
            ])
    }

    @Test func smfgGoodwillMatchesBalanceSheetTotal() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100W0S7", total: 230_070_000_000, totalTag: "Goodwill",
            rows: [
                ("GlobalBusinessUnitReportableSegmentMember", 161_611_000_000, "segment"),
                ("GlobalMarketsBusinessUnitReportableSegmentMember", 0, "segment"),
                ("HeadOfficeAccountsEtcReportableSegmentMember", 47_749_000_000, "reconciling"),
                ("ReportableSegmentsMember", 230_070_000_000, "subtotal"),
                ("RetailBusinessUnitReportableSegmentMember", 20_709_000_000, "segment"),
                ("WholesaleBusinessUnitReportableSegmentMember", 0, "segment"),
            ])
    }
}

/// smoke 床では拾えないエッジケースの golden（Step 2）。`normalizeGoodwill` 決定論検証。
/// IFRS の `goodwill_and_intangibles` note_type は `GoodwillAndIntangiblesOracleFormatTests` が別途カバー。

@Suite struct RealXbrlGoodwillBreakdownTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard FileManager.default.fileExists(atPath: xbrlDir(docID).path) else {
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func resolveGoodwill(docID: String) -> BreakdownSnapshot? {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labelsByTag = XBRLUtils.breakdownMemberLabels(in: dir)
        let allTagElements = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
        let totalItem = resolveItem(fieldSetFromInstant(allTagElements), tags: Xbrl.goodwillSegmentTags)
        return BreakdownNormalizer.normalizeGoodwill(
            facts: facts, total: totalItem.current, totalTag: totalItem.tag,
            axis: breakdownAxisGoodwill, labelsByTag: labelsByTag)
    }

    private static func expectGoodwillResolved(
        docID: String, total: Double, totalTag: String,
        rows: [(labelRaw: String, amount: Double, rowKind: String)]
    ) async throws {
        guard await ensureAvailable(docID) else { return }
        let snapshot = try #require(resolveGoodwill(docID: docID))
        #expect(snapshot.axis == breakdownAxisGoodwill)
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.denominatorTag == totalTag)
        #expect(snapshot.denominator == total)
        #expect(snapshot.rows.count == rows.count)
        for expected in rows {
            let row = try #require(snapshot.rows.first { $0.labelRaw == expected.labelRaw })
            #expect(row.amount == expected.amount)
            #expect(row.rowKind == expected.rowKind)
        }
    }

    // MARK: - 横河電機 S100VY8X（2026-08-13）
    //
    // のれん全額が単一報告セグメント（制御）に集中。オークマ型（Europe 1セグメント）と同型だが
    // 銀行の GoodwillBeforeOffsetting 分離パターンではない通常 J-GAAP 事業会社。

    @Test func yokogawaGoodwillAllInControlSegment() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100VY8X", total: 6_563_000_000, totalTag: "Goodwill",
            rows: [
                ("IndustrialAutomationAndControlReportableSegmentsMember", 6_563_000_000, "segment"),
                ("NewBussinessesOtherReportableSegmentsMember", 0, "segment"),
                ("TestAndMeasurementReportableSegmentsMember", 0, "segment"),
            ])
    }

    // MARK: - SOMPO S100R1LR（2026-08-13）
    //
    // 保険持株。介護・海外保険の2セグメントにのれんが配分。ReportableSegmentsMember subtotal あり。
    // 生命・損保セグメントはのれんゼロ（dimension 行は出る）。

    @Test func sompoGoodwillSplitsAcrossNursingCareAndOverseasInsurance() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100R1LR", total: 197_729_000_000, totalTag: "Goodwill",
            rows: [
                ("DomesticLifeInsuranceBusinessReportableSegmentsMember", 0, "segment"),
                ("DomesticPAndCInsuranceBusinessReportableSegmentsMember", 0, "segment"),
                ("NursingCareAndSeniorBusinessReportableSegmentsMember", 78_983_000_000, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    0, "segment"),
                ("OverseasInsuranceBusinessReportableSegmentsMember", 118_746_000_000, "segment"),
                ("ReportableSegmentsMember", 197_729_000_000, "subtotal"),
                ("UnallocatedAmountsAndEliminationMember", 0, "reconciling"),
            ])
    }

    // MARK: - トヨタ S100VWVY（2026-08-13）
    //
    // BS にのれん合計タグが無く segment dimension も無い。not_found が正当（note_type 側も
    // `toyotaHasNoGoodwillNoteIsNotApplicableNotAFailure` と対応）。

    @Test func toyotaGoodwillNotFoundIsLegitimate() async throws {
        guard await Self.ensureAvailable("S100VWVY") else { return }
        #expect(Self.resolveGoodwill(docID: "S100VWVY") == nil)
    }
}

