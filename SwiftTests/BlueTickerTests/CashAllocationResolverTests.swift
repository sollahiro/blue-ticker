// 資金配分（現金増減ブリッジ）の決定論と Jev fail-closed。値は CF 本表行そのもの。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct CashAllocationResolverTests {
    private let million = 1_000_000.0

    private func row(
        _ tag: String, _ label: String, _ millionYen: Double, order: Int,
        section: StatementLineSection? = nil, total: Bool = false
    ) -> StatementLineItem {
        StatementLineItem(
            tag: tag, label: label, value: millionYen * million, unit: "JPY", order: order,
            section: section, isTotal: total)
    }

    /// SMC 6273（日本基準）の CF 本表の財務区分と末尾（百万円、公開 statement の値）。
    private func smcCashFlow() -> [StatementLineItem] {
        [
            row("NetCashProvidedByUsedInOperatingActivities", "営業活動によるキャッシュ・フロー", 150_000, order: 0, section: .operating, total: true),
            row("NetCashProvidedByUsedInInvestmentActivities", "投資活動によるキャッシュ・フロー", -107_511, order: 1, section: .investing, total: true),
            row("NetIncreaseDecreaseInShortTermLoansPayableFinCF", "短期借入金の純増減額（△は減少）", 51, order: 2, section: .financing),
            row("RepaymentOfLongTermLoansPayableFinCF", "長期借入金の返済による支出", 0, order: 3, section: .financing),
            row("PurchaseOfTreasuryStockFinCF", "自己株式の取得による支出", -30_018, order: 4, section: .financing),
            row("CashDividendsPaidFinCF", "配当金の支払額", -63_535, order: 5, section: .financing),
            row("PaymentsFromChangesInOwnershipInterestsInSubsidiariesThatDoNotResultInChangeInScopeOfConsolidationFinCF", "連結の範囲の変更を伴わない子会社株式の取得による支出", 0, order: 6, section: .financing),
            row("OtherNetFinCF", "その他", -617, order: 7, section: .financing),
            row("NetCashProvidedByUsedInFinancingActivities", "財務活動によるキャッシュ・フロー", -94_119, order: 8, section: .financing, total: true),
            row("EffectOfExchangeRateChangeOnCashAndCashEquivalents", "現金及び現金同等物に係る換算差額", 44_553, order: 9),
            row("NetIncreaseDecreaseInCashAndCashEquivalents", "現金及び現金同等物の増減額（△は減少）", 31_839, order: 10, total: true),
            row("CashAndCashEquivalents", "現金及び現金同等物の期首残高", 531_649, order: 11),
            row("IncreaseDecreaseInCashAndCashEquivalentsResultingFromChangeOfScopeOfConsolidationCCE", "連結の範囲の変更に伴う現金及び現金同等物の増減額（△は減少）", 10_281, order: 12),
            row("CashAndCashEquivalents", "現金及び現金同等物の期末残高", 573_769, order: 13),
        ]
    }

    @Test func jgaapRowsSplitIntoDebtDividendsBuybackAndOther() throws {
        let values = CashAllocationResolver.resolve(
            cashFlow: smcCashFlow(), cfo: nil, cfi: nil, isBank: false)
        #expect(values.cff == -94_119 * million)
        #expect(values.debtChange == 51 * million)
        #expect(values.dividendsParent == -63_535 * million)
        #expect(values.buyback == -30_018 * million)
        #expect(values.otherFinancing == -617 * million)
        #expect(values.fxEffect == 44_553 * million)
        #expect(values.cashChange == (573_769 - 531_649) * million)
        // cfi が無ければ「その他」は出さない。
        #expect(values.otherCashChange == nil)
        #expect(values.jevAudit == nil)
    }

    @Test func otherCashChangeAbsorbsScopeChangeRow() throws {
        let cfo = 147_116.0 * million
        let cfi = -107_511.0 * million
        let values = CashAllocationResolver.resolve(
            cashFlow: smcCashFlow(), cfo: cfo, cfi: cfi, isBank: false)
        let other = try #require(values.otherCashChange)
        // 期末 − 期首 = cfo + cfi + cff + 換算差額 + その他。連結範囲の変更 10,281 がここに入る。
        let expected = (573_769 - 531_649) * million - cfo - cfi - (-94_119 * million) - 44_553 * million
        #expect(abs(other - expected) < 1)
        let bridge = cfo + cfi + values.debtChange! + values.dividendsParent! + values.buyback!
            + values.otherFinancing! + values.fxEffect! + other
        #expect(abs(bridge - values.cashChange!) < 1)
    }

    @Test func ifrsNonControllingDividendsGoToOtherAndNetTreasuryRowIsBuyback() throws {
        // トヨタ 7203（IFRS）の財務区分（百万円）。
        let cashFlow = [
            row("IncreaseDecreaseInShortTermDebtFinCFIFRS", "短期有利子負債の純増減額（△は減少）", -90_691, order: 0, section: .financing),
            row("ProceedsFromLongTermDebtFinCFIFRS", "長期有利子負債の増加", 12_880_225, order: 1, section: .financing),
            row("PaymentsOfLongTermDebtFinCFIFRS", "長期有利子負債の返済", -11_956_541, order: 2, section: .financing),
            row("DividendsPaidToOwnersOfParentFinCFIFRS", "親会社の所有者への配当金の支払額", -1_238_974, order: 3, section: .financing),
            row("DividendsPaidToNonControllingInterestsFinCFIFRS", "非支配持分への配当金の支払額", -125_416, order: 4, section: .financing),
            row("ReissuanceRepurchaseOfTreasuryStockFinCFIFRS", "自己株式の取得（△）及び処分", -39_975, order: 5, section: .financing),
            row("OtherFinCFIFRS", "その他", 34_712, order: 6, section: .financing),
            row("NetCashProvidedByUsedInFinancingActivitiesIFRS", "財務活動によるキャッシュ・フロー", -536_659, order: 7, section: .financing, total: true),
            row("EffectOfExchangeRateChangesOnCashAndCashEquivalentsIFRS", "現金及び現金同等物に対する為替変動の影響額", 377_197, order: 8),
            row("CashAndCashEquivalentsIFRS", "現金及び現金同等物の期首残高", 8_982_404, order: 9),
            row("NetIncreaseDecreaseInCashAndCashEquivalentsResultingFromTransferToAssetsHeldForSaleCCEIFRS", "売却目的で保有する資産への振替に伴う現金及び現金同等物の増減額（△は減少）", -115_932, order: 10),
            row("CashAndCashEquivalentsIFRS", "現金及び現金同等物の期末残高", 12_659_622, order: 11),
        ]
        let values = CashAllocationResolver.resolve(
            cashFlow: cashFlow, cfo: nil, cfi: nil, isBank: false)
        #expect(values.debtChange == (-90_691 + 12_880_225 - 11_956_541) * million)
        #expect(values.dividendsParent == -1_238_974 * million)
        // 取得と処分を純額で開示する行は自己株式の取得。
        #expect(values.buyback == -39_975 * million)
        // 行の和（−536,660）と合計（−536,659）の丸め差は許容し、その他は合計から引いて出す。
        #expect(values.otherFinancing == (-125_416 + 34_712 + 1) * million)
        #expect(values.fxEffect == 377_197 * million)
    }

    @Test func financingSumMismatchWithholdsBreakdown() throws {
        let cashFlow = [
            row("RepaymentOfLongTermLoansPayableFinCF", "長期借入金の返済による支出", -100, order: 0, section: .financing),
            row("NetCashProvidedByUsedInFinancingActivities", "財務活動によるキャッシュ・フロー", -150, order: 1, section: .financing, total: true),
        ]
        let values = CashAllocationResolver.resolve(cashFlow: cashFlow, cfo: nil, cfi: nil, isBank: false)
        #expect(values.cff == -150 * million)
        #expect(values.debtChange == nil)
        #expect(values.dividendsParent == nil)
        #expect(values.otherFinancing == nil)
    }

    @Test func bankWithholdsDebtBreakdownButKeepsCashLines() throws {
        let values = CashAllocationResolver.resolve(
            cashFlow: smcCashFlow(), cfo: nil, cfi: nil, isBank: true)
        #expect(values.cff == -94_119 * million)
        #expect(values.fxEffect == 44_553 * million)
        #expect(values.debtChange == nil)
        #expect(values.otherFinancing == nil)
    }

    @Test func missingFxRowIsZero() throws {
        let cashFlow = [
            row("CashDividendsPaidFinCF", "配当金の支払額", -10, order: 0, section: .financing),
            row("NetCashProvidedByUsedInFinancingActivities", "財務活動によるキャッシュ・フロー", -10, order: 1, section: .financing, total: true),
            row("CashAndCashEquivalents", "現金及び現金同等物の期首残高", 100, order: 2),
            row("CashAndCashEquivalents", "現金及び現金同等物の期末残高", 120, order: 3),
        ]
        let values = CashAllocationResolver.resolve(cashFlow: cashFlow, cfo: 50, cfi: -20, isBank: false)
        #expect(values.fxEffect == 0)
        #expect(values.debtChange == 0)
        #expect(values.dividendsParent == -10 * million)
    }

    @Test func labelRulesForCompanyExtensionTags() {
        #expect(CashAllocationResolver.classify(label: "長期借入れによる収入") == .debt)
        #expect(CashAllocationResolver.classify(label: "コマーシャル・ペーパーの純増減額") == .debt)
        #expect(CashAllocationResolver.classify(label: "新株予約権付社債の償還による支出") == .debt)
        #expect(CashAllocationResolver.classify(label: "リース負債の返済による支出") == .debt)
        #expect(CashAllocationResolver.classify(label: "配当金の支払額") == .dividendParent)
        #expect(CashAllocationResolver.classify(label: "非支配株主への配当金の支払額") == .other)
        #expect(CashAllocationResolver.classify(label: "SVFの外部投資家に対する分配額・返還額") == .other)
        #expect(CashAllocationResolver.classify(label: "自己株式の取得による支出") == .buyback)
        #expect(CashAllocationResolver.classify(label: "自己株式の取得及び処分") == .buyback)
        #expect(CashAllocationResolver.classify(label: "自己株式の純増減額（△は増加）") == .buyback)
        #expect(CashAllocationResolver.classify(label: "自己株式の処分による収入") == .other)
        #expect(CashAllocationResolver.classify(label: "自己株式の売却による収入") == .other)
        #expect(CashAllocationResolver.classify(label: "連結子会社による自己株式の取得による支出") == .other)
        #expect(CashAllocationResolver.classify(label: "その他") == .other)
        // 曖昧な行は Jev 行き。
        #expect(CashAllocationResolver.classify(label: "カード事業の短期借入金の純増減額（△は減少）") == nil)
        #expect(CashAllocationResolver.classify(label: "債権流動化による収入") == nil)
        #expect(CashAllocationResolver.classify(label: "グループファイナンス預り金(３ヶ月以内)の純増減(△減少)") == nil)
        #expect(CashAllocationResolver.classify(label: "社債及び借入金に係る金利通貨スワップの決済による収入") == nil)
        #expect(CashAllocationResolver.classify(label: "鉄道施設購入長期未払金の支払による支出") == nil)
    }

    private func jevCashFlow() -> [StatementLineItem] {
        [
            row("CashDividendsPaidFinCF", "配当金の支払額", -10, order: 0, section: .financing),
            row("X_ProceedsFromFluidityFinCF", "債権流動化による収入", 30, order: 1, section: .financing),
            row("NetCashProvidedByUsedInFinancingActivities", "財務活動によるキャッシュ・フロー", 20, order: 2, section: .financing, total: true),
        ]
    }

    @Test func unresolvedRowWithoutDeciderWithholdsBreakdown() async {
        let values = await CashAllocationResolver.resolve(
            cashFlow: jevCashFlow(), cfo: nil, cfi: nil, isBank: false, decider: nil, docID: "S100TEST")
        #expect(values.cff == 20 * million)
        #expect(values.debtChange == nil)
        #expect(values.jevAudit == nil)
    }

    @Test func jevClassifiesUnresolvedRow() async throws {
        let decider = FakeCashFlowFinancingRowDecider(answer: "debt", probability: 0.95)
        let values = await CashAllocationResolver.resolve(
            cashFlow: jevCashFlow(), cfo: nil, cfi: nil, isBank: false, decider: decider, docID: "S100TEST")
        #expect(values.debtChange == 30 * million)
        #expect(values.dividendsParent == -10 * million)
        #expect(values.otherFinancing == 0)
        let audit = try #require(values.jevAudit)
        #expect(audit.applied)
        #expect(audit.axis == CashAllocationResolver.axis)
        #expect(await decider.calls == 3)
    }

    @Test func lowConfidenceJevFailsClosed() async throws {
        let decider = FakeCashFlowFinancingRowDecider(answer: "debt", probability: 0.6)
        let values = await CashAllocationResolver.resolve(
            cashFlow: jevCashFlow(), cfo: nil, cfi: nil, isBank: false, decider: decider, docID: "S100TEST")
        #expect(values.debtChange == nil)
        let audit = try #require(values.jevAudit)
        #expect(!audit.applied)
        #expect(audit.needsReview)
    }

    @Test func waterfallProjectsCashAllocationButSummaryDoesNot() throws {
        var year = FinancialsYear()
        year.cff = -94_119
        year.cfDebtChange = 51
        year.cfDividendsParent = -63_535
        year.cfBuyback = -30_018
        year.cfOtherFinancing = -617
        year.cfFxEffect = 44_553
        year.cfCashChange = 42_120
        year.cfOtherCashChange = 10_281
        let analysis = year.analysisJsonObject(prior: nil)
        #expect(analysis["cf_debt_change"] as? Double == 51)
        #expect(analysis["cf_other_cash_change"] as? Double == 10_281)
        let summary = year.summaryJsonObject()
        for key in ["cff", "cf_debt_change", "cf_dividends_parent", "cf_buyback", "cf_other_financing",
                    "cf_fx_effect", "cf_cash_change", "cf_other_cash_change"] {
            #expect(summary[key] == nil)
            #expect(financialsUnits[key] == .currencyAmount)
        }
    }

    @Test func usgaapHtmlRowsResolveByLabel() throws {
        // 富士フイルム 4901（US-GAAP、S100YIBH）の CF 本表（百万円、タグは USGAAP_HTML_CF_n）。
        let f = StatementLineSection.financing
        let cashFlow = [
            row("USGAAP_HTML_CF_11", "営業活動によるキャッシュ・フロー", 410_555, order: 11, section: .operating, total: true),
            row("USGAAP_HTML_CF_22", "投資活動によるキャッシュ・フロー", -554_604, order: 22, section: .investing, total: true),
            row("USGAAP_HTML_CF_23", "長期債務による調達額", 170_000, order: 23, section: f),
            row("USGAAP_HTML_CF_24", "長期債務の返済額", -67_602, order: 24, section: f),
            row("USGAAP_HTML_CF_25", "満期日が3ヶ月以内の短期債務の 増加・減少(△)(純額)", 102_324, order: 25, section: f),
            row("USGAAP_HTML_CF_26", "親会社による配当金支払額", -84_354, order: 26, section: f),
            row("USGAAP_HTML_CF_27", "非支配持分への配当金支払額", -332, order: 27, section: f),
            row("USGAAP_HTML_CF_28", "自己株式の取得及び売却", -12, order: 28, section: f),
            row("USGAAP_HTML_CF_29", "非支配持分との資本取引", 141, order: 29, section: f),
            row("USGAAP_HTML_CF_30", "その他", 84, order: 30, section: f),
            row("USGAAP_HTML_CF_31", "財務活動によるキャッシュ・フロー", 120_249, order: 31, section: f, total: true),
            row("USGAAP_HTML_CF_32", "為替変動による現金及び現金同等物への影響", 22_242, order: 32),
            row("USGAAP_HTML_CF_33", "現金及び現金同等物純減少", -1_558, order: 33, total: true),
            row("USGAAP_HTML_CF_34", "現金及び現金同等物期首残高", 172_111, order: 34, total: true),
            row("USGAAP_HTML_CF_35", "現金及び現金同等物期末残高", 170_553, order: 35, total: true),
        ]
        let values = CashAllocationResolver.resolve(
            cashFlow: cashFlow, cfo: 410_555 * million, cfi: -554_604 * million, isBank: false)
        #expect(values.cff == 120_249 * million)
        #expect(values.debtChange == (170_000 - 67_602 + 102_324) * million)
        #expect(values.dividendsParent == -84_354 * million)
        #expect(values.buyback == -12 * million)
        #expect(values.otherFinancing == (-332 + 141 + 84) * million)
        #expect(values.fxEffect == 22_242 * million)
        #expect(values.cashChange == -1_558 * million)
        #expect(values.otherCashChange == 0)
    }

    @Test func usgaapKomatsuTotalLabelWithoutCashFlowWording() throws {
        // 小松 6301（US-GAAP、S100YD25）。合計行が「財務活動による現金及び現金同等物の減少（純額）」。
        let f = StatementLineSection.financing
        let cashFlow = [
            row("USGAAP_HTML_CF_30", "満期日が３カ月超の借入債務による調達", 905_072, order: 30, section: f),
            row("USGAAP_HTML_CF_31", "満期日が３カ月超の借入債務の返済", -884_071, order: 31, section: f),
            row("USGAAP_HTML_CF_32", "満期日が３カ月以内の借入債務の増減（純額）", 81_214, order: 32, section: f),
            row("USGAAP_HTML_CF_33", "自己株式の売却及び取得（純額）", -105_720, order: 33, section: f),
            row("USGAAP_HTML_CF_34", "配当金支払", -185_142, order: 34, section: f),
            row("USGAAP_HTML_CF_35", "その他（純額）", -19_889, order: 35, section: f),
            row("USGAAP_HTML_CF_36", "財務活動による現金及び現金同等物の減少（純額）", -208_536, order: 36, section: f, total: true),
            row("USGAAP_HTML_CF_37", "為替変動による現金及び現金同等物への影響額", 12_937, order: 37),
            row("USGAAP_HTML_CF_38", "現金及び現金同等物純増加（減少）額", 54_132, order: 38),
            row("USGAAP_HTML_CF_39", "現金及び現金同等物期首残高", 385_569, order: 39, total: true),
            row("USGAAP_HTML_CF_40", "現金及び現金同等物期末残高", 439_701, order: 40, total: true),
        ]
        let values = CashAllocationResolver.resolve(
            cashFlow: cashFlow, cfo: 448_963 * million, cfi: -199_232 * million, isBank: false)
        #expect(values.cff == -208_536 * million)
        #expect(values.debtChange == (905_072 - 884_071 + 81_214) * million)
        #expect(values.dividendsParent == -185_142 * million)
        #expect(values.buyback == -105_720 * million)
        #expect(values.otherFinancing == -19_889 * million)
        #expect(values.fxEffect == 12_937 * million)
        #expect(values.cashChange == 54_132 * million)
        #expect(values.otherCashChange == 0)
    }

    @Test func usgaapOmronRowsAfterFinancingTotalAreOutsideRows() throws {
        // オムロン 6645（US-GAAP、S100YG81）。換算差額・期首期末残高の行が財務区分に入って並ぶ。
        let f = StatementLineSection.financing
        let cashFlow = [
            row("USGAAP_HTML_CF_30", "満期日が3ヶ月以内の短期債務の増加（純額）", 54_262, order: 30, section: f),
            row("USGAAP_HTML_CF_31", "満期日が3ヶ月超の短期債務による収入", 1_160, order: 31, section: f),
            row("USGAAP_HTML_CF_32", "満期日が3ヶ月超の短期債務による支出", -1_210, order: 32, section: f),
            row("USGAAP_HTML_CF_33", "長期債務による収入", 5_745, order: 33, section: f),
            row("USGAAP_HTML_CF_34", "長期債務による支出", -4_773, order: 34, section: f),
            row("USGAAP_HTML_CF_35", "親会社の支払配当金", -20_462, order: 35, section: f),
            row("USGAAP_HTML_CF_36", "非支配株主への支払配当金", -1_268, order: 36, section: f),
            row("USGAAP_HTML_CF_37", "自己株式の売却による収入", 263, order: 37, section: f),
            row("USGAAP_HTML_CF_38", "自己株式の取得による支出", -1_322, order: 38, section: f),
            row("USGAAP_HTML_CF_39", "その他(純額)", -33, order: 39, section: f),
            row("USGAAP_HTML_CF_40", "財務活動によるキャッシュ・フロー", 32_362, order: 40, section: f, total: true),
            row("USGAAP_HTML_CF_41", "換算レート変動の影響", 11_106, order: 41, section: f),
            row("USGAAP_HTML_CF_42", "現金及び現金同等物の増減額", 34_316, order: 42, section: f),
            row("USGAAP_HTML_CF_43", "期首現金及び現金同等物残高", 149_023, order: 43, section: f),
            row("USGAAP_HTML_CF_44", "期末現金及び現金同等物残高", 183_339, order: 44, section: f),
            row("USGAAP_HTML_CF_45", "非継続事業に係る期末現金及び現金同等物残高（控除）", 16_798, order: 45, section: f),
            row("USGAAP_HTML_CF_46", "継続事業に係る期末現金及び現金同等物残高", 166_541, order: 46, section: f),
        ]
        let values = CashAllocationResolver.resolve(
            cashFlow: cashFlow, cfo: 60_919 * million, cfi: -70_071 * million, isBank: false)
        #expect(values.cff == 32_362 * million)
        #expect(values.debtChange == (54_262 + 1_160 - 1_210 + 5_745 - 4_773) * million)
        #expect(values.dividendsParent == -20_462 * million)
        // 取得（−1,322）のみ。売却による収入 263 はその他へ。
        #expect(values.buyback == -1_322 * million)
        #expect(values.fxEffect == 11_106 * million)
        #expect(values.cashChange == 34_316 * million)
        #expect(values.otherCashChange == 0)
    }

    @Test func usgaapFinancialCompanyKeepsTotalsButNoBreakdown() throws {
        // オリックス 8591（US-GAAP、S100YG5L）。金融業は有利子負債等の内訳を出さない（銀行と同じ）。
        let f = StatementLineSection.financing
        let cashFlow = [
            row("USGAAP_HTML_CF_30", "満期日が３ヶ月超の借入債務による調達", 1_210_761, order: 30, section: f),
            row("USGAAP_HTML_CF_31", "預金の受入の増加（純額）", 175_554, order: 31, section: f),
            row("USGAAP_HTML_CF_32", "財務活動から得た(に使用した)現金（純額）", -160_535, order: 32, section: f, total: true),
            row("USGAAP_HTML_CF_33", "現金、現金等価物および使途制限付現金に対する 為替相場変動の影響額", 34_755, order: 33, section: f),
            row("USGAAP_HTML_CF_34", "現金、現金等価物および使途制限付現金増加額（純額）", 129_116, order: 34, section: f),
            row("USGAAP_HTML_CF_35", "現金、現金等価物および使途制限付現金期首残高", 1_321_983, order: 35, section: f, total: true),
            row("USGAAP_HTML_CF_36", "現金、現金等価物および使途制限付現金期末残高", 1_451_099, order: 36, section: f, total: true),
        ]
        let values = CashAllocationResolver.resolve(
            cashFlow: cashFlow, cfo: 1_369_567 * million, cfi: -1_114_671 * million, isBank: true)
        #expect(values.cff == -160_535 * million)
        #expect(values.fxEffect == 34_755 * million)
        #expect(values.cashChange == 129_116 * million)
        #expect(values.otherCashChange == 0)
        #expect(values.debtChange == nil)
        #expect(values.dividendsParent == nil)
        #expect(values.buyback == nil)
        #expect(values.otherFinancing == nil)
    }

    @Test func usgaapCanonOtherNetDashLabelIsOther() throws {
        // キヤノン 7751（US-GAAP、S100XTLJ）。「その他－純額」が「その他」として区分できる。
        let f = StatementLineSection.financing
        let cashFlow = [
            row("USGAAP_HTML_CF_30", "長期債務による調達額", 200_844, order: 30, section: f),
            row("USGAAP_HTML_CF_31", "長期債務の返済額", -2_469, order: 31, section: f),
            row("USGAAP_HTML_CF_32", "金融サービスに係る短期借入金の増加 （△減少）－純額", -2_300, order: 32, section: f),
            row("USGAAP_HTML_CF_33", "その他の短期借入金の増加（△減少） －純額", 95_000, order: 33, section: f),
            row("USGAAP_HTML_CF_34", "配当金の支払額", -147_644, order: 34, section: f),
            row("USGAAP_HTML_CF_35", "自己株式取得及び処分", -300_019, order: 35, section: f),
            row("USGAAP_HTML_CF_36", "その他－純額", -22_633, order: 36, section: f),
            row("USGAAP_HTML_CF_37", "財務活動によるキャッシュ・フロー", -179_221, order: 37, section: f, total: true),
            row("USGAAP_HTML_CF_38", "為替変動の現金及び現金同等物への影響額", 25_184, order: 38),
            row("USGAAP_HTML_CF_39", "現金及び現金同等物の純増減額", 84_416, order: 39, total: true),
            row("USGAAP_HTML_CF_40", "現金及び現金同等物の期首残高", 501_565, order: 40, total: true),
            row("USGAAP_HTML_CF_41", "現金及び現金同等物の期末残高", 585_981, order: 41, total: true),
        ]
        let values = CashAllocationResolver.resolve(
            cashFlow: cashFlow, cfo: 475_903 * million, cfi: -237_450 * million, isBank: false)
        #expect(values.cff == -179_221 * million)
        #expect(values.debtChange == (200_844 - 2_469 - 2_300 + 95_000) * million)
        #expect(values.dividendsParent == -147_644 * million)
        #expect(values.buyback == -300_019 * million)
        #expect(values.otherFinancing == -22_633 * million)
        #expect(values.otherCashChange == 0)
    }

    @Test func otherNetLabelDoesNotSwallowDebtRows() throws {
        #expect(CashAllocationResolver.isOtherNetLabel("その他－純額"))
        #expect(CashAllocationResolver.isOtherNetLabel("その他（純額）"))
        #expect(!CashAllocationResolver.isOtherNetLabel("その他の短期借入金の増加（△減少）－純額"))
        #expect(!CashAllocationResolver.isOtherNetLabel("その他の投資"))
    }
}

actor FakeCashFlowFinancingRowDecider: CashFlowFinancingRowDeciding {
    let answer: String
    let probability: Double
    private(set) var calls = 0

    init(answer: String, probability: Double) {
        self.answer = answer
        self.probability = probability
    }

    func classifyFinancingRow(
        row: CashFlowFinancingRowCandidate,
        financingRows: [CashFlowFinancingRowCandidate],
        docID: String
    ) async -> CashFlowFinancingRowChoice {
        calls += 1
        return CashFlowFinancingRowChoice(
            selected: answer, probability: probability,
            probabilities: [answer: probability],
            options: CashFlowFinancingRole.allCases.map(\.rawValue),
            model: "typesafe/jev-1.13")
    }
}
