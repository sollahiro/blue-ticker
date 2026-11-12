// geography 軸の欠測理由（国内売上 90% 超 / 海外売上なし / not_found）を文だけで分ける純関数のテスト。
// 文言は有報の関連情報「地域ごとの情報」の定型文。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct GeographyOmissionReasonTests {
    private func classify(_ sentences: [String]) -> String? {
        BreakdownExtractor.classifyGeographyOmission(sentences: sentences)
    }

    @Test func domesticNinetyPercentIsDomesticDominant() {
        #expect(classify(["本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"])
            == breakdownNotApplicableDomesticDominant90pct)
        #expect(classify(["本邦の外部顧客への売上高が連結損益及び包括利益計算書の売上高の90%を超えるため、記載を省略しております。"])
            == breakdownNotApplicableDomesticDominant90pct)
        // IFRS の言い回し
        #expect(classify(["日本の外部顧客からの売上収益が連結損益計算書の売上収益の90％を超えるため、記載を省略しております。"])
            == breakdownNotApplicableDomesticDominant90pct)
        // 売上と有形固定資産を1文で省略
        #expect(classify(["本邦の外部顧客への売上高及び本邦に所在している有形固定資産の金額がいずれも90％を超えるため、記載を省略しております。"])
            == breakdownNotApplicableDomesticDominant90pct)
    }

    @Test func noOverseasSalesWinsOverNinetyPercent() {
        #expect(classify(["本邦以外の外部顧客への売上高がないため、該当事項はありません。"])
            == breakdownNotApplicableNoOverseasSales)
        #expect(classify(["海外売上高がないため、記載を省略しております。"])
            == breakdownNotApplicableNoOverseasSales)
        #expect(classify(["外部顧客への売上高は、全て本邦の外部顧客への売上高であるため、記載を省略しております。"])
            == breakdownNotApplicableNoOverseasSales)
        #expect(classify([
            "本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。",
            "本邦以外の外部顧客への売上高がないため、該当事項はありません。",
        ]) == breakdownNotApplicableNoOverseasSales)
    }

    /// のれん注記の「セグメント情報に同様」は地域ごとの情報ではない。本邦90%文だけを残す。
    /// source: code=6577 fy_end=2026-07-31 doc_id=S100Z940 page=77 field=geography
    @Test func goodwillSameAsSentenceIsNotGeographyDisclosure() {
        let ninety =
            "本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"
        let goodwill =
            "（注）のれん償却額に関しては、セグメント情報に同様の情報を開示しているため、記載を省略しております。"
        #expect(!BreakdownExtractor.isGeographyDisclosureSentence(goodwill))
        #expect(BreakdownExtractor.isGeographyDisclosureSentence(ninety))
        #expect(
            BreakdownExtractor.geographyDisclosureSentences(from: [goodwill, ninety]) == [ninety])
        #expect(
            classify([goodwill, ninety]) == breakdownNotApplicableDomesticDominant90pct)
        #expect(
            BreakdownExtractor.geographyOmissionTakesPriority(
                overSameAs: breakdownNotApplicableDomesticDominant90pct))
        #expect(
            BreakdownExtractor.geographyOmissionTakesPriority(
                overSameAs: breakdownNotApplicableNoOverseasSales))
        #expect(
            !BreakdownExtractor.geographyOmissionTakesPriority(
                overSameAs: breakdownNotApplicableNotFound))
    }

    @Test func unrelatedNinetyPercentSentencesStayNil() {
        // 有形固定資産だけの 90% 文
        #expect(classify(["本邦に所在している有形固定資産の金額が連結貸借対照表の有形固定資産の金額の90％を超えるため、記載を省略しております。"]) == nil)
        // 製品 90% 文
        #expect(classify(["単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"]) == nil)
        // 本邦以外に拠点が無い（売上の文ではない）
        #expect(classify(["本邦以外の国又は地域に所在する連結子会社及び在外支店がないため、該当事項はありません。"]) == nil)
        // セグメントと同一の省略は same_as 側で扱う
        #expect(classify(["セグメント情報に同様の情報を開示しているため、記載を省略しています。"]) == nil)
        #expect(classify([]) == nil)
    }

    @Test func splitSentencesKeepsNonOmissionSentences() {
        let sentences = BreakdownExtractor.splitSentences("(1) 売上高\n本邦以外の外部顧客への売上高がないため、該当事項はありません。(2) 有形固定資産\n記載を省略しております。")
        #expect(sentences == [
            "(1) 売上高本邦以外の外部顧客への売上高がないため、該当事項はありません。",
            "(2) 有形固定資産記載を省略しております。",
        ])
    }

    @Test func newReasonsAreDeterministic() {
        #expect(isDeterministicBreakdownNotApplicableReason(breakdownNotApplicableDomesticDominant90pct))
        #expect(isDeterministicBreakdownNotApplicableReason(breakdownNotApplicableNoOverseasSales))
    }
}
