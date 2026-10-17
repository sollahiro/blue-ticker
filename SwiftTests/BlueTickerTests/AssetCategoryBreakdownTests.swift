// 資産の種類別内訳の組み立て（XBRL を読まない純関数）。

import Testing
@testable import BlueTickerCore

@Suite struct AssetCategoryBreakdownTests {
    private func item(_ tag: String, _ label: String, _ millions: Double) -> StatementLineItem {
        StatementLineItem(tag: tag, label: label, value: millions * 1_000_000, unit: "yen", order: nil)
    }

    @Test func totalRowBecomesDenominator() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("LandIFRS", "土地", 100),
            item("BuildingsAndStructuresIFRS", "建物及び構築物", 250),
            item("PropertyPlantAndEquipmentIFRS", "有形固定資産", 350),
        ], spec: AssetCategoryBreakdown.propertyPlantEquipment))
        #expect(payload.axis == breakdownAxisPropertyPlantEquipment)
        #expect(payload.denominator == 350_000_000)
        #expect(payload.denominatorTag == "PropertyPlantAndEquipmentIFRS")
        #expect(payload.rows.map(\.label) == ["土地", "建物及び構築物"])
        #expect(payload.rows.allSatisfy { $0.rowKind == "segment" && $0.categoryGroup == nil })
        #expect(payload.needsReview == false)
    }

    /// 百万円の丸めで区分行の和が合計と行数単位までずれる開示は合計として扱う。
    @Test func roundingWithinRowCountUnitsStillTotals() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("LandIFRS", "土地", 100),
            item("BuildingsAndStructuresIFRS", "建物及び構築物", 250),
            item("PropertyPlantAndEquipmentIFRS", "有形固定資産", 349),
        ], spec: AssetCategoryBreakdown.propertyPlantEquipment))
        #expect(payload.denominatorTag == "PropertyPlantAndEquipmentIFRS")
        #expect(payload.needsReview == false)
    }

    /// 合計科目が区分行の和と合わないときは行に残し、公開保留にする。
    @Test func unmatchedTotalNeedsReview() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("LandIFRS", "土地", 100),
            item("BuildingsAndStructuresIFRS", "建物及び構築物", 250),
            item("PropertyPlantAndEquipmentIFRS", "有形固定資産", 400),
        ], spec: AssetCategoryBreakdown.propertyPlantEquipment))
        #expect(payload.needsReview == true)
        #expect(payload.warnings == [breakdownWarningAssetCategoryTotalUnmatched])
    }

    /// のれんと、のれん以外の無形資産の小計。合計科目が無いので分母は最上位の和。
    @Test func goodwillBesideIntangibleSubtotal() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("GoodwillIFRS", "のれん", 500),
            item("SoftwareIFRS", "ソフトウェア", 30),
            item("TrademarksIFRS", "商標権", 20),
            item("IntangibleAssetsIFRS", "無形資産", 50),
        ], spec: AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(payload.needsReview == false)
        #expect(payload.denominator == 550_000_000)
        #expect(payload.denominatorTag == "GoodwillIFRS+IntangibleAssetsIFRS")
        #expect(payload.rows.map(\.rowKind) == ["segment", "subtotal", "segment", "segment"])
        #expect(payload.rows.map(\.categoryGroup) == [nil, "無形資産", "無形資産", "無形資産"])
        #expect(payload.rows.map(\.label) == ["のれん", "無形資産", "ソフトウェア", "商標権"])
    }

    /// 区分行の無い「無形資産」だけの行は、そのまま正しい行。
    @Test func standaloneIntangibleTotalIsARow() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("GoodwillIFRS", "のれん", 500),
            item("IntangibleAssetsIFRS", "無形資産", 50),
        ], spec: AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(payload.needsReview == false)
        #expect(payload.denominator == 550_000_000)
    }

    /// 小計の内訳にさらに小計があるときは公開保留。
    @Test func nestedSubtotalNeedsReview() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("GoodwillIFRS", "のれん", 500),
            item("FilmCostIFRS", "映画", 10),
            item("GameContentIFRS", "ゲーム", 20),
            item("ContentAssetsNCAIFRS", "コンテンツ資産", 30),
            item("SoftwareIFRS", "ソフトウェア", 40),
            item("IntangibleAssetsIFRS", "無形資産", 70),
        ], spec: AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(payload.needsReview == true)
        #expect(payload.warnings == [breakdownWarningAssetCategoryNestedSubtotal])
    }

    @Test func emptyNoteIsNotFound() {
        #expect(AssetCategoryBreakdown.build(items: [], spec: AssetCategoryBreakdown.propertyPlantEquipment) == nil)
    }
}
