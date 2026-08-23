import Foundation
import Testing

@testable import BlueTickerCore

/// IFRS 1計算書方式（ComprehensiveIncomeSingleStatement）の PL role が
/// incomeStatement に分類され、Summary sales/OP が連結 RevenueIFRS /
/// OperatingProfitLossIFRS から埋まることを固定する。
///
/// 回帰: role キーワード欠落時は個別 StatementOfIncome の NetSales だけが採用され、
/// duration FieldSet の連結値が取れず sales/OP が nil になる
/// （野村総研 S100YBM8 / fin-v9 実測）。
@Suite struct IfrsSingleStatementSalesTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    @Test func nriS100YBM8SummarySalesAndOperatingProfitFromIfrsSingleStatement() async throws {
        let docID = "S100YBM8"
        let dir = Self.xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        // 手動展開キャッシュが .extract_complete 無しだと ensureCached の失敗再取得で
        // ディレクトリを消してしまうため、既存 XBRL があればマーカーだけ補完する。
        if FileManager.default.fileExists(atPath: dir.path) {
            let marker = dir.appendingPathComponent(EdinetCacheStore.xbrlExtractCompleteMarker)
            if !FileManager.default.fileExists(atPath: marker.path) {
                FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: nil)
            }
        } else {
            await SmokeCacheSupport.ensureCached([docID], cacheDir: Self.xbrlRoot)
        }
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return
        }

        let singleRole =
            "http://disclosure.edinet-fsa.go.jp/role/jpigp/rol_ConsolidatedStatementOfComprehensiveIncomeSingleStatementIFRS"
        #expect(StatementClassifier.classify(role: singleRole) == .incomeStatement)

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: dir, docID: docID, statementTypes: [.incomeStatement]
        ) else {
            Issue.record("resolveFromXBRL failed for \(docID)")
            return
        }
        let tags = year.incomeStatement.map(\.tag)
        #expect(tags.contains("RevenueIFRS"))
        #expect(tags.contains("OperatingProfitLossIFRS"))
        #expect(!tags.contains("NetSales"), "連結 PL を採用するため個別 NetSales は出ない")

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(values.sales == 814_708_000_000)
        #expect(values.operatingProfit == 58_273_000_000)
    }
}
