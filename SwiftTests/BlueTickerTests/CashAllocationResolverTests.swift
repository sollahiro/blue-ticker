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

    @Test func jgaapRowsSplitIntoDebtDividendsAndOther() throws {
        let values = CashAllocationResolver.resolve(
            cashFlow: smcCashFlow(), cfo: nil, cfi: nil, isBank: false)
        #expect(values.cff == -94_119 * million)
        #expect(values.debtChange == 51 * million)
        #expect(values.dividendsParent == -63_535 * million)
        #expect(values.otherFinancing == (-30_018 - 617) * million)
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
        let bridge = cfo + cfi + values.debtChange! + values.dividendsParent!
            + values.otherFinancing! + values.fxEffect! + other
        #expect(abs(bridge - values.cashChange!) < 1)
    }

    @Test func ifrsDividendsToNonControllingInterestsGoToOther() throws {
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
        // 行の和（−536,660）と合計（−536,659）の丸め差は許容し、その他は合計から引いて出す。
        #expect(values.otherFinancing == (-125_416 - 39_975 + 34_712 + 1) * million)
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
        #expect(CashAllocationResolver.classify(label: "自己株式の取得による支出") == .other)
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
        year.cfOtherFinancing = -30_635
        year.cfFxEffect = 44_553
        year.cfCashChange = 42_120
        year.cfOtherCashChange = 10_281
        let analysis = year.analysisJsonObject(prior: nil)
        #expect(analysis["cf_debt_change"] as? Double == 51)
        #expect(analysis["cf_other_cash_change"] as? Double == 10_281)
        let summary = year.summaryJsonObject()
        for key in ["cff", "cf_debt_change", "cf_dividends_parent", "cf_other_financing",
                    "cf_fx_effect", "cf_cash_change", "cf_other_cash_change"] {
            #expect(summary[key] == nil)
            #expect(financialsUnits[key] == .currencyAmount)
        }
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
