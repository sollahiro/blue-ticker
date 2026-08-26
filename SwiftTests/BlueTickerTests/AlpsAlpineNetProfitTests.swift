import Foundation
import Testing

@testable import BlueTickerCore

/// Alps Alpine 6770 / S100YB8V（FY2026-03、J-GAAP）の Summary 純利益が
/// 親会社株主に帰属する当期純利益 26,879 百万円と一致することを固定する。
///
/// 回帰: 売上・営業利益は埋まるが `ProfitLossAttributableToOwnersOfParent`
/// （本表）／`ProfitLossAttributableToOwnersOfParentSummaryOfBusinessResults`
/// （主要な経営指標等）が候補から漏れると Summary `net_profit` が null になる。
@Suite struct AlpsAlpineNetProfitTests {
    private static let docID = "S100YB8V"
    private static let xbrlDir = SmokeCacheSupport.cacheDir
        .appendingPathComponent("\(docID)_xbrl")

    @Test func summaryNetProfitMatchesParentAttributableProfit() async throws {
        await SmokeCacheSupport.ensureCached([Self.docID])
        guard FileManager.default.fileExists(atPath: Self.xbrlDir.path) else {
            print("SKIP   \(Self.docID): XBRL キャッシュなし")
            return
        }

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: Self.xbrlDir,
            docID: Self.docID,
            statementTypes: [.incomeStatement]
        ) else {
            Issue.record("resolveFromXBRL failed for \(Self.docID)")
            return
        }

        #expect(
            year.incomeStatement.contains {
                $0.tag == "ProfitLossAttributableToOwnersOfParent" && $0.value == 26_879_000_000
            })

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: Self.xbrlDir))
        #expect(values.sales == 1_019_459_000_000)
        #expect(values.operatingProfit == 42_043_000_000)
        // 有報どおり 26,879 百万円（円単位）。売上・営業利益と同じ単位。
        #expect(values.netProfit == 26_879_000_000)
    }
}
