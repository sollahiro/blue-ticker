// 設備投資の本文総額(capex_prose)の実データ回帰(SPEC_ORACLE の L1 実行器)。
// 候補の切り出しと円換算は決定論。会社全体の総額かの分類は Jev(ここでは呼ばない)。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlCapexProseTests {
    /// キングジム。「総額６億8,006万円の設備投資を実施いたしました」(万円の丸め。セグメント注記は 680,063千円)。
    /// 続く文の「工場生産設備の３億5,256万円」は一部の金額なので別の候補になる。
    /// source: code=7962 fy_end=2026-06-20 doc_id=S100Z29T page=23 field=capex_overview
    @Test func kingjimTotalInOkuManIsACandidate() async throws {
        await SmokeCacheSupport.ensureCached(["S100Z29T"])
        let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("S100Z29T_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let text = try #require(CapexProseTotalDecision.overviewPlainText(in: dir))
        let yens = CapexProseTotalDecision.candidates(in: text, limit: nil).map(\.yen)
        #expect(yens.contains(680_060_000))
        #expect(yens.contains(352_560_000))
    }

    /// 穴吹興産。「2,180,870千円を取得いたしました」だけが候補(概要タグは無い書類)。
    /// source: code=8928 fy_end=2025-06-30 doc_id=S100WQZC page=31 field=capex_overview
    @Test func anabukiProseTotalIsTheOnlyCandidate() async throws {
        await SmokeCacheSupport.ensureCached(["S100WQZC"])
        let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("S100WQZC_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let text = try #require(CapexProseTotalDecision.overviewPlainText(in: dir))
        #expect(CapexProseTotalDecision.candidates(in: text, limit: nil).map(\.yen) == [2_180_870_000])
        #expect(BreakdownFinancialsResolver.breakdownCanonicalCapexOverviewItem(xbrlDir: dir).value == nil)
    }
}

/// 決定論の capex 行があり概要が無いとき、Jev が不達なら行を確定しない(.failed)。
/// 確定すると「現行版の決定論の行」として以後 skip され、本文の総額が永久に入らない(Jev 402 の間に
/// 作られた行が残った)。Jev が総額でないと答えたときは、概要なしの行を確定する。
/// source: code=8928 fy_end=2025-06-30 doc_id=S100WQZC page=31 field=capex_overview
@Suite struct RealXbrlCapexProseFillTests {
    private struct FixedDecider: CapexProseDeciding {
        var selected: String?
        var probability: Double?
        func classify(sentence: String) async -> BreakdownProseChoice {
            BreakdownProseChoice(sentence: sentence, selected: selected, probability: probability)
        }
        func classifyRemainder(sentence: String) async -> BreakdownProseChoice {
            BreakdownProseChoice(sentence: sentence, selected: nil, probability: nil)
        }
        func classifyExclusion(sentence: String) async -> BreakdownProseChoice {
            BreakdownProseChoice(sentence: sentence, selected: nil, probability: nil)
        }
    }

    private let docID = "S100WQZC"

    private var deterministicPayload: BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisCapex, denominator: 0, denominatorTag: "noncurrent_asset_additions",
            rows: [], sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    private func fill(_ decider: FixedDecider) async throws -> CapexProseFillResult? {
        await SmokeCacheSupport.ensureCached([docID])
        let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let context = BltServerContext(
            apiKey: "test", cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()),
            capexProseDecider: decider)
        return await context.fillCapexProse(payload: deterministicPayload, xbrlDir: dir, docID: docID)
    }

    @Test func unavailableJevDoesNotFinalizeARowWithoutOverview() async throws {
        guard let result = try await fill(FixedDecider(selected: nil, probability: nil)) else { return }
        guard case .failed = result else {
            Issue.record("Jev 不達のとき概要なしの行を確定している")
            return
        }
    }

    @Test func companyTotalFillsTheOverview() async throws {
        guard let result = try await fill(
            FixedDecider(selected: CapexProseRole.currentCompanyTotal, probability: 0.95))
        else { return }
        guard case .resolved(let filled) = result else {
            Issue.record("総額と判定されたのに resolved でない")
            return
        }
        #expect(filled.payload.capitalExpendituresOverview?.denominator == 2_180_870_000)
        #expect(
            filled.payload.capitalExpendituresOverview?.denominatorTag
                == breakdownDenominatorTagCapexProse)
    }

    @Test func nonTotalAnswerKeepsTheDeterministicRowWithoutOverview() async throws {
        guard let result = try await fill(
            FixedDecider(selected: CapexProseRole.priorPeriod, probability: 0.95))
        else { return }
        guard case .resolved(let filled) = result else {
            Issue.record("総額でないと判定されたのに resolved でない")
            return
        }
        #expect(filled.payload.capitalExpendituresOverview == nil)
    }
}
