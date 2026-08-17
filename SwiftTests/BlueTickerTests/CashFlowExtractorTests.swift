// J-GAAP/IFRS 各タグで CFO・CFI を取得できること、タグが存在しない場合は nil を返すことを検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct CashFlowExtractorTests {

    @Test func testJgaapCfoAndCfi() {
        let fs = makeFieldSet(
            ("NetCashProvidedByUsedInOperatingActivities", 500_000.0, 450_000.0),
            ("NetCashProvidedByUsedInInvestingActivities", -300_000.0, -250_000.0)
        )
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.cfo == 500_000.0)
        #expect(result.cfoPrior == 450_000.0)
        #expect(result.cfi == -300_000.0)
        #expect(result.cfiPrior == -250_000.0)
        #expect(result.accountingStandard == "J-GAAP")
    }

    @Test func testJgaapCfiSpellingVariant() {
        // NetCashProvidedByUsedInInvestmentActivities（表記ゆれ）でも取得できる
        let fs = makeFieldSet(("NetCashProvidedByUsedInInvestmentActivities", -200_000.0, nil))
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.cfi == -200_000.0)
    }

    @Test func testIfrsCfoAndCfi() {
        let fs = makeFieldSet(
            ("CashFlowsFromUsedInOperationsIFRS", 600_000.0, 580_000.0),
            ("CashFlowsUsedInInvestingActivitiesIFRS", -200_000.0, -180_000.0)
        )
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.cfo == 600_000.0)
        #expect(result.cfi == -200_000.0)
        #expect(result.accountingStandard == "IFRS")
    }

    @Test func testIfrsNetCashStatementTotalsAreNotPickedByExtractor() {
        // 本表の NetCash*IFRS は StatementFinancialsResolver が読む。IA の
        // CashFlowExtractor には載せない（Summary 欠測時の現行出力を変えない）。
        let fs = makeFieldSet(
            ("NetCashProvidedByUsedInOperatingActivitiesIFRS", 209_898_000_000.0, nil),
            ("NetCashProvidedByUsedInInvestingActivitiesIFRS", -77_382_000_000.0, nil)
        )
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.cfo == nil)
        #expect(result.cfi == nil)
    }

    @Test func testIfrsSummaryStillPreferredWhenBothPresent() {
        // IA 現行経路を変えない: Summary タグがある FieldSet ではそちらを先に取る。
        let fs = makeFieldSet(
            ("CashFlowsFromUsedInOperatingActivitiesIFRSSummaryOfBusinessResults", 669_784_000_000.0, nil),
            ("NetCashProvidedByUsedInOperatingActivitiesIFRS", 1.0, nil),
            ("CashFlowsFromUsedInInvestingActivitiesIFRSSummaryOfBusinessResults", -475_605_000_000.0, nil),
            ("NetCashProvidedByUsedInInvestingActivitiesIFRS", -1.0, nil)
        )
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.cfo == 669_784_000_000.0)
        #expect(result.cfi == -475_605_000_000.0)
    }

    @Test func testNotFoundReturnsNil() {
        let result = CashFlowExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.cfo == nil)
        #expect(result.cfoPrior == nil)
        #expect(result.cfi == nil)
        #expect(result.cfiPrior == nil)
    }

    @Test func testCfoFoundCfiMissing() {
        let fs = makeFieldSet(("NetCashProvidedByUsedInOperatingActivities", 500_000.0, nil))
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.cfo == 500_000.0)
        #expect(result.cfi == nil)
    }

    @Test func testAccountingStandardPropagated() {
        let fs = makeFieldSet(("CashFlowsFromUsedInOperatingActivitiesIFRS", 100_000.0, nil))
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.accountingStandard == "IFRS")
    }

    @Test func testPriorOnlyWhenCurrentNone() {
        let fs = makeFieldSet(("NetCashProvidedByUsedInOperatingActivities", nil, 450_000.0))
        let result = CashFlowExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.cfo == nil)
        #expect(result.cfoPrior == 450_000.0)
    }
}
