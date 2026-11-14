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

    /// キングジム 7962 S100Z29T の設備投資の概要:「総額６億8,006万円の設備投資を実施いたしました」。
    /// 「億」と「万円」の併記、「万円」だけの表記も円に換算する。百万円・千円の既存挙動は変えない。
    @Test func convertsOkuManCompoundAndManYen() {
        let compound = BreakdownProseToolkit.candidates(
            in: "当連結会計年度において、総額６億8,006万円の設備投資を実施いたしました。",
            preferredPhrases: [])
        #expect(compound.map(\.yen) == [680_060_000])
        let man = BreakdownProseToolkit.candidates(
            in: "設備投資の総額は5,256万円であります。", preferredPhrases: [])
        #expect(man.map(\.yen) == [52_560_000])
        let hundredMillion = BreakdownProseToolkit.candidates(
            in: "設備投資の総額は100百万円であります。", preferredPhrases: [])
        #expect(hundredMillion.map(\.yen) == [100_000_000])
        // 億円 と 万円 が別々の金額として並ぶ文は 2 金額なので候補にしない。
        #expect(
            BreakdownProseToolkit.candidates(
                in: "Aは3億円、Bは5,256万円であります。", preferredPhrases: []).isEmpty)
        #expect(
            BreakdownProseToolkit.candidates(
                in: "総額は△5,256万円であります。", preferredPhrases: []).isEmpty)
    }

    /// キングジム: 総額の文と工場の一部が並ぶとき、総額だけを会社全体とする。
    /// 穴吹興産: 取得いたしましたの1文だけなら Jev なし。事業においての1文は採らない。
    @Test func deterministicCompanyTotalPicksSoleAcquisitionOrUniqueSogaku() {
        let kingjim = BreakdownProseToolkit.candidates(
            in: """
                当連結会計年度において、総額６億8,006万円の設備投資を実施いたしました。\
                その主なものは、工場生産設備の３億5,256万円であります。
                """,
            preferredPhrases: [])
        #expect(Set(kingjim.map(\.yen)) == [680_060_000, 352_560_000])
        #expect(BreakdownProseToolkit.deterministicCompanyTotal(in: kingjim)?.yen == 680_060_000)

        let anabuki = BreakdownProseToolkit.candidates(
            in: "太陽光発電設備、倉庫及び高圧受電設備等、2,180,870千円を取得いたしました。",
            preferredPhrases: [])
        #expect(anabuki.map(\.yen) == [2_180_870_000])
        #expect(
            BreakdownProseToolkit.deterministicCompanyTotal(in: anabuki)?.yen == 2_180_870_000)

        let limited = BreakdownProseToolkit.candidates(
            in: "不動産関連事業において1,059,739千円を取得いたしました。",
            preferredPhrases: [])
        #expect(BreakdownProseToolkit.deterministicCompanyTotal(in: limited) == nil)

        let noCue = BreakdownProseToolkit.candidates(
            in: "ヘルスケアの設備投資は10百万円であります。", preferredPhrases: [])
        #expect(BreakdownProseToolkit.deterministicCompanyTotal(in: noCue) == nil)
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
