// 有報「セグメント情報」の「報告セグメントの概要」（`DescriptionOfReportableSegmentsTextBlock`）。
// 事業の内容が系統図だけで読めないときの Overview 入力。Filing 公開 `texts` には載せない。

import Foundation

enum ReportableSegmentsOverviewExtractor {
    static let headingMarker = "報告セグメントの概要"
    /// 概要の直後に来る売上表・関連情報。IFRS 巨大注記を最後まで飲まない。
    static let nextSectionPattern =
        #"【(?:関連情報|主要な顧客|報告セグメントごとの)|２[\.．、]?\s*報告セグメント|2[\.．]\s*報告セグメント"#
    /// 見出しフォールバック時の HTML 切り出し上限（文字）。htmlToText 前。
    static let headingHtmlLimit = 80_000

    /// 展開済み XBRL ディレクトリから本文を返す。無ければ空文字。
    static func extract(in xbrlDir: URL) -> String {
        for htmlFile in htmlFiles(in: xbrlDir) {
            guard let raw = try? String(contentsOf: htmlFile, encoding: .utf8) else { continue }
            let text = extract(html: raw)
            if !text.isEmpty { return text }
        }
        if let inner = XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: Xbrl.descriptionOfReportableSegmentsTextblockTag)
        {
            let text = DescriptionOfBusinessExtractor.htmlToText(inner)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// iXBRL HTML から本文を抜く。専用タグを優先し、無ければ見出しから次節まで。
    static func extract(html: String) -> String {
        let fromTags = ixBlocks(in: html)
            .map { DescriptionOfBusinessExtractor.htmlToText($0) }
            .filter { !$0.isEmpty }
        if !fromTags.isEmpty {
            return fromTags.joined(separator: "\n")
        }
        guard let heading = html.range(of: headingMarker) else { return "" }
        let restString = String(html[heading.lowerBound...])
        let limited = String(restString.prefix(headingHtmlLimit))
        let nextRange = limited.range(of: nextSectionPattern, options: .regularExpression)
        let chunk = nextRange.map { String(limited[..<$0.lowerBound]) } ?? limited
        return DescriptionOfBusinessExtractor.htmlToText(chunk)
    }

    private static func ixBlocks(in html: String) -> [String] {
        let tag = NSRegularExpression.escapedPattern(for: Xbrl.descriptionOfReportableSegmentsTextblockTag)
        let pattern =
            #"<ix:nonNumeric\b[^>]*\bname=['\"][^'\"]*"# + tag + #"[^'\"]*['\"][^>]*>(.*?)</ix:nonNumeric>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        let full = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: full).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: html) else {
                return nil
            }
            return String(html[range])
        }
    }

    /// 注記 HTML（0105010 / 保険の 0105110）を先に見る。
    private static func htmlFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "htm" || ext == "html" { files.append(url) }
        }
        files.sort { a, b in
            func rank(_ path: String) -> Int {
                if path.contains("0105010") { return 0 }
                if path.contains("0105110") { return 1 }
                return 2
            }
            let ar = rank(a.path)
            let br = rank(b.path)
            if ar != br { return ar < br }
            return a.path < b.path
        }
        return files
    }
}
