// Python tests/test_xbrl_tangible_fixed_assets.py 相当
// 有形固定資産（PPE）抽出を実XBRLキャッシュ値ベースで検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct TangibleFixedAssetsExtractorTests {

    private func extract(_ elementsXml: String) -> TangibleFixedAssetsResult {
        var result: TangibleFixedAssetsResult!
        let xml = XBRLTestSupport.makeXbrlInstant(elementsXml)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let (fs, std) = XBRLTestSupport.instantFieldSet(in: dir)
            result = TangibleFixedAssetsExtractor.extract(fieldSet: fs, accountingStandard: std)
        }
        return result
    }

    // MARK: - IFRS（味の素・日立相当）

    @Test func testAjinomotoValues() {
        let result = extract("""
            <jpifrs_cor:PropertyPlantAndEquipmentIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">581330000000</jpifrs_cor:PropertyPlantAndEquipmentIFRS>
            <jpifrs_cor:BuildingsAndStructuresIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">244337000000</jpifrs_cor:BuildingsAndStructuresIFRS>
            <jpifrs_cor:LandIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">46252000000</jpifrs_cor:LandIFRS>
            <jpifrs_cor:MachineryAndVehiclesIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">212696000000</jpifrs_cor:MachineryAndVehiclesIFRS>
            <jpifrs_cor:ToolsFurnitureAndFixturesIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">23870000000</jpifrs_cor:ToolsFurnitureAndFixturesIFRS>
            <jpifrs_cor:ConstructionInProgressIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">54172000000</jpifrs_cor:ConstructionInProgressIFRS>
        """)
        #expect(result.accountingStandard == "IFRS")
        #expect(result.method == "field_parser")
        #expect(result.total == 581_330 * Financial.millionYen)
    }

    @Test func testHitachiValues() {
        let result = extract("""
            <jpifrs_cor:PropertyPlantAndEquipmentIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">1341537000000</jpifrs_cor:PropertyPlantAndEquipmentIFRS>
            <jpifrs_cor:BuildingsAndStructuresIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">452774000000</jpifrs_cor:BuildingsAndStructuresIFRS>
            <jpifrs_cor:LandIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">93953000000</jpifrs_cor:LandIFRS>
            <jpifrs_cor:MachineryAndVehiclesIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">242157000000</jpifrs_cor:MachineryAndVehiclesIFRS>
            <jpifrs_cor:ToolsFurnitureAndFixturesIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">141718000000</jpifrs_cor:ToolsFurnitureAndFixturesIFRS>
            <jpifrs_cor:ConstructionInProgressIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">151158000000</jpifrs_cor:ConstructionInProgressIFRS>
        """)
        #expect(result.accountingStandard == "IFRS")
        #expect(result.total == 1_341_537 * Financial.millionYen)
    }

    @Test func testPriorYearValues() {
        // 当期・前期両方あるとき total は当期値
        let result = extract("""
            <jpifrs_cor:PropertyPlantAndEquipmentIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">581330000000</jpifrs_cor:PropertyPlantAndEquipmentIFRS>
            <jpifrs_cor:PropertyPlantAndEquipmentIFRS contextRef="Prior1YearInstant" decimals="-6" unitRef="JPY">587407000000</jpifrs_cor:PropertyPlantAndEquipmentIFRS>
        """)
        #expect(result.total == 581_330 * Financial.millionYen)
    }

    // MARK: - J-GAAP（大日本印刷相当）

    @Test func testDnpValues() {
        let result = extract("""
            <jppfs_cor:PropertyPlantAndEquipment contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">405795000000</jppfs_cor:PropertyPlantAndEquipment>
            <jppfs_cor:BuildingsAndStructuresNet contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">151499000000</jppfs_cor:BuildingsAndStructuresNet>
            <jppfs_cor:Land contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">141787000000</jppfs_cor:Land>
            <jppfs_cor:MachineryEquipmentAndVehiclesNet contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">61072000000</jppfs_cor:MachineryEquipmentAndVehiclesNet>
            <jppfs_cor:ConstructionInProgress contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">17607000000</jppfs_cor:ConstructionInProgress>
        """)
        #expect(result.accountingStandard == "J-GAAP")
        #expect(result.method == "field_parser")
        #expect(result.total == 405_795 * Financial.millionYen)
    }

    // MARK: - 取得原価 − 累計減価償却フォールバック（トヨタ相当）

    @Test func testToyotaValues() {
        // 直接帳簿価額タグが存在する場合はそちらを使う
        let result = extract("""
            <jpifrs_cor:PropertyPlantAndEquipmentIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">15333693000000</jpifrs_cor:PropertyPlantAndEquipmentIFRS>
            <jpifrs_cor:BuildingsAcquisitionCostIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">6170063000000</jpifrs_cor:BuildingsAcquisitionCostIFRS>
            <jpifrs_cor:BuildingsAccumulatedDepreciationAndImpairmentLossesIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">-3867037000000</jpifrs_cor:BuildingsAccumulatedDepreciationAndImpairmentLossesIFRS>
        """)
        #expect(result.accountingStandard == "IFRS")
        #expect(result.method == "field_parser")
        #expect(result.total == 15_333_693 * Financial.millionYen)
    }

    @Test func testTotalFallbackToCostCalculation() {
        // 合計の直接タグがない場合は取得原価 + 減価償却累計（負値）で計算する
        let result = extract("""
            <jpifrs_cor:PropertyPlantAndEquipmentAcquisitionCostIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">33867518000000</jpifrs_cor:PropertyPlantAndEquipmentAcquisitionCostIFRS>
            <jpifrs_cor:PropertyPlantAndEquipmentAccumulatedDepreciationAndImpairmentLossesIFRS contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">-18533826000000</jpifrs_cor:PropertyPlantAndEquipmentAccumulatedDepreciationAndImpairmentLossesIFRS>
        """)
        #expect(result.method == "field_parser")
        #expect(result.total == (33_867_518 - 18_533_826) * Financial.millionYen)
    }

    // MARK: - not_found

    @Test func testReturnsNotFoundWhenNoPpeTags() {
        let result = extract("""
            <jppfs_cor:CurrentAssets contextRef="CurrentYearInstant" decimals="-6" unitRef="JPY">1000000000000</jppfs_cor:CurrentAssets>
        """)
        #expect(result.method == "not_found")
        #expect(result.total == nil)
    }

    @Test func testTotalIsNilWhenNoTags() {
        let result = extract("")
        #expect(result.total == nil)
    }
}
