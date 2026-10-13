// 実 EDINET XBRL（analysis_cache）での事業別内訳 profit golden: 会社が「セグメント利益」と
// 定義した測度（`BreakdownNormalizer.segmentProfitTag`）。値は有報 PDF のセグメント表（当期）を
// 百万円で読み、円（× 1e6）で照合する。page は EDINET PDF のページ番号（PDF ビューアの通し番号）。
// 行は product_service 軸 snapshot の全行（segment / subtotal / reconciling）の profit。
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlSegmentProfitTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func ensureAvailable(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        let dir = xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return nil
        }
        return dir
    }

    /// member（label_raw）→ profit（百万円）。
    private func expectProfits(_ docID: String, _ expected: [String: Double]) async throws {
        guard let dir = await Self.ensureAvailable(docID) else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
        let denom = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(
            xbrlDir: dir, tables: segments.tables)
        let result = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: denom.value,
            labelsByTag: XBRLUtils.loadLabelsByTag(in: dir), denominatorTag: denom.tag,
            fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: dir), docID: docID)
        let snapshot = try #require(result.snapshot, "\(docID): product_service snapshot")
        #expect(snapshot.sourceKind == "xbrl_facts")
        var actual: [String: Double] = [:]
        for row in snapshot.rows {
            if let profit = row.profit { actual[row.labelRaw] = profit / 1_000_000 }
        }
        #expect(actual == expected, Comment(rawValue: "\(docID): profit rows"))
    }

    // 8308 りそなHD: 与信費用控除後業務純益(計)（本文 (2)⑤ でセグメント利益と定義。差異調整 報告セグメント計 330,552）
    // source: code=8308 fy_end=2026-03-31 doc_id=S100YDP3 page=223 field=segment_profit
    @Test func resonaNetOperatingProfitLessCreditCost() async throws {
        try await expectProfits("S100YDP3", [
            "ConsumerBankingReportableSegmentMember": 171617,
            "CorporateBankingReportableSegmentMember": 246938,
            "MarketTradingReportableSegmentMember": -88003,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": -38632,
            "ReportableSegmentsMember": 330552,
            "TotalOfReportableSegmentsAndOthersMember": 291920,
        ])
    }

    // 8766 東京海上HD: セグメント利益 (△は損失)（注）3 = 親会社の所有者に帰属する当期利益
    // source: code=8766 fy_end=2026-03-31 doc_id=S100YLS8 page=144 field=segment_profit
    @Test func tokioMarineOwnersOfParentProfit() async throws {
        try await expectProfits("S100YLS8", [
            "EntityTotal": 531255,
            "InternationalBusinessReportableSegmentMember": 502750,
            "JapanLifeBusinessReportableSegmentMember": -204860,
            "JapanPCBusinessReportableSegmentMember": 237541,
            "ReconcilingItemsMember": -18692,
            "ReportableSegmentsMember": 549947,
            "SolutionAndOtherBusinessReportableSegmentMember": 14515,
        ])
    }

    // 8750 第一ライフグループ: セグメント利益又は損失（△）（経常利益基準）
    // source: code=8750 fy_end=2026-03-31 doc_id=S100YC7A page=281 field=segment_profit
    @Test func daiichiLifeOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100YC7A", [
            "DomesticInsuranceBusinessReportableSegmentMember": 676269,
            "EntityTotal": 753688,
            "OtherReportableSegmentsMember": 340204,
            "OverseasInsuranceBusinessReportableSegmentMember": 112629,
            "ReconcilingItemsMember": -375415,
            "ReportableSegmentsMember": 1129103,
        ])
    }

    // 8795 T&D HD: セグメント利益又は損失(△)（経常利益基準）
    // source: code=8795 fy_end=2026-03-31 doc_id=S100Y9UP page=196 field=segment_profit
    @Test func tdOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100Y9UP", [
            "DaidoLifeInsuranceReportableSegmentsMember": 134680,
            "EntityTotal": 257191,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": 160555,
            "ReconcilingItemsMember": -165144,
            "ReportableSegmentsMember": 261780,
            "TAndDFinancialLifeInsuranceReportableSegmentsMember": 12328,
            "TAndDUnitedCapitalConsolidatedReportableSegmentMember": -1816,
            "TaiyoLifeInsuranceReportableSegmentsMember": 116588,
            "TotalOfReportableSegmentsAndOthersMember": 422335,
        ])
    }

    // 5831 しずおかFG: セグメント利益（経常利益基準）
    // source: code=5831 fy_end=2026-03-31 doc_id=S100Y9RT page=163 field=segment_profit
    @Test func shizuokaOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100Y9RT", [
            "BankingReportableSegmentsMember": 122758,
            "EntityTotal": 130298,
            "LeasingReportableSegmentsMember": 1621,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": 63135,
            "ReconcilingItemsMember": -57216,
            "ReportableSegmentsMember": 124380,
            "TotalOfReportableSegmentsAndOthersMember": 187515,
        ])
    }

    // 8601 大和証券グループ本社: セグメント利益又はセグメント損失（△）（経常利益又は経常損失（△））
    // source: code=8601 fy_end=2026-03-31 doc_id=S100YCMP page=222 field=segment_profit
    @Test func daiwaOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100YCMP", [
            "AssetManagementReportableSegmentsMember": 65432,
            "GlobalMarketsInvestmentBankingReportableSegmentsMember": 58995,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": -2919,
            "ReportableSegmentsMember": 236461,
            "TotalOfReportableSegmentsAndOthersMember": 233542,
            "WealthManagementReportableSegmentsMember": 112033,
        ])
    }

    // 9505 北陸電力: セグメント利益（経常利益基準）
    // source: code=9505 fy_end=2026-03-31 doc_id=S100YE68 page=92 field=segment_profit
    @Test func hokurikuOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100YE68", [
            "EntityTotal": 85013,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": 3901,
            "PowerGenerationSalesReportableSegmentsMember": 66363,
            "ReconcilingItemsMember": -4881,
            "TotalOfReportableSegmentsAndOthersMember": 89894,
            "TransmissionAndDistributionReportableSegmentsMember": 19629,
        ])
    }

    // 9506 東北電力: セグメント利益又は損失(△)（経常利益基準）
    // source: code=9506 fy_end=2026-03-31 doc_id=S100YEK2 page=125 field=segment_profit
    @Test func tohokuOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100YEK2", [
            "EntityTotal": 126407,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": 15948,
            "PowerGenerationSalesReportableSegmentMember": 126604,
            "PowerTransmissionAndDistributionReportableSegmentMember": -1078,
            "ReconcilingItemsMember": -15068,
            "ReportableSegmentsMember": 125526,
            "TotalOfReportableSegmentsAndOthersMember": 141475,
        ])
    }

    // 9507 四国電力: セグメント利益（経常利益基準）
    // source: code=9507 fy_end=2026-03-31 doc_id=S100YH23 page=115 field=segment_profit
    @Test func shikokuOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100YH23", [
            "ConstructionEngineeringReportableSegmentsMember": 5175,
            "EnergyReportableSegmentsMember": 5366,
            "EntityTotal": 67890,
            "InformationTechnologyCommunicationsReportableSegmentsMember": 11289,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": 3933,
            "PowerGenerationAndSalesReportableSegmentMember": 34886,
            "ReconcilingItemsMember": -1300,
            "ReportableSegmentsMember": 65256,
            "TotalOfReportableSegmentsAndOthersMember": 69190,
            "TransmissionAndDistributionReportableSegmentMember": 8538,
        ])
    }

    // 9508 九州電力: セグメント利益（経常利益基準）
    // source: code=9508 fy_end=2026-03-31 doc_id=S100YHHO page=138 field=segment_profit
    @Test func kyushuOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100YHHO", [
            "ElectricityTransmissionAndDistributionBusinessReportableSegmentMember": 8297,
            "EntityTotal": 207059,
            "ICTServicesReportableSegmentMember": 10615,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": 25,
            "OtherEnergyServiceBusinessReportableSegmentMember": 36921,
            "OverseasBusinessReportableSegmentMember": 12635,
            "PowerGenerationAndRetailElectricityBusinessReportableSegmentMember": 136420,
            "ReconcilingItemsMember": -3022,
            "ReportableSegmentsMember": 210056,
            "TotalOfReportableSegmentsAndOthersMember": 210082,
            "UrbanDevelopmentBusinessReportableSegmentsMember": 5166,
        ])
    }

    // 9509 北海道電力: セグメント利益（経常利益基準）
    // source: code=9509 fy_end=2026-03-31 doc_id=S100YDWY page=100 field=segment_profit
    @Test func hokkaidoOrdinaryIncomeBasis() async throws {
        try await expectProfits("S100YDWY", [
            "EntityTotal": 61348,
            "HokkaidoElectricPowerNetworkReportableSegmentMember": 2520,
            "HokkaidoElectricPowerReportableSegmentMember": 44618,
            "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember": 19057,
            "ReconcilingItemsMember": -4847,
            "ReportableSegmentsMember": 47138,
            "TotalOfReportableSegmentsAndOthersMember": 66196,
        ])
    }

    // 8593 三菱HCキャピタル: セグメント利益又は損失（△）（行ラベルでセグメント利益と定義。調整額 4,144・連結 162,206）
    // source: code=8593 fy_end=2026-03-31 doc_id=S100YF4V page=167 field=segment_profit
    @Test func mitsubishiHCCapitalSegmentProfitRowLabel() async throws {
        try await expectProfits("S100YF4V", [
            "AviationReportableSegmentsMember": 54538,
            "CustomerSolutionsUnitReportableSegmentsMember": 41117,
            "EntityTotal": 162206,
            "EnvironmentEnergyAndInfrastructureBusinessReportableSegmentsMember": -4852,
            "LogisticsReportableSegmentsMember": 29313,
            "MobilityReportableSegmentsMember": 3382,
            "OverseasCustomersReportableSegmentsMember": 8384,
            "RealEstateReportableSegmentsMember": 26176,
            "ReconcilingItemsMember": 4144,
        ])
    }

    // 東京海上・MS&AD: 親会社所有者帰属利益の PL 行は、セグメント表用ロールのラベル
    // （「セグメント利益…」）ではなく標準ラベル「親会社の所有者」（連結損益計算書「当期利益の帰属」）。
    // source: code=8766 fy_end=2026-03-31 doc_id=S100YLS8 page=123 field=income_statement.ProfitLossAttributableToOwnersOfParentIFRS.label
    // source: code=8725 fy_end=2026-03-31 doc_id=S100YNCJ page=134 field=income_statement.ProfitLossAttributableToOwnersOfParentIFRS.label
    @Test(arguments: [("S100YLS8", 531_255.0), ("S100YNCJ", 510_612.0)])
    func ownersOfParentProfitStatementLabel(docID: String, millions: Double) async throws {
        guard let dir = await Self.ensureAvailable(docID) else { return }
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: dir, docID: docID, statementTypes: [.incomeStatement])
        else {
            Issue.record("\(docID): statement not resolved")
            return
        }
        let row = try #require(
            year.incomeStatement.first { $0.tag == "ProfitLossAttributableToOwnersOfParentIFRS" })
        #expect(row.label == "親会社の所有者")
        #expect(row.value == millions * 1_000_000)
    }
}
