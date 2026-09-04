import Foundation
import Testing

@testable import BlueTickerCore

/// Summary `net_profit` は親会社株主に帰属する当期純利益を優先する。
/// PL に親会社帰属タグが無く、SS にだけある書類では `ProfitLoss`（当期純利益）へ
/// 落ちてはならない。
@Suite struct ParentAttributableNetProfitTests {
    private func line(_ tag: String, _ value: Double, unit: String = "JPY") -> StatementLineItem {
        StatementLineItem(tag: tag, label: nil, value: value, unit: unit, order: nil)
    }

    @Test func prefersIncomeStatementParentAttributableOverEquity() {
        let np = StatementFinancialsResolver.resolveParentAttributableNetProfit(
            incomeStatement: [
                line("ProfitLoss", 1_223_000_000),
                line("ProfitLossAttributableToOwnersOfParent", 1_213_000_000),
            ],
            changesInEquity: [
                line("ProfitLossAttributableToOwnersOfParent", 999_000_000)
            ],
            fallback: 1_223_000_000)
        #expect(np == 1_213_000_000)
    }

    @Test func usesEquityParentAttributableWhenAbsentFromIncomeStatement() {
        let np = StatementFinancialsResolver.resolveParentAttributableNetProfit(
            incomeStatement: [line("ProfitLoss", 1_223_000_000)],
            changesInEquity: [
                line("ProfitLossAttributableToOwnersOfParent", 1_213_000_000)
            ],
            fallback: 1_223_000_000)
        #expect(np == 1_213_000_000)
    }

    @Test func usesIfrsParentAttributableFromEquity() {
        let np = StatementFinancialsResolver.resolveParentAttributableNetProfit(
            incomeStatement: [line("ProfitLoss", 100)],
            changesInEquity: [
                line("ProfitLossAttributableToOwnersOfParentIFRS", 90)
            ],
            fallback: 100)
        #expect(np == 90)
    }

    @Test func fallsBackToProfitLossWhenParentAttributableAbsent() {
        let np = StatementFinancialsResolver.resolveParentAttributableNetProfit(
            incomeStatement: [line("ProfitLoss", 1_223_000_000)],
            changesInEquity: [line("NetAssets", 29_700_000_000)],
            fallback: 1_223_000_000)
        #expect(np == 1_223_000_000)
    }

    @Test func skipsPerShareParentAttributableRows() {
        let np = StatementFinancialsResolver.resolveParentAttributableNetProfit(
            incomeStatement: [
                line(
                    "ProfitLossAttributableToOwnersOfParent", 41.86, unit: "JPYPerShares")
            ],
            changesInEquity: [
                line("ProfitLossAttributableToOwnersOfParent", 1_213_000_000)
            ],
            fallback: nil)
        #expect(np == 1_213_000_000)
    }

    @Test func tamaHomeS100YYFRSummaryNetProfitIsParentAttributable() async throws {
        let docID = "S100YYFR"
        let xbrlDir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        await SmokeCacheSupport.ensureCached([docID])
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return
        }

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: docID,
            statementTypes: [.incomeStatement, .changesInEquity]
        ) else {
            Issue.record("resolveFromXBRL failed for \(docID)")
            return
        }

        #expect(
            year.incomeStatement.contains {
                $0.tag == "ProfitLoss" && $0.value == 1_223_000_000
            })
        #expect(!year.incomeStatement.contains { $0.tag == "ProfitLossAttributableToOwnersOfParent" })
        #expect(
            year.changesInEquity.contains {
                $0.tag == "ProfitLossAttributableToOwnersOfParent" && $0.value == 1_213_000_000
            })

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 197_740_000_000)
        #expect(values.operatingProfit == 3_842_000_000)
        #expect(values.netProfit == 1_213_000_000)
        #expect(values.netProfit != 1_223_000_000)
    }
}
