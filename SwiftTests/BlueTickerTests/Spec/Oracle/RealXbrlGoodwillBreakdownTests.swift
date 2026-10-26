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
/// IFRS ののれん及び無形資産の種類別は軸 `goodwill_and_intangibles`（`RealXbrlAssetCategoryBreakdownTests`）。

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

    private static func resolveMerged(docID: String) -> BreakdownSnapshotPayload? {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labelsByTag = XBRLUtils.breakdownMemberLabels(in: dir)
        let memberParents = XBRLUtils.operatingSegmentMemberParents(in: dir)
        let allTagElements = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
        let totalItem = resolveItem(
            fieldSetFromInstant(allTagElements), tags: Xbrl.goodwillSegmentTags)
        let companyTotal: (value: Double, tag: String)? =
            totalItem.current.flatMap { value in
                guard let tag = totalItem.tag else { return nil }
                return (value, tag)
            }
        return GoodwillNormalizer.normalize(
            facts: facts, labelsByTag: labelsByTag, memberParents: memberParents,
            companyClosingTotal: companyTotal, notes: GoodwillNoteFlags.load(from: dir))
    }

    private static func row(
        _ payload: BreakdownSnapshotPayload, labelContains needle: String
    ) -> BreakdownRowPayload? {
        let compactNeedle = needle.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        return payload.rows.first { row in
            let compact = row.label.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
            return compact.contains(compactNeedle)
        }
    }

    // source: code=2871 fy_end=2025-03-31 doc_id=S100VYA0 page=114 field=goodwill.amortization
    @Test func nichireiGoodwillAmortizationCells() async throws {
        guard await Self.ensureAvailable("S100VYA0") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100VYA0"))
        let food = try #require(Self.row(payload, labelContains: "加工食品"))
        let logistics = try #require(Self.row(payload, labelContains: "低温物流"))
        #expect(food.closing == 751_000_000)
        #expect(food.amortization == 126_000_000)
        #expect(food.impairment == nil)
        #expect(logistics.closing == 6_604_000_000)
        #expect(logistics.amortization == 577_000_000)
        #expect(payload.amortization?.denominator == 703_000_000)
    }

    // source: code=6103 fy_end=2025-03-31 doc_id=S100W043 page=96 field=goodwill.impairment
    @Test func okumaGoodwillImpairmentIsZeroWhenNoneDisclosed() async throws {
        guard await Self.ensureAvailable("S100W043") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100W043"))
        let europe = try #require(
            payload.rows.first { $0.labelRaw == "EuropeReportableSegmentsMember" })
        #expect(europe.closing == 1_053_000_000)
        #expect(europe.impairment == 0)
    }

    // source: code=8316 fy_end=2025-03-31 doc_id=S100W0S7 page=225 field=goodwill.amortization
    @Test func smfgGoodwillAmortizationCells() async throws {
        guard await Self.ensureAvailable("S100W0S7") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100W0S7"))
        let retail = try #require(
            payload.rows.first { $0.labelRaw == "RetailBusinessUnitReportableSegmentMember" })
        let global = try #require(
            payload.rows.first { $0.labelRaw == "GlobalBusinessUnitReportableSegmentMember" })
        let head = try #require(
            payload.rows.first { $0.labelRaw == "HeadOfficeAccountsEtcReportableSegmentMember" })
        #expect(retail.closing == 20_709_000_000)
        #expect(retail.amortization == 9_462_000_000)
        #expect(global.closing == 161_611_000_000)
        #expect(global.amortization == 13_754_000_000)
        #expect(head.rowKind == "reconciling")
        #expect(head.amortization == 9_695_000_000)
        #expect(payload.amortization?.denominator == 32_912_000_000)
    }

    // source: code=6841 fy_end=2025-03-31 doc_id=S100VY8X page=112 field=goodwill.amortization
    @Test func yokogawaGoodwillAmortizationCells() async throws {
        guard await Self.ensureAvailable("S100VY8X") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100VY8X"))
        let control = try #require(
            payload.rows.first {
                $0.labelRaw == "IndustrialAutomationAndControlReportableSegmentsMember"
            })
        #expect(control.closing == 6_563_000_000)
        #expect(control.amortization == 1_800_000_000)
        #expect(control.impairment == nil)
    }

    // source: code=8630 fy_end=2025-03-31 doc_id=S100R1LR page=192 field=goodwill.amortization
    @Test func sompoGoodwillAmortizationCells() async throws {
        guard await Self.ensureAvailable("S100R1LR") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100R1LR"))
        let overseas = try #require(
            payload.rows.first { $0.labelRaw == "OverseasInsuranceBusinessReportableSegmentsMember" })
        let nursing = try #require(
            payload.rows.first { $0.labelRaw == "NursingCareAndSeniorBusinessReportableSegmentsMember" })
        #expect(overseas.closing == 118_746_000_000)
        #expect(overseas.amortization == 25_003_000_000)
        #expect(nursing.closing == 78_983_000_000)
        #expect(nursing.amortization == 5_274_000_000)
        #expect(payload.amortization?.denominator == 30_277_000_000)
        #expect(overseas.impairment == nil)
    }

    // source: code=9602 fy_end=2026-02-28 doc_id=S100Y5O3 page=124 field=goodwill.closing
    @Test func tohoDurationUnamortizedBalanceClosing() async throws {
        guard await Self.ensureAvailable("S100Y5O3") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100Y5O3"))
        let anime = try #require(Self.row(payload, labelContains: "アニメ"))
        #expect(anime.rowKind == "segment")
        #expect(anime.closing == 15_448_000_000)
        #expect(payload.amortization?.denominator == 1_051_000_000)
    }

    // source: code=6501 fy_end=2026-03-31 doc_id=S100YGBO page=128 field=goodwill.closing
    @Test func hitachiGoodwillIFRSClosingAndNullAmortization() async throws {
        guard await Self.ensureAvailable("S100YGBO") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100YGBO"))
        let digital = try #require(Self.row(payload, labelContains: "デジタルシステム"))
        #expect(digital.rowKind == "segment")
        #expect(digital.closing == 1_429_043_000_000)
        #expect(payload.closing?.denominator == 2_647_501_000_000)
        #expect(digital.amortization == nil)
        #expect(payload.amortization == nil)
    }

    // source: code=6367 fy_end=2026-03-31 doc_id=S100YFQL page=156 field=goodwill.impairment
    @Test func daikinDoesNotTakeSegmentWideImpairmentAsGoodwill() async throws {
        guard await Self.ensureAvailable("S100YFQL") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100YFQL"))
        let air = try #require(Self.row(payload, labelContains: "空調・冷凍機"))
        #expect(air.impairment == nil || air.impairment == 0)
        #expect(air.impairment != 11_849_000_000)
        for row in payload.rows {
            #expect(row.impairment != 11_849_000_000)
        }
    }

    // source: code=8075 fy_end=2026-03-31 doc_id=S100YEV4 page=103 field=goodwill.closing
    @Test func shinshoNestedSubtotalIsNotASegment() async throws {
        guard await Self.ensureAvailable("S100YEV4") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100YEV4"))
        let aluminum = try #require(Self.row(payload, labelContains: "アルミ・銅"))
        #expect(aluminum.rowKind == "segment")
        #expect(aluminum.closing == 235_000_000)
        let metalSubtotal = try #require(
            payload.rows.first {
                $0.rowKind == "subtotal"
                    && ($0.label.contains("金属") || $0.labelRaw.contains("Metars"))
            })
        #expect(metalSubtotal.rowKind == "subtotal")
        #expect(payload.closing?.denominator == 235_000_000)
    }

    // source: code=9033 fy_end=2026-03-31 doc_id=S100YI48 page=98 field=goodwill.closing
    @Test func hirodenUnallocatedGoodwillIsReconciling() async throws {
        guard await Self.ensureAvailable("S100YI48") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100YI48"))
        let segments = payload.rows.filter { $0.rowKind == "segment" }
        let reconciling = payload.rows.filter { $0.rowKind == "reconciling" }
        #expect(segments.isEmpty)
        #expect(reconciling.count == 1)
        let row = try #require(reconciling.first)
        #expect(row.closing == 52_000_000)
        #expect(row.opening == 0)
        #expect(row.amortization == 0)
        #expect(row.impairment == nil)
        #expect(payload.closing?.denominator == 52_000_000)
    }

    // source: code=7320 fy_end=2026-06-30 doc_id=S100Z3SN page=101 field=goodwill.amortization
    @Test func solvvyMergedGoodwillDedupesCorporateAmortization() async throws {
        guard await Self.ensureAvailable("S100Z3SN") else { return }
        let payload = try #require(Self.resolveMerged(docID: "S100Z3SN"))
        let reconciling = payload.rows.filter { $0.rowKind == "reconciling" }
        #expect(reconciling.count == 1)
        let row = try #require(Self.row(payload, labelContains: "全社・消去"))
        #expect(row.rowKind == "reconciling")
        #expect(row.closing == 12_341_000)
        #expect(row.amortization == 3_702_000)
        #expect(payload.amortization?.denominator == 3_702_000)
    }
}

