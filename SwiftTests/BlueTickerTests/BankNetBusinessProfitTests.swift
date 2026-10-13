import Foundation
import Testing
@testable import BlueTickerCore

// StatementFinancialsResolver.bankNetBusinessProfit の合成入力での仕様。
// 業務純益 = 業務粗利益 − 営業経費（持分法は足さない）。
@Suite struct BankNetBusinessProfitTests {
    @Test func netBusinessProfitIsGrossProfitMinusOperatingExpenses() {
        let fs: FieldSet = ["GeneralAndAdministrativeExpensesOEBNK": FieldValue(current: 300, prior: 280)]
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "連結業務粗利益", durationFS: fs)
        #expect(r.netBusinessProfit == 200)
        #expect(r.operatingExpenses == 300)
    }

    @Test func equityMethodInFieldSetIsNotAdded() {
        // CF の持分法調整行が FieldSet にあっても業務純益には入れない。
        let fs: FieldSet = [
            "GeneralAndAdministrativeExpensesOEBNK": FieldValue(current: 300, prior: nil),
            "EquityInEarningsLossesOfAffiliatesOpeCF": FieldValue(current: -40, prior: nil),
        ]
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "連結業務粗利益", durationFS: fs)
        #expect(r.netBusinessProfit == 200)
    }

    @Test func missingOperatingExpensesFailsClosed() {
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "連結業務粗利益", durationFS: [:])
        #expect(r.netBusinessProfit == nil)
        #expect(r.operatingExpenses == nil)
    }

    @Test func nonBankGrossProfitIsNotUsed() {
        // 業務粗利益でない粗利（営業総利益等）からは業務純益を作らない。
        let fs: FieldSet = ["GeneralAndAdministrativeExpensesOEBNK": FieldValue(current: 300, prior: nil)]
        let r = StatementFinancialsResolver.bankNetBusinessProfit(
            grossProfit: 500, grossProfitLabel: "営業総利益", durationFS: fs)
        #expect(r.netBusinessProfit == nil)
    }

    @Test func bankDetectionUsesDepositsMarker() {
        #expect(Xbrl.isBankFiling(["DepositsLiabilitiesBNK": FieldValue(current: 1, prior: nil)]))
        #expect(Xbrl.isBankFiling(["DepositsLiabilitiesBNK": FieldValue(current: nil, prior: 1)]))
        #expect(!Xbrl.isBankFiling(["DepositsLiabilitiesBNK": FieldValue(current: nil, prior: nil)]))
        #expect(!Xbrl.isBankFiling([:]))
    }

    @Test func bankDetectionAlsoUsesEdinetIndustry() {
        // EDINET 提出者業種が銀行業なら預金マーカーが無くても銀行（ゆうちょ 7182）。
        let japanPostBankLike: FieldSet = ["DepositsLiabilities": FieldValue(current: 1, prior: nil)]
        #expect(Xbrl.isBankFiling(japanPostBankLike, edinetIndustry: "銀行業"))
        #expect(!Xbrl.isBankFiling(japanPostBankLike))
        #expect(!Xbrl.isBankFiling(japanPostBankLike, edinetIndustry: "その他金融業"))
        // マーカーがある会社は業種に関係なく従来どおり銀行（8421 / 8699 / 8729）。
        #expect(Xbrl.isBankFiling(
            ["DepositsLiabilitiesBNK": FieldValue(current: 1, prior: nil)], edinetIndustry: "保険業"))
    }
}
