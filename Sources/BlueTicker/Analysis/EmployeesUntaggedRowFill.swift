// 従業員数の内訳: 「連結会社の状況」表で iXBRL の fact が付いていない行を、分母との差額に
// 整数一致するときだけ reconciling 行として補う。
//
// 会社によっては表の一部の行（例: イオンの「純粋持株会社等」）に ix:nonFraction が付かず、
// dimension 付き fact だけを読む `BreakdownNormalizer.normalizeEmployees` では行が落ちる
// （行の和が分母を下回る）。同じ表の中で fact が付いた行と並ぶ未タグ行に限り、値は開示の
// セルそのまま。未タグ行の合計が差額とぴったり一致しなければ何も足さない（値を作らない）。
// 全社（共通）が member 付きで開示される会社は差額が 0 のため、この経路は動かない。
// 行の種別は、本社・全社共通・持株会社などのバケツ語を含めば reconciling、それ以外は segment。

import Foundation

enum EmployeesUntaggedRowFill {
    struct TableRow: Equatable {
        var label: String
        var amount: Double
        /// 値セルに従業員数の ix:nonFraction が付いている。
        var tagged: Bool
    }

    struct Table: Equatable {
        var rows: [TableRow]
        /// セグメント member 付きの従業員数 fact を持つ表（セグメント別の従業員表）。
        var anchored: Bool
    }

    /// 人数は整数。差額との一致判定は 0.5 人未満。
    private static let equalityEpsilon = 0.5

    static func fill(
        snapshot: BreakdownSnapshot, facts: [BreakdownFact], xbrlDir: URL
    ) -> BreakdownSnapshot {
        let tag = snapshot.denominatorTag
        guard Xbrl.employeeTags.contains(tag), snapshot.denominator > 0, residual(of: snapshot) > equalityEpsilon
        else { return snapshot }
        let anchorRefs = Set(
            facts.filter { $0.tag == tag && XBRLUtils.primaryBreakdownMember($0.dimensions) != nil }
                .map(\.contextRef))
        guard !anchorRefs.isEmpty else { return snapshot }
        let tables = loadTables(in: xbrlDir, tag: tag, anchorRefs: anchorRefs)
        return apply(snapshot: snapshot, tables: tables)
    }

    /// 純関数。未タグ行の合計が差額と一致するときだけ reconciling 行を足す。
    static func apply(snapshot: BreakdownSnapshot, tables: [Table]) -> BreakdownSnapshot {
        let gap = residual(of: snapshot)
        guard snapshot.denominator > 0, gap > equalityEpsilon else { return snapshot }

        let existing = Set(snapshot.rows.flatMap { [compact($0.labelRaw), compact($0.label ?? "")] })
        var seen: Set<String> = []
        var candidates: [TableRow] = []
        for table in tables where table.anchored {
            for row in table.rows where !row.tagged && row.amount > 0 {
                let key = compact(row.label)
                guard !key.isEmpty, !isTotalOrMeasureLabel(key), !existing.contains(key) else { continue }
                guard seen.insert("\(key)|\(row.amount)").inserted else { continue }
                candidates.append(row)
            }
        }
        guard !candidates.isEmpty else { return snapshot }
        let sum = candidates.reduce(0.0) { $0 + $1.amount }
        guard abs(sum - gap) < equalityEpsilon else { return snapshot }

        var filled = snapshot
        for row in candidates {
            filled.rows.append(
                BreakdownRow(
                    labelRaw: row.label, label: row.label, amount: row.amount,
                    share: row.amount / snapshot.denominator, profit: nil,
                    rowKind: rowKind(forLabel: row.label)))
        }
        // 行の和が分母と一致したので、行不足による乖離警告は解消する。
        filled.warnings.removeAll { $0.hasSuffix("_segment_sum_far_from_total") }
        filled.needsReview = !filled.warnings.isEmpty
        return filled
    }

    /// 本社・全社共通・持株会社など事業に属さない人員のバケツは reconciling、それ以外は segment。
    /// member 付きの `CorporateSharedMember`（reconciling）と同じ扱いに揃える。
    private static let corporateBucketWords = [
        "全社", "共通", "持株会社", "本社", "管理部門", "調整", "消去",
    ]

