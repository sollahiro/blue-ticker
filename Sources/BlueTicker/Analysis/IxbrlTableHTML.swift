// 本文 iXBRL（PublicDoc/*.htm）の表を行・セルに分け、セルに付いた ix:nonFraction を読む小道具。
// 未タグ行の補完（`EmployeesUntaggedRowFill` / `CapexOverviewUntaggedRowFill`）が共有する。

import Foundation

enum IxbrlTableHTML {
    static let rowPattern = try! NSRegularExpression(
        pattern: #"<tr\b.*?</tr>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let cellPattern = try! NSRegularExpression(
        pattern: #"<t[dh]\b[^>]*>(.*?)</t[dh]>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let nonFractionPattern = try! NSRegularExpression(
        pattern: #"<ix:nonFraction\b([^>]*)>"#, options: [.caseInsensitive])
    private static let contextRefPattern = try! NSRegularExpression(
        pattern: #"contextRef\s*=\s*["']([^"']+)["']"#)

    /// `dir` 以下の .htm / .html のうち `tag` を含む本文（ファイル名順）。
    static func htmlFiles(in dir: URL, containing tag: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "htm" || ext == "html" { files.append(url) }
        }
        return files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).compactMap { url in
            guard let html = try? String(contentsOf: url, encoding: .utf8), html.contains(tag)
            else { return nil }
            return html
        }
    }

    /// `html` の `<table>` のうち `tag` を自身のセルに含むもの（出現順）。入れ子の扱いは `HTMLTables`。
    static func tables(in html: String, containing tag: String) -> [String] {
        HTMLTables.tables(in: html, containing: tag)
    }

    /// 表の `<tr>` ごとの HTML（出現順）。
    static func rows(in tableHTML: String) -> [String] {
        let ns = NSRange(tableHTML.startIndex..., in: tableHTML)
        return rowPattern.matches(in: tableHTML, range: ns).compactMap { match in
            Range(match.range, in: tableHTML).map { String(tableHTML[$0]) }
        }
    }

    static func cellBodies(in rowHTML: String) -> [String] {
        let ns = NSRange(rowHTML.startIndex..., in: rowHTML)
        return cellPattern.matches(in: rowHTML, range: ns).compactMap { match in
            Range(match.range(at: 1), in: rowHTML).map { String(rowHTML[$0]) }
        }
    }

    private static let cellOpenPattern = try! NSRegularExpression(
        pattern: #"<t[dh]\b([^>]*)>(?:.*?)</t[dh]>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let rowspanPattern = try! NSRegularExpression(
        pattern: #"rowspan\s*=\s*["']?([0-9]+)"#, options: [.caseInsensitive])

    /// 行の各セルの rowspan（無ければ 1）。`cellBodies` と同じ順。
    static func cellRowspans(in rowHTML: String) -> [Int] {
        let ns = NSRange(rowHTML.startIndex..., in: rowHTML)
        return cellOpenPattern.matches(in: rowHTML, range: ns).map { match in
            guard let attrsRange = Range(match.range(at: 1), in: rowHTML) else { return 1 }
            let attrs = String(rowHTML[attrsRange])
            let attrsNS = NSRange(attrs.startIndex..., in: attrs)
            guard let span = rowspanPattern.firstMatch(in: attrs, range: attrsNS),
                  let spanRange = Range(span.range(at: 1), in: attrs),
                  let value = Int(attrs[spanRange])
            else { return 1 }
            return max(1, value)
        }
    }

    /// セルに含まれる、指定タグの ix:nonFraction の contextRef 一覧（無ければ空）。
    static func factContextRefs(in cellHTML: String, tag: String) -> [String] {
        let ns = NSRange(cellHTML.startIndex..., in: cellHTML)
        var refs: [String] = []
        for match in nonFractionPattern.matches(in: cellHTML, range: ns) {
            guard let attrsRange = Range(match.range(at: 1), in: cellHTML) else { continue }
            let attrs = String(cellHTML[attrsRange])
            guard StatementNotesResolver.ixbrlFactLocalName(fromAttributes: attrs) == tag else { continue }
            let attrsNS = NSRange(attrs.startIndex..., in: attrs)
            if let ref = contextRefPattern.firstMatch(in: attrs, range: attrsNS),
               let refRange = Range(ref.range(at: 1), in: attrs)
            {
                refs.append(String(attrs[refRange]))
            } else {
                refs.append("")
            }
        }
        return refs
    }

    static func plainText(_ cellHTML: String) -> String {
        var text = cellHTML.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.htmlEntityDecoded.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
