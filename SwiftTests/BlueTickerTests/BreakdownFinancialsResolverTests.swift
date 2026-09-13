import Testing
@testable import BlueTickerCore

@Suite struct BreakdownFinancialsResolverTests {
    @Test func customerContractConsolidatedYenReads連結金額Not合計行() {
        let tables = [
            BreakdownTable(
                heading: BreakdownExtractor.revenueRecognitionHeading,
                markdown: """
                | | 地球環境エネルギー | 連結金額 |
                |---|---|---|
                | 顧客との契約から認識した収益 | 1851642 | 13948091 |
                | 合計 | 3267295 | 18915995 |
                """,
                period: "当期"
            )
        ]
        #expect(
            BreakdownExtractor.customerContractConsolidatedYen(tables: tables)
                == 13_948_091_000_000)
    }
}
