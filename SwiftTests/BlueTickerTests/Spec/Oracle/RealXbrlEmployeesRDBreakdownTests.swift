// 実 EDINET XBRL キャッシュ（analysis_cache）での内訳回帰（SPEC_ORACLE の L1 実行器）。
// 対象企業は各 @Test にハードコード。共有モックは RealXbrlBreakdownSupport.swift。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlEmployeesRDBreakdownTests {

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

    // MARK: - 京セラ S100TSIJ（2026-08-01）

    @Test func kyoceraEmployeesReconcilesCorporateSharedAsAdditiveNotSubtotal() async throws {
        guard await Self.ensureAvailable("S100TSIJ") else { return }
        let xbrlDir = Self.xbrlDir("S100TSIJ")
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: xbrlDir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labelsByTag = XBRLUtils.breakdownMemberLabels(in: xbrlDir)

        // 全社合計は 財務取り込み 計算済みの値を想定した固定値（実データ: 73,165人）。
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 73_165, axis: "employees", labelsByTag: labelsByTag))

        #expect(snapshot.axis == "employees")
        #expect(snapshot.denominator == 73_165)
        // CorporateShared を含めた実際の内訳合計が総数に一致するため、誤検知の
        // needs_review が立たないこと（監査指摘の核心）。
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)

        let corporateShared = try #require(
            snapshot.rows.first { $0.labelRaw == "CorporateSharedMember" })
        // 代替総合計（subtotal）ではなく、合計に加算される少額バケツ（reconciling）として
        // 分類されること。誤って "subtotal" のままだと表示側が総数を3,645人と誤認する
        // （監査指摘 #3、served payload への波及）。
        #expect(corporateShared.rowKind == "reconciling")
        #expect(corporateShared.amount == 3_645)

        let segmentSum = snapshot.rows.map(\.amount).reduce(0, +)
        #expect(segmentSum == snapshot.denominator)

        // ラベルリンクベースの日本語ラベルが解決されること（提出書類の label linkbase 実データ確認）。
        // CorporateSharedMember は提出書類側の拡張ラベルが無く、jpcrp 標準ラベルで埋める。
        let components = try #require(
            snapshot.rows.first { $0.labelRaw == "ComponentsReportableSegmentsMember" })
        #expect(components.label == "コンポーネント")
        #expect(corporateShared.label == "全社（共通）")
    }

    // MARK: - サスメド S100Z4GF（2 セグメント共通の人数）

    /// 2 セグメント共通の 35 名はどのセグメント member にも fact が無い。表の未タグ行として
    /// 1 行で足し、全社（共通）15 と合わせて 50 名に閉じる。
    // source: code=4263 fy_end=2026-06-30 doc_id=S100Z4GF page=78 field=employees.DTxプロダクト事業・DTxプラットフォーム事業
    @Test func susmedSharedSegmentHeadcountBecomesOneRow() async throws {
        guard await Self.ensureAvailable("S100Z4GF") else { return }
        let xbrlDir = Self.xbrlDir("S100Z4GF")
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: xbrlDir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(facts: facts, total: 50, axis: "employees"))
        let filled = EmployeesUntaggedRowFill.fill(snapshot: snapshot, facts: facts, xbrlDir: xbrlDir)
        let shared = try #require(filled.rows.first { $0.amount == 35 })
        #expect(shared.label?.contains("DTxプロダクト事業") == true)
        #expect(shared.label?.contains("DTxプラットフォーム事業") == true)
        #expect(shared.rowKind == "segment")
        let included = filled.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
        #expect(included.map(\.amount).reduce(0, +) == 50)
        #expect(filled.needsReview == false)
    }

    @Test func eisaiEmployeesPromotesPharmaceuticalBusinessLabel() async throws {
        guard await Self.ensureAvailable("S100YB05") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100YB05")
        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 10_543, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        let pharma = try #require(emp.rows.first { $0.labelRaw == "ReportableSegmentsMember" })
        #expect(pharma.rowKind == "segment")
        #expect(pharma.amount == 9_832)
        #expect(pharma.label == "医薬品事業")
        #expect(pharma.categoryGroup == nil)
        #expect(pharma.category == nil)
        let other = try #require(
            emp.rows.first {
                $0.labelRaw
                    == "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember"
            })
        #expect(other.amount == 711)
        #expect(other.rowKind == "segment")
    }

    @Test func kaoEmployeesDemotesGlobalConsumerCareParent() async throws {
        guard await Self.ensureAvailable("S100XT6G") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100XT6G")
        let parents = XBRLUtils.operatingSegmentMemberParents(in: Self.xbrlDir("S100XT6G"))
        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 31_514, axis: "employees", labelsByTag: labels,
                memberParents: parents))
        #expect(emp.needsReview == false)
        let parent = try #require(
            emp.rows.first { $0.labelRaw == "GlobalConsumerCareBusinessReportableSegmentMember" })
        #expect(parent.rowKind == "subtotal")
        #expect(parent.categoryGroup == nil)
        #expect(parent.category == nil)
        let reconciled = emp.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(reconciled == 31_514)
    }

    @Test func mitsuiOSKEmployeesDemotesOfWhichNestedChildren() async throws {
        guard await Self.ensureAvailable("S100YI2T") else { return }
        let dir = Self.xbrlDir("S100YI2T")
        let (facts, labels) = Self.employeesFactsAndLabels("S100YI2T")
        let parents = XBRLUtils.operatingSegmentMemberParents(in: dir)
        #expect(parents["ContainershipsReportableSegmentsMember"]
            == "ProductTransportBusinessReportableSegmentsMember")
        #expect(parents["RealEstateBusinessReportableSegmentsMember"]
            == "WellbeingAndLifestyleBusinessReportableSegmentsMember")
        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 11_567, axis: "employees", labelsByTag: labels,
                memberParents: parents))
        #expect(emp.needsReview == false)
        #expect(emp.warnings.isEmpty)
        #expect(emp.denominator == 11_567)
        let product = try #require(
            emp.rows.first { $0.labelRaw == "ProductTransportBusinessReportableSegmentsMember" })
        #expect(product.rowKind == "segment")
        #expect(product.categoryGroup == nil)
        let wellbeing = try #require(
            emp.rows.first { $0.labelRaw == "WellbeingAndLifestyleBusinessReportableSegmentsMember" })
        #expect(wellbeing.rowKind == "segment")
        #expect(wellbeing.categoryGroup == nil)
        let containerships = try #require(
            emp.rows.first { $0.labelRaw == "ContainershipsReportableSegmentsMember" })
        #expect(containerships.rowKind == "subtotal")
        #expect(containerships.amount == 57)
        #expect(containerships.categoryGroup == (product.label ?? product.labelRaw))
        #expect(containerships.category == containerships.label ?? containerships.labelRaw)
        let realEstate = try #require(
            emp.rows.first { $0.labelRaw == "RealEstateBusinessReportableSegmentsMember" })
        #expect(realEstate.rowKind == "subtotal")
        #expect(realEstate.amount == 1_255)
        #expect(realEstate.categoryGroup == (wellbeing.label ?? wellbeing.labelRaw))
        #expect(realEstate.category == realEstate.label ?? realEstate.labelRaw)
        let reconciled = emp.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(reconciled == 11_567)
    }

    /// 三井住友トラスト S100O9U5: 銀行 member 22,024 はタグ付き合計列。運用ビジネス 1,421 は未タグのまま省略。
    @Test func sumitomoMitsuiTrustEmployeesDemotesTaggedBankTotalWithoutUntaggedAssetManagement()
        async throws
    {
        guard await Self.ensureAvailable("S100O9U5") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100O9U5")
        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 22_024, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.warnings.isEmpty)
        #expect(emp.denominator == 22_024)
        let bank = try #require(
            emp.rows.first {
                $0.labelRaw == "SumitomoMitsuiTrustBankLimitedReportableSegmentsMember"
            })
        #expect(bank.rowKind == "subtotal")
        #expect(bank.amount == 22_024)
        #expect(bank.categoryGroup == nil)
        #expect(bank.category == nil)
        #expect(emp.rows.contains { $0.labelRaw.lowercased().contains("assetmanagement") } == false)
        #expect(emp.rows.contains { $0.label?.contains("運用") == true } == false)
        let ident = emp.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(ident == 20_603)
        let retail = try #require(
            emp.rows.first { $0.labelRaw == "RetailTotalSolutionServicesReportableSegmentMember" })
        #expect(retail.rowKind == "segment")
        #expect(retail.amount == 8_594)
    }

    /// リコー S100LKDZ: 「上記３分野共通」は未タグのまま省略。合成 reconciling は足さない。
    @Test func ricohEmployeesOmitsUntaggedSharedThreeFieldsWithoutSyntheticRow() async throws {
        guard await Self.ensureAvailable("S100LKDZ") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100LKDZ")
        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 81_184, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == true)
        #expect(emp.warnings.contains("employees_segment_sum_far_from_total"))
        #expect(emp.denominator == 81_184)
        #expect(emp.rows.contains { $0.labelRaw.contains("BlueTicker") } == false)
        #expect(emp.rows.contains { $0.label?.contains("上記") == true } == false)
        let corporate = try #require(emp.rows.first { $0.labelRaw == "CorporateSharedMember" })
        #expect(corporate.rowKind == "reconciling")
        #expect(corporate.amount == 2_734)
        let printing = try #require(
            emp.rows.first { $0.labelRaw == "OfficePrintingReportableSegmentMember" })
        #expect(printing.rowKind == "segment")
        #expect(printing.amount == 32_474)
        let ident = emp.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(ident == 68_631)
    }

    // MARK: - employees 軸 実データゴールデン（2026-08-03、10社レビュー）
    //
    // ユーザーが10社（日経225）のemployees軸抽出結果を実データで
    // 目視確認済み（生XBRLと突き合わせ、SCREEN HD「上記セグメント以外9,151」・日東電工
    // 「全社技術部門10,725」等、注記本文にのみ存在しXBRL dimensionタグが無い値の欠測を確認）。
    // needs_review=false の行のみ確認対象とし、正しさが確認できた絶対値をgolden化する
    // （needs_review=true の行は開示側の構造的欠測であり別途対応、docs/breakdown.md）。
    // 割合ではなく実額（人数・円）で確認したユーザー指摘に合わせ、golden も実額のみを見る。

    private static func employeesFactsAndLabels(
        _ docID: String
    ) -> (facts: [BreakdownFact], labels: [String: String]) {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        return (facts, XBRLUtils.breakdownMemberLabels(in: dir))
    }

    // source: code=9537 fy_end=2026-03-31 doc_id=S100YIW6 page=46 field=employees
    // `XxxSegmentsReportableSegmentsMember` は葉のセグメント名。小計に落とさない。
    @Test func hokurikuGasSegmentsReportableSegmentsLeavesStaySegments() async throws {
        guard await Self.ensureAvailable("S100YIW6") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100YIW6")
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 652, axis: "employees", labelsByTag: labels))
        for (member, amount) in [
            ("EngineeringSegmentsReportableSegmentsMember", 36.0),
            ("LPGSegmentsReportableSegmentsMember", 12.0),
            ("LivingServiceSegmentsReportableSegmentsMember", 48.0),
            ("PlumingSegmentsReportableSegmentsMember", 67.0),
        ] {
            let row = try #require(snapshot.rows.first { $0.labelRaw == member })
            #expect(row.rowKind == "segment")
            #expect(row.amount == amount)
        }
    }

    // source: code=1605 fy_end=2020-12-31 doc_id=S100L16P page=14 field=employees
    // 日本〜米州を結合したセル 2,893 人＋全社（共通）270 人の表。報告セグメントを segment に残す。
    @Test func inpexSoleReportableSegmentsMemberStaysSegment() async throws {
        guard await Self.ensureAvailable("S100L16P") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100L16P")
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 3_163, axis: "employees", labelsByTag: labels))
        let row = try #require(snapshot.rows.first { $0.labelRaw == "ReportableSegmentsMember" })
        #expect(row.rowKind == "segment")
        #expect(row.amount == 2_893)
        #expect(snapshot.needsReview == false)
    }

    @Test func yokogawaEmployeesMatchDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VY8X") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VY8X")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 17_670, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 17_670)
        let empControl = try #require(
            emp.rows.first { $0.labelRaw == "IndustrialAutomationAndControlReportableSegmentsMember" })
        #expect(empControl.amount == 16_781)
        #expect(empControl.label == "制御")
    }

    @Test func mitsubishiMotorsEmployeesMatchesDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VZMJ") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VZMJ")

        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 28_572, axis: "employees", labelsByTag: labels))
        #expect(snapshot.needsReview == false)
        #expect(snapshot.rows.map(\.amount).reduce(0, +) == 28_572)
        let car = try #require(snapshot.rows.first { $0.labelRaw == "CarSegmentMember" })
        #expect(car.amount == 28_384)
        #expect(car.label == "自動車事業")
        let financial = try #require(snapshot.rows.first { $0.labelRaw == "FinancialSegmentMember" })
        #expect(financial.amount == 188)
        #expect(financial.label == "金融事業")
    }

    @Test func itochuEmployeesMatchesDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VYN4") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VYN4")

        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 115_089, axis: "employees", labelsByTag: labels))
        #expect(snapshot.needsReview == false)
        #expect(snapshot.rows.map(\.amount).reduce(0, +) == 115_089)
        let food = try #require(snapshot.rows.first { $0.labelRaw == "FoodReportableSegmentMember" })
        #expect(food.amount == 31_380)
        #expect(food.label == "食料")
    }

    @Test func nittoDenkoEmployeesMatchesDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VYH3") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VYH3")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 25_769, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 25_769)
        let optronics = try #require(
            emp.rows.first { $0.labelRaw == "OptronicsReportableSegmentMember" })
        #expect(optronics.amount == 12_798)
        #expect(optronics.label == "オプトロニクス")
    }

    @Test func hondaEmployeesMatchesDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VYOD") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VYOD")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 194_173, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 194_173)
        let automobile = try #require(
            emp.rows.first { $0.labelRaw == "AutomobileBusinessReportableSegmentMember" })
        #expect(automobile.amount == 133_665)
        #expect(automobile.label == "四輪事業")
    }

    @Test func nomuraResearchInstituteEmployeesMatchDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VZKL") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VZKL")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 16_679, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 16_679)
        let industrialIT = try #require(
            emp.rows.first { $0.labelRaw == "IndustrialITSolutionsReportableSegmentMember" })
        #expect(industrialIT.amount == 6_034)
        #expect(industrialIT.label == "産業ＩＴソリューション")
    }

    @Test func toyotaEmployeesMatchDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VWVY") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VWVY")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 383_853, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 383_853)
        let automotive = try #require(
            emp.rows.first { $0.labelRaw == "AutomotiveReportableSegmentMember" })
        #expect(automotive.amount == 339_062)
        #expect(automotive.label == "自動車")
    }

    @Test func sumitomoCorpEmployeesMatchesDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VYV6") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VYV6")

        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 83_327, axis: "employees", labelsByTag: labels))
        #expect(snapshot.needsReview == false)
        #expect(snapshot.rows.map(\.amount).reduce(0, +) == 83_327)
        let mediaDigital = try #require(
            snapshot.rows.first { $0.labelRaw == "MediaAndDigitalReportableSegmentMember" })
        #expect(mediaDigital.amount == 20_816)
        #expect(mediaDigital.label == "メディア・デジタル")
    }

    @Test func ajinomotoEmployeesMatchDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VXJA") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VXJA")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 34_860, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 34_860)
        let seasonings = try #require(
            emp.rows.first { $0.labelRaw == "SeasoningsAndFoodsReportableSegmentMember" })
        #expect(seasonings.amount == 22_096)
        #expect(seasonings.label == "調味料・食品")
    }

    /// product_service 軸（`normalizeSalesBasis` 経路）でも同じラベル解決が効くこと。
    /// メンバー名は事業年度で変わりうるため固定文字列にせず、
    /// 「少なくとも1行は生member名と異なる日本語ラベルに解決される」ことだけを検証する。
    @Test func kyoceraBusinessAxisResolvesJapaneseLabels() async throws {
        guard await Self.ensureAvailable("S100TSIJ") else { return }
        let xbrlDir = Self.xbrlDir("S100TSIJ")
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)
        #expect(segments.method == "xbrl_facts")
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)

        let snapshot = try #require(
            BreakdownNormalizer.normalize(
                segments, consolidatedSales: 1_069_763_000_000, labelsByTag: labelsByTag))
        #expect(snapshot.axis == breakdownAxisProductService)
        #expect(snapshot.rows.contains { $0.label != nil && $0.label != $0.labelRaw })
    }
}

