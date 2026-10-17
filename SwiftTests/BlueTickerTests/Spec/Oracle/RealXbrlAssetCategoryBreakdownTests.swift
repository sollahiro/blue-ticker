// 実 EDINET XBRL キャッシュでの資産の種類別内訳（property_plant_equipment / goodwill_and_intangibles）の回帰。
// 旧 notes（`property_plant_equipment_schedule` / `goodwill_and_intangibles`）の外出しオラクル
// `smoke/statement_notes_*_expected.json` の正味帳簿価額が、軸の行・小計・分母に1つ残らず載ることを見る。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlAssetCategoryBreakdownTests {
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

    private static func resolve(
        _ docID: String, _ spec: AssetCategoryBreakdown.Spec
    ) -> BreakdownSnapshotPayload? {
        AssetCategoryBreakdown.resolve(xbrlDir: xbrlDir(docID), spec: spec)
    }

    /// 旧 notes の外出しオラクルの正味帳簿価額（タグ → 円）。not_applicable の書類は nil。
    private static func oracleItems(file: String, docID: String) throws -> [String: Double]? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("smoke/\(file)")
        let all = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])
        let entry = try #require(all[docID])
        guard entry["status"] as? String == "resolved" else { return nil }
        let items = try #require(entry["items"] as? [[String: Any]])
        var values: [String: Double] = [:]
        for item in items {
            let tag = try #require(item["tag"] as? String)
            values[tag] = try #require((item["value"] as? NSNumber)?.doubleValue)
        }
        return values
    }

    /// 軸の行・小計（行）と合計（分母タグが単一のとき）を、タグ → 円にしたもの。
    private static func axisValues(_ payload: BreakdownSnapshotPayload) -> [String: Double] {
        var values: [String: Double] = [:]
        for row in payload.rows { values[row.sourceTag ?? row.labelRaw] = row.amount }
        if !payload.denominatorTag.contains("+") {
            values[payload.denominatorTag] = payload.denominator
        }
        return values
    }

    private static func assertOracleParity(
        docID: String, file: String, spec: AssetCategoryBreakdown.Spec
    ) throws {
        let payload = resolve(docID, spec)
        guard let expected = try oracleItems(file: file, docID: docID) else {
            #expect(payload == nil, "\(docID) \(spec.axis): 旧 notes は not_found")
            return
        }
        let resolved = try #require(payload, "\(docID) \(spec.axis): 旧 notes は resolved")
        #expect(resolved.needsReview == false)
        #expect(Self.axisValues(resolved) == expected)
        // 合計に入る行（最上位）の和が分母
        let topLevel = resolved.rows.filter { $0.categoryGroup == nil || $0.rowKind == "subtotal" }
        let sum = topLevel.reduce(0) { $0 + $1.amount }
        let tolerance = Double(topLevel.count) * AssetCategoryBreakdown.displayUnit(topLevel.map(\.amount))
        #expect(abs(sum - resolved.denominator) <= tolerance)
    }

    // MARK: - 旧 notes オラクルとの一致（smoke 固定社）

    @Test(arguments: ["S100VXJA", "S100XR0M", "S100W4MT"])
    func propertyPlantEquipmentMatchesRetiredNoteOracle(docID: String) async throws {
        guard await Self.ensureAvailable(docID) else { return }
        try Self.assertOracleParity(
            docID: docID, file: "statement_notes_property_plant_equipment_schedule_expected.json",
            spec: AssetCategoryBreakdown.propertyPlantEquipment)
    }

    @Test(arguments: ["S100VWVY", "S100VXJA", "S100XR0M", "S100W4MT"])
    func goodwillAndIntangiblesMatchesRetiredNoteOracle(docID: String) async throws {
        guard await Self.ensureAvailable(docID) else { return }
        try Self.assertOracleParity(
            docID: docID, file: "statement_notes_goodwill_and_intangibles_expected.json",
            spec: AssetCategoryBreakdown.goodwillAndIntangibles)
    }

    // MARK: - 小計・丸め・合計科目の無い注記

    /// ソニー: 「コンテンツ資産」「その他の無形資産」が直前の行の小計。合計科目は無いので分母は最上位3行の和。
    /// source: code=6758 fy_end=2026-03-31 doc_id=S100YE2C page=126 field=のれん及び無形資産.帳簿価額.コンテンツ資産
    @Test func sonyNestsContentAssetsAndOtherIntangibles() async throws {
        guard await Self.ensureAvailable("S100YE2C") else { return }
        let payload = try #require(Self.resolve("S100YE2C", AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(payload.needsReview == false)
        #expect(payload.denominator == 4_892_099_000_000)
        #expect(payload.denominatorTag == "GoodwillIFRS+ContentAssetsNCAIFRS+OtherIntangibleAssetsIFRS")
        let subtotals = payload.rows.filter { $0.rowKind == "subtotal" }
        #expect(subtotals.map(\.sourceTag) == ["ContentAssetsNCAIFRS", "OtherIntangibleAssetsIFRS"])
        let content = payload.rows.filter { $0.categoryGroup == "コンテンツ資産" && $0.rowKind == "segment" }
        #expect(content.count == 6)
        #expect(content.reduce(0) { $0 + $1.amount } == 2_558_615_000_000)
        let goodwill = try #require(payload.rows.first)
        #expect(goodwill.sourceTag == "GoodwillIFRS")
        #expect(goodwill.categoryGroup == nil)
        #expect(goodwill.amount == 1_673_906_000_000)
    }

    /// JT: 区分行の和が合計と 1 百万円ずれる（丸め）。合計科目を分母にし、行には出さない。
    /// source: code=2914 fy_end=2025-12-31 doc_id=S100XSSA page=143 field=有形固定資産.帳簿価額.合計
    /// source: code=2914 fy_end=2025-12-31 doc_id=S100XSSA page=145 field=のれん及び無形資産.帳簿価額.合計
    @Test func jtToleratesRoundingAgainstTotal() async throws {
        guard await Self.ensureAvailable("S100XSSA") else { return }
        let ppe = try #require(Self.resolve("S100XSSA", AssetCategoryBreakdown.propertyPlantEquipment))
        #expect(ppe.needsReview == false)
        #expect(ppe.denominator == 979_800_000_000)
        #expect(ppe.denominatorTag == "PropertyPlantAndEquipmentIFRS")
        #expect(ppe.rows.count == 4)
        let goodwill = try #require(Self.resolve("S100XSSA", AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(goodwill.needsReview == false)
        #expect(goodwill.denominator == 3_318_755_000_000)
        #expect(goodwill.denominatorTag == "GoodwillAndIntangibleAssetsIFRS")
        #expect(goodwill.rows.map(\.sourceTag) == [
            "GoodwillIFRS", "TrademarksIFRS", "SoftwareIFRS", "OtherComponentsOfIntangibleAssetsIFRS",
        ])
    }

    /// 京セラ: 取得原価・累計償却のタグは行に入れない。
    /// source: code=6971 fy_end=2024-03-31 doc_id=S100TSIJ page=120 field=有形固定資産.帳簿価額.合計
    /// source: code=6971 fy_end=2024-03-31 doc_id=S100TSIJ page=122 field=のれん及び無形資産.帳簿価額.無形資産
    @Test func kyoceraKeepsNetCarryingAmountsOnly() async throws {
        guard await Self.ensureAvailable("S100TSIJ") else { return }
        for spec in [AssetCategoryBreakdown.propertyPlantEquipment, AssetCategoryBreakdown.goodwillAndIntangibles] {
            let payload = try #require(Self.resolve("S100TSIJ", spec))
            #expect(payload.needsReview == false)
            for tag in payload.rows.compactMap(\.sourceTag) {
                #expect(!tag.contains("AcquisitionCost"))
                #expect(!tag.contains("Accumulated"))
            }
        }
        let ppe = try #require(Self.resolve("S100TSIJ", AssetCategoryBreakdown.propertyPlantEquipment))
        #expect(ppe.denominator == 1_184_608_000_000)
        let goodwill = try #require(Self.resolve("S100TSIJ", AssetCategoryBreakdown.goodwillAndIntangibles))
        #expect(goodwill.denominatorTag == "GoodwillIFRS+IntangibleAssetsIFRS")
        #expect(goodwill.denominator == 176_193_000_000)
    }
}
