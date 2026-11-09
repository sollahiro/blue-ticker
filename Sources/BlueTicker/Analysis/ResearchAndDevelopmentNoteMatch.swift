// /financials の `rd` の分母を、製造費用込みの注記へ替えてよいか判定する。
// 研究開発活動の本文（ResearchAndDevelopmentActivitiesTextBlock）の1文と注記の金額が一致するかを見る。
// 文の切り出し・円換算は BreakdownProseToolkit に置く。LLM は使わない。

import Foundation

enum ResearchAndDevelopmentProseTotalDecision {
    private static let preferredPhrases = ["研究開発費"]

    static func activityPlainText(in xbrlDir: URL) -> String? {
        guard let tag = xbrlSections["research_and_development"]?.xbrlElements.first,
            let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: tag)
        else { return nil }
        let text = BreakdownProseToolkit.plainText(from: html)
        return text.isEmpty ? nil : text
    }

    /// 1文にちょうど1つの正の金額がある文だけ。`limit == nil` は上限なし。
    static func candidates(in text: String, limit: Int? = BreakdownProseToolkit.maxCandidates)
        -> [BreakdownProseCandidate]
    {
        BreakdownProseToolkit.candidates(
            in: text, preferredPhrases: preferredPhrases, limit: limit)
    }

    /// 億円表記は 0.5億円まで。332億円と注記 33,244百万円（神戸製鋼 S100OAOM）がこれ。
    static func matchesRoundedProse(_ proseYen: Double, taggedYen: Double, sentence: String)
        -> Bool
    {
        let tolerance: Double = sentence.contains("億円") ? 50_000_000 : 5_000_000
        return abs(proseYen - taggedYen) <= tolerance
    }

    /// 活動タグの全社合計が無く、採用中のタグが販管費側で、本文の研究開発費総額が
    /// 製造費用込みの注記と1文だけで一致するとき true。活動タグがある書類は対象外。
    static func confirmsManufacturingNote(
        extractedTag: String?, extractedYen: Double?, noteYen: Double?, plainText: String
    ) -> Bool {
        guard let extractedTag, Xbrl.rdExpenseJGAAPTags.contains(extractedTag),
            let extractedYen, let noteYen, noteYen > 0, extractedYen != noteYen
        else { return false }
        let matches = candidates(in: plainText, limit: nil).filter { candidate in
            candidate.sentence.contains("研究開発費")
                && matchesRoundedProse(
                    candidate.yen, taggedYen: noteYen, sentence: candidate.sentence)
                && abs(candidate.yen - noteYen) < abs(candidate.yen - extractedYen)
        }
        return matches.count == 1
    }
}
