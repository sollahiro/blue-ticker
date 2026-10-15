// Golden: structurally special rows that broke in production and were fixed.
// Real EDINET packages; SKIP when the XBRL cache is missing and BLT_EDINET_API_KEY is unset.

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlStructuralCaseGoldenTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard FileManager.default.fileExists(
            atPath: xbrlRoot.appendingPathComponent("\(docID)_xbrl").path)
        else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return false
        }
        return true
    }

    // 9072 ニッコンHD: 訂正有報 130 が OCI / SS をおよそ 10 倍訂正し、親会社株主帰属
    // 当期純利益も訂正する。兄弟コンテキストを理由にレイヤごと捨てず、1000 倍ガードにも
    // 掛からず、訂正後の値を載せる。売上・営業利益は訂正されない。
    // source: code=9072 fy_end=2026-03-31 doc_id=S100YVHV page=1 field=net_profit
    // source: code=9072 fy_end=2026-03-31 doc_id=S100YVHV page=1 field=eps
    // source: code=9072 fy_end=2026-03-31 doc_id=S100YLI5 page=1 field=sales
    // source: code=9072 fy_end=2026-03-31 doc_id=S100YLI5 page=1 field=operating_profit
    @Test func nikkonAmendmentOverlayAppliesNetProfitAndEps() async throws {
        let original = "S100YLI5"
        let amendment = "S100YVHV"
        await SmokeCacheSupport.ensureCached([original, amendment])
        for docID in [original, amendment] {
            guard StatementNotesOracleSupport.smokeCacheAvailable(docID) else { return }
        }
        let merged = try #require(
            await resolveAnnualXbrlDirectory(
                originalDocID: original,
                correctionDocIDs: [amendment],
                download: { StatementNotesOracleSupport.smokeXbrlDir($0) }))
        #expect(readOverlayRegressions(in: merged).isEmpty)
        let facts = XBRLUtils.collectAllNumericFacts(in: merged, nilAsZero: false)
        #expect(
            facts["ProfitLossAttributableToOwnersOfParent"]?["CurrentYearDuration"]?.value
                == 17_493_000_000)
        #expect(
            facts["BasicEarningsLossPerShareSummaryOfBusinessResults"]?["CurrentYearDuration"]?
                .value == 146.62)
        #expect(facts["NetSales"]?["CurrentYearDuration"]?.value == 269_862_000_000)
        #expect(facts["OperatingIncome"]?["CurrentYearDuration"]?.value == 23_818_000_000)
    }

    // 1419 タマホーム: 個別 PL role の loc 数が連結より多く、連結専用の親会社株主帰属
    // 当期純利益が PL から落ちていた。連結 PL と Summary の両方で 1,213 百万円。
    // source: code=1419 fy_end=2026-05-31 doc_id=S100YYFR page=1 field=income_statement.ProfitLossAttributableToOwnersOfParent
    // source: code=1419 fy_end=2026-05-31 doc_id=S100YYFR page=1 field=net_profit
    @Test func tamaHomeConsolidatedPLKeepsOwnersOfParent() async throws {
        let docID = "S100YYFR"
        guard await Self.ensureAvailable(docID) else { return }
        let cacheDir = defaultUserDataPath().appendingPathComponent("analysis_cache", isDirectory: true)
        let analyzer = StatementAnalyzer(edinetClient: EdinetAPIClient(cacheDir: cacheDir))
        guard case .resolved(let year) = await analyzer.extract(
            docID: docID, statementTypes: [.incomeStatement])
        else {
            Issue.record("expected .resolved for \(docID)")
            return
        }
        let byTag = Dictionary(
            year.incomeStatement.map { ($0.tag, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byTag["ProfitLossAttributableToOwnersOfParent"]?.value == 1_213_000_000)
        let financials = StatementFinancialsResolver.resolve(
            xbrlDir: Self.xbrlRoot.appendingPathComponent("\(docID)_xbrl"))
        #expect(financials?.netProfit == 1_213_000_000)
    }
}
