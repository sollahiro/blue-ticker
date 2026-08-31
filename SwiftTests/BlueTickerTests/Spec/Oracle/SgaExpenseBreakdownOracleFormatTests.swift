// 外出し SPEC_ORACLE（`sga_expense_breakdown` note_type）。
//
// smoke 固定11社の実データ検証・目視確認（2026-08-27、golden化承認）:
// - resolved: オークマ・アズ企画・スズキ・味の素・東邦レマック・ニチレイ（構造化 *SGA / IFRS 費目）
// - not_found: クボタ・三菱UFJ・三井住友（連結に費目タグ無し。個別注記のみは拾わない）
// - us_gaap_unsupported: 富士フイルム・キヤノン
//
// 発生支出（ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities）は含めない。
// セグメント情報ののれん償却（AmortizationOfGoodwillSGA）は注記に含めない。
// スズキの販管費内 R&D は ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS。
// ニチレイ広告宣伝費は当期 5,082 百万円。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct SgaExpenseBreakdownOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_sga_expense_breakdown_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
        let items: [[String: Any]]?
        if case .resolved(let payload, _, _) = result {
            items = payload.items?.map { $0.jsonObject() }
        } else {
            items = nil
        }
        try StatementNotesOracleSupport.assertMatchesOracle(
            docID: docID, expectedFileURL: Self.expectedFileURL, result: result,
            itemsKey: "items", items: items)
    }

    private func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        try await StatementNotesOracleSupport.withSmokeCache(docID, body)
    }

    // MARK: - smoke 床11社（tmp_cache / SmokeCacheSupport）

    @Test
    func smokeSgaOkumaMatchesOracle() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaAzPlanningMatchesOracle() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaTohoRemacMatchesOracle() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaNichireiMatchesOracle() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaKubotaNotFound() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaSmfgNotFound() async throws {
        try await withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaMufgNotFound() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaFujifilmUSGAAPUnsupported() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokeSgaCanonUSGAAPUnsupported() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }

    // MARK: - golden（2026-08-27 ユーザー全件目視確認済み）
    //
    // smoke 固定11社の label / tag / 百万円 / section / total を開示 HTML・XBRL と突合。
    // のれんの償却額（AmortizationOfGoodwillSGA）はセグメント情報由来のため注記に含めない。
    // ニチレイ広告宣伝費は当期 5,082 百万円（5082000000 円）。発生支出タグは含めない。


    @Test
    func goldenSgaOkumaMatchesUserVerifiedValues() async throws {
        try await withSmokeCache("S100W043") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let items = try #require(payload.items)
            #expect(items.count == 7)
            let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0) })
            #expect(byTag["AmortizationOfGoodwillSGA"] == nil)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(byTag["CompensationsSalariesAndAllowancesSGA"]?.value == 15_837_000_000)
            #expect(byTag["CompensationsSalariesAndAllowancesSGA"]?.label == "報酬、給料及び手当")
            #expect(byTag["FreightageAndPackingExpensesSGA"]?.value == 11_862_000_000)
            #expect(byTag["FreightageAndPackingExpensesSGA"]?.label == "運賃荷造費")
            #expect(byTag["ResearchAndDevelopmentExpensesSGA"]?.value == 2_094_000_000)
            #expect(byTag["ResearchAndDevelopmentExpensesSGA"]?.label == "研究開発費")
            #expect(byTag["SalesChargesSGA"]?.value == 4_413_000_000)
            #expect(byTag["SalesChargesSGA"]?.label == "販売諸掛")
            #expect(byTag["TravelingAndCommunicationExpensesSGA"]?.value == 2_180_000_000)
            #expect(byTag["TravelingAndCommunicationExpensesSGA"]?.label == "旅費通信費")
            #expect(byTag["WelfareAndRetirementBenefitExpensesSGA"]?.value == 2_725_000_000)
            #expect(byTag["WelfareAndRetirementBenefitExpensesSGA"]?.label == "福利費及び退職給付費用")
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.value == 50_985_000_000)
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.label == "販売費及び一般管理費")
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.isTotal == true)
        }
    }

    @Test
    func goldenSgaAzPlanningMatchesUserVerifiedValues() async throws {
        try await withSmokeCache("S100VU4O") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let items = try #require(payload.items)
            #expect(items.count == 9)
            let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0) })
            #expect(byTag["AmortizationOfGoodwillSGA"] == nil)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(byTag["CommissionFeeSGA"]?.value == 100_215_000)
            #expect(byTag["CommissionFeeSGA"]?.label == "支払手数料")
            #expect(byTag["DirectorsCompensationsSGA"]?.value == 99_300_000)
            #expect(byTag["DirectorsCompensationsSGA"]?.label == "役員報酬")
            #expect(byTag["ProvisionForBonusesSGA"]?.value == 22_063_000)
            #expect(byTag["ProvisionForBonusesSGA"]?.label == "賞与引当金繰入額")
            #expect(byTag["ProvisionForShareholderBenefitProgramSGA"]?.value == 10_911_000)
            #expect(byTag["ProvisionForShareholderBenefitProgramSGA"]?.label == "株主優待引当金繰入額")
            #expect(byTag["ProvisionOfAllowanceForDoubtfulAccountsSGA"]?.value == 12_000)
            #expect(byTag["ProvisionOfAllowanceForDoubtfulAccountsSGA"]?.label == "貸倒引当金繰入額")
            #expect(byTag["RetirementBenefitExpensesSGA"]?.value == 6_468_000)
            #expect(byTag["RetirementBenefitExpensesSGA"]?.label == "退職給付費用")
            #expect(byTag["SalariesAndAllowancesSGA"]?.value == 297_087_000)
            #expect(byTag["SalariesAndAllowancesSGA"]?.label == "給料及び手当")
            #expect(byTag["TaxesAndDuesSGA"]?.value == 26_505_000)
            #expect(byTag["TaxesAndDuesSGA"]?.label == "租税公課")
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.value == 966_110_000)
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.label == "販売費及び一般管理費")
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.isTotal == true)
        }
    }

    @Test
    func goldenSgaSuzukiMatchesUserVerifiedValues() async throws {
        try await withSmokeCache("S100W4MT") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let items = try #require(payload.items)
            #expect(items.count == 7)
            let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0) })
            #expect(byTag["AmortizationOfGoodwillSGA"] == nil)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(byTag["AdvertisingExpensesIFRS"]?.value == 79_310_000_000)
            #expect(byTag["AdvertisingExpensesIFRS"]?.label == "広告宣伝費")
            #expect(byTag["EmployeeBenefitExpensesSGAIFRS"]?.value == 205_295_000_000)
            #expect(byTag["EmployeeBenefitExpensesSGAIFRS"]?.label == "従業員給付費用")
            #expect(byTag["OtherSGAIFRS"]?.value == 150_399_000_000)
            #expect(byTag["OtherSGAIFRS"]?.label == "その他")
            #expect(byTag["ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS"]?.value == 241_018_000_000)
            #expect(byTag["ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS"]?.label == "研究開発費")
            #expect(byTag["SellingAndVariousExpensesSGAIFRS"]?.value == 67_209_000_000)
            #expect(byTag["SellingAndVariousExpensesSGAIFRS"]?.label == "販売諸費")
            #expect(byTag["ShippingExpenseSGAIFRS"]?.value == 201_107_000_000)
            #expect(byTag["ShippingExpenseSGAIFRS"]?.label == "発送費")
            #expect(byTag["SellingGeneralAndAdministrativeExpensesIFRS"]?.value == 944_341_000_000)
            #expect(byTag["SellingGeneralAndAdministrativeExpensesIFRS"]?.label == "販売費及び一般管理費")
            #expect(byTag["SellingGeneralAndAdministrativeExpensesIFRS"]?.isTotal == true)
        }
    }

    @Test
    func goldenSgaAjinomotoMatchesUserVerifiedValues() async throws {
        try await withSmokeCache("S100VXJA") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let items = try #require(payload.items)
            #expect(items.count == 12)
            let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0) })
            #expect(byTag["AmortizationOfGoodwillSGA"] == nil)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(byTag["AdvertisingExpensesIFRS"]?.value == 44_529_000_000)
            #expect(byTag["AdvertisingExpensesIFRS"]?.label == "広告費")
            #expect(byTag["AdvertisingExpensesIFRS"]?.section == .group("selling"))
            #expect(byTag["DepreciationAndAmortizationGAIFRS"]?.value == 21_148_000_000)
            #expect(byTag["DepreciationAndAmortizationGAIFRS"]?.label == "減価償却費及び償却費")
            #expect(byTag["DepreciationAndAmortizationGAIFRS"]?.section == .group("general_and_administrative"))
            #expect(byTag["DepreciationAndAmortizationSellingExpensesIFRS"]?.value == 3_848_000_000)
            #expect(byTag["DepreciationAndAmortizationSellingExpensesIFRS"]?.label == "減価償却費及び償却費")
            #expect(byTag["DepreciationAndAmortizationSellingExpensesIFRS"]?.section == .group("selling"))
            #expect(byTag["EmployeeBenefitExpensesGAIFRS"]?.value == 82_136_000_000)
            #expect(byTag["EmployeeBenefitExpensesGAIFRS"]?.label == "従業員給付費用")
            #expect(byTag["EmployeeBenefitExpensesGAIFRS"]?.section == .group("general_and_administrative"))
            #expect(byTag["EmployeeBenefitExpensesSellingExpensesIFRS"]?.value == 52_837_000_000)
            #expect(byTag["EmployeeBenefitExpensesSellingExpensesIFRS"]?.label == "従業員給付費用")
            #expect(byTag["EmployeeBenefitExpensesSellingExpensesIFRS"]?.section == .group("selling"))
            #expect(byTag["OtherGAIFRS"]?.value == 51_592_000_000)
            #expect(byTag["OtherGAIFRS"]?.label == "その他")
            #expect(byTag["OtherGAIFRS"]?.section == .group("general_and_administrative"))
            #expect(byTag["OtherSellingExpensesIFRS"]?.value == 22_766_000_000)
            #expect(byTag["OtherSellingExpensesIFRS"]?.label == "その他")
            #expect(byTag["OtherSellingExpensesIFRS"]?.section == .group("selling"))
            #expect(byTag["PackingAndTransportationExpensesIFRS"]?.value == 57_357_000_000)
            #expect(byTag["PackingAndTransportationExpensesIFRS"]?.label == "物流費")
            #expect(byTag["PackingAndTransportationExpensesIFRS"]?.section == .group("selling"))
            #expect(byTag["SalesCommissionsIFRS"]?.value == 2_419_000_000)
            #expect(byTag["SalesCommissionsIFRS"]?.label == "販売手数料")
            #expect(byTag["SalesCommissionsIFRS"]?.section == .group("selling"))
            #expect(byTag["SalesPromotionExpensesIFRS"]?.value == 28_217_000_000)
            #expect(byTag["SalesPromotionExpensesIFRS"]?.label == "販売促進費")
            #expect(byTag["SalesPromotionExpensesIFRS"]?.section == .group("selling"))
            #expect(byTag["GeneralAndAdministrativeExpensesIFRS"]?.value == 154_878_000_000)
            #expect(byTag["GeneralAndAdministrativeExpensesIFRS"]?.label == "一般管理費")
            #expect(byTag["GeneralAndAdministrativeExpensesIFRS"]?.section == .group("general_and_administrative"))
            #expect(byTag["GeneralAndAdministrativeExpensesIFRS"]?.isTotal == true)
            #expect(byTag["SellingExpensesIFRS"]?.value == 211_976_000_000)
            #expect(byTag["SellingExpensesIFRS"]?.label == "販売費")
            #expect(byTag["SellingExpensesIFRS"]?.section == .group("selling"))
            #expect(byTag["SellingExpensesIFRS"]?.isTotal == true)
        }
    }

    @Test
    func goldenSgaTohoRemacMatchesUserVerifiedValues() async throws {
        try await withSmokeCache("S100XRD8") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let items = try #require(payload.items)
            #expect(items.count == 22)
            let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0) })
            #expect(byTag["AmortizationOfGoodwillSGA"] == nil)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(byTag["AdvertisingExpensesSGA"]?.value == 59_730_000)
            #expect(byTag["AdvertisingExpensesSGA"]?.label == "広告宣伝費")
            #expect(byTag["CommissionFeeSGA"]?.value == 272_800_000)
            #expect(byTag["CommissionFeeSGA"]?.label == "支払手数料")
            #expect(byTag["CommunicationExpensesSGA"]?.value == 3_187_000)
            #expect(byTag["CommunicationExpensesSGA"]?.label == "通信費")
            #expect(byTag["DepreciationSGA"]?.value == 23_809_000)
            #expect(byTag["DepreciationSGA"]?.label == "減価償却費")
            #expect(byTag["DirectorsCompensationsSGA"]?.value == 47_920_000)
            #expect(byTag["DirectorsCompensationsSGA"]?.label == "役員報酬")
            #expect(byTag["EmployeesSalariesAndAllowancesSGA"]?.value == 357_253_000)
            #expect(byTag["EmployeesSalariesAndAllowancesSGA"]?.label == "従業員給料及び手当")
            #expect(byTag["MiscellaneousExpensesSGA"]?.value == 119_949_000)
            #expect(byTag["MiscellaneousExpensesSGA"]?.label == "雑費")
            #expect(byTag["OtherPersonalExpensesSGA"]?.value == 74_280_000)
            #expect(byTag["OtherPersonalExpensesSGA"]?.label == "その他の人件費")
            #expect(byTag["OtherSalariesSGA"]?.value == 29_542_000)
            #expect(byTag["OtherSalariesSGA"]?.label == "雑給")
            #expect(byTag["PromotionExpensesSGA"]?.value == 91_482_000)
            #expect(byTag["PromotionExpensesSGA"]?.label == "販売促進費")
            #expect(byTag["ProvisionForBonusesSGA"]?.value == 15_029_000)
            #expect(byTag["ProvisionForBonusesSGA"]?.label == "賞与引当金繰入額")
            #expect(byTag["ProvisionForDirectorsRetirementBenefitsSGA"]?.value == 4_558_000)
            #expect(byTag["ProvisionForDirectorsRetirementBenefitsSGA"]?.label == "役員退職慰労引当金繰入額")
            #expect(byTag["ProvisionOfAllowanceForDoubtfulAccountsSGA"]?.value == 527_000)
            #expect(byTag["ProvisionOfAllowanceForDoubtfulAccountsSGA"]?.label == "貸倒引当金繰入額")
            #expect(byTag["RentExpensesSGA"]?.value == 8_401_000)
            #expect(byTag["RentExpensesSGA"]?.label == "賃借料")
            #expect(byTag["RepairExpensesSGA"]?.value == 7_139_000)
            #expect(byTag["RepairExpensesSGA"]?.label == "修繕費")
            #expect(byTag["RetirementBenefitExpensesSGA"]?.value == 21_333_000)
            #expect(byTag["RetirementBenefitExpensesSGA"]?.label == "退職給付費用")
            #expect(byTag["SuppliesExpensesSGA"]?.value == 25_691_000)
            #expect(byTag["SuppliesExpensesSGA"]?.label == "消耗品費")
            #expect(byTag["TaxesAndDuesSGA"]?.value == 32_137_000)
            #expect(byTag["TaxesAndDuesSGA"]?.label == "租税公課")
            #expect(byTag["TransportationAndWarehousingExpensesSGA"]?.value == 198_267_000)
            #expect(byTag["TransportationAndWarehousingExpensesSGA"]?.label == "運送費及び保管費")
            #expect(byTag["TravelingAndTransportationExpensesSGA"]?.value == 29_920_000)
            #expect(byTag["TravelingAndTransportationExpensesSGA"]?.label == "旅費及び交通費")
            #expect(byTag["UtilitiesExpensesSGA"]?.value == 11_062_000)
            #expect(byTag["UtilitiesExpensesSGA"]?.label == "水道光熱費")
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.value == 1_434_025_000)
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.label == "販売費及び一般管理費合計")
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.isTotal == true)
        }
    }

    @Test
    func goldenSgaNichireiMatchesUserVerifiedValues() async throws {
        try await withSmokeCache("S100VYA0") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let items = try #require(payload.items)
            #expect(items.count == 12)
            let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0) })
            #expect(byTag["AmortizationOfGoodwillSGA"] == nil)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(byTag["AdvertisingExpensesSGA"]?.value == 5_082_000_000)
            #expect(byTag["AdvertisingExpensesSGA"]?.label == "広告宣伝費")
            #expect(byTag["BusinessConsignmentExpensesSGA"]?.value == 6_044_000_000)
            #expect(byTag["BusinessConsignmentExpensesSGA"]?.label == "業務委託費")
            #expect(byTag["DirectorsCompensationEmployeesSalariesBonusesAndAllowancesSGA"]?.value == 24_799_000_000)
            #expect(byTag["DirectorsCompensationEmployeesSalariesBonusesAndAllowancesSGA"]?.label == "役員報酬及び従業員給料・賞与・手当")
            #expect(byTag["LegalAndEmployeeBenefitsExpensesSGA"]?.value == 4_154_000_000)
            #expect(byTag["LegalAndEmployeeBenefitsExpensesSGA"]?.label == "法定福利及び厚生費")
            #expect(byTag["OtherSGA"]?.value == 16_175_000_000)
            #expect(byTag["OtherSGA"]?.label == "その他")
            #expect(byTag["PromotionExpensesSGA"]?.value == 1_430_000_000)
            #expect(byTag["PromotionExpensesSGA"]?.label == "販売促進費")
            #expect(byTag["RentExpensesSGA"]?.value == 2_628_000_000)
            #expect(byTag["RentExpensesSGA"]?.label == "賃借料")
            #expect(byTag["ResearchAndDevelopmentExpensesSGA"]?.value == 2_206_000_000)
            #expect(byTag["ResearchAndDevelopmentExpensesSGA"]?.label == "研究開発費")
            #expect(byTag["RetirementBenefitExpensesSGA"]?.value == 1_282_000_000)
            #expect(byTag["RetirementBenefitExpensesSGA"]?.label == "退職給付費用")
            #expect(byTag["TransportationAndCommunicationExpensesSGA"]?.value == 2_673_000_000)
            #expect(byTag["TransportationAndCommunicationExpensesSGA"]?.label == "旅費交通費及び通信費")
            #expect(byTag["TransportationAndWarehousingExpensesSGA"]?.value == 21_434_000_000)
            #expect(byTag["TransportationAndWarehousingExpensesSGA"]?.label == "運送費及び保管費")
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.value == 87_913_000_000)
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.label == "販売費及び一般管理費合計")
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.isTotal == true)
        }
    }

    @Test
    func goldenSgaKubotaNotApplicable() async throws {
        try await withSmokeCache("S100XR0M") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .notApplicable(let reason) = result else {
                Issue.record("expected notApplicable, got \(result)")
                return
            }
            #expect(reason == "not_found")
        }
    }

    @Test
    func goldenSgaSmfgNotApplicable() async throws {
        try await withSmokeCache("S100W0S7") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .notApplicable(let reason) = result else {
                Issue.record("expected notApplicable, got \(result)")
                return
            }
            #expect(reason == "not_found")
        }
    }

    @Test
    func goldenSgaMufgNotApplicable() async throws {
        try await withSmokeCache("S100W4FB") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .notApplicable(let reason) = result else {
                Issue.record("expected notApplicable, got \(result)")
                return
            }
            #expect(reason == "not_found")
        }
    }

    @Test
    func goldenSgaFujifilmNotApplicable() async throws {
        try await withSmokeCache("S100W3XJ") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .notApplicable(let reason) = result else {
                Issue.record("expected notApplicable, got \(result)")
                return
            }
            #expect(reason == "us_gaap_unsupported")
        }
    }

    @Test
    func goldenSgaCanonNotApplicable() async throws {
        try await withSmokeCache("S100XTLJ") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .notApplicable(let reason) = result else {
                Issue.record("expected notApplicable, got \(result)")
                return
            }
            #expect(reason == "us_gaap_unsupported")
        }
    }


    // MARK: - sga_expense_breakdown golden（発生支出と販管費内 R&D の区別・別年度）

    @Test
    func goldenOkumaSgaRdDistinctFromOccurrenceSpend() async throws {
        try await withSmokeCache("S100YFQC") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let byTag = Dictionary(uniqueKeysWithValues: (payload.items ?? []).map { ($0.tag, $0) })
            #expect(byTag["ResearchAndDevelopmentExpensesSGA"]?.value == 2_097_000_000)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(
                byTag[
                    "ResearchAndDevelopmentExpensesIncludedInGeneralAndAdministrativeExpensesAndManufacturingCostForCurrentPeriod"
                ] == nil)
            #expect(byTag["FreightageAndPackingExpensesSGA"]?.value == 12_834_000_000)
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.isTotal == true)
            #expect(byTag["SellingGeneralAndAdministrativeExpenses"]?.value == 53_796_000_000)
            #expect(byTag["AmortizationOfGoodwillSGA"] == nil)
        }
    }

    @Test
    func goldenSuzukiSgaRdMatchesNotesNotOccurrenceSpend() async throws {
        try await withSmokeCache("S100YFG2") { xbrlDir in
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
            guard case .resolved(let payload, _, _) = result else {
                Issue.record("expected resolved, got \(result)")
                return
            }
            let byTag = Dictionary(uniqueKeysWithValues: (payload.items ?? []).map { ($0.tag, $0) })
            #expect(
                byTag["ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS"]?.value
                    == 271_082_000_000)
            #expect(byTag["ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"] == nil)
            #expect(byTag["SellingGeneralAndAdministrativeExpensesIFRS"]?.value == 1_012_493_000_000)
            let components = (payload.items ?? []).filter { !$0.isTotal }.map(\.value)
            #expect(abs(components.reduce(0, +) - 1_012_493_000_000) < 3_000_000)
        }
    }

    /// `DUMP_SGA_ORACLE=1` のとき smoke 11社の実結果を expected JSON に書き出す（床の初期生成用）。
    @Test
    func dumpSgaOracleIfRequested() async throws {
        guard ProcessInfo.processInfo.environment["DUMP_SGA_ORACLE"] == "1" else { return }
        let docIDs = [
            "S100W043", "S100VU4O", "S100W4MT", "S100VXJA", "S100XRD8", "S100VYA0",
            "S100XR0M", "S100W0S7", "S100W4FB", "S100W3XJ", "S100XTLJ",
        ]
        await SmokeCacheSupport.ensureCached(docIDs)
        var out: [String: Any] = [:]
        for docID in docIDs {
            guard StatementNotesOracleSupport.smokeCacheAvailable(docID) else {
                Issue.record("missing cache \(docID)")
                continue
            }
            let result = StatementNotesResolver.resolveSgaExpenseBreakdown(
                xbrlDir: StatementNotesOracleSupport.smokeXbrlDir(docID))
            switch result {
            case .notApplicable(let reason):
                out[docID] = ["status": "not_applicable", "reason": reason]
            case .failed:
                out[docID] = ["status": "failed"]
            case .resolved(let payload, let source, _):
                var entry: [String: Any] = ["status": "resolved", "source": source]
                if let items = payload.items {
                    entry["items"] = items.map { $0.jsonObject() }
                }
                out[docID] = entry
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.expectedFileURL)
        print("DUMPED \(Self.expectedFileURL.path)")
    }
}
