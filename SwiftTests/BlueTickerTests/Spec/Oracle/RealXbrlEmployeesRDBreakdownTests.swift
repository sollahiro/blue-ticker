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
        // CorporateSharedMember は提出書類側の拡張ラベルが無く未解決（label == nil、公開層で
        // labelRaw へフォールバック）。
        let components = try #require(
            snapshot.rows.first { $0.labelRaw == "ComponentsReportableSegmentsMember" })
        #expect(components.label == "コンポーネント")
        #expect(corporateShared.label == nil)
    }

    @Test func kyoceraResearchAndDevelopmentResolvesWithoutWarning() async throws {
        guard await Self.ensureAvailable("S100TSIJ") else { return }
        let xbrlDir = Self.xbrlDir("S100TSIJ")
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: xbrlDir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labelsByTag = XBRLUtils.breakdownMemberLabels(in: xbrlDir)

        let snapshot = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 132_502_000_000, axis: "research_and_development",
                labelsByTag: labelsByTag))

        #expect(snapshot.axis == "research_and_development")
        #expect(snapshot.needsReview == false)
        let labels = Set(snapshot.rows.map(\.labelRaw))
        #expect(labels.contains("ComponentsReportableSegmentsMember"))
        #expect(labels.contains("DevicesAndModulesReportableSegmentsMember"))
        #expect(labels.contains("OtherReportableSegmentsMember"))

        let devicesAndModules = try #require(
            snapshot.rows.first { $0.labelRaw == "DevicesAndModulesReportableSegmentsMember" })
        #expect(devicesAndModules.label == "デバイス・モジュール")
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
        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 31_514, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        let parent = try #require(
            emp.rows.first { $0.labelRaw == "GlobalConsumerCareBusinessReportableSegmentMember" })
        #expect(parent.rowKind == "subtotal")
        let reconciled = emp.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(reconciled == 31_514)
    }

    @Test func nttResearchAndDevelopmentSubtractsIntersegmentElimination() async throws {
        guard await Self.ensureAvailable("S100YCP3") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100YCP3")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 278_649_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let elim = try #require(
            rd.rows.first { $0.labelRaw == "UnallocatedAmountsAndEliminationMember" })
        #expect(elim.rowKind == "reconciling")
        #expect(elim.amount == -119_217_000_000)
        let reconciled = rd.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(reconciled == 278_649_000_000)
    }

    // MARK: - employees/research_and_development 軸 実データゴールデン（2026-08-03、10社レビュー）
    //
    // ユーザーが10社（日経225）のemployees/research_and_development軸抽出結果を実データで
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

    @Test func yokogawaEmployeesAndRDMatchDisclosedSegmentTotals() async throws {
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

        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 32_061_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let rdControl = try #require(
            rd.rows.first { $0.labelRaw == "IndustrialAutomationAndControlReportableSegmentsMember" })
        #expect(rdControl.amount == 28_835_000_000)
        #expect(rdControl.label == "制御")
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

    @Test func nittoDenkoEmployeesMatchesDisclosedSegmentTotalsRDStaysNeedsReview() async throws {
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

        // R&D は注記本文（HTMLテキストブロック）に「全社技術部門10,725百万円」の内訳が
        // あるが XBRL dimension タグが無いため未タグ分が残り、needs_review=true が正しい
        // （2026-08-03 実データ確認。SCREEN HD も同型）。
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 46_771_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
    }

    @Test func hondaEmployeesMatchesDisclosedSegmentTotalsRDStaysNeedsReview() async throws {
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

        // R&D 注記21は費用の性質別（発生支出／資産化／償却）の調整であり事業セグメント別の
        // 内訳ではない。四輪事業のR&D費はこの書類のどこにも（タグにもテキストにも）
        // セグメント単位で開示されていない正当な欠測（2026-08-03 実データ確認）。
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 1_099_482_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
    }

    @Test func nomuraResearchInstituteEmployeesAndRDMatchDisclosedSegmentTotals() async throws {
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

        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 6_114_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let financialIT = try #require(
            rd.rows.first { $0.labelRaw == "FinancialITSolutionsReportableSegmentMember" })
        #expect(financialIT.amount == 2_929_000_000)
        #expect(financialIT.label == "金融ＩＴソリューション")
    }

    @Test func toyotaEmployeesAndRDMatchDisclosedSegmentTotals() async throws {
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

        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 1_326_496_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let automotiveRD = try #require(
            rd.rows.first { $0.labelRaw == "AutomotiveReportableSegmentMember" })
        #expect(automotiveRD.amount == 1_310_754_000_000)
        #expect(automotiveRD.label == "自動車")
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

    @Test func ajinomotoEmployeesAndRDMatchDisclosedSegmentTotals() async throws {
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

        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 30_921_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let healthcare = try #require(
            rd.rows.first { $0.labelRaw == "HealthcareAndOthersReportableSegmentMember" })
        #expect(healthcare.amount == 11_212_000_000)
        #expect(healthcare.label == "ヘルスケア等")
    }

    /// business 軸（`normalizeSalesBasis` 経路）でも同じラベル解決が効くこと。
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
        #expect(snapshot.axis == "business")
        #expect(snapshot.rows.contains { $0.label != nil && $0.label != $0.labelRaw })
    }
}

