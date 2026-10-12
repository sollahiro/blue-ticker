import Foundation
import Testing
@testable import BlueTickerCore

// StatementFinancialsResolver.bankNetBusinessProfit の合成入力での仕様。
@Suite struct BankNetBusinessProfitTests {
    private func cfLine(_ value: Double) -> StatementLineItem {
        StatementLineItem(
            tag: "EquityInEarningsLossesOfAffiliatesOpeCF", label: "持分法による投資損益（△は益）",
            value: value, unit: "JPY", order: nil)
    }

    @Test func netBusinessProfitAddsEquityMethodGainFromCashFlow() {
        let fs: FieldSet = ["GeneralAndAdministrativeExpensesOEBNK": FieldValue(current: 300, prior: 280)]
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "連結業務粗利益", durationFS: fs, cashFlow: [cfLine(-40)])
        #expect(r.netBusinessProfit == 240)  // 500 − 300 + 40（CF の △40 は益）
        #expect(r.operatingExpenses == 300)
        #expect(r.equityMethodIncome == 40)
    }

    @Test func equityMethodLossReducesNetBusinessProfit() {
        let fs: FieldSet = ["GeneralAndAdministrativeExpensesOEBNK": FieldValue(current: 300, prior: nil)]
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "連結業務粗利益", durationFS: fs, cashFlow: [cfLine(15)])
        #expect(r.netBusinessProfit == 185)
        #expect(r.equityMethodIncome == -15)
    }

    @Test func missingEquityMethodLineCountsAsZero() {
        let fs: FieldSet = ["GeneralAndAdministrativeExpensesOEBNK": FieldValue(current: 300, prior: nil)]
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "連結業務粗利益", durationFS: fs, cashFlow: [])
        #expect(r.netBusinessProfit == 200)
        #expect(r.equityMethodIncome == 0)
    }

    @Test func missingOperatingExpensesFailsClosed() {
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "連結業務粗利益", durationFS: [:], cashFlow: [cfLine(-40)])
        #expect(r.netBusinessProfit == nil)
        #expect(r.operatingExpenses == nil)
    }

    @Test func nonBankGrossProfitIsNotUsed() {
        // 業務粗利益でない粗利（営業総利益等）からは業務純益を作らない。
        let fs: FieldSet = ["GeneralAndAdministrativeExpensesOEBNK": FieldValue(current: 300, prior: nil)]
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "営業総利益", durationFS: fs, cashFlow: [])
        #expect(r.netBusinessProfit == nil)
    }

    @Test func bankDetectionUsesDepositsMarker() {
        #expect(Xbrl.isBankFiling(["DepositsLiabilitiesBNK": FieldValue(current: 1, prior: nil)]))
        #expect(Xbrl.isBankFiling(["DepositsLiabilitiesBNK": FieldValue(current: nil, prior: 1)]))
        #expect(!Xbrl.isBankFiling(["DepositsLiabilitiesBNK": FieldValue(current: nil, prior: nil)]))
        #expect(!Xbrl.isBankFiling([:]))
    }
}