// US-GAAP smoke 2社（富士フイルム・キヤノン）は連結売上のセグメント fact が無く
// `breakdown_extraction_expected` の segments は html_table（facts=[]）だが、
// Overview タグ `CapitalExpendituresOverviewOfCapitalExpendituresEtc` には
// OperatingSegmentsAxis 付き fact があり、`capital_expenditures_overview` 軸は
// 数値・合計を決定論で再構成できる（2026-08-20 実データ確認）。
// HTML 経路（notes resolver）とも金額一致。description は HTML 側のみ。

@Suite struct SmokeEmployeesBreakdownTests {

    private static let xbrlRoot = SmokeCacheSupport.cacheDir
    private static let employeeTag = "NumberOfEmployees"

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID])
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

    private static func expectEmployees(
        docID: String, total: Double,
        rows: [(labelRaw: String, label: String?, amount: Double, rowKind: String)]
    ) async throws {
        guard await ensureAvailable(docID) else { return }
        let (facts, labels) = factsAndLabels(docID)
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: total, axis: "employees", labelsByTag: labels))
        #expect(snapshot.axis == "employees")
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.denominatorTag == employeeTag)
        #expect(snapshot.denominator == total)
        #expect(snapshot.rows.map(\.amount).reduce(0, +) == total)
        #expect(snapshot.rows.count == rows.count)
        for expected in rows {
            let row = try #require(snapshot.rows.first { $0.labelRaw == expected.labelRaw })
            #expect(row.amount == expected.amount)
            #expect(row.rowKind == expected.rowKind)
            #expect(row.label == expected.label)
        }
    }

    @Test func ajinomotoEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100VXJA", total: 34_860,
            rows: [
                ("CorporateSharedMember", "全社（共通）", 780, "reconciling"),
                ("FrozenFoodsReportableSegmentMember", "冷凍食品", 5_478, "segment"),
                ("HealthcareAndOthersReportableSegmentMember", "ヘルスケア等", 5_321, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    "その他", 1_185, "segment"),
                ("SeasoningsAndFoodsReportableSegmentMember", "調味料・食品", 22_096, "segment"),
            ])
    }

    @Test func nichireiEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100VYA0", total: 16_626,
            rows: [
                ("CorporateSharedMember", "全社（共通）", 229, "reconciling"),
                ("LogisticsReportableSegmentsMember", "低温物流", 4_926, "segment"),
                ("MarineProductsReportableSegmentsMember", "水産", 744, "segment"),
                ("MeatAndPoultryProductsReportableSegmentsMember", "畜産", 397, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    "その他", 190, "segment"),
                ("ProcessedFoodsReportableSegmentsMember", "加工食品", 10_125, "segment"),
                ("RealEstateReportableSegmentsMember", "不動産", 15, "segment"),
            ])
    }

    @Test func azPlanningEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100VU4O", total: 63,
            rows: [
                ("CorporateSharedMember", "全社（共通）", 15, "reconciling"),
                ("RealEstateLeasingReportableSegmentMember", "不動産賃貸事業", 4, "segment"),
                ("RealEstateManagementReportableSegmentMember", "不動産管理事業", 5, "segment"),
                ("RealEstateSalesReportableSegmentMember", "不動産販売事業", 39, "segment"),
            ])
    }

    @Test func fujifilmEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W3XJ", total: 72_593,
            rows: [
                ("BusinessInnovationReportableSegmentsMember", "ビジネスイノベーション", 34_173, "segment"),
                ("CorporateSharedMember", "全社（共通）", 4_129, "reconciling"),
                ("ElectronicsReportableSegmentsMember", "エレクトロニクス", 6_472, "segment"),
                ("HealthcareReportableSegmentsMember", "ヘルスケア", 21_369, "segment"),
                ("ImagingReportableSegmentsMember", "イメージング", 6_450, "segment"),
            ])
    }

    @Test func okumaEmployeesMatchGeographyReportableSegments() async throws {
        try await Self.expectEmployees(
            docID: "S100W043", total: 4_071,
            rows: [
                ("AmericasReportableSegmentsMember", "米州", 264, "segment"),
                ("AsiaAndPacificReportableSegmentsMember", "アジア・パシフィック", 753, "segment"),
                ("EuropeReportableSegmentsMember", "欧州", 388, "segment"),
                ("JapanReportableSegmentsMember", "日本", 2_666, "segment"),
            ])
    }

    @Test func kubotaEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100XR0M", total: 52_503,
            rows: [
                ("CorporateSharedMember", "全社（共通）", 1_403, "reconciling"),
                ("MachineryReportableSegmentMember", "機械", 41_342, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    "その他", 1_379, "segment"),
                ("WaterAndEnvironmentReportableSegmentMember", "水・環境", 8_379, "segment"),
            ])
    }

    @Test func suzukiEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W4MT", total: 74_077,
            rows: [
                ("AutomobileBusinessReportableSegmentMember", "四輪事業", 64_149, "segment"),
                ("CorporateSharedMember", "全社（共通）", 996, "reconciling"),
                ("MarineBusinessReportableSegmentMember", "マリン事業", 1_460, "segment"),
                ("MotorcycleBusinessReportableSegmentMember", "二輪事業", 7_121, "segment"),
                ("OtherBusinessReportableSegmentMember", "その他事業", 351, "segment"),
            ])
    }

    @Test func tohoRemacEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100XRD8", total: 74,
            rows: [
                ("RealEstateBusinessMember", "不動産事業", 2, "segment"),
                ("ShoesBusinessMember", "シューズ事業", 72, "segment"),
            ])
    }

    @Test func canonEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100XTLJ", total: 165_547,
            rows: [
                ("ImagingBusinessUnitReportableSegmentsMember", "イメージングビジネスユニット", 26_367, "segment"),
                ("IndustryBusinessUnitReportableSegmentsMember", "インダストリアルビジネスユニット", 7_757, "segment"),
                ("MedicalBusinessUnitReportableSegmentsMember", "メディカルビジネスユニット", 13_347, "segment"),
                ("OtherAndCorporateMember", "その他及び全社", 12_138, "segment"),
                ("PrintingBusinessUnitReportableSegmentsMember", "プリンティングビジネスユニット", 105_938, "segment"),
            ])
    }

    @Test func mufgEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W4FB", total: 156_253,
            rows: [
                ("AssetManagementAndInvestorServicesBusinessGroupMember", "受託財産事業本部", 12_635, "segment"),
                ("CommercialBankingAndWealthManagementBusinessGroupMember", "法人・ウェルスマネジメント事業本部", 18_905, "segment"),
                ("GlobalCommercialBankingBusinessGroupMember", "グローバルコマーシャルバンキング事業本部", 71_479, "segment"),
                ("GlobalCorporateAndInvestmentBankingBusinessGroupMember", "グローバルCIB事業本部", 3_313, "segment"),
                ("GlobalMarketsBusinessGroupMember", "市場事業本部", 2_546, "segment"),
                ("JapaneseCorporateAndInvestmentBankingBusinessGroupMember", "コーポレートバンキング事業本部", 6_816, "segment"),
                ("OtherMember", "その他", 23_101, "segment"),
                ("RetailAndDigitalBusinessGroupMember", "リテール・デジタル事業本部", 17_458, "segment"),
            ])
    }

    @Test func smfgEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W0S7", total: 122_978,
            rows: [
                ("GlobalBusinessUnitReportableSegmentMember", "グローバル事業部門", 69_590, "segment"),
                ("GlobalMarketsBusinessUnitReportableSegmentMember", "市場事業部門", 1_371, "segment"),
                ("HeadOfficeAccountReportableSegmentMember", "本社管理", 16_293, "segment"),
                ("RetailBusinessUnitReportableSegmentMember", "リテール事業部門", 26_979, "segment"),
                ("WholesaleBusinessUnitReportableSegmentMember", "ホールセール事業部門", 8_745, "segment"),
            ])
    }
    // MARK: - 未タグ行の補完（純粋持株会社等）

    /// 取り込みと同じ経路: `normalizeEmployees` の後に `EmployeesUntaggedRowFill`。
    private static func filledEmployees(
        docID: String, total: Double
    ) throws -> BreakdownSnapshot {
        let (facts, labels) = factsAndLabels(docID)
        let dir = xbrlDir(docID)
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: total, axis: "employees", labelsByTag: labels,
                memberParents: XBRLUtils.operatingSegmentMemberParents(in: dir)))
        return EmployeesUntaggedRowFill.fill(snapshot: snapshot, facts: facts, xbrlDir: dir)
    }

    // source: code=8267 fy_end=2026-02-28 doc_id=S100Y5VH page=18 row=純粋持株会社等 3,523 (従業員の状況 連結会社の状況、合計179,230)
    // 「純粋持株会社等」の値セルには ix:nonFraction が付かず、dimension 付き fact だけでは行が落ちる。
    @Test func aeonEmployeesKeepsUntaggedPureHoldingCompanyRowAsReconciling() async throws {
        guard await Self.ensureAvailable("S100Y5VH") else { return }
        let snapshot = try Self.filledEmployees(docID: "S100Y5VH", total: 179_230)
        #expect(snapshot.denominator == 179_230)
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.rows.count == 10)
        #expect(
            snapshot.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
                .map(\.amount).reduce(0, +) == 179_230)
        let holding = try #require(snapshot.rows.first { $0.label == "純粋持株会社等" })
        #expect(holding.amount == 3_523)
        #expect(holding.rowKind == "reconciling")
        let segments: [(String, Double)] = [
            ("GMSReportableSegmentsMember", 34_470),
            ("SupermarketReportableSegmentsMember", 26_209),
            ("DiscountStoreReportableSegmentMember", 1_848),
            ("HealthAndWellnessReportableSegmentMember", 28_105),
            ("FinancialServicesReportableSegmentMember", 14_942),
            ("SCDevelopmentReportableSegmentMember", 4_295),
            ("ServiceSpecialtyStoreReportableSegmentsMember", 32_880),
            ("InternationalReportableSegmentsMember", 30_683),
            (
                "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                2_275),
        ]
        for (member, amount) in segments {
            let row = try #require(snapshot.rows.first { $0.labelRaw == member })
            #expect(row.amount == amount)
            #expect(row.rowKind == "segment")
        }
    }

    // source: code=8354 fy_end=2026-03-31 doc_id=S100YFNB page=94 field=employees row=銀行業務 6,895 / その他事業 1,155 (従業員の状況 連結会社、合計8,050)
    // セグメント member 付きの fact が無く、横並び表の合計 8,050 だけにタグが付く。
    // セグメント別かは Jev（ここではスタブ）が判定。Jev 無し・「別の内訳」なら行を作らない。
    @Test func fukuokaFGEmployeesFromTotalOnlyHorizontalTable() async throws {
        guard await Self.ensureAvailable("S100YFNB") else { return }
        let (facts, labels) = Self.factsAndLabels("S100YFNB")
        let dir = Self.xbrlDir("S100YFNB")
        let normalized = BreakdownNormalizer.normalizeEmployees(
            facts: facts, total: 8_050, axis: "employees", labelsByTag: labels,
            memberParents: XBRLUtils.operatingSegmentMemberParents(in: dir))
        #expect(normalized == nil)
        let snapshot = try #require(await EmployeesUntaggedRowFill.fromTotalOnlyTable(
            total: 8_050, xbrlDir: dir, segmentLabels: [],
            decider: StubEmployeesTableDecider(answer: EmployeesTableJev.segmentsKey), docID: "S100YFNB"))
        #expect(snapshot.denominator == 8_050)
        #expect(snapshot.needsReview == false)
        let rows: [String: Double] = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.labelRaw, $0.amount) })
        let expected: [String: Double] = ["銀行業務": 6_895, "その他事業": 1_155]
        #expect(rows == expected)
        #expect(snapshot.rows.allSatisfy { $0.rowKind == "segment" })
        let other = await EmployeesUntaggedRowFill.fromTotalOnlyTable(
            total: 8_050, xbrlDir: dir, segmentLabels: [],
            decider: StubEmployeesTableDecider(answer: EmployeesTableJev.otherKey), docID: "S100YFNB")
        #expect(other == nil)
        let noKey = await EmployeesUntaggedRowFill.fromTotalOnlyTable(
            total: 8_050, xbrlDir: dir, segmentLabels: [], decider: nil, docID: "S100YFNB")
        #expect(noKey == nil)
    }

    // source: code=8331 fy_end=2026-03-31 doc_id=S100YDSE page=102 field=employees row=従業員数 4,377 (単一セグメント。従業員表は合計のみ)
    // 合計しか無い表からは行を作らない（Jev に聞く前に候補が無い）。
    @Test func chibaBankTotalOnlyEmployeesStaysNotFound() async throws {
        guard await Self.ensureAvailable("S100YDSE") else { return }
        let snapshot = await EmployeesUntaggedRowFill.fromTotalOnlyTable(
            total: 4_377, xbrlDir: Self.xbrlDir("S100YDSE"), segmentLabels: [],
            decider: StubEmployeesTableDecider(answer: EmployeesTableJev.segmentsKey), docID: "S100YDSE")
        #expect(snapshot == nil)
    }

    // source: code=3086 fy_end=2026-02-28 doc_id=S100Y6K0 page=18 row=全社（共通） 243 (従業員の状況 連結会社の状況、合計5,584)
    // 全社（共通）が member 付き fact で開示される会社は、補完で行も値も変わらない。
    @Test func jFrontEmployeesWithTaggedCorporateSharedUnchangedByUntaggedFill() async throws {
        guard await Self.ensureAvailable("S100Y6K0") else { return }
        let (facts, labels) = Self.factsAndLabels("S100Y6K0")
        let dir = Self.xbrlDir("S100Y6K0")
        let before = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 5_584, axis: "employees", labelsByTag: labels,
                memberParents: XBRLUtils.operatingSegmentMemberParents(in: dir)))
        let after = EmployeesUntaggedRowFill.fill(snapshot: before, facts: facts, xbrlDir: dir)
        #expect(after == before)
        #expect(after.rows.count == 6)
        #expect(after.rows.map(\.amount).reduce(0, +) == 5_584)
        let shared = try #require(after.rows.first { $0.labelRaw == "CorporateSharedMember" })
        #expect(shared.amount == 243)
        #expect(shared.rowKind == "reconciling")
    }

    // source: code=3099 fy_end=2026-03-31 doc_id=S100YD7C page=18 row=従業員数合計 8,670 (従業員の状況 連結会社の状況)
    // 表の全行が member 付き fact の会社は、補完で変わらない。
    @Test func isetanMitsukoshiEmployeesFullyTaggedUnchangedByUntaggedFill() async throws {
        guard await Self.ensureAvailable("S100YD7C") else { return }
        let (facts, labels) = Self.factsAndLabels("S100YD7C")
        let dir = Self.xbrlDir("S100YD7C")
        let before = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 8_670, axis: "employees", labelsByTag: labels,
                memberParents: XBRLUtils.operatingSegmentMemberParents(in: dir)))
        let after = EmployeesUntaggedRowFill.fill(snapshot: before, facts: facts, xbrlDir: dir)
        #expect(after == before)
        #expect(after.rows.count == 4)
        #expect(after.rows.map(\.amount).reduce(0, +) == 8_670)
        #expect(after.rows.allSatisfy { $0.rowKind == "segment" })
    }

    /// 単一セグメントの事業部門別従業員表。タグは全社（共通）だけ。
    private func departmentEmployees(
        docID: String, total: Double
    ) async throws -> BreakdownSnapshot? {
        guard await Self.ensureAvailable(docID) else { return nil }
        let dir = Self.xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labels = XBRLUtils.breakdownMemberLabels(in: dir)
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: total, axis: breakdownAxisEmployees, labelsByTag: labels))
        let anchored = EmployeesUntaggedRowFill.fill(snapshot: snapshot, facts: facts, xbrlDir: dir)
        return EmployeesUntaggedRowFill.fillDepartmentTable(snapshot: anchored, xbrlDir: dir)
    }

    /// source: code=2303 fy_end=2026-05-31 doc_id=S100YXLE page=43 field=employees.営業部門
    @Test func dawnSingleSegmentDepartmentEmployees() async throws {
        guard let filled = try await departmentEmployees(docID: "S100YXLE", total: 66) else { return }
        #expect(filled.denominator == 66)
        #expect(filled.rows.contains { ($0.label ?? "").contains("営業") && $0.amount == 12 })
        #expect(filled.rows.contains { ($0.label ?? "").contains("サービス推進") && $0.amount == 13 })
        #expect(filled.rows.contains { ($0.label ?? "").contains("開発") && $0.amount == 34 })
        #expect(filled.rows.contains { $0.rowKind == "reconciling" && $0.amount == 7 })
        #expect(filled.rows.map(\.amount).reduce(0, +) == 66)
        #expect(filled.needsReview == false)
    }

    /// source: code=324A fy_end=2026-04-30 doc_id=S100YSTV page=45 field=employees.集客支援事業
    @Test func bookingResortSingleSegmentDepartmentEmployees() async throws {
        guard let filled = try await departmentEmployees(docID: "S100YSTV", total: 48) else { return }
        #expect(filled.denominator == 48)
        #expect(filled.rows.contains { ($0.label ?? "").contains("集客支援") && $0.amount == 26 })
        #expect(filled.rows.contains { ($0.label ?? "").contains("直営宿泊") && $0.amount == 16 })
        #expect(filled.rows.contains { $0.rowKind == "reconciling" && $0.amount == 6 })
        #expect(filled.rows.map(\.amount).reduce(0, +) == 48)
        #expect(filled.needsReview == false)
    }

    /// source: code=500A fy_end=2026-04-30 doc_id=S100YSBO page=55 field=employees.IPクリエーション
    @Test func toBooksSingleSegmentDepartmentEmployees() async throws {
        guard let filled = try await departmentEmployees(docID: "S100YSBO", total: 149) else { return }
        #expect(filled.denominator == 149)
        #expect(filled.rows.contains { ($0.label ?? "").contains("IPクリエーション") && $0.amount == 119 })
        #expect(filled.rows.contains { ($0.label ?? "").contains("IPソリューション") && $0.amount == 14 })
        #expect(filled.rows.contains { $0.rowKind == "reconciling" && $0.amount == 16 })
        #expect(filled.rows.map(\.amount).reduce(0, +) == 149)
        #expect(filled.needsReview == false)
    }
}

/// 固定の答えを返すスタブ（3 サンプルとも同じ）。
struct StubEmployeesTableDecider: EmployeesTableDeciding {
    var answer: String
    func classifyEmployeesTable(
        table: EmployeesUntaggedRowFill.TotalOnlyTable, segmentLabels: [String], docID: String
    ) async -> JevChoiceAggregate.Sample {
        JevChoiceAggregate.Sample(
            selected: answer, probability: 0.97,
            options: [EmployeesTableJev.segmentsKey, EmployeesTableJev.otherKey], model: "stub")
    }
}