// smoke 固定11社（`SmokeTests.swift`と同じ docID セット）での research_and_development 軸
// 実データゴールデン（2026-08-11）。キャッシュは `tmp_cache/edinet/`（`SmokeCacheSupport.cacheDir`、
// 他の smoke オラクル形式テストと同じ場所）。全社とも実タグ
// `ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities` を確認済みのため denominatorTag
// もあわせて固定する。ニチレイ・富士フイルム・キヤノンの乖離は開示側が「その他」「基礎研究費」を
// 地の文（プレーンテキスト）のみで開示しXBRLタグを振っていないための正当な未タグ残差（元のiXBRLを
// 直接確認して金額まで一致を確認済み。292/9,105/52,971百万円は`ix:nonFraction`化されていない）。

@Suite struct SmokeResearchAndDevelopmentBreakdownTests {

    private static let xbrlRoot = SmokeCacheSupport.cacheDir

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

    private static let rdTag = "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"

    // MARK: - resolved・needsReview=false

    @Test func ajinomotoResolvesFiveSegmentRows() async throws {
        guard await Self.ensureAvailable("S100VXJA") else { return }
        let (facts, labels) = Self.factsAndLabels("S100VXJA")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 30_921_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == false)
        #expect(rd.denominatorTag == Self.rdTag)
        #expect(rd.rows.count == 5)
        let healthcare = try #require(rd.rows.first { $0.labelRaw == "HealthcareAndOthersReportableSegmentMember" })
        #expect(healthcare.amount == 11_212_000_000)
        #expect(healthcare.label == "ヘルスケア等")
        let unallocated = try #require(
            rd.rows.first { $0.labelRaw == "UnallocatedAmountsAndEliminationMember" })
        #expect(unallocated.amount == 9_562_000_000)
        #expect(unallocated.rowKind == "reconciling")
    }

    @Test func okumaTotalOnlyResolvesWithoutSegmentRowsUsingRealTag() async throws {
        guard await Self.ensureAvailable("S100W043") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W043")
        #expect(facts.filter { $0.tag == Self.rdTag }.isEmpty)  // セグメントdimension開示なし
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 4_409_000_000, totalTag: Self.rdTag,
                axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == false)
        #expect(rd.denominator == 4_409_000_000)
        #expect(rd.denominatorTag == Self.rdTag)
        #expect(rd.rows.isEmpty)
    }

    @Test func kubotaResolvesTwoSegmentRowsSummingExactlyToTotal() async throws {
        guard await Self.ensureAvailable("S100XR0M") else { return }
        let (facts, labels) = Self.factsAndLabels("S100XR0M")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 110_300_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == false)
        #expect(rd.denominatorTag == Self.rdTag)
        #expect(rd.rows.map(\.amount).reduce(0, +) == 110_300_000_000)
        let machinery = try #require(rd.rows.first { $0.labelRaw == "MachineryReportableSegmentMember" })
        #expect(machinery.amount == 103_500_000_000)
        #expect(machinery.label == "機械")
    }

    @Test func suzukiResolvesFourSegmentRowsSummingExactlyToTotal() async throws {
        guard await Self.ensureAvailable("S100W4MT") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W4MT")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 265_600_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == false)
        #expect(rd.denominatorTag == Self.rdTag)
        #expect(rd.rows.map(\.amount).reduce(0, +) == 265_600_000_000)
        let automobile = try #require(
            rd.rows.first { $0.labelRaw == "AutomobileBusinessReportableSegmentMember" })
        #expect(automobile.amount == 239_100_000_000)
        #expect(automobile.label == "四輪事業")
    }

    // MARK: - resolved・needsReview=true（未タグ残差、実データ確認済み）

    /// 「その他の事業は291百万円となりました」は地の文のみでXBRLタグなし（実データ確認済み）。
    @Test func nichireiRDStaysNeedsReviewForUntaggedOtherSegment() async throws {
        guard await Self.ensureAvailable("S100VYA0") else { return }
        let (facts, labels) = Self.factsAndLabels("S100VYA0")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 2_206_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
        #expect(rd.rows.map(\.amount).reduce(0, +) == 1_915_000_000)
        let processedFoods = try #require(
            rd.rows.first { $0.labelRaw == "ProcessedFoodsReportableSegmentsMember" })
        #expect(processedFoods.amount == 1_436_000_000)
        #expect(processedFoods.label == "加工食品")
    }

    /// 「基礎研究費は9,105百万円です」は地の文のみでXBRLタグなし（実データ確認済み）。
    @Test func fujifilmRDStaysNeedsReviewForUntaggedBasicResearch() async throws {
        guard await Self.ensureAvailable("S100W3XJ") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W3XJ")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 163_399_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
        #expect(rd.rows.map(\.amount).reduce(0, +) == 154_294_000_000)
        let healthcare = try #require(rd.rows.first { $0.labelRaw == "HealthcareReportableSegmentsMember" })
        #expect(healthcare.amount == 60_698_000_000)
        #expect(healthcare.label == "ヘルスケア")
    }

    /// 「基礎研究等のその他及び全社に係る研究開発費は52,971百万円」は地の文のみでXBRLタグなし
    /// （実データ確認済み）。
    @Test func canonRDStaysNeedsReviewForUntaggedBasicResearchAndCorporate() async throws {
        guard await Self.ensureAvailable("S100XTLJ") else { return }
        let (facts, labels) = Self.factsAndLabels("S100XTLJ")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 339_288_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
        #expect(rd.rows.map(\.amount).reduce(0, +) == 286_317_000_000)
        let imaging = try #require(
            rd.rows.first { $0.labelRaw == "ImagingBusinessUnitReportableSegmentsMember" })
        #expect(imaging.amount == 112_298_000_000)
        #expect(imaging.label == "イメージングビジネスユニット")
    }

    // MARK: - nil（RD非開示、正当欠測）

    @Test func azPlanningHasNoResearchAndDevelopmentDisclosure() async throws {
        guard await Self.ensureAvailable("S100VU4O") else { return }
        let (facts, labels) = Self.factsAndLabels("S100VU4O")
        let rd = BreakdownNormalizer.normalizeResearchAndDevelopment(
            facts: facts, total: nil, axis: "research_and_development", labelsByTag: labels)
        #expect(rd == nil)
    }

    @Test func tohoRemacHasNoResearchAndDevelopmentDisclosure() async throws {
        guard await Self.ensureAvailable("S100XRD8") else { return }
        let (facts, labels) = Self.factsAndLabels("S100XRD8")
        let rd = BreakdownNormalizer.normalizeResearchAndDevelopment(
            facts: facts, total: nil, axis: "research_and_development", labelsByTag: labels)
        #expect(rd == nil)
    }

    @Test func mufgBankHasNoResearchAndDevelopmentDisclosure() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W4FB")
        let rd = BreakdownNormalizer.normalizeResearchAndDevelopment(
            facts: facts, total: nil, axis: "research_and_development", labelsByTag: labels)
        #expect(rd == nil)
    }

    @Test func smfgBankHasNoResearchAndDevelopmentDisclosure() async throws {
        guard await Self.ensureAvailable("S100W0S7") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W0S7")
        let rd = BreakdownNormalizer.normalizeResearchAndDevelopment(
            facts: facts, total: nil, axis: "research_and_development", labelsByTag: labels)
        #expect(rd == nil)
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
                ("CorporateSharedMember", nil, 780, "reconciling"),
                ("FrozenFoodsReportableSegmentMember", "冷凍食品", 5_478, "segment"),
                ("HealthcareAndOthersReportableSegmentMember", "ヘルスケア等", 5_321, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    nil, 1_185, "segment"),
                ("SeasoningsAndFoodsReportableSegmentMember", "調味料・食品", 22_096, "segment"),
            ])
    }

    @Test func nichireiEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100VYA0", total: 16_626,
            rows: [
                ("CorporateSharedMember", nil, 229, "reconciling"),
                ("LogisticsReportableSegmentsMember", "低温物流", 4_926, "segment"),
                ("MarineProductsReportableSegmentsMember", "水産", 744, "segment"),
                ("MeatAndPoultryProductsReportableSegmentsMember", "畜産", 397, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    nil, 190, "segment"),
                ("ProcessedFoodsReportableSegmentsMember", "加工食品", 10_125, "segment"),
                ("RealEstateReportableSegmentsMember", "不動産", 15, "segment"),
            ])
    }

    @Test func azPlanningEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100VU4O", total: 63,
            rows: [
                ("CorporateSharedMember", nil, 15, "reconciling"),
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
                ("CorporateSharedMember", nil, 4_129, "reconciling"),
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
                ("CorporateSharedMember", nil, 1_403, "reconciling"),
                ("MachineryReportableSegmentMember", "機械", 41_342, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    nil, 1_379, "segment"),
                ("WaterAndEnvironmentReportableSegmentMember", "水・環境", 8_379, "segment"),
            ])
    }

    @Test func suzukiEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W4MT", total: 74_077,
            rows: [
                ("AutomobileBusinessReportableSegmentMember", "四輪事業", 64_149, "segment"),
                ("CorporateSharedMember", nil, 996, "reconciling"),
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
}

