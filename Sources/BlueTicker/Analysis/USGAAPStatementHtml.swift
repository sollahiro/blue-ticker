// US-GAAP 連結財務諸表 HTML（0105010）→ Statement 行抽出。
//
// EDINET の US-GAAP 連結には ix:nonFraction が無いため、XBRL fact + presentation 経路
// （StatementClassifier）は使えない。開示 HTML テーブルを決定論で読み、
// StatementLineItem として返す（LLM なし。docs/statement.md）。
//
// 現行 summary 用の USGAAPHtml（選択ラベル→仮想タグ）とは別経路。こちらは全データ行を
// 開示ラベルのまま出す（企業間の科目統一はしない）。
//
// `order`: presentation linkbase が無いため、HTML 本表の読み順（上から下）を
// 0 始まりの通し番号で付与する（`XBRLUtils.loadPresentationOrder` の DFS 通し番号と同型）。
// 金額の無い区分見出し行は行にしないため、番号は出力行だけで密になる。
// 科目縦 SS（連結資本勘定変動表）ではその見出しを `section` に載せる。
//
// `components`: calculation linkbase が無いため、キヤノン型（「…合計」の直後内訳が
// 親金額と一致）のときだけ合成 tag で付与する。内訳が合計の前に来る型（富士フイルムの
// 空番号親＋右セル小計）は、足し算で復元できる親なので行にしない。
// 表示ラベルは項番・括弧番号を落とす（分類・is_total は元ラベル）。
// 表分類・残高・合計の語彙は `USGAAPStatementHtmlVocabulary`（次の見出しゆれは語を足す）。

import Foundation
import SwiftSoup

enum USGAAPStatementHtml {

    /// 0105010（無ければ 0104010）から要求セクションの行を抽出する。単位は円。
    /// HTML が無い・行が1つも取れない場合は nil（呼び出し側で notApplicable 等へ倒す）。
    static func extractLineItems(
        in xbrlDir: URL, statementTypes: Set<StatementSectionType>
    ) -> (
        balanceSheet: [StatementLineItem], incomeStatement: [StatementLineItem],
        cashFlow: [StatementLineItem], changesInEquity: [StatementLineItem]
    )? {
        guard let htmlURL = findStatementHtml(in: xbrlDir),
              let content = try? String(contentsOf: htmlURL, encoding: .utf8),
              let soup = try? SwiftSoup.parse(content),
              let tables = try? soup.select("table")
        else { return nil }

        var balanceSheet: [StatementLineItem] = []
        var incomeStatement: [StatementLineItem] = []
        var cashFlow: [StatementLineItem] = []
        var changesInEquity: [StatementLineItem] = []

        var sawBSAssets = false
        var sawBSLiabilities = false
        var sawPL = false
        var sawCF = false
        var pendingSS: [StatementLineItem] = []
        var pendingSSYearColumns: String?

        for table in tables.array() {
            let rows = tableRows(table)
            guard let kind = classifyTable(rows) else { continue }

            switch kind {
            case .bsAssets:
                guard statementTypes.contains(.balanceSheet), !sawBSAssets else { continue }
                let parsed = parseBSRows(rows, startingSection: .assets, startingOrder: balanceSheet.count)
                balanceSheet.append(contentsOf: parsed)
                sawBSAssets = true
            case .bsLiabilitiesAndEquity:
                guard statementTypes.contains(.balanceSheet), !sawBSLiabilities else { continue }
                let parsed = parseBSRows(
                    rows, startingSection: .liabilities, startingOrder: balanceSheet.count)
                balanceSheet.append(contentsOf: parsed)
                sawBSLiabilities = true
            case .incomeStatement:
                guard statementTypes.contains(.incomeStatement), !sawPL else { continue }
                incomeStatement = parseSimpleStatementRows(
                    rows, sectionType: .incomeStatement, sectionForRow: { _ in nil })
                sawPL = true
            case .changesInEquity:
                // キヤノン/小松: 前期表＋当期表が連続 → 最後の表を採用。
                // 野村 連結資本勘定変動表: 科目縦・年次は列で、改ページで株主資本と
                // 非支配持分が別表になる → 同じ年次列の続きだけ追記する。
                guard statementTypes.contains(.changesInEquity), !sawCF else { continue }
                let parsed = parseEquityStatementRows(table)
                let yearCols = equityYearColumnFingerprint(rows)
                if let yearCols, yearCols == pendingSSYearColumns, !pendingSS.isEmpty {
                    pendingSS = concatenatingEquityItems(pendingSS, parsed)
                } else {
                    pendingSS = parsed
                    pendingSSYearColumns = yearCols
                }
            case .cashFlow:
                // 野村: 営業CFと投資/財務CFが別表。最初のCF表で SS を確定し、
                // 投資・財務が揃うまで後続の CF 表を追記する（注記内の同名表は揃った後は無視）。
                let hasInvesting = cashFlow.contains { $0.section == .investing }
                let hasFinancing = cashFlow.contains { $0.section == .financing }
                if sawCF && hasInvesting && hasFinancing { continue }
                if !sawCF && statementTypes.contains(.changesInEquity) {
                    changesInEquity = pendingSS
                }
                if statementTypes.contains(.cashFlow) {
                    let parsed = parseSimpleStatementRows(
                        rows, sectionType: .cashFlow, sectionForRow: cfSection(for:),
                        startingOrder: cashFlow.count)
                    cashFlow.append(contentsOf: parsed)
                }
                sawCF = true
            }
        }

        // CF が無い書類でも、溜めた SS を返す。
        if statementTypes.contains(.changesInEquity), changesInEquity.isEmpty, !pendingSS.isEmpty {
            changesInEquity = pendingSS
        }

        let any =
            (statementTypes.contains(.balanceSheet) && !balanceSheet.isEmpty)
            || (statementTypes.contains(.incomeStatement) && !incomeStatement.isEmpty)
            || (statementTypes.contains(.cashFlow) && !cashFlow.isEmpty)
            || (statementTypes.contains(.changesInEquity) && !changesInEquity.isEmpty)
        guard any else { return nil }
        polishDisplayLabels(&balanceSheet)
        polishDisplayLabels(&incomeStatement)
        polishDisplayLabels(&cashFlow)
        polishDisplayLabels(&changesInEquity)
        return (balanceSheet, incomeStatement, cashFlow, changesInEquity)
    }

