// 販管費の業種別合計行・販売費の無い PL の一般管理費を `sga` として読む（差額では埋めない）。
// ガス: 供給販売費及び一般管理費（SellingGeneralAndAdministrativeExpensesGAS）、
// 商品先物: 営業費用合計（OperatingExpensesCMD）、海運・倉庫・運送・証券金融等: 一般管理費（GeneralAndAdministrativeExpensesSGA）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct IndustrySgaResolutionTests {

    private func sga(_ facts: [(String, String, Double)]) -> OperatingProfitResult {
        let body = facts.map { ns, tag, v in
            """
            <\(ns):\(tag) contextRef="CurrentYearDuration" unitRef="JPY" decimals="-6">\(Int64(v))</\(ns):\(tag)>
            """
        }.joined(separator: "\n")
        var out: OperatingProfitResult!
        XBRLTestSupport.withXbrlDir(XBRLTestSupport.makeXbrlDuration(body)) { dir in
            let (fs, std) = XBRLTestSupport.durationFieldSet(in: dir)
            out = OperatingProfitExtractor.extract(fieldSet: fs, accountingStandard: std)
        }
        return out
    }

    @Test func gasSupplySellingAndAdministrativeTotal() {
        // 東邦瓦斯 9533 FY2026: GP 179,295 / 供給販売費及び一般管理費 147,511 / OP 31,784
        let r = sga([
            ("jppfs_cor", "GrossProfit", 179_295e6),
            ("jppfs_cor", "SellingGeneralAndAdministrativeExpensesGAS", 147_511e6),
            ("jppfs_cor", "OperatingIncome", 31_784e6),
        ])
        #expect(r.method == "direct")
        #expect(r.sga == 147_511e6)
    }

    @Test func gasTotalWinsOverItsComponents() {
        // 北海道瓦斯 9534: 供給販売費 33,119 + 一般管理費 5,448 = 合計 38,568
        let r = sga([
            ("jppfs_cor", "SupplyAndSalesExpensesGAS", 33_119e6),
            ("jppfs_cor", "GeneralAndAdministrativeExpensesSGA", 5_448e6),
            ("jppfs_cor", "SellingGeneralAndAdministrativeExpensesGAS", 38_568e6),
            ("jppfs_cor", "OperatingIncome", 16_437e6),
        ])
        #expect(r.sga == 38_568e6)
    }

    @Test func generalAdministrativeOnlyPL() {
        // ケイヒン 9312: 売上総利益の下は一般管理費だけ
        let r = sga([
            ("jppfs_cor", "GrossProfit", 5_612e6),
            ("jppfs_cor", "GeneralAndAdministrativeExpensesSGA", 2_185e6),
            ("jppfs_cor", "OperatingIncome", 3_427e6),
        ])
        #expect(r.sga == 2_185e6)
    }

    @Test func generalAdministrativeNextToSellingLineIsNotSga() {
        // 販売費の行が別にあり合計行が無いときは一般管理費だけを販管費にしない。
        let r = sga([
            ("jppfs_cor", "SupplyAndSalesExpensesGAS", 33_119e6),
            ("jppfs_cor", "GeneralAndAdministrativeExpensesSGA", 5_448e6),
            ("jppfs_cor", "OperatingIncome", 16_437e6),
        ])
        #expect(r.sga == nil)
    }

    @Test func commodityFuturesOperatingExpensesTotal() {
        // 小林洋行 8742: 営業総利益 3,393 − 営業費用合計 3,210 = 営業利益 182
        let r = sga([
            ("jppfs_cor", "OperatingGrossProfit", 3_392_744_000),
            ("jppfs_cor", "OperatingExpensesCMD", 3_210_396_000),
            ("jppfs_cor", "OperatingIncome", 182_347_000),
        ])
        #expect(r.sga == 3_210_396_000)
    }

    @Test func directSgaTagStillWins() {
        let r = sga([
            ("jppfs_cor", "SellingGeneralAndAdministrativeExpenses", 100e6),
            ("jppfs_cor", "SellingGeneralAndAdministrativeExpensesGAS", 90e6),
            ("jppfs_cor", "GeneralAndAdministrativeExpensesSGA", 10e6),
            ("jppfs_cor", "OperatingIncome", 50e6),
        ])
        #expect(r.sga == 100e6)
    }
}
