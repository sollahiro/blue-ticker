import Foundation
import SwiftSoup

struct InterestExpenseResult {
    var current: Double?
    var prior: Double?
    var method: String
    var accountingStandard: String
}

enum InterestExpenseExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String, xbrlDir: URL? = nil) -> InterestExpenseResult {
        // US-GAAP 企業: 連結損益計算書HTML(0105010)から直接解析
        if accountingStandard == "US-GAAP" {
            if let dir = xbrlDir, let fv = USGAAPHtml.extractInterestExpense(in: dir) {
                return InterestExpenseResult(
                    current: fv.current, prior: fv.prior,
                    method: "usgaap_html", accountingStandard: "US-GAAP"
                )
            }
            return InterestExpenseResult(
                current: nil, prior: nil,
                method: "not_found", accountingStandard: "US-GAAP"
            )
        }

        let tags = accountingStandard == "IFRS"
            ? Xbrl.interestExpenseIFRSTags
            : Xbrl.interestExpenseJGAAPTags
        let item = resolveItem(fieldSet, tags: tags)
        if item.tag != nil {
            return InterestExpenseResult(
                current: item.current, prior: item.prior,
                method: "direct", accountingStandard: accountingStandard
            )
        }

        // IFRS注記の文章中に支払利息が出るケース（トヨタ型）を拾う
        if let dir = xbrlDir, let textblock = extractIfrsIEFromTextblock(in: dir) {
            return textblock
        }

        return InterestExpenseResult(
            current: nil, prior: nil,
            method: "not_found", accountingStandard: accountingStandard
        )
    }

    /// IFRS注記テキストブロックから支払利息を抽出する。
    /// 「支払利息は、…それぞれ X百万円 および Y百万円」の文章パターン（前期・当期の順）。
    private static let ifrsInterestExpenseTextPattern = try! NSRegularExpression(
        pattern: "支払利息は、.*?それぞれ\\s*([0-9,]+)百万円\\s*および\\s*([0-9,]+)百万円",
        options: [.dotMatchesLineSeparators]
    )

    private static func extractIfrsIEFromTextblock(in xbrlDir: URL) -> InterestExpenseResult? {
        let pattern = ifrsInterestExpenseTextPattern
        guard let enumerator = FileManager.default.enumerator(at: xbrlDir, includingPropertiesForKeys: nil)
        else { return nil }

        let candidates = enumerator.compactMap { $0 as? URL }
            .filter { ["htm", "html", "xbrl"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in candidates {
            guard let data = try? Data(contentsOf: file) else { continue }
            let content = String(decoding: data, as: UTF8.self)
            guard content.contains("支払利息"), content.contains("百万円") else { continue }

            let text = (try? SwiftSoup.parse(content).text()) ?? content
            guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let priorRange = Range(match.range(at: 1), in: text),
                  let currentRange = Range(match.range(at: 2), in: text),
                  let prior = Double(text[priorRange].replacingOccurrences(of: ",", with: "")),
                  let current = Double(text[currentRange].replacingOccurrences(of: ",", with: ""))
            else { continue }

            return InterestExpenseResult(
                current: current * Financial.millionYen,
                prior: prior * Financial.millionYen,
                method: "ifrs_textblock",
                accountingStandard: "IFRS"
            )
        }
        return nil
    }
}