    /// components 結線のあとで項番だけ落とす（キヤノン型の番号打ち切りを壊さない）。
    private static func polishDisplayLabels(_ items: inout [StatementLineItem]) {
        for i in items.indices {
            if let label = items[i].label {
                items[i].label = displayLabel(label)
            }
        }
    }

    /// 項番・括弧番号・丸数字を先頭から落とす。西暦と「１株当たり」は残す。
    static func displayLabel(_ label: String) -> String {
        var s = label
        var previous = ""
        while s != previous {
            previous = s
            s = stripOneOutlinePrefix(s)
        }
        return s
    }

    private static let circledNumbers: Set<Unicode.Scalar> = [
        "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
        "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳",
    ]

    private static let parenOutlineRegex = try! NSRegularExpression(
        pattern: #"^[\(（]\s*[0-9０-９]{1,2}\s*[\)）]\s*"#
    )

    /// 注記番号セル（「23」「15,32」「３,26,32」）。カンマ区切りの1〜2桁は
    /// `parseHtmlNumber` が金額（15,32 → 1532）に化けるため、金額スロットの前に除外する。
    private static let footnoteRefRegex = try! NSRegularExpression(
        pattern: #"^[0-9０-９]{1,2}([,，、][0-9０-９]{1,2})*$"#
    )

