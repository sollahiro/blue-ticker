// Jev 販管費行選択の決定論（スパン・採否・fail-closed）。値は既存行だけ。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct SgaLineJevPickerTests {
    private let million = 1_000_000.0

    private func item(
        _ tag: String, _ label: String, _ yen: Double, order: Int
    ) -> StatementLineItem {
        StatementLineItem(tag: tag, label: label, value: yen, unit: "JPY", order: order)
    }

    @Test func spanTakesRowsBetweenGrossProfitAndOperatingProfit() throws {
        let pl = [
            item("NetSales", "売上高", 200, order: 0),
            item("GrossProfit", "売上総利益", 100, order: 1),
            item("GeneralAndAdministrativeExpensesSGA", "一般管理費", 40, order: 2),
            item("OperatingIncome", "営業利益", 60, order: 3),
        ]
        let span = try #require(SgaLineJevPicker.span(pl: pl))
        #expect(span.grossProfit.tag == "GrossProfit")
        #expect(span.operatingProfit.tag == "OperatingIncome")
        let candidates = SgaLineJevPicker.candidates(in: span)
        #expect(candidates.map(\.tag) == ["GeneralAndAdministrativeExpensesSGA"])
        #expect(SgaLineJevPicker.accepts(value: 40, span: span))
    }

    @Test func explainedGapByOtherIncomeAndExpenseIsAccepted() throws {
        // ナブテスコ型: GP − OP は販管費＋その他収益・費用。
        let pl = [
            item("GrossProfitIFRS", "売上総利益", 93_781 * million, order: 0),
            item(
                "SellingGeneralAndAdministrativeExpensesIFRSContinuingOperationsIFRS",
                "販売費及び一般管理費", 71_964 * million, order: 1),
            item("OtherIncomeIFRS", "その他の収益", 2_000 * million, order: 2),
            item("OtherExpensesIFRS", "その他の費用", 3_091 * million, order: 3),
            item("OperatingProfitLossIFRS", "営業利益", 20_726 * million, order: 4),
        ]
        let span = try #require(SgaLineJevPicker.span(pl: pl))
        #expect(SgaLineJevPicker.candidates(in: span).map(\.tag) == [
            "SellingGeneralAndAdministrativeExpensesIFRSContinuingOperationsIFRS",
        ])
        #expect(SgaLineJevPicker.accepts(value: 71_964 * million, span: span))
        #expect(!SgaLineJevPicker.accepts(value: 50_000 * million, span: span))
    }

    @Test func unexplainedResidualIsRejected() throws {
        // ゆうちょ型: 営業経費が GP − OP に一致しない。
        let pl = [
            item("GrossProfit", "連結業務粗利益", 1_381_863 * million, order: 0),
            item("GeneralAndAdministrativeExpensesOEBNK", "営業経費", 946_425 * million, order: 1),
            item("OrdinaryIncome", "経常利益", 759_150 * million, order: 2),
        ]
        let span = try #require(SgaLineJevPicker.span(pl: pl))
        #expect(!SgaLineJevPicker.accepts(value: 946_425 * million, span: span))
        #expect(abs((1_381_863 - 759_150) - 622_713) == 0)
    }

    @Test func publishedLabelNullsStandardSgaName() {
        #expect(SgaLineJevPicker.publishedSgaLabel("販売費及び一般管理費") == nil)
        #expect(SgaLineJevPicker.publishedSgaLabel("販売費及び一般管理費合計") == nil)
        #expect(
            SgaLineJevPicker.publishedSgaLabel("供給販売費及び一般管理費合計")
                == "供給販売費及び一般管理費")
        #expect(SgaLineJevPicker.publishedSgaLabel("一般管理費") == "一般管理費")
        #expect(SgaLineJevPicker.publishedSgaLabel("営業費用合計") == "営業費用")
    }

    @Test func pickAcceptsExistingRowOnly() async {
        let pl = [
            item("GrossProfit", "売上総利益", 5_612 * million, order: 0),
            item("GeneralAndAdministrativeExpensesSGA", "一般管理費", 2_185 * million, order: 1),
            item("OperatingIncome", "営業利益", 3_427 * million, order: 2),
        ]
        let decider = FakeSgaLineDecider(pickLabelContains: "一般管理費")
        let result = await SgaLineJevPicker.pick(pl: pl, decider: decider, docID: "S100YHI4")
        #expect(result.accepted?.value == 2_185 * million)
        #expect(result.accepted?.label == "一般管理費")
        #expect(result.audit.applied)
        #expect(SgaLineJevPicker.publishedSgaLabel(result.accepted?.label) == "一般管理費")
    }

    @Test func pickFailsClosedOnTimeout() async {
        let pl = [
            item("GrossProfit", "売上総利益", 100 * million, order: 0),
            item("GeneralAndAdministrativeExpensesSGA", "一般管理費", 40 * million, order: 1),
            item("OperatingIncome", "営業利益", 60 * million, order: 2),
        ]
        let result = await SgaLineJevPicker.pick(
            pl: pl, decider: FakeSgaLineDecider(fail: true), docID: "S-fail")
        #expect(result.accepted == nil)
        #expect(!result.audit.applied)
        #expect(result.audit.needsReview)
    }

    @Test func pickFailsClosedOnDisagreement() async {
        let pl = [
            item("GrossProfit", "売上総利益", 100 * million, order: 0),
            item("FooSGA", "一般管理費", 40 * million, order: 1),
            item("BarSGA", "営業費用", 40 * million, order: 2),
            item("OperatingIncome", "営業利益", 60 * million, order: 3),
        ]
        let result = await SgaLineJevPicker.pick(
            pl: pl, decider: FakeSgaLineDecider(disagreement: true), docID: "S-split")
        #expect(result.accepted == nil)
        #expect(!result.audit.applied)
    }

    @Test func pickRejectsUnexplainedOperatingExpenses() async {
        let pl = [
            item("GrossProfit", "連結業務粗利益", 1_381_863 * million, order: 0),
            item("GeneralAndAdministrativeExpensesOEBNK", "営業経費", 946_425 * million, order: 1),
            item("OrdinaryIncome", "経常利益", 759_150 * million, order: 2),
        ]
        let result = await SgaLineJevPicker.pick(
            pl: pl, decider: FakeSgaLineDecider(pickLabelContains: "営業経費"),
            docID: "S100Y9G1")
        #expect(result.accepted == nil)
        #expect(!result.audit.applied)
        #expect(result.audit.sentences.contains { $0.contains("residual_mismatch") })
    }

    @Test func pickFailsClosedWhenResidualDoesNotMatch() async {
        // ラクオリア: 売上総利益行が無く、事業費用合計はスパンに入らない。
        let noGP = [
            item("BusinessRevenue", "事業収益", 3_980 * million, order: 0),
            item("BusinessExpenses", "事業費用合計", 3_496 * million, order: 1),
            item("OperatingIncome", "営業利益", 484 * million, order: 2),
        ]
        let result = await SgaLineJevPicker.pick(
            pl: noGP, decider: FakeSgaLineDecider(pickLabelContains: "事業費用"),
            docID: "S-raqualia")
        #expect(result.accepted == nil)
        #expect(result.audit.sentences.contains { $0.contains("no_gp_op_span") })
    }

    @Test func neverInventedValue() async {
        let pl = [
            item("GrossProfit", "売上総利益", 100 * million, order: 0),
            item("GeneralAndAdministrativeExpensesSGA", "一般管理費", 40 * million, order: 1),
            item("OperatingIncome", "営業利益", 60 * million, order: 2),
        ]
        let result = await SgaLineJevPicker.pick(
            pl: pl, decider: FakeSgaLineDecider(pickKey: "invented"), docID: "S-invent")
        #expect(result.accepted == nil)
        #expect(result.accepted?.value != 60 * million)
    }
}
