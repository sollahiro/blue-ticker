// fixed_assets 軸の組み立て（XBRL を読まない純関数）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct FixedAssetsBreakdownTests {
    private func line(
        _ tag: String, _ label: String, _ millions: Double, order: Int,
        components: [(String, Int)]? = nil
    ) -> StatementLineItem {
        StatementLineItem(
            tag: tag, label: label, value: millions * 1_000_000, unit: "JPY", order: order,
            isTotal: components != nil,
            components: components?.map { StatementLineComponent(tag: $0.0, weight: $0.1) })
    }

    /// 日本基準: 区分合計の計算リンクの内訳を表示順の行にし、区分ごとの合計を payload に載せる。
    @Test func japaneseGaapBalanceSheetClasses() throws {
        let payload = try #require(FixedAssetsBreakdown.fromBalanceSheet([
            line("BuildingsAndStructuresNet", "建物及び構築物（純額）", 300, order: 1),
            line("Land", "土地", 100, order: 2),
            line("PropertyPlantAndEquipment", "有形固定資産合計", 400, order: 3,
                 components: [("Land", 1), ("BuildingsAndStructuresNet", 1)]),
            line("Goodwill", "のれん", 50, order: 4),
            line("Software", "ソフトウェア", 20, order: 5),
            line("IntangibleAssets", "無形固定資産合計", 70, order: 6,
                 components: [("Goodwill", 1), ("Software", 1)]),
        ]))
        #expect(payload.axis == breakdownAxisFixedAssets)
        #expect(payload.needsReview == false)
        #expect(payload.denominator == 470_000_000)
        #expect(payload.denominatorTag == "PropertyPlantAndEquipment+IntangibleAssets")
        #expect(payload.propertyPlantEquipment?.denominator == 400_000_000)
        #expect(payload.intangibleAssets?.denominatorTag == "IntangibleAssets")
        #expect(payload.rows.map(\.sourceTag) == ["BuildingsAndStructuresNet", "Land", "Goodwill", "Software"])
        #expect(payload.rows.map(\.assetClass) == [
            breakdownAssetClassPropertyPlantEquipment, breakdownAssetClassPropertyPlantEquipment,
            breakdownAssetClassIntangibleAssets, breakdownAssetClassIntangibleAssets,
        ])
        let json = payload.jsonObject()
        #expect((json[breakdownAssetClassPropertyPlantEquipment] as? [String: Any])?["denominator"] as? Double == 400_000_000)
        let rows = try #require(json["rows"] as? [[String: Any]])
        #expect(rows.first?[breakdownAssetClassKey] as? String == breakdownAssetClassPropertyPlantEquipment)
    }

    /// 百万円の丸めで内訳の和が行数単位までずれるのは合っているとみなす。超えたら要確認。
    @Test func roundingToleranceAndMismatch() throws {
        let rounded = try #require(FixedAssetsBreakdown.fromBalanceSheet([
            line("Land", "土地", 100, order: 1),
            line("BuildingsAndStructuresNet", "建物及び構築物（純額）", 300, order: 2),
            line("PropertyPlantAndEquipment", "有形固定資産合計", 402, order: 3,
                 components: [("Land", 1), ("BuildingsAndStructuresNet", 1)]),
        ]))
        #expect(rounded.needsReview == false)
        #expect(rounded.intangibleAssets == nil)

        let mismatched = try #require(FixedAssetsBreakdown.fromBalanceSheet([
            line("Land", "土地", 100, order: 1),
            line("PropertyPlantAndEquipment", "有形固定資産合計", 400, order: 2,
                 components: [("Land", 1), ("BuildingsAndStructuresNet", 1)]),
        ]))
        #expect(mismatched.needsReview == true)
        #expect(mismatched.warnings == [breakdownWarningAssetCategoryTotalUnmatched])
    }

    /// 加算だけの合計の内訳科目は1段だけ小計として開く。純額科目（控除あり）は開かない。
    @Test func additiveComponentOpensAsSubtotal() throws {
        let payload = try #require(FixedAssetsBreakdown.fromBalanceSheet([
            line("Buildings", "建物", 500, order: 1),
            line("AccumulatedDepreciationBuildings", "減価償却累計額", 200, order: 2),
            line("BuildingsNet", "建物（純額）", 300, order: 3,
                 components: [("Buildings", 1), ("AccumulatedDepreciationBuildings", -1)]),
            line("PropertyPlantAndEquipment", "有形固定資産合計", 300, order: 4,
                 components: [("BuildingsNet", 1)]),
            line("Goodwill", "のれん", 50, order: 5),
            line("Software", "ソフトウェア", 20, order: 6),
            line("Trademark", "商標権", 10, order: 7),
            line("OtherIA", "その他", 30, order: 8, components: [("Software", 1), ("Trademark", 1)]),
            line("IntangibleAssets", "無形固定資産合計", 80, order: 9,
                 components: [("Goodwill", 1), ("OtherIA", 1)]),
        ]))
        #expect(payload.needsReview == false)
        #expect(payload.rows.map(\.sourceTag) == ["BuildingsNet", "Goodwill", "OtherIA", "Software", "Trademark"])
        #expect(payload.rows.map(\.rowKind) == ["segment", "segment", "subtotal", "segment", "segment"])
        #expect(payload.rows.map(\.categoryGroup) == [nil, nil, "その他", "その他", "その他"])
    }

    /// 内訳の無い無形固定資産合計は1行だけ。区分合計の科目が無ければ nil。
    @Test func singleLineIntangibleAndNoClasses() throws {
        let payload = try #require(FixedAssetsBreakdown.fromBalanceSheet([
            line("IntangibleAssets", "無形固定資産", 15, order: 1),
        ]))
        #expect(payload.propertyPlantEquipment == nil)
        #expect(payload.rows.map(\.sourceTag) == ["IntangibleAssets"])
        #expect(payload.denominator == 15_000_000)
        #expect(FixedAssetsBreakdown.fromBalanceSheet([line("Land", "土地", 1, order: 1)]) == nil)
    }

    /// IFRS の区分ごとの payload を合計付きで1つにする。
    @Test func combinesIfrsNoteClasses() throws {
        func item(_ tag: String, _ label: String, _ millions: Double) -> StatementLineItem {
            StatementLineItem(tag: tag, label: label, value: millions * 1_000_000, unit: "yen", order: nil)
        }
        let ppe = try #require(AssetCategoryBreakdown.build(items: [
            item("LandIFRS", "土地", 100),
            item("PropertyPlantAndEquipmentIFRS", "有形固定資産", 100),
        ], spec: AssetCategoryBreakdown.propertyPlantEquipment))
        let intangible = try #require(AssetCategoryBreakdown.build(items: [
            item("GoodwillIFRS", "のれん", 40),
        ], spec: AssetCategoryBreakdown.goodwillAndIntangibles))
        let payload = try #require(FixedAssetsBreakdown.combine([
            FixedAssetsBreakdown.classPart(ppe, assetClass: breakdownAssetClassPropertyPlantEquipment),
            FixedAssetsBreakdown.classPart(intangible, assetClass: breakdownAssetClassIntangibleAssets),
        ]))
        #expect(payload.denominator == 140_000_000)
        #expect(payload.denominatorTag == "PropertyPlantAndEquipmentIFRS+GoodwillIFRS")
        #expect(payload.propertyPlantEquipment?.denominator == 100_000_000)
        #expect(payload.intangibleAssets?.denominator == 40_000_000)
        #expect(payload.rows.map(\.assetClass) == [
            breakdownAssetClassPropertyPlantEquipment, breakdownAssetClassIntangibleAssets,
        ])
    }

    /// 旧2軸は廃止し、fixed_assets を v1 から配信する。
    @Test func contractRetiresOldAxes() {
        #expect(isSupportedBreakdownAxis(breakdownAxisFixedAssets))
        #expect(fixedAssetsBreakdownCacheVersion == "breakdown-fixed-assets-v1")
        #expect(breakdownCacheVersion(forAxis: breakdownAxisFixedAssets) == fixedAssetsBreakdownCacheVersion)
        #expect(isServableBreakdown(
            source: breakdownSourceXbrlFacts, cacheVersion: fixedAssetsBreakdownCacheVersion,
            axis: breakdownAxisFixedAssets))
        for axis in [breakdownAxisPropertyPlantEquipment, breakdownAxisGoodwillAndIntangibles] {
            #expect(retiredBreakdownAxes.contains(axis))
            #expect(isSupportedBreakdownAxis(axis) == false)
        }
    }
}
