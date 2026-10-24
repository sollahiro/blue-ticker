// 開示 HTML（TextBlock の中身・本文 iXBRL）から最上位の `<table>` を切り出す共有の小道具。
// 非貪欲な `<table\b.*?</table>` は表の中の表の閉じタグで外側の表を切ってしまうため、
// 開き・閉じタグの入れ子を数えて切り出し、中の表は外側のセルの中身として平らにする。

import Foundation

enum HTMLTables {
    private static let tableTagPattern = try! NSRegularExpression(
        pattern: #"<(/?)table\b[^>]*>"#, options: [.caseInsensitive])
    /// 中の表を平らにするときに外す表構造のタグ。セルの中身（段落・ix:nonFraction 等）は残す。
    private static let structureTagPattern = try! NSRegularExpression(
        pattern: #"</?(?:table|thead|tbody|tfoot|tr|td|th|caption|colgroup|col)\b[^>]*>"#,
        options: [.caseInsensitive])

    /// 入れ子を数えた最上位の表の範囲（出現順）。閉じていない表は末尾まで。
    static func topLevelRanges(in html: String) -> [NSRange] {
        let ns = html as NSString
        var ranges: [NSRange] = []
        var depth = 0
        var start = 0
        for m in tableTagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).length == 0 {
                if depth == 0 { start = m.range.location }
                depth += 1
            } else if depth > 0 {
                depth -= 1
                if depth == 0 { ranges.append(NSRange(location: start, length: m.range.upperBound - start)) }
            }
        }
        if depth > 0 { ranges.append(NSRange(location: start, length: ns.length - start)) }
        return ranges
    }

    /// `tag` を自身のセルに含む表（出現順。中の表は `flattenNested` 済み）。外側の表が中の表を
    /// 包むだけのとき（日立 S100YGBO の従業員表は 1 セルの枠の表の中）は、外側でなく中の表を返す。
    static func tables(in html: String, containing tag: String) -> [String] {
        let ns = html as NSString
        return topLevelRanges(in: html).flatMap { tablesOwning(tag, in: ns.substring(with: $0)) }
    }

    private static func tablesOwning(_ tag: String, in tableHTML: String) -> [String] {
        let ns = tableHTML as NSString
        let children = nestedRanges(in: tableHTML)
        var own = tableHTML
        for range in children.reversed() { own = (own as NSString).replacingCharacters(in: range, with: "") }
        let selfMatch = own.contains(tag) ? [flattenNested(tableHTML)] : []
        return selfMatch + children.flatMap { tablesOwning(tag, in: ns.substring(with: $0)) }
    }

    /// 表のすぐ中（1 段下）の表の範囲。
    private static func nestedRanges(in tableHTML: String) -> [NSRange] {
        let ns = tableHTML as NSString
        var nested: [NSRange] = []
        var depth = 0
        var start = 0
        for m in tableTagPattern.matches(in: tableHTML, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).length == 0 {
                depth += 1
                if depth == 2 { start = m.range.location }
            } else if depth > 0 {
                if depth == 2 { nested.append(NSRange(location: start, length: m.range.upperBound - start)) }
                depth -= 1
            }
        }
        return nested
    }

    /// 表の中の表から表構造のタグを外し、外側のセルの中身として残す（外側の行・セルの数を変えない）。
    static func flattenNested(_ tableHTML: String) -> String {
        let nested = nestedRanges(in: tableHTML)
        guard !nested.isEmpty else { return tableHTML }
        var out = tableHTML
        for range in nested.reversed() {
            let inner = (out as NSString).substring(with: range)
            let flat = structureTagPattern.stringByReplacingMatches(
                in: inner, range: NSRange(location: 0, length: (inner as NSString).length), withTemplate: " ")
            out = (out as NSString).replacingCharacters(in: range, with: "<span>\(flat)</span>")
        }
        return out
    }
}
