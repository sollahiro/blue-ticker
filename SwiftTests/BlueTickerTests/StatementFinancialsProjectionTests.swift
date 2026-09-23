import Foundation
import Testing

@testable import BlueTickerCore

/// Summary 組立が statement 本表の当期 PL を投影することの実データ回帰。
/// 再 ingest だけでは直らない extractor 欠落（親会社 NP タグ / 非連結 PL 投影）を固定する。
@Suite struct StatementFinancialsProjectionTests {
    private func ensureCached(_ docID: String) async -> URL? {
        let xbrlDir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        await SmokeCacheSupport.ensureCached([docID])
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return nil
        }
        return xbrlDir
    }

    /// コカ・コーラBJH 2579 / S100XR1L。本表は `ProfitAttributableToOwnersOfParentIFRS`
    /// （親会社帰属 −50,763）。`ProfitLossIFRS`（グループ −50,668 = NCI 95 差）へ落ちない。
    @Test func cocaColaS100XR1LSummaryNetProfitIsParentAttributable() async throws {
        let docID = "S100XR1L"
        guard let xbrlDir = await ensureCached(docID) else { return }

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: docID,
            statementTypes: [.incomeStatement]
        ) else {
            Issue.record("resolveFromXBRL failed for \(docID)")
            return
        }

        #expect(
            year.incomeStatement.contains {
                $0.tag == "ProfitAttributableToOwnersOfParentIFRS" && $0.value == -50_763_000_000
            })
        #expect(
            year.incomeStatement.contains {
                $0.tag == "ProfitLossIFRS" && $0.value == -50_668_000_000
            })

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 893_805_000_000)
        #expect(values.operatingProfit == -72_385_000_000)
        #expect(values.netProfit == -50_763_000_000)
        #expect(values.netProfit != -50_668_000_000)
    }

    /// ニッカトー 5367 / S100Y9NY。非連結のみで PL/BS は `*_NonConsolidatedMember`。
    /// statement は 11,340.9 / 1,071.2 / 775.7 百万円。CF だけ埋まって PL が null にならない。
    @Test func nikkatoS100Y9NYProjectsLatestYearPnLFromStatement() async throws {
        let docID = "S100Y9NY"
        guard let xbrlDir = await ensureCached(docID) else { return }

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: docID,
            statementTypes: [.incomeStatement, .cashFlow]
        ) else {
            Issue.record("resolveFromXBRL failed for \(docID)")
            return
        }

        #expect(
            year.incomeStatement.contains {
                $0.tag == "NetSales" && $0.value == 11_340_906_000
            })
        #expect(
            year.incomeStatement.contains {
                $0.tag == "OperatingIncome" && $0.value == 1_071_164_000
            })
        #expect(
            year.incomeStatement.contains {
                $0.tag == "ProfitLoss" && $0.value == 775_702_000
            })
        #expect(
            year.cashFlow.contains {
                $0.tag == "NetCashProvidedByUsedInOperatingActivities"
                    && $0.value == 1_675_324_000
            })

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 11_340_906_000)
        #expect(values.operatingProfit == 1_071_164_000)
        #expect(values.netProfit == 775_702_000)
        #expect(values.cfo == 1_675_324_000)
        #expect(values.totalAssets == 18_853_231_000)
    }
}