    private static func stripOneOutlinePrefix(_ label: String) -> String {
        let s = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = NSRange(s.startIndex..., in: s)
        if let match = parenOutlineRegex.firstMatch(in: s, range: full),
           let range = Range(match.range, in: s)
        {
            return s[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        if let first = s.unicodeScalars.first, circledNumbers.contains(first) {
            var rest = String(s.unicodeScalars.dropFirst())
            if rest.first == " " || rest.first == "　" { rest = String(rest.dropFirst()) }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        let afterRoman = USGAAPHtml.stripSectionPrefix(s)
        if afterRoman != s, !afterRoman.isEmpty { return afterRoman }
        return stripArabOutline(s) ?? s
    }

    private static func isArabDigit(_ u: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(u) || ("０"..."９").contains(u)
    }

    private static func stripArabOutline(_ label: String) -> String? {
        let scalars = Array(label.unicodeScalars)
        var i = 0
        while i < scalars.count, i < 2, isArabDigit(scalars[i]) { i += 1 }
        guard (i == 1 || i == 2), i < scalars.count else { return nil }
        let next = scalars[i]
        if next == " " || next == "　" {
            return String(String.UnicodeScalarView(scalars[(i + 1)...]))
                .trimmingCharacters(in: .whitespaces)
        }
        if next == "." || next == "．" {
            var j = i + 1
            while j < scalars.count, scalars[j] == " " || scalars[j] == "　" { j += 1 }
            guard j < scalars.count, scalars[j] != "株" else { return nil }
            return String(String.UnicodeScalarView(scalars[j...]))
                .trimmingCharacters(in: .whitespaces)
        }
        // 「１株当たり」「2024年…」「３ヶ月以内」は項番ではない。
        if next == "株" || next == "年" || next == "月"
            || next == "ヶ" || next == "か" || next == "カ" || next == "箇"
            || next == "," || next == "，"
        {
            return nil
        }
        if isArabDigit(next) { return nil }
        return String(String.UnicodeScalarView(scalars[i...])).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - File discovery

    private static func findStatementHtml(in xbrlDir: URL) -> URL? {
        XBRLUtils.findUSGAAPStatementHtml(in: xbrlDir)
    }

    // MARK: - Table classification

    private enum TableKind {
        case bsAssets
        case bsLiabilitiesAndEquity
        case incomeStatement
        case cashFlow
        case changesInEquity
    }

    /// 本表は 0105010 先頭付近に現れ、注記内の同名語を含む表より先に来る前提で
    /// 「最初の一致のみ採用」する（呼び出し側。CF の分割表だけは追記）。
    /// 分類語彙は `USGAAPStatementHtmlVocabulary`（見出しゆれは語を足す。社名分岐は作らない）。
    private static func classifyTable(_ rows: [[String]]) -> TableKind? {
        let labels = rows.map { rowLabel($0) }.filter { !$0.isEmpty }
        let allCells = rows.flatMap { $0 }.joined(separator: "\n")
        let vocab = USGAAPStatementHtmlVocabulary.self

        if vocab.isCashFlowTable(labels: labels) {
            return .cashFlow
        }

        // SS: 合計列のみ。残高マーカーのゆれは Vocabulary。
        // 信用損失引当金の増減表も期首/期末残高を持つため資本文脈を要求する。
        if isEquityStatementTable(labels: labels, allCells: allCells) {
            return .changesInEquity
        }

        if labels.contains(where: vocab.isAssetsSectionHeader)
            && labels.contains(where: vocab.isAssetsTotalLabel)
        {
            return .bsAssets
        }
        if vocab.isLiabilitiesAndEquityTable(labels: labels) {
            return .bsLiabilitiesAndEquity
        }

        // PL: 売上高＋営業利益、売上高＋当期純利益、収益合計＋当期純利益。OCI 表は除外。
        if vocab.isIncomeStatementTable(labels: labels) {
            return .incomeStatement
        }

        return nil
    }

    /// 持分変動計算書か。資本文脈があり、残高マーカーが期首/期末（または日付残高）として揃う。
    private static func isEquityStatementTable(labels: [String], allCells: String) -> Bool {
        let vocab = USGAAPStatementHtmlVocabulary.self
        guard vocab.hasEquityContext(allCells) else { return false }
        if vocab.isExcludedEquityTable(allCells) { return false }
        return labels.contains { vocab.isEquityBalanceRowLabel($0) }
    }

    // MARK: - Row parsing

    private static func tableRows(_ table: Element) -> [[String]] {
        guard let trs = try? table.select("tr") else { return [] }
        return trs.array().compactMap { tr -> [String]? in
            guard let cells = try? tr.select("td, th"), !cells.isEmpty else { return nil }
            return cells.array().map(cellDisplayText)
        }
    }

    private struct ParsedHtmlRow {
        let indent: Int
        let cells: [String]
    }

    private static func cellDisplayText(_ cell: Element) -> String {
        let text = (try? cell.text(trimAndNormaliseWhitespace: true)) ?? ""
        return text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// `cell.text(trim:)` は先頭の全角空白を落とす。実 HTML の字下げは `<p>　期末残高</p>` にある。
    private static func firstCellRawText(_ cell: Element) -> String {
        if let p = try? cell.select("p").first(), let html = try? p.html() {
            return String(html)
                .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
                .replacingOccurrences(of: "&#160;", with: "\u{00A0}")
        }
        return (try? cell.text(trimAndNormaliseWhitespace: false)) ?? ""
    }

    private static func equityIndent(_ raw: String) -> Int {
        var n = 0
        for ch in raw {
            if ch == "\u{3000}" || ch == "\u{00A0}" {
                n += 1
            } else if ch == " " {
                continue
            } else {
                break
            }
        }
        return n
    }

    private static func parsedTableRows(_ table: Element) -> [ParsedHtmlRow] {
        guard let trs = try? table.select("tr") else { return [] }
        return trs.array().compactMap { tr -> ParsedHtmlRow? in
            guard let cells = try? tr.select("td, th"), !cells.isEmpty else { return nil }
            let firstRaw = cells.array().first.map(firstCellRawText) ?? ""
            return ParsedHtmlRow(indent: equityIndent(firstRaw), cells: cells.array().map(cellDisplayText))
        }
    }

    private static func rowLabel(_ row: [String]) -> String {
        for cell in row {
            let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return ""
    }

    private static func parseBSRows(
        _ rows: [[String]], startingSection: StatementLineSection, startingOrder: Int = 0
    ) -> [StatementLineItem] {
        var section = startingSection
        var order = startingOrder
        var items: [StatementLineItem] = []

        for row in rows {
            let raw = rowLabel(row)
            let label = normalizeLabel(raw)
            guard !label.isEmpty, !isHeaderLabel(label) else { continue }

            if isAssetsSectionHeader(label) {
                section = .assets
                continue
            }
            if isLiabilitiesSectionHeader(label) {
                section = .liabilities
                continue
            }
            if isNetAssetsSectionHeader(label) {
                section = .netAssets
                continue
            }
            if shouldSkipMetaRow(label) { continue }

            guard let yen = currentYenValue(row) else { continue }
            let itemOrder = order
            order += 1
            items.append(
                StatementLineItem(
                    tag: syntheticTag(.balanceSheet, order: itemOrder),
                    label: label,
                    value: yen,
                    unit: "JPY",
                    order: itemOrder,
                    section: isLiabilitiesAndEquityTotalLabel(label) ? nil : section,
                    isTotal: isTotalLabel(label, sectionType: .balanceSheet),
                    components: nil))
        }
        attachCanonStyleFollowingComponents(&items)
        return items
    }

    private static func parseSimpleStatementRows(
        _ rows: [[String]],
        sectionType: StatementSectionType,
        sectionForRow: (String) -> StatementLineSection?,
        startingOrder: Int = 0
    ) -> [StatementLineItem] {
        var order = startingOrder
        var items: [StatementLineItem] = []
        var currentCFSection: StatementLineSection? =
            sectionType == .cashFlow ? .operating : nil
        // PL の「１株当たり情報」節（基本的/希薄化後EPS等）は見出し行自体に金額が無く、
        // 直後の値行のラベルは「基本的」等 見出しを参照しないと分からない場合がある
        // （キヤノン実データ確認済み）。一度立てたら表の残りに適用する（EPS 節は本表末尾）。
        // `hasPrefix`（`contains` ではない）: 「当社株主への配当金 （１株当たり160.00円）」
        // のような金額行の説明文中の「１株当たり」に誤反応しない（キヤノン実データ確認済み）。
        // `stripSectionPrefix` で先頭のローマ数字節番号（「Ⅷ　」等）を落としてから判定する
        // ことで、区分番号付きの見出し（未確認だが実データ上あり得る形）も拾う。
        var inPerShareSection = false

        for row in rows {
            let raw = rowLabel(row)
            let label = normalizeLabel(raw)
            guard !label.isEmpty, !isHeaderLabel(label) else { continue }
            if shouldSkipMetaRow(label) { continue }
            if USGAAPHtml.stripSectionPrefix(label).hasPrefix("１株当たり") { inPerShareSection = true }

            if sectionType == .cashFlow {
                if isCashAndEquivalentsTailRow(label) {
                    // 「現金及び現金同等物」を含む期首/期末残高・為替影響・純増減行は
                    // 営業/投資/財務いずれの区分にも属さない（J-GAAPのXBRL fact経路と同じ扱い）。
                    currentCFSection = nil
                } else if let s = sectionForRow(label) {
                    currentCFSection = s
                }
            }

            let value: Double?
            let unit: String
            if inPerShareSection {
                value = currentMillionYen(from: row)
                // XBRL fact 経路（`StatementClassifier`）の unitRef 慣例に揃える
                // （実データ確認: S100VXJA の基本的EPS fact は unitRef="JPYPerShares"）。
                unit = "JPYPerShares"
            } else {
                value = currentYenValue(row)
                unit = "JPY"
            }
            guard let value else { continue }
            let itemOrder = order
            order += 1
            let section: StatementLineSection? =
                sectionType == .cashFlow ? currentCFSection : nil
            items.append(
                StatementLineItem(
                    tag: syntheticTag(sectionType, order: itemOrder),
                    label: label,
                    value: value,
                    unit: unit,
                    order: itemOrder,
                    section: section,
                    isTotal: inPerShareSection ? false : isTotalLabel(label, sectionType: sectionType),
                    components: nil))
        }
        attachCanonStyleFollowingComponents(&items)
        return items
    }

    /// SS は合計列（純資産合計＝各行の最右セル）のみ。`－`/`-` は 0。
    /// 複行列ヘッダ＋colspan（キヤノン）で列 index がずれるためヘッダ照合はせず最右を使う。
    /// `order` は表の読み順（期首→変動→期末）で 0 始まり。
    ///
    /// 年次切り出しは時系列マーカー（現在残高 / 期末現在 / 日付残高）だけを見る。
    /// 科目縦の連結資本勘定変動表は期首/期末を各科目で繰り返すので、それを
    /// 年次マーカーにすると末尾2行だけ残る。年次は列で分かれている。
    /// その型では金額なしの区分見出し（資本金 等）を `section` に載せ、label は開示どおり。
    ///
    /// 会社によっては1つの表に前期・当期2年分が連続する（実データ確認: 富士フイルム。
    /// キヤノンは表自体が年度ごとに分かれ、呼び出し側が最後の表のみ渡す）。
    /// 「現在残高」行は前期首→前期末=当期首→当期末の順で最低2回、
    /// 2年分が1表に混在する場合は3回以上現れるため、最後から2番目の時系列残高行
    /// （＝当期の期首）より前（前期分）を切り捨てて当期のみを返す。1年度のみの表
    /// （時系列残高2回）では最後から2番目＝期首そのものなので何も切り捨てない。
    private static func parseEquityStatementRows(_ table: Element) -> [StatementLineItem] {
        let parsedRows = parsedTableRows(table)
        let rows = parsedRows.map(\.cells)
        let labels = rows.map { normalizeLabel(rowLabel($0)) }
        if isComponentMajorEquityTable(labels, rows) {
            return parseComponentMajorEquityRows(parsedRows)
        }

        var raw: [(label: String, value: Double)] = []
        for row in rows {
            let rawLabel = rowLabel(row)
            let label = normalizeLabel(rawLabel)
            guard !label.isEmpty, !isHeaderLabel(label) else { continue }
            if shouldSkipMetaRow(label) { continue }
            guard let last = row.last, let million = parseAmountSlot(last) else { continue }
            raw.append((label, million * Financial.millionYen))
        }

        let chronoIndices = raw.indices.filter { isEquityChronologicalBalanceLabel(raw[$0].label) }
        let startIndex = chronoIndices.count >= 2 ? chronoIndices[chronoIndices.count - 2] : 0

        var order = 0
        var items: [StatementLineItem] = []
        for entry in raw[startIndex...] {
            let itemOrder = order
            order += 1
            items.append(
                StatementLineItem(
                    tag: syntheticTag(.changesInEquity, order: itemOrder),
                    label: entry.label,
                    value: entry.value,
                    unit: "JPY",
                    order: itemOrder,
                    section: nil,
                    isTotal: isTotalLabel(entry.label, sectionType: .changesInEquity),
                    components: nil))
        }
        attachCanonStyleFollowingComponents(&items)
        return items
    }

    /// 科目が行・年度が列の資本勘定変動表（野村）。金額なしの見出し行を `section` に載せる。
    private static func isComponentMajorEquityTable(_ labels: [String], _ rows: [[String]]) -> Bool {
        let hasBarePeriod = labels.contains { isBareEquityOpenCloseLabel($0) }
        let hasChrono = labels.contains { isEquityChronologicalBalanceLabel($0) }
        return hasBarePeriod && !hasChrono && equityYearColumnFingerprint(rows) != nil
    }

    /// 金額セルが無く、科目見出しだけ（資本金・資本剰余金・累積的その他の包括利益 等）。
    private static func isEquityGroupHeaderRow(_ label: String, cells: [String]) -> Bool {
        guard !label.isEmpty else { return false }
        if isEquityChronologicalBalanceLabel(label) { return false }
        if isBareEquityOpenCloseLabel(label) { return false }
        if label.contains("年") && label.contains("期") { return false }
        return cells.dropFirst().allSatisfy { parseAmountSlot($0) == nil }
    }

    private static func parseComponentMajorEquityRows(_ parsedRows: [ParsedHtmlRow]) -> [StatementLineItem] {
        var headerStack: [(level: Int, label: String)] = []
        var order = 0
        var items: [StatementLineItem] = []
        for parsedRow in parsedRows {
            let label = normalizeLabel(rowLabel(parsedRow.cells))
            if label.isEmpty { continue }
            if isHeaderLabel(label) || shouldSkipMetaRow(label) { continue }

            if isEquityGroupHeaderRow(label, cells: parsedRow.cells) {
                headerStack.removeAll { $0.level >= parsedRow.indent }
                headerStack.append((parsedRow.indent, label))
                continue
            }

            headerStack.removeAll { $0.level >= parsedRow.indent }
            guard let last = parsedRow.cells.last, let million = parseAmountSlot(last) else { continue }
            let groupHeading =
                headerStack.last(where: { $0.level < parsedRow.indent })?.label
                ?? headerStack.last?.label
            let itemOrder = order
            order += 1
            items.append(
                StatementLineItem(
                    tag: syntheticTag(.changesInEquity, order: itemOrder),
                    label: label,
                    value: million * Financial.millionYen,
                    unit: "JPY",
                    order: itemOrder,
                    section: groupHeading.map { .group($0) },
                    isTotal: isTotalLabel(label, sectionType: .changesInEquity),
                    components: nil))
        }
        attachCanonStyleFollowingComponents(&items)
        return items
    }

    private static func concatenatingEquityItems(
        _ existing: [StatementLineItem], _ more: [StatementLineItem]
    ) -> [StatementLineItem] {
        var combined = existing
        combined.append(contentsOf: more)
        for i in combined.indices {
            combined[i].order = i
            combined[i].tag = syntheticTag(.changesInEquity, order: i)
        }
        return combined
    }

    /// 年次が列になっている SS 表の列指紋。一致する続き表だけ追記する。
    private static func equityYearColumnFingerprint(_ rows: [[String]]) -> String? {
        let periods = rows.prefix(4).flatMap { $0 }.map { normalizeLabel($0) }.filter {
            $0.contains("年") && $0.contains("期") && !$0.contains("資本")
        }
        guard periods.count >= 2 else { return nil }
        return periods.joined(separator: "|")
    }

    /// キヤノン型: 「…合計」行の直後に内訳が続き、その合計が親と一致するとき `components` を付与する。
    ///
    /// J-GAAP/IFRS の calculation linkbase 相当を HTML から推定する。親が番号付き
    /// （`１` / `Ⅰ` 等）のときは次の同型番号行で打ち切る。内訳が合計の**前**に来る型
    /// （富士フイルムの流動資産合計など、および多くのセクション合計）は対象外
    /// （先行行合算は別ヒューリスティックになり誤結線しやすいため、ここでは足さない）。
    private static func attachCanonStyleFollowingComponents(_ items: inout [StatementLineItem]) {
        guard !items.isEmpty else { return }
        for i in items.indices {
            let label = items[i].label ?? ""
            guard items[i].isTotal, label.contains("合計") else { continue }

            var childIndices: [Int] = []
            var j = i + 1
            while j < items.count {
                let childLabel = items[j].label ?? ""
                if items[j].isTotal { break }
                if items[j].unit != items[i].unit { break }
                if leadingMajorMarker(label) != nil, leadingMajorMarker(childLabel) != nil {
                    break
                }
                childIndices.append(j)
                j += 1
            }
            guard !childIndices.isEmpty else { continue }

            let childSum = childIndices.reduce(0.0) { $0 + items[$1].value }
            // childSum == 0 は「－」（未開示・非該当）多用行が偶然一致しただけの誤結線が
            // 起きやすいため対象外にする（親も0のケースは実データ上ここでは確認されていない）。
            guard childSum != 0, abs(childSum - items[i].value) < 0.5 else { continue }

            items[i].components = childIndices.map {
                StatementLineComponent(tag: items[$0].tag, weight: 1)
            }
        }
    }

    /// 行頭の大区分番号（`１` / `1` / `Ⅰ` 等）。`(1)` や番号なし内訳は nil。
    private static func leadingMajorMarker(_ label: String) -> String? {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.unicodeScalars.first else { return nil }

        func isArab(_ u: Unicode.Scalar) -> Bool {
            ("0"..."9").contains(u) || ("０"..."９").contains(u)
        }
        let roman: Set<Unicode.Scalar> = [
            "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ", "Ⅸ", "Ⅹ",
        ]

        let scalars = Array(t.unicodeScalars)
        if isArab(first) {
            var i = 1
            while i < scalars.count, isArab(scalars[i]) { i += 1 }
            guard i < scalars.count, scalars[i] == " " || scalars[i] == "　" else { return nil }
            return String(String.UnicodeScalarView(scalars[0..<i]))
        }
        if roman.contains(first) {
            var i = 1
            while i < scalars.count, roman.contains(scalars[i]) { i += 1 }
            guard i < scalars.count, scalars[i] == " " || scalars[i] == "　" else { return nil }
            return String(String.UnicodeScalarView(scalars[0..<i]))
        }
        return nil
    }

    /// BS/PL/CF 行の当期金額（円）。
    ///
    /// 富士フイルム形式は「前期左・前期右・当期左・当期右」の4スロットで、明細行は左が当該科目、
    /// 右が親の小計/累計になる（例: 信用損失引当金 △15,841 / 受取債権合計 699,986）。
    /// 単純行は右だけに金額が入る。キヤノン形式の構成比列も「左=金額・右=%」のため同じ優先で良い。
    /// `－` は 0。空欄はスキップ。`filterFinancialTableAmounts` は使わない（小さい当期額が落ちるため）。
    private static func currentYenValue(_ row: [String]) -> Double? {
        currentLineAndGroupSubtotal(from: row)?.line
    }

    /// 当期左＝当該科目。当期半分に2つ目の値があれば親小計（富士フイルム入れ子の右セル）。
    private static func currentLineAndGroupSubtotal(from row: [String]) -> (
        line: Double, groupSubtotal: Double?
    )? {
        guard let million = currentMillionYenSlots(from: row) else { return nil }
        return (
            million.line * Financial.millionYen,
            million.groupSubtotal.map { $0 * Financial.millionYen }
        )
    }

    private static func currentMillionYen(from row: [String]) -> Double? {
        currentMillionYenSlots(from: row)?.line
    }

    private static func currentMillionYenSlots(from row: [String]) -> (
        line: Double, groupSubtotal: Double?
    )? {
        guard let labelIdx = row.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        let rest = stripLeadingNoteSpacersKeepingEvenCount(Array(row[(labelIdx + 1)...]))
        let slots = rest.map { parseAmountSlot($0) }
        guard !slots.isEmpty else { return nil }
        // 前期/当期のスロット数が揃わない（想定外の列構成）場合は前期/当期の
        // 折り返し位置を保証できないため、誤った値を返すより nil で失敗させる。
        guard slots.count % 2 == 0 else { return nil }

        // 前期半分 | 当期半分。
        let mid = slots.count / 2
        let currentHalf = Array(slots[mid...])
        let filled = currentHalf.compactMap { $0 }
        guard let line = filled.first else { return nil }
        let group = filled.count >= 2 ? filled[1] : nil
        return (line, group)
    }

    /// ラベル直後の空スペーサ／注記番号セルを、前期/当期の偶数スロットが残る範囲でのみ剥がす。
    ///
    /// 富士フイルム「５ 短期オペレーティング・リース負債」は空+「注５」の2連続。
    /// オムロン CF「１　当期純利益」は4スロットの左が空（値は右セル）で、空1個を剥がすと
    /// 奇数になり行ごと落ちる。空をスペーサとみなすのは、剥がしたあと偶数が残るときに限る。
    /// 2個目以降が「空」なだけなら前期/当期グリッド内の正当な空スロットのため剥がさない
    /// （実データ確認: 富士フイルム「流動資産合計」）。
    private static func stripLeadingNoteSpacersKeepingEvenCount(_ cells: [String]) -> [String] {
        guard let first = cells.first, isNoteOrNonAmountCell(first) else { return cells }
        if cells.count >= 2, cells[1].contains("注") {
            let afterNote = Array(cells.dropFirst(2))
            if afterNote.count % 2 == 0 { return afterNote }
        }
        let afterOne = Array(cells.dropFirst())
        if afterOne.count % 2 == 0 { return afterOne }
        return cells
    }

    /// セルを金額スロットにする。`－` 類は 0、空・注記・非数値は nil。
    private static func parseAmountSlot(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if ["－", "-", "―", "—", "─"].contains(t) { return 0 }
        return XBRLUtils.parseHtmlNumber(t)
    }

    private static func isNoteOrNonAmountCell(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.contains("注") { return true }
        if isFootnoteRefCell(t) { return true }
        if parseAmountSlot(t) != nil { return false }
        return true
    }

    /// 注記番号列の「15,32」や単独の「23」。空白を潰してから照合する。
    private static func isFootnoteRefCell(_ text: String) -> Bool {
        let collapsed = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard !collapsed.isEmpty else { return false }
        let full = NSRange(collapsed.startIndex..., in: collapsed)
        return footnoteRefRegex.firstMatch(in: collapsed, range: full) != nil
    }

    // MARK: - Label / section helpers（語彙は `USGAAPStatementHtmlVocabulary`）

    private static func normalizeLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: "　", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }

    private static func isHeaderLabel(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isHeaderLabel(label)
    }

    private static func isAssetsSectionHeader(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isAssetsSectionHeader(label)
    }

    private static func isLiabilitiesSectionHeader(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isLiabilitiesSectionHeader(label)
    }

    /// 負債と資本を束ねるグランドトータル。複数区分にまたがるので section は付けない。
    private static func isLiabilitiesAndEquityTotalLabel(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isLiabilitiesAndEquityTotalLabel(label)
    }

    private static func isNetAssetsSectionHeader(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isNetAssetsSectionHeader(label)
    }

    /// SS の期首/期末（または日付）残高行。分類と is_total で使う。
    /// 年次切り出しは `isEquityChronologicalBalanceLabel` のみ（科目縦の繰り返し
    /// 期首/期末は年次ではない）。
    private static func isEquityBalanceRowLabel(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isEquityBalanceRowLabel(label)
    }

    /// 1表に前期・当期が連続するときの切り出しマーカー。日付や「現在」が付く行だけ。
    private static func isEquityChronologicalBalanceLabel(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isEquityChronologicalBalanceLabel(label)
    }

    private static func isBareEquityOpenCloseLabel(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isBareEquityOpenCloseLabel(label)
    }

    private static func shouldSkipMetaRow(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.shouldSkipMetaRow(label)
    }

    private static func cfSection(for label: String) -> StatementLineSection? {
        USGAAPStatementHtmlVocabulary.cfSection(for: label)
    }

    /// 財務活動の後に続く「現金及び現金同等物」関連行（為替影響・純増減・期首/期末残高）。
    /// 投資活動の明細（現金同等物控除後）と区別するため、残高・純増減・為替語を併せて要求する。
    private static func isCashAndEquivalentsTailRow(_ label: String) -> Bool {
        USGAAPStatementHtmlVocabulary.isCashAndEquivalentsTailRow(label)
    }

    private static func isTotalLabel(_ label: String, sectionType: StatementSectionType) -> Bool {
        USGAAPStatementHtmlVocabulary.isTotalLabel(label, sectionType: sectionType)
    }

    private static func syntheticTag(_ section: StatementSectionType, order: Int) -> String {
        let prefix: String
        switch section {
        case .balanceSheet: prefix = "USGAAP_HTML_BS"
        case .incomeStatement: prefix = "USGAAP_HTML_PL"
        case .cashFlow: prefix = "USGAAP_HTML_CF"
        case .changesInEquity: prefix = "USGAAP_HTML_SS"
        }
        return "\(prefix)_\(order)"
    }
}
