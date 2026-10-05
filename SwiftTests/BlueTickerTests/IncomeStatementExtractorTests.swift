// J-GAAP/IFRS 各タグで売上高・営業利益・純利益を取得できること、
// ordinary_income フォールバック・salesLabel 付与・not_found を検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct IncomeStatementExtractorTests {

    @Test func testJgaapExtractsSalesOperatingProfitAndNetProfit() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, 900_000.0),
            ("OperatingIncomeLoss", 100_000.0, 80_000.0),
            ("ProfitLossAttributableToOwnersOfParent", 60_000.0, 50_000.0)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 1_000_000.0)
        #expect(result.salesPrior == 900_000.0)
        #expect(result.operatingProfit == 100_000.0)
        #expect(result.operatingProfitPrior == 80_000.0)
        #expect(result.netProfit == 60_000.0)
        #expect(result.netProfitPrior == 50_000.0)
        #expect(result.accountingStandard == "J-GAAP")
    }

    @Test func testOrdinaryIncomeFallbackWhenNoOperatingProfit() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, nil),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.operatingProfit == 90_000.0)
    }

    @Test func testOperatingProfitTakesPrecedenceOverOrdinaryIncome() {
        let fs = makeFieldSet(
            ("OperatingIncomeLoss", 100_000.0, nil),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.operatingProfit == 100_000.0)
    }

    @Test func testIfrsTags() {
        let fs = makeFieldSet(
            ("RevenueIFRS", 2_000_000.0, 1_900_000.0),
            ("OperatingProfitLossIFRS", 200_000.0, nil),
            ("ProfitLossAttributableToOwnersOfParentIFRS", 120_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 2_000_000.0)
        #expect(result.salesLabel == "売上収益")
        #expect(result.operatingProfit == 200_000.0)
        #expect(result.accountingStandard == "IFRS")
    }

    @Test func testIfrsProfitLossIFRSWhenParentAttributableAbsent() {
        let fs = makeFieldSet(("ProfitLossIFRS", 25_382_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.netProfit == 25_382_000_000.0)
    }

    @Test func testIfrsParentAttributableBeatsProfitLossIFRS() {
        let fs = makeFieldSet(
            ("ProfitLossAttributableToOwnersOfParentIFRS", 90.0, nil),
            ("ProfitLossIFRS", 100.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.netProfit == 90.0)
    }

    @Test func testIfrsProfitAttributableToOwnersOfParentBeatsProfitLossIFRS() {
        let fs = makeFieldSet(
            ("ProfitAttributableToOwnersOfParentIFRS", -50_763_000_000.0, nil),
            ("ProfitLossIFRS", -50_668_000_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.netProfit == -50_763_000_000.0)
    }

    @Test func testIfrsTotalNetRevenues() {
        let fs = makeFieldSet(
            ("TotalNetRevenuesIFRS", 48_036_704_000_000.0, 45_095_325_000_000.0)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 48_036_704_000_000.0)
        #expect(result.salesPrior == 45_095_325_000_000.0)
        #expect(result.salesLabel == "売上収益")
    }

    @Test func testNetSalesIfrsPreferredOverTotalNetRevenues() {
        let fs = makeFieldSet(
            ("NetSalesIFRS", 1_000.0, nil),
            ("TotalNetRevenuesIFRS", 2_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 1_000.0)
    }

    @Test func testSalesLabelOrdinaryRevenue() {
        let fs = makeFieldSet(("OrdinaryIncomeBNK", 500_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.salesLabel == "経常収益")
    }

    @Test func testSalesLabelOperatingRevenue() {
        let fs = makeFieldSet(("OperatingRevenue1SummaryOfBusinessResults", 300_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.salesLabel == "営業収益")
    }

    @Test func testIfrsOperatingRevenues() {
        // NTT: 本表は OperatingRevenuesIFRS（Summary/KeyFinancialData 接尾辞なし）
        let fs = makeFieldSet(
            ("OperatingRevenuesIFRS", 14_409_121_000_000.0, 13_374_619_000_000.0)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 14_409_121_000_000.0)
        #expect(result.salesPrior == 13_374_619_000_000.0)
        #expect(result.salesLabel == "営業収益")
    }

    @Test func testJgaapOperatingRevenueRWY() {
        let fs = makeFieldSet(("OperatingRevenueRWY", 1_086_179_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 1_086_179_000_000.0)
        #expect(result.salesLabel == "営業収益")
    }

    @Test func testSalesLabelInsuranceRevenueIFRS() {
        let fs = makeFieldSet(("InsuranceRevenueIFRS", 7_693_560_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 7_693_560_000_000.0)
        #expect(result.salesLabel == "保険収益")
    }

    @Test func testSalesLabelOperatingIncomeINS() {
        let fs = makeFieldSet(("OperatingIncomeINS", 5_625_758_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 5_625_758_000_000.0)
        #expect(result.salesLabel == "経常収益")
    }

    @Test func testInsuranceDoesNotFallbackToOrdinaryIncome() {
        let fs = makeFieldSet(
            ("OperatingIncomeINS", 5_625_758_000_000.0, nil),
            ("OrdinaryIncome", 271_946_000_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 5_625_758_000_000.0)
        #expect(result.operatingProfit == nil)
        #expect(result.operatingProfitPrior == nil)
    }

    @Test func testSalesLabelDefaultNetSales() {
        let fs = makeFieldSet(("NetSales", 1_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.salesLabel == "売上高")
    }

    @Test func testSalesLabelAbsentWhenSalesNone() {
        let result = IncomeStatementExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.salesLabel == nil)
    }

    @Test func testNotFoundAllNone() {
        let result = IncomeStatementExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.sales == nil)
        #expect(result.operatingProfit == nil)
        #expect(result.netProfit == nil)
        #expect(result.method == "not_found")
    }

    @Test func testJgaapSummaryParentAttributableNetProfit() {
        // 本表タグが無く、主要な経営指標等の親会社帰属純利益だけがある場合
        // （Alps Alpine 6770 S100YB8V と同型の J-GAAP Summary タグ）。
        let fs = makeFieldSet(
            ("ProfitLossAttributableToOwnersOfParentSummaryOfBusinessResults", 26_879_000_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.netProfit == 26_879_000_000.0)
    }

    @Test func testJgaapSummaryParentAttributableBeatsNonconsolidatedNetIncomeLoss() {
        // NetIncomeLossSummaryOfBusinessResults は個別（NonConsolidated）になりがち。
        // 連結の親会社帰属 Summary を優先する。
        let fs = makeFieldSet(
            ("ProfitLossAttributableToOwnersOfParentSummaryOfBusinessResults", 26_879_000_000.0, nil),
            ("NetIncomeLossSummaryOfBusinessResults", 46_471_000_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.netProfit == 26_879_000_000.0)
    }

    @Test func testMethodIncludesFoundFields() {
        let fs = makeFieldSet(
            ("NetSales", 1_000_000.0, nil),
            ("OperatingIncomeLoss", 100_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        let fields = result.method.split(separator: ",").map(String.init)
        #expect(fields.contains("sales"))
        #expect(fields.contains("operating_profit"))
        #expect(!(fields.contains("net_profit")))
    }

    @Test func testOrdinaryIncomeFallbackBlockedByPriorOnlyOp() {
        // OperatingIncomeLoss が前期のみ存在する場合は経常利益フォールバックを使わない
        let fs = makeFieldSet(
            ("OperatingIncomeLoss", nil, 80_000.0),
            ("OrdinaryIncome", 90_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.operatingProfit == nil)
        #expect(result.operatingProfitPrior == 80_000.0)
    }

    @Test func testPriorValuesIncluded() {
        let fs = makeFieldSet(("NetSales", nil, 900_000.0))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == nil)
        #expect(result.salesPrior == 900_000.0)
    }

    @Test func testSalesLabelRevenue2IFRS() {
        // 三菱商事等: 本表先頭は Revenue2IFRS「収益」（顧客契約+その他の源泉）
        let fs = makeFieldSet(("Revenue2IFRS", 18_915_995_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 18_915_995_000_000.0)
        #expect(result.salesLabel == "収益")
    }

    @Test func testJgaapBusinessRevenue() {
        let fs = makeFieldSet(("BusinessRevenue", 91_140_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 91_140_000.0)
        #expect(result.salesLabel == "事業収益")
    }

    @Test func testNetSalesPreferredOverBusinessRevenue() {
        let fs = makeFieldSet(
            ("NetSales", 1_000.0, nil),
            ("BusinessRevenue", 91_140_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 1_000.0)
        #expect(result.salesLabel == "売上高")
    }

    @Test func testOperatingRevenueRevenue2IFRSPreferredOverRevenue2IFRS() {
        // JPX: 営業収益は OperatingRevenueRevenue2IFRS。Revenue2IFRS は収益計。
        let fs = makeFieldSet(
            ("OperatingRevenueRevenue2IFRS", 198_735_000_000.0, nil),
            ("Revenue2IFRS", 210_000_000_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 198_735_000_000.0)
        #expect(result.salesLabel == "営業収益")
    }

    @Test func testOperatingRevenue2Label() {
        let fs = makeFieldSet(("OperatingRevenue2", 360_663_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 360_663_000_000.0)
        #expect(result.salesLabel == "営業収入")
    }

    @Test func testNetSalesPreferredOverOperatingRevenue2() {
        let fs = makeFieldSet(
            ("NetSales", 1_000.0, nil),
            ("OperatingRevenue2", 360_663_000_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 1_000.0)
        #expect(result.salesLabel == "売上高")
    }

    @Test func testNetSalesAndOperatingRevenueIFRS() {
        let fs = makeFieldSet(("NetSalesAndOperatingRevenueIFRS", 493_677_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.sales == 493_677_000_000.0)
        #expect(result.salesLabel == "売上高及び営業収入")
    }

    @Test func testShippingBusinessRevenueWAT() {
        let fs = makeFieldSet(
            ("ShippingBusinessRevenueAndOtherOperatingRevenueWAT", 1_018_364_000_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 1_018_364_000_000.0)
        #expect(result.salesLabel == "海運業収益")
    }

    @Test func testOperatingRevenueSPF() {
        let fs = makeFieldSet(("OperatingRevenueSPF", 337_709_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 337_709_000_000.0)
        #expect(result.salesLabel == "営業収益")
    }

    @Test func testContractsCompletedRevOA() {
        let fs = makeFieldSet(("ContractsCompletedRevOA", 46_586_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 46_586_000_000.0)
        #expect(result.salesLabel == "完成業務高")
    }

    @Test func testBusinessRevenuesTotalPreferredOverGoodsComponent() {
        let fs = makeFieldSet(
            ("NetSalesOfGoodsRevOA", 302_845_000.0, nil),
            ("BusinessRevenues", 874_120_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 874_120_000.0)
        #expect(result.salesLabel == "事業収益")
    }

    @Test func testGrossOperatingRevenue() {
        let fs = makeFieldSet(("GrossOperatingRevenue", 91_788_000_000.0, nil))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 91_788_000_000.0)
        #expect(result.salesLabel == "営業総収入")
    }

    /// 9436 沖縄セルラー: 連結営業収益合計タグがあれば電気通信/附帯の内訳より優先する。
    @Test func testOperatingRevenueTotalBeatsTelecomBusinessComponents() {
        let fs = makeFieldSet(
            ("OperatingRevenue1SummaryOfBusinessResults", 86_348_000_000.0, 84_314_000_000.0),
            ("OperatingRevenueOILTelecommunications", 52_291_000_000.0, 50_695_000_000.0),
            ("OperatingRevenueIncidentalELC", 34_057_000_000.0, 33_619_000_000.0)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 86_348_000_000.0)
        #expect(result.salesPrior == 84_314_000_000.0)
        #expect(result.salesLabel == "営業収益")
    }

    /// 合計タグが無ければ業種別内訳を合算する（電気通信 + 附帯）。
    @Test func testTelecomBusinessComponentsAreSummedWhenNoTotal() {
        let fs = makeFieldSet(
            ("OperatingRevenueOILTelecommunications", 52_291_000_000.0, 50_695_000_000.0),
            ("OperatingRevenueIncidentalELC", 34_057_000_000.0, 33_619_000_000.0)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 86_348_000_000.0)
        #expect(result.salesPrior == 84_314_000_000.0)
        #expect(result.salesLabel == "営業収益")
    }

    /// 9127 玉井商船: 海運業収益合計 + その他事業収益。合計タグは無い。
    @Test func testShippingAndOtherBusinessRevenueAreSummedWhenNoTotal() {
        let fs = makeFieldSet(
            ("ShippingBusinessRevenueWAT", 4_997_823_000.0, 5_273_015_000.0),
            ("OtherBusinessRevenueWAT", 124_204_000.0, 116_037_000.0)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 5_122_027_000.0)
        #expect(result.salesPrior == 5_389_052_000.0)
        #expect(result.salesLabel == "営業収益")
    }

    /// 通常の売上高企業は営業収益合計タグの追加で変わらない。
    @Test func testNetSalesUnchangedWhenNoOperatingRevenueComponents() {
        let fs = makeFieldSet(("NetSales", 1_000_000.0, 900_000.0))
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 1_000_000.0)
        #expect(result.salesPrior == 900_000.0)
        #expect(result.salesLabel == "売上高")
    }

    /// 電力: 営業収益合計 `OperatingRevenueELE` が電気事業/その他事業の内訳より勝つ。
    @Test func testOperatingRevenueELEBeatsElectricUtilityComponents() {
        let fs = makeFieldSet(
            ("OperatingRevenueELE", 6_328_574_000_000.0, nil),
            ("ElectricUtilityOperatingRevenueELE", 5_735_316_000_000.0, nil),
            ("OtherBusinessOperatingRevenueELE", 593_258_000_000.0, nil)
        )
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 6_328_574_000_000.0)
        #expect(result.salesLabel == "営業収益")
    }

    /// 東急: `OperatingRevenueRWY` は会社全体合計。Summary 合計より先。
    @Test func testOperatingRevenueRWYBeatsSummaryTotal() {
        let fs = makeFieldSet(
            ("OperatingRevenueRWY", 1_086_179_000_000.0, nil),
            ("OperatingRevenue1SummaryOfBusinessResults", 1_086_179_000_000.0, nil)
        )
        let result = resolveNetSales(fs)
        #expect(result.tag == "OperatingRevenueRWY")
        #expect(result.current == 1_086_179_000_000.0)
    }

    /// JPX: `OperatingRevenueRevenue2IFRS` は `Revenue2IFRS` と Summary 合計より先。
    @Test func testOperatingRevenueRevenue2IFRSBeatsRevenue2AndSummaryTotal() {
        let fs = makeFieldSet(
            ("OperatingRevenueRevenue2IFRS", 198_735_000_000.0, nil),
            ("Revenue2IFRS", 210_000_000_000.0, nil),
            ("OperatingRevenue1SummaryOfBusinessResults", 198_735_000_000.0, nil)
        )
        let result = resolveNetSales(fs)
        #expect(result.tag == "OperatingRevenueRevenue2IFRS")
        #expect(result.current == 198_735_000_000.0)
    }
}