    private static func rowKind(forLabel label: String) -> String {
        let key = compact(label)
        return corporateBucketWords.contains { key.contains($0) } ? "reconciling" : "segment"
    }

    private static func residual(of snapshot: BreakdownSnapshot) -> Double {
        let included = snapshot.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .reduce(0.0) { $0 + $1.amount }
        return snapshot.denominator - included
    }

    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "　" && $0 != "・" }
    }

    /// 合計・小計行と、人数以外の測度（平均年齢など）は行にしない。
    private static func isTotalOrMeasureLabel(_ compactLabel: String) -> Bool {
        let blocked = ["合計", "小計", "総計", "総数", "平均", "年齢", "勤続", "給与"]
        if compactLabel == "計" { return true }
        return blocked.contains { compactLabel.contains($0) }
    }

    // MARK: - HTML

    private static let tablePattern = try! NSRegularExpression(
        pattern: #"<table\b.*?</table>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let rowPattern = try! NSRegularExpression(
        pattern: #"<tr\b.*?</tr>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let cellPattern = try! NSRegularExpression(
        pattern: #"<t[dh]\b[^>]*>(.*?)</t[dh]>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let nonFractionPattern = try! NSRegularExpression(
        pattern: #"<ix:nonFraction\b([^>]*)>"#, options: [.caseInsensitive])
    private static let contextRefPattern = try! NSRegularExpression(
        pattern: #"contextRef\s*=\s*["']([^"']+)["']"#)
    private static let leadingNumberPattern = try! NSRegularExpression(
        pattern: #"^([0-9][0-9,]*)(?:\s*[\[［〔(（].*)?$"#)

    static func loadTables(in dir: URL, tag: String, anchorRefs: Set<String>) -> [Table] {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var tables: [Table] = []
        var files: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "htm" || ext == "html" { files.append(url) }
        }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let html = try? String(contentsOf: url, encoding: .utf8), html.contains(tag)
            else { continue }
            tables.append(contentsOf: parseTables(html: html, tag: tag, anchorRefs: anchorRefs))
        }
        return tables
    }

    static func parseTables(html: String, tag: String, anchorRefs: Set<String>) -> [Table] {
        var out: [Table] = []
        let whole = NSRange(html.startIndex..., in: html)
        for tableMatch in tablePattern.matches(in: html, range: whole) {
            guard let tableRange = Range(tableMatch.range, in: html) else { continue }
            let tableHTML = String(html[tableRange])
            guard tableHTML.contains(tag) else { continue }
            var anchored = false
            var rows: [TableRow] = []
            let tableNS = NSRange(tableHTML.startIndex..., in: tableHTML)
            for rowMatch in rowPattern.matches(in: tableHTML, range: tableNS) {
                guard let rowRange = Range(rowMatch.range, in: tableHTML) else { continue }
                let rowHTML = String(tableHTML[rowRange])
                let cells = cellBodies(in: rowHTML)
                for cell in cells where factInfo(in: cell, tag: tag).contains(where: { anchorRefs.contains($0) }) {
                    anchored = true
                }
                guard cells.count >= 2 else { continue }
                let label = plainText(cells[0])
                guard containsJapanese(label) else { continue }
                for cell in cells.dropFirst() {
                    guard let amount = leadingNumber(plainText(cell)) else { continue }
                    let tagged = !factInfo(in: cell, tag: tag).isEmpty
                    rows.append(TableRow(label: label, amount: amount, tagged: tagged))
                    break
                }
            }
            if anchored { out.append(Table(rows: rows, anchored: true)) }
        }
        return out
    }

    private static func cellBodies(in rowHTML: String) -> [String] {
        let ns = NSRange(rowHTML.startIndex..., in: rowHTML)
        return cellPattern.matches(in: rowHTML, range: ns).compactMap { match in
            Range(match.range(at: 1), in: rowHTML).map { String(rowHTML[$0]) }
        }
    }

    /// セルに含まれる、指定タグの ix:nonFraction の contextRef 一覧（無ければ空）。
    private static func factInfo(in cellHTML: String, tag: String) -> [String] {
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

    private static func plainText(_ cellHTML: String) -> String {
        var text = cellHTML.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.htmlEntityDecoded.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func leadingNumber(_ text: String) -> Double? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let match = leadingNumberPattern.firstMatch(in: text, range: ns),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: ""))
    }

    private static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
    }
}
