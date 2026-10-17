// 従業員数の内訳: 「連結会社の状況」表で iXBRL の fact が付いていない行を、分母との差額に
// 整数一致するときだけ reconciling 行として補う。
//
// 会社によっては表の一部の行（例: イオンの「純粋持株会社等」）に ix:nonFraction が付かず、
// dimension 付き fact だけを読む `BreakdownNormalizer.normalizeEmployees` では行が落ちる
// （行の和が分母を下回る）。同じ表の中で fact が付いた行と並ぶ未タグ行に限り、値は開示の
// セルそのまま。未タグ行の合計が差額とぴったり一致しなければ何も足さない（値を作らない）。
// 全社（共通）が member 付きで開示される会社は差額が 0 のため、この経路は動かない。
// 行の種別は、本社・全社共通・持株会社などのバケツ語を含めば reconciling、それ以外は segment。
// セグメント member の fact が1つも無く合計だけにタグが付く表は `fromTotalOnlyTable` が読む（8354）。

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

    /// セグメント member 付きの fact が1つも無く、表の全社合計だけにタグが付く会社
    ///（8354 ふくおかFG: 銀行業務 6,895 / その他事業 1,155 / 合計 8,050 の横並び表）。
    /// 当期連結の合計セル（`CurrentYearInstant`）と同じ行（横並び）または同じ列（縦並び）の未タグ値が
    /// 2 つ以上あり、和が合計とぴったり一致する表を候補にする（値は開示のセルそのまま）。
    /// 行がセグメント別か（部門別・製品区分別・会社別でないか）は Jev が判定する（3 回一致・0.9）。
    /// 見出し・データ行の結合でずれる表、ラベル列と値の列の間に別のラベル列がある表
    ///（5985 サンコール S100LIN3: 製品区分の名称 / セグメントの名称 / 従業員数）は候補にしない。
    /// キーが無い・合意できないときは行を作らない（not_found のまま）。
    static func fromTotalOnlyTable(
        total: Double?, xbrlDir: URL, segmentLabels: [String],
        decider: (any EmployeesTableDeciding)?, docID: String
    ) async -> BreakdownSnapshot? {
        guard let total, total > 0, let decider else { return nil }
        for tag in Xbrl.employeeTags {
            for html in htmlFiles(in: xbrlDir, containing: tag) {
                for table in totalOnlyTables(html: html, tag: tag, total: total) {
                    // セグメント注記にセグメント名があるのに、表の行がどれとも重ならないときは聞かない。
                    if !segmentLabels.isEmpty, !rowsOverlapSegmentLabels(table.rows, segmentLabels) { continue }
                    let decision = await EmployeesTableJev.decide(
                        table: table, segmentLabels: segmentLabels, decider: decider, docID: docID)
                    guard decision.selectedKey == EmployeesTableJev.segmentsKey else { continue }
                    return BreakdownSnapshot(
                        axis: breakdownAxisEmployees, denominator: total, denominatorTag: tag,
                        rows: table.rows.map {
                            BreakdownRow(
                                labelRaw: $0.label, label: $0.label, amount: $0.amount,
                                share: $0.amount / total, profit: nil, rowKind: rowKind(forLabel: $0.label))
                        },
                        sourceKind: "xbrl_facts", needsReview: false, warnings: [])
                }
            }
        }
        return nil
    }

    static let totalOnlyContextRef = "CurrentYearInstant"

    /// 行ラベルのどれかがセグメント名を含む、またはセグメント名に含まれるか（空白・中黒は無視）。
    static func rowsOverlapSegmentLabels(_ rows: [TableRow], _ segmentLabels: [String]) -> Bool {
        let segments = segmentLabels.map(compact).filter { !$0.isEmpty }
        return rows.contains { row in
            let key = compact(row.label)
            return !key.isEmpty && segments.contains { $0.contains(key) || key.contains($0) }
        }
    }

    /// 合計だけタグの表から読んだ候補。`header` はラベル列の見出し（無ければ空）。
    struct TotalOnlyTable: Equatable, Sendable {
        var header: String
        var rows: [TableRow]
    }

    private struct GridRow {
        var cells: [String]
        var colspanned: Bool
        var rowspanned: Bool
    }

    /// 純関数。`fromTotalOnlyTable` の表読み（構造と和の一致だけ。セグメント別かは見ない）。
    static func totalOnlyTables(html: String, tag: String, total: Double) -> [TotalOnlyTable] {
        var out: [TotalOnlyTable] = []
        let whole = NSRange(html.startIndex..., in: html)
        for tableMatch in tablePattern.matches(in: html, range: whole) {
            guard let tableRange = Range(tableMatch.range, in: html) else { continue }
            let tableHTML = String(html[tableRange])
            guard tableHTML.contains(tag) else { continue }
            let grid = gridRows(in: tableHTML)
            for (r, row) in grid.enumerated() {
                for (c, cell) in row.cells.enumerated()
                where factInfo(in: cell, tag: tag) == [totalOnlyContextRef]
                    && leadingNumber(plainText(cell)) == total
                {
                    let candidates = [
                        horizontalRows(grid: grid, row: r, totalColumn: c, tag: tag),
                        verticalRows(grid: grid, row: r, totalColumn: c, tag: tag),
                    ].compactMap { $0 }
                    for candidate in candidates where candidate.rows.count >= 2 {
                        let sum = candidate.rows.reduce(0.0) { $0 + $1.amount }
                        if abs(sum - total) < equalityEpsilon, !out.contains(candidate) {
                            out.append(candidate)
                        }
                    }
                }
            }
        }
        return out
    }

    /// 合計セルと同じ行の未タグ値。ラベルは同じ列数の直近の見出し行。
    private static func horizontalRows(grid: [GridRow], row r: Int, totalColumn c: Int, tag: String) -> TotalOnlyTable? {
        let data = grid[r]
        // データ行自身の rowspan（下の［臨時］行へ伸びる先頭セル、8354）は自分の列をずらさない。
        // 見出し行の結合と、見出しとデータの間の行の rowspan はずれるので読まない。
        guard !data.colspanned,
              let h = grid[..<r].lastIndex(where: { $0.cells.count == data.cells.count }),
              !grid[h].colspanned, !grid[h].rowspanned,
              !grid[(h + 1)..<r].contains(where: \.rowspanned)
        else { return nil }
        let header = grid[h]
        var out: [TableRow] = []
        for i in 1..<data.cells.count where i != c {
            guard factInfo(in: data.cells[i], tag: tag).isEmpty,
                  let amount = leadingNumber(plainText(data.cells[i])), amount > 0
            else { continue }
            let label = plainText(header.cells[i])
            let key = compact(label)
            guard containsJapanese(label), !isTotalOrMeasureLabel(key) else { return nil }
            out.append(TableRow(label: label, amount: amount, tagged: false))
        }
        return TotalOnlyTable(header: plainText(header.cells[0]), rows: out)
    }

    /// 合計セルと同じ列の未タグ値。ラベルは各行の先頭セル。ラベル列と値の列の間に
    /// 別のラベル列（製品区分など）があるときは読まない。
    private static func verticalRows(grid: [GridRow], row r: Int, totalColumn c: Int, tag: String) -> TotalOnlyTable? {
        guard c >= 1 else { return nil }
        var out: [TableRow] = []
        var firstDataRow: Int?
        for (i, row) in grid.enumerated() where i != r && c < row.cells.count {
            guard factInfo(in: row.cells[c], tag: tag).isEmpty,
                  let amount = leadingNumber(plainText(row.cells[c])), amount > 0
            else { continue }
            let label = plainText(row.cells[0])
            let key = compact(label)
            guard containsJapanese(label), !key.isEmpty, !isTotalOrMeasureLabel(key) else { continue }
            guard !row.colspanned, !row.cells[1..<c].contains(where: { containsJapanese(plainText($0)) })
            else { return nil }
            if firstDataRow == nil { firstDataRow = i }
            out.append(TableRow(label: label, amount: amount, tagged: false))
        }
        guard let firstDataRow else { return nil }
        let header = grid[..<firstDataRow].last(where: { c < $0.cells.count })
        if let header, header.colspanned
            || header.cells[1..<c].contains(where: { containsJapanese(plainText($0)) })
        {
            return nil
        }
        return TotalOnlyTable(header: header.map { plainText($0.cells[0]) } ?? "", rows: out)
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
        htmlFiles(in: dir, containing: tag).flatMap {
            parseTables(html: $0, tag: tag, anchorRefs: anchorRefs)
        }
    }

    private static func htmlFiles(in dir: URL, containing tag: String) -> [String] {
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

    private static func gridRows(in tableHTML: String) -> [GridRow] {
        let ns = NSRange(tableHTML.startIndex..., in: tableHTML)
        return rowPattern.matches(in: tableHTML, range: ns).compactMap { match in
            Range(match.range, in: tableHTML).map { range in
                let rowHTML = String(tableHTML[range])
                let lower = rowHTML.lowercased()
                return GridRow(
                    cells: cellBodies(in: rowHTML),
                    colspanned: lower.contains("colspan"), rowspanned: lower.contains("rowspan"))
            }
        }
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
