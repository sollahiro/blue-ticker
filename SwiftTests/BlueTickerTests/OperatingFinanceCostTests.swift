// 営業費用内の金融費用（リース・信販・消費者金融・オリックス型）。実データはアコム 8572・オリックス 8591 の statement 行。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct OperatingFinanceCostTests {
    private func row(
        _ tag: String, _ label: String, _ millionYen: Double, total: Bool = false
    ) -> StatementLineItem {
        StatementLineItem(
            tag: tag, label: label, value: millionYen * 1_000_000, unit: "JPY", order: nil,
            section: nil, isTotal: total)
    }

    /// アコム 8572（2026年3月期、百万円）。金融費用計が営業費用の中にあり、営業外にも支払利息（5）がある。
    @Test func acomPicksFinancialExpenseTotalInsideOperatingExpenses() {
        let items = [
            row("OperatingRevenueSPF", "営業収益合計", 337_709, total: true),
            row("InterestExpensesOESPF", "支払利息", 4_957),
            row("InterestOnBondsOESPF", "社債利息", 1_533),
            row("FinancialExpensesSPF", "金融費用計", 7_323, total: true),
            row("OperatingExpensesSPF", "営業費用合計", 237_315, total: true),
            row("OperatingIncome", "営業利益", 100_394, total: true),
            row("InterestExpensesNOE", "支払利息", 5),
        ]
        #expect(StatementFinancialsResolver.operatingFinanceCost(items) == 7_323.0 * 1_000_000)
    }

    /// オリックス 8591（US-GAAP）。営業利益より前の「支払利息」行を拾う。
    @Test func orixPicksInterestExpenseBeforeOperatingIncome() {
        let items = [
            row("USGAAP_HTML_PL_6", "営業収益 計", 3_330_831, total: true),
            row("USGAAP_HTML_PL_7", "支払利息", 193_889),
            row("USGAAP_HTML_PL_17", "営業費用 計", 2_874_583, total: true),
            row("USGAAP_HTML_PL_18", "営業利益", 456_248, total: true),
        ]
        #expect(StatementFinancialsResolver.operatingFinanceCost(items) == 193_889.0 * 1_000_000)
    }

    /// 一般事業会社: 支払利息は営業外（営業利益より後）なので足し戻さない。
    @Test func nonOperatingInterestExpenseIsIgnored() {
        let items = [
            row("NetSales", "売上高", 100_000, total: true),
            row("OperatingIncome", "営業利益", 10_000, total: true),
            row("InterestExpensesNOE", "支払利息", 500),
        ]
        #expect(StatementFinancialsResolver.operatingFinanceCost(items) == nil)
    }

    /// 営業利益の行が無い（銀行など）ときは何も拾わない。
    @Test func noOperatingIncomeRowReturnsNil() {
        let items = [row("InterestExpensesOEBNK", "資金調達費用", 500)]
        #expect(StatementFinancialsResolver.operatingFinanceCost(items) == nil)
    }

    /// 金融収益や引当は費用として拾わない。
    @Test func financeIncomeAndProvisionsAreExcluded() {
        let items = [
            row("A", "金融収益", 365_570),
            row("B", "貸倒引当金繰入額", 95_779),
            row("OperatingIncome", "営業利益", 100_394, total: true),
        ]
        #expect(StatementFinancialsResolver.operatingFinanceCost(items) == nil)
    }
}
