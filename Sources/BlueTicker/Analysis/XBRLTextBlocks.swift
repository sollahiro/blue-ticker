import Foundation
import SwiftSoup

extension XBRLUtils {
    // MARK: IFRS TextBlock

    /// IFRS Summary型XBRLのTextBlock HTMLテーブルをパースする。
    /// ラベル → (当期値, 前期値) を返す。値は百万円単位。
    static func extractIfrsTextblockTable(
        in dir: URL,
        textblockTag: String
    ) -> [String: (current: Double?, prior: Double?)] {
        guard let htmlContent = extractTextblockHtml(in: dir, textblockTag: textblockTag),
              let soup = try? SwiftSoup.parse(htmlContent),
              let rows = try? soup.select("tr") else { return [:] }

        var result: [String: (current: Double?, prior: Double?)] = [:]
        for row in rows {
            guard let cells = try? row.select("td"), cells.count >= 3 else { continue }
            guard let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true),
                  !label.isEmpty else { continue }
            let dataCells = Array(cells.dropFirst())
            guard dataCells.count >= 2 else { continue }
            let currentV = parseTextblockCellValue(try? dataCells.last?.text())
            let priorV = parseTextblockCellValue(try? dataCells[dataCells.count - 2].text())
            if currentV != nil || priorV != nil {
                result[label] = (currentV, priorV)
            }
        }
        return result
    }

    /// 指定タグの TextBlock 要素内のHTML（エンティティ復号済み）を最初に一致したファイルから返す。
    /// 訂正 overlay に同じタグがあれば、提出が新しい訂正の本文で置き換える。
    static func extractTextblockHtml(in dir: URL, textblockTag: String) -> String? {
        var found = extractTextblockHtmlUnlayered(in: dir, textblockTag: textblockTag)
        for overlayDir in overlayDirectories(in: dir) {
            if let html = extractTextblockHtmlUnlayered(in: overlayDir, textblockTag: textblockTag) {
                found = html
            }
        }
        return found
    }

    private static func extractTextblockHtmlUnlayered(in dir: URL, textblockTag: String) -> String? {
        guard let pattern = textblockHtmlPattern(for: textblockTag) else { return nil }
        for xbrlFile in findXbrlFiles(in: dir) {
            guard let raw = try? String(contentsOf: xbrlFile, encoding: .utf8) else { continue }
            guard let match = pattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { continue }
            return String(raw[range]).htmlEntityDecoded
        }
        return nil
    }

    /// TextBlock 内 HTML 表セルの数値テキスト → Double（百万円単位の生値）。△/▲ は負、－ は nil。
    /// 末尾の "%"／"％" は除去する（実データ検証2026-08-03、メルカリ S100RX8V の平均利率列は
    /// "0.39%" のように単位付きで書かれる会社があり、付けたまま `Double()` に渡すと nil になる）。
    static func parseTextblockCellValue(_ text: String?) -> Double? {
        guard let t = text else { return nil }
        var s = t.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.hasSuffix("%") || s.hasSuffix("％") { s.removeLast() }
        if s.isEmpty || ["－", "-", "—", "―"].contains(s) { return nil }
        let negative = s.hasPrefix("△") || s.hasPrefix("▲")
        s = s.replacingOccurrences(of: "△", with: "").replacingOccurrences(of: "▲", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        guard let val = Double(s) else { return nil }
        return negative ? -val : val
    }

    // MARK: HTML Label Extraction

    /// soup の全 <tr> を走査し label_map に一致する行の当期/前期値を返す。
    static func extractHtmlLabels(
        from element: Element,
        labelMap: [String: String]
    ) -> FieldSet {
        var fieldSet: FieldSet = [:]
        var remaining = Set(labelMap.keys)

        // 仮想タグ → 対応ラベルの集合（一括除去用）
        var tagToLabels: [String: Set<String>] = [:]
        for (lbl, vtag) in labelMap {
            tagToLabels[vtag, default: []].insert(lbl)
        }

        guard let rows = try? element.select("tr") else { return fieldSet }
        let labelsByLength = remaining.sorted { $0.count > $1.count }
        for row in rows {
            guard !remaining.isEmpty else { break }
            guard let cells = try? row.select("td, th"), !cells.isEmpty else { continue }
            let texts = cells.array().compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }
                .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
            guard !texts.isEmpty else { continue }

            var matched: String?
            for label in remaining where texts[0] == label { matched = label; break }
            if matched == nil {
                for label in labelsByLength where remaining.contains(label) {
                    if texts[0].contains(label) { matched = label; break }
                }
            }
            guard let lbl = matched else { continue }

            let numbers = texts.map { parseHtmlNumber($0) }
            let allNums = numbers.compactMap { $0 }
            guard !allNums.isEmpty else { continue }
            let found = filterFinancialTableAmounts(allNums)
            let current = found.last! * Financial.millionYen
            let prior: Double? = found.count >= 2 ? found[found.count - 2] * Financial.millionYen : nil
            let vtag = labelMap[lbl]!
            fieldSet[vtag] = FieldValue(current: current, prior: prior)
            remaining.subtract(tagToLabels[vtag] ?? [])
        }
        return fieldSet
    }

}

private let _textblockPatternLock = NSLock()
nonisolated(unsafe) private var _textblockPatterns: [String: NSRegularExpression] = [:]

private func textblockHtmlPattern(for tag: String) -> NSRegularExpression? {
    _textblockPatternLock.lock()
    defer { _textblockPatternLock.unlock() }
    if let cached = _textblockPatterns[tag] { return cached }
    let escaped = NSRegularExpression.escapedPattern(for: tag)
    let regex = try? NSRegularExpression(
        pattern: "<[^>]*:" + escaped + "(?:\\s|>|/)[^>]*>(.*?)</[^>]*:" + escaped + "[^>]*>",
        options: [.dotMatchesLineSeparators]
    )
    if let regex { _textblockPatterns[tag] = regex }
    return regex
}
