// 有報「企業の概況」の「事業の内容」（`DescriptionOfBusinessTextBlock`）を抽出する。
// Filing 公開 `texts` / `xbrlSections` には載せない。Overview 生成の入力専用。

import Foundation

enum DescriptionOfBusinessExtractor {
    static let headingMarker = "【事業の内容】"
    static let nextSectionPattern = #"【(?:関係会社の状況|従業員の状況)】"#

    /// 展開済み XBRL ディレクトリから本文を返す。無ければ空文字。
    static func extract(in xbrlDir: URL) -> String {
        for htmlFile in htmlFiles(in: xbrlDir) {
            guard let raw = try? String(contentsOf: htmlFile, encoding: .utf8) else { continue }
            let text = extract(html: raw)
            if !text.isEmpty { return text }
        }
        if let inner = XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: Xbrl.descriptionOfBusinessTextblockTag)
        {
            let text = htmlToText(inner)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// iXBRL HTML（またはエンティティ化した inner HTML）から本文を抜く。
    static func extract(html: String) -> String {
        if let inner = firstIXBlock(in: html) {
            let text = htmlToText(inner)
            if !text.isEmpty { return text }
        }
        guard let heading = html.range(of: headingMarker) else { return "" }
        let rest = html[heading.lowerBound...]
        let restString = String(rest)
        let nextRange = restString.range(of: nextSectionPattern, options: .regularExpression)
        let chunk = nextRange.map { String(restString[..<$0.lowerBound]) } ?? restString
        return htmlToText(chunk)
    }

    static func htmlToText(_ raw: String) -> String {
        var s = raw.htmlEntityDecoded
        s = replace(#"<script[^>]*>.*?</script>"#, in: s, with: " ", options: [.caseInsensitive, .dotMatchesLineSeparators])
        s = replace(#"<style[^>]*>.*?</style>"#, in: s, with: " ", options: [.caseInsensitive, .dotMatchesLineSeparators])
        s = replace(#"<br\s*/?>"#, in: s, with: "\n", options: [.caseInsensitive])
        s = replace(#"</(p|h[1-6]|tr|div|li|table)>"#, in: s, with: "\n", options: [.caseInsensitive])
        s = replace(#"<[^>]+>"#, in: s, with: " ", options: [.dotMatchesLineSeparators])
        s = s.htmlEntityDecoded
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
        s = replace(#"[ \t]+"#, in: s, with: " ")
        s = replace(#"\n[ \t]+"#, in: s, with: "\n")
        s = replace(#"\n{2,}"#, in: s, with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstIXBlock(in html: String) -> String? {
        let tag = NSRegularExpression.escapedPattern(for: Xbrl.descriptionOfBusinessTextblockTag)
        let pattern =
            #"<ix:nonNumeric\b[^>]*\bname=['\"][^'\"]*"# + tag + #"[^'\"]*['\"][^>]*>(.*?)</ix:nonNumeric>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    private static func htmlFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "htm" || ext == "html" { files.append(url) }
        }
        files.sort { a, b in
            let ap = a.path.contains("0101010") ? 0 : 1
            let bp = b.path.contains("0101010") ? 0 : 1
            if ap != bp { return ap < bp }
            return a.path < b.path
        }
        return files
    }

    private static func replace(
        _ pattern: String, in text: String, with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
