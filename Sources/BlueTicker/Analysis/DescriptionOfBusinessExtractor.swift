// 有報「企業の概況」の「事業の内容」（`DescriptionOfBusinessTextBlock`）を抽出する。
// Filing 公開 `texts` / `xbrlSections` には載せない。Overview 生成の入力専用。

import Foundation

enum DescriptionOfBusinessExtractor {
    static let headingMarker = "【事業の内容】"
    static let nextSectionPattern = #"【(?:関係会社の状況|従業員の状況)】"#

    /// 展開済み XBRL ディレクトリから本文を返す。無ければ空文字。
    /// 訂正 overlay があるときは TextBlock を先に見る（訂正に当該要素があればそれが勝つ）。
    static func extract(in xbrlDir: URL) -> String {
        if !overlayDirectories(in: xbrlDir).isEmpty,
            let inner = XBRLUtils.extractTextblockHtml(
                in: xbrlDir, textblockTag: Xbrl.descriptionOfBusinessTextblockTag)
        {
            let text = htmlToText(inner)
            if !text.isEmpty { return text }
        }
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

    /// タグ除去フェーズの置換（entity デコード前）。順序依存。
    /// 定数パターンのため静的に保持し、呼び出しごとの再コンパイルを避ける。
    private static let tagReplacements: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"<script[^>]*>.*?</script>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]), " "),
        (try! NSRegularExpression(pattern: #"<style[^>]*>.*?</style>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]), " "),
        (try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive]), "\n"),
        (try! NSRegularExpression(pattern: #"</(p|h[1-6]|tr|div|li|table)>"#, options: [.caseInsensitive]), "\n"),
        (try! NSRegularExpression(pattern: #"<[^>]+>"#, options: [.dotMatchesLineSeparators]), " "),
    ]

    /// 空白正規化フェーズの置換（entity デコード後）。順序依存。
    private static let whitespaceReplacements: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"[ \t]+"#), " "),
        (try! NSRegularExpression(pattern: #"\n[ \t]+"#), "\n"),
        (try! NSRegularExpression(pattern: #"\n{2,}"#), "\n"),
    ]

    static func htmlToText(_ raw: String) -> String {
        var s = raw.htmlEntityDecoded
        s = apply(tagReplacements, to: s)
        s = s.htmlEntityDecoded
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
        s = apply(whitespaceReplacements, to: s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func apply(_ replacements: [(NSRegularExpression, String)], to text: String) -> String {
        var s = text
        for (regex, template) in replacements {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    /// 定数パターンのため静的に保持し、呼び出しごとの再コンパイルを避ける。
    private static let ixBlockPattern: NSRegularExpression = {
        let tag = NSRegularExpression.escapedPattern(for: Xbrl.descriptionOfBusinessTextblockTag)
        return try! NSRegularExpression(
            pattern: #"<ix:nonNumeric\b[^>]*\bname=['\"][^'\"]*"# + tag + #"[^'\"]*['\"][^>]*>(.*?)</ix:nonNumeric>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive])
    }()

    private static func firstIXBlock(in html: String) -> String? {
        guard let match = ixBlockPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
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

}
