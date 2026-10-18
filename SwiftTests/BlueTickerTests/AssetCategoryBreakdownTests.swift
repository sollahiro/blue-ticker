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

    /// 合計科目の無い注記で、区分の行が直前の行の和に丸め差つきで近いだけ（100＋50 と 151）。
    /// 商標権が「合計」に見えるが集約科目ではなく確かめる相手が無いので、公開保留にする。
    @Test func roundedSubtotalWithoutTotalNeedsReview() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("GoodwillIFRS", "のれん", 100),
            item("SoftwareIFRS", "ソフトウェア", 50),
            item("TrademarksIFRS", "商標権", 151),
        ], spec: AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(payload.needsReview == true)
        #expect(payload.warnings == [breakdownWarningAssetCategorySubtotalUnverified])
    }

    /// 合計科目が無くても、丸め差なしで一致する区分の小計（ソニーのコンテンツ資産型）は公開する。
    @Test func exactSubtotalWithoutTotalIsPublished() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("GoodwillIFRS", "のれん", 500),
            item("FilmCostIFRS", "映画", 10),
            item("GameContentIFRS", "ゲーム", 20),
            item("ContentAssetsNCAIFRS", "コンテンツ資産", 30),
        ], spec: AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(payload.needsReview == false)
        #expect(payload.denominator == 530_000_000)
        #expect(payload.denominatorTag == "GoodwillIFRS+ContentAssetsNCAIFRS")
    }

    /// 合計科目があれば、丸め差つきの小計も合計で確かめられるので公開する。
    @Test func roundedSubtotalUnderTotalIsPublished() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("GoodwillIFRS", "のれん", 500),
            item("FilmCostIFRS", "映画", 10),
            item("GameContentIFRS", "ゲーム", 20),
            item("ContentAssetsNCAIFRS", "コンテンツ資産", 31),
            item("GoodwillAndIntangibleAssetsIFRS", "のれん及び無形資産", 531),
        ], spec: AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(payload.needsReview == false)
        #expect(payload.denominatorTag == "GoodwillAndIntangibleAssetsIFRS")
    }

    /// 会社ごとの合計科目（4902 等の `PropertyPlantAndEquipmentIfDifferentFromBSBalanceIFRS`）の下の丸め差は公開する。
    @Test func roundedTotalUnderCompanyTotalTagIsPublished() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("LandIFRS", "土地", 100),
            item("BuildingsAndStructuresIFRS", "建物及び構築物", 250),
            item("PropertyPlantAndEquipmentIfDifferentFromBSBalanceIFRS", "有形固定資産", 351),
        ], spec: AssetCategoryBreakdown.propertyPlantEquipment))
        #expect(payload.needsReview == false)
        #expect(payload.denominatorTag == "PropertyPlantAndEquipmentIfDifferentFromBSBalanceIFRS")
    }

    /// 区分科目（`OtherComponentsOf…`）が丸め差で「合計」に見えても合計科目とはみなさない。
    @Test func componentsTagIsNotATotal() throws {
        let payload = try #require(AssetCategoryBreakdown.build(items: [
            item("LandIFRS", "土地", 100),
            item("BuildingsAndStructuresIFRS", "建物及び構築物", 250),
            item("OtherComponentsOfPropertyPlantAndEquipmentIFRS", "その他", 351),
        ], spec: AssetCategoryBreakdown.propertyPlantEquipment))
        #expect(payload.needsReview == true)
        #expect(payload.warnings == [breakdownWarningAssetCategorySubtotalUnverified])
    }

    @Test func emptyNoteIsNotFound() {
        #expect(AssetCategoryBreakdown.build(items: [], spec: AssetCategoryBreakdown.propertyPlantEquipment) == nil)
    }
}
