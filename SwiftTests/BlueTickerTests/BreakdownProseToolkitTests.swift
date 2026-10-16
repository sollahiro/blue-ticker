// SPEC_ORACLE: Capex / 研究開発費が共有する本文・円・残り行の道具。
// 金額はコードが換算する。不足額は本文の金額と照合するだけで、総額−抽出済み合計では埋めない。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct BreakdownProseToolkitTests {
    @Test func convertsUnitsAndDropsMultiAmountAndNegatives() {
        let oku = BreakdownProseToolkit.candidates(
            in: "当期の総額は1,234億円であります。", preferredPhrases: [])
        #expect(oku.map(\.yen) == [123_400_000_000])
        #expect(
            BreakdownProseToolkit.yen(magnitude: 4_409, unit: "百万円") == 4_409_000_000)
        #expect(BreakdownProseToolkit.yen(magnitude: 1_234, unit: "千円") == 1_234_000)
        #expect(
            BreakdownProseToolkit.candidates(
                in: "Aは10百万円、Bは20百万円であります。", preferredPhrases: []).isEmpty)
        #expect(
            BreakdownProseToolkit.candidates(
                in: "総額は△4,409百万円であります。", preferredPhrases: []).isEmpty)
        let fullwidth = BreakdownProseToolkit.candidates(
            in: "総額は４，４０９百万円であります。", preferredPhrases: [])
        #expect(fullwidth.map(\.yen) == [4_409_000_000])
    }

    @Test func remainderMatchUsesSentenceYenAndDoesNotInventTheGap() {
        let pool = [
            BreakdownProseCandidate(sentence: "全社は20百万円であります", yen: 20_000_000),
            BreakdownProseCandidate(sentence: "Aは80百万円であります", yen: 80_000_000),
        ]
        let match = BreakdownProseToolkit.matchRemainderCandidate(
            pool: pool, gap: 20_000_000, matchesTaggedRow: { $0 == 80_000_000 })
        #expect(match?.yen == 20_000_000)

        let twoExact = [
            BreakdownProseCandidate(sentence: "Xは20百万円", yen: 20_000_000),
            BreakdownProseCandidate(sentence: "Yは20百万円", yen: 20_000_000),
        ]
        #expect(
            BreakdownProseToolkit.matchRemainderCandidate(
                pool: twoExact, gap: 20_000_000, matchesTaggedRow: { _ in false }) == nil)

        let phrase = [
            BreakdownProseCandidate(
                sentence: "配分することが困難な金額は15百万円であります", yen: 15_000_000)
        ]
        let gap = 100_000_000.0
        #expect(BreakdownProseToolkit.matchesShortfall(15_000_000, gap: gap) == false)
        let fallback = BreakdownProseToolkit.matchRemainderCandidate(
            pool: phrase, gap: gap, matchesTaggedRow: { _ in false })
        #expect(fallback?.yen == 15_000_000)

        #expect(
            BreakdownProseToolkit.matchRemainderCandidate(
                pool: [], gap: 20_000_000, matchesTaggedRow: { _ in false }) == nil)
    }
}
