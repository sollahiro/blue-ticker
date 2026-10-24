// 関係（顧客・グループ会社・出資先・大株主）の抽出。材料は最新有報 1 件の XBRL。
// - 主要な顧客ごとの情報（`InformationForEachOfMainCustomersTextBlock`、当期 context の HTML 表）
// - 関係会社の状況（`OverviewOfAffiliatedEntitiesTextBlock`、HTML 表。区分は決定論で取り、
//   決まらない表だけ Jev の選択式。`RelationKindJev`）
// - 提出会社の親会社等の情報（`InformationAboutParentCompanyEtcOfReportingCompanyTextBlock`。表があれば親会社）
// - 政策保有株式（特定投資株式・みなし保有株式の銘柄別タグ。当期 `CurrentYearInstant_Row{N}Member`）
// - 大株主の状況（`NameMajorShareholders` 等。当期 `CurrentYearInstant_No{N}MajorShareholdersMember`）
// 社名を直書きした辞書・例外は作らない。区分語・法人格語・単位語などの一般規則だけを使う。

import Foundation
import SwiftSoup

#if canImport(FoundationXML)
    import FoundationXML
#endif

enum CompanyRelationsExtractor {
    static let mainCustomersTag = "InformationForEachOfMainCustomersTextBlock"
    static let affiliatedEntitiesTag = "OverviewOfAffiliatedEntitiesTextBlock"
    static let parentCompanyInfoTag = "InformationAboutParentCompanyEtcOfReportingCompanyTextBlock"

    /// 区分が決定論で決まらなかった関係会社表 1 つ分（Jev に渡す）。`rowIndices` は抽出行の添字。
    struct PendingGroupTable: Sendable, Equatable {
        var rowIndices: [Int]
        var header: [String]
        var rows: [[String]]
        var precedingText: String
        var followingText: String
    }

    struct Result: Sendable, Equatable {
        var extraction: CompanyRelationsExtraction
        var pendingGroupTables: [PendingGroupTable]
    }

    /// 書類 1 件分を抽出する（Jev は呼ばない。区分の決まらない行は `unclassified`・`needs_review`）。
    static func extract(xbrlDir: URL) -> Result {
        var rows: [CompanyRelationDraft] = []
        rows += extractMainCustomers(xbrlDir: xbrlDir)
        let group = extractAffiliatedEntities(xbrlDir: xbrlDir, rowOffset: rows.count)
        rows += group.rows
        rows += extractParentCompanyInfo(xbrlDir: xbrlDir)
        rows += extractPolicyHoldings(xbrlDir: xbrlDir)
        rows += extractMajorShareholders(xbrlDir: xbrlDir)
        let warnings = readOverlayRegressions(in: xbrlDir).map(\.warningToken)
        return Result(
            extraction: CompanyRelationsExtraction(
                rows: rows, fyEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir),
                warnings: warnings),
            pendingGroupTables: group.pending)
    }

    // MARK: - 主要な顧客

    static func extractMainCustomers(xbrlDir: URL) -> [CompanyRelationDraft] {
        let blocks = textBlocksByContext(in: xbrlDir, tag: mainCustomersTag)
        guard let html = currentPeriodBlock(blocks) else {
            return [.status(section: relationSectionMainCustomers, relationSectionStatusNotFound)]
        }
        let rows = parseMainCustomers(html: html)
        if !rows.isEmpty { return rows }
        return [.status(section: relationSectionMainCustomers, omissionStatus(html))]
    }

    /// 顧客表 HTML（TextBlock 1 つ）から行を作る。表が無い・顧客列が無いときは空。
    static func parseMainCustomers(html: String) -> [CompanyRelationDraft] {
        let segments = splitTables(html)
        let candidates = segments.enumerated().compactMap { index, segment -> (Int, CustomerTable)? in
            guard let table = segment.table, let parsed = customerTable(table.grid) else { return nil }
            return (index, parsed)
        }
        guard !candidates.isEmpty else { return [] }
        // 前期・当期の 2 表が 1 つの TextBlock にあるときは当期だけ（直前の見出しで判定。無ければ最後の表）。
        let chosen: [(Int, CustomerTable)]
        if candidates.count >= 2 {
            let current = candidates.filter { index, _ in
                isCurrentPeriodHeading(segments[index].precedingText)
            }
            chosen = current.isEmpty ? [candidates[candidates.count - 1]] : current
        } else {
            chosen = candidates
        }
        var result: [CompanyRelationDraft] = []
        for (index, table) in chosen {
            let unitText = segments[index].precedingText + " " + table.header.joined(separator: " ")
            let tableUnit = amountUnitMultiplier(in: unitText)
                ?? amountUnitMultiplier(in: table.grid.prefix(table.headerRow).flatMap { $0 }.joined(separator: " "))
            for row in table.body {
                let name = cleanCounterpartyName(row[table.nameColumn])
                guard isCounterpartyName(name) else { continue }
                var amount: Double?
                if let col = table.amountColumn {
                    let cell = row[col]
                    if let value = XBRLUtils.parseHtmlNumber(compactCell(cell)) {
                        let unit = amountUnitMultiplier(inCell: cell) ?? tableUnit
                        amount = unit.map { value * $0 }
                    }
                }
                let segment = table.segmentColumn.map { compactLabel(row[$0]) }.flatMap {
                    $0.isEmpty || isDash($0) ? nil : $0
                }
                // 相手先・金額を rowspan で縦に結合し、セグメントだけを行ごとに書いた表は 1 行にまとめる。
                if let last = result.last, last.nameRaw == name, last.amountYen == amount {
                    if let segment, !(last.segmentLabel ?? "").split(separator: "、").contains(Substring(segment)) {
                        result[result.count - 1].segmentLabel =
                            last.segmentLabel.map { $0 + "、" + segment } ?? segment
                    }
                    continue
                }
                result.append(
                    CompanyRelationDraft(
                        section: relationSectionMainCustomers, kind: relationKindCustomer,
                        position: result.count, nameRaw: name, amountYen: amount,
                        segmentLabel: segment))
            }
        }
        return result
    }

    struct CustomerTable {
        var grid: [[String]]
        var headerRow: Int
        var nameColumn: Int
        var amountColumn: Int?
        var segmentColumn: Int?
        var header: [String] { grid[headerRow] }
        var body: ArraySlice<[String]> { grid[(headerRow + 1)...] }
    }

    private static let customerHeaderWords = ["顧客", "相手先", "販売先", "得意先"]

    static func customerTable(_ grid: [[String]]) -> CustomerTable? {
        for (r, row) in grid.enumerated() {
            guard let nameCol = row.firstIndex(where: { cell in
                let c = compactCell(cell)
                return customerHeaderWords.contains { c.contains($0) }
            }) else { continue }
            let amountCol = row.indices.first { c in
                c != nameCol && ["売上", "金額", "収益", "販売高", "取引高"].contains {
                    compactCell(row[c]).contains($0)
                }
            }
            let segmentCol = row.indices.first { c in
                c != nameCol && compactCell(row[c]).contains("セグメント")
            }
            guard r + 1 < grid.count else { return nil }
            return CustomerTable(
                grid: grid, headerRow: lastHeaderRow(grid, from: r, nameColumn: nameCol),
                nameColumn: nameCol, amountColumn: amountCol, segmentColumn: segmentCol)
        }
        return nil
    }

    /// rowspan で見出しが続く行（名称列が同じ文字列）までを見出しとみなす。
    private static func lastHeaderRow(_ grid: [[String]], from row: Int, nameColumn: Int) -> Int {
        var last = row
        while last + 1 < grid.count, grid[last + 1][nameColumn] == grid[row][nameColumn] {
            last += 1
        }
        return last
    }

    // MARK: - 関係会社の状況

    struct GroupExtraction {
        var rows: [CompanyRelationDraft]
        var pending: [PendingGroupTable]
    }

    static func extractAffiliatedEntities(xbrlDir: URL, rowOffset: Int = 0) -> GroupExtraction {
        let blocks = textBlocksByContext(in: xbrlDir, tag: affiliatedEntitiesTag)
        guard let html = filingDateBlock(blocks) else {
            return GroupExtraction(
                rows: [.status(section: relationSectionAffiliatedEntities, relationSectionStatusNotFound)],
                pending: [])
        }
        var parsed = parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        if parsed.rows.isEmpty {
            return GroupExtraction(
                rows: [.status(section: relationSectionAffiliatedEntities, omissionStatus(html))],
                pending: [])
        }
        for i in parsed.pending.indices {
            parsed.pending[i].rowIndices = parsed.pending[i].rowIndices.map { $0 + rowOffset }
        }
        return parsed
    }

    /// 関係会社表（TextBlock 1 つ）から行を作る。区分は ①表内の区分見出し行 ②名称の頭の「（連結子会社）」等
    /// ③表の外の直前の短い見出し の順に決定論で取る。どれも無い表は `unclassified` で `pending` に積む。
    /// `defaultKind` は親会社等の情報のように節そのものが区分を決める場合だけ渡す。
    static func parseAffiliatedEntities(
        html: String, section: String, defaultKind: String?
    ) -> GroupExtraction {
        let segments = splitTables(html)
        var rows: [CompanyRelationDraft] = []
        var pending: [PendingGroupTable] = []
        var previous: GroupTableLayout?
        var carriedKind: String?
        for (index, segment) in segments.enumerated() {
            guard let table = segment.table else { continue }
            let outsideKind = outsideHeadingKind(segment.precedingParagraphs)
            let layout: GroupTableLayout
            var bodyStart: Int
            // 関係会社表の下に付く「主要な損益情報等」の表（列数が同じでも続きの表ではない）。
            // 議決権の列を持つ表の右端の列に損益情報があるだけなら関係会社表として読む。
            let found = groupTableLayout(table.grid)
            if found?.ownedRatioColumn == nil, isFinancialInfoTable(table.grid) {
                previous = nil
                carriedKind = nil
                continue
            }
            if let found {
                layout = found
                bodyStart = found.headerRow + 1
                // 改ページで見出し行だけを繰り返した続きの表は、前の表の区分を引き継ぐ。
                if previous.map({ $0.header.map(compactLabel) }) != found.header.map(compactLabel) {
                    carriedKind = nil
                }
            } else if let previous, table.columnCount == previous.columnCount, previous.columnCount >= 4 {
                // 改ページで見出しの無い続きの表（列数が同じ）。
                layout = previous
                bodyStart = 0
            } else {
                previous = nil
                carriedKind = nil
                continue
            }
            previous = layout
            var headingKind = outsideKind ?? carriedKind
            var previousRawName: String?
            var pendingRows: [Int] = []
            var pendingCells: [[String]] = []
            while bodyStart < table.grid.count {
                let row = table.grid[bodyStart]
                bodyStart += 1
                let rawName = row[layout.nameColumn]
                if let kind = headingRowKind(row, nameColumn: layout.nameColumn) {
                    headingKind = kind
                    continue
                }
                // 全列にまたがる見出し（「●探鉱・開発・生産等」）は相手ではない。
                if isSpanningLabelRow(row) { continue }
                var (prefixKind, name) = stripKindPrefix(rawName)
                // 「（持分法適用会社）澤藤電機㈱」のように区分の先頭行の名称に付いた区分語は、次の区分までの行にも効く。
                if let prefixKind { headingKind = prefixKind }
                name = cleanCounterpartyName(name)
                guard isCounterpartyName(name), name != compactLabel(layout.headerName) else { continue }
                let kind = headingKind ?? defaultKind
                let isPassive = kind == relationKindParent || kind == relationKindOtherRelated
                let ratioColumn = isPassive ? layout.passiveRatioColumn : layout.ownedRatioColumn
                let ratio = ratioColumn.flatMap { votingRatioCell(row[$0]) } ?? VotingRatioCell()
                // 名称を縦に結合した 2 段目の行（「52.6」の下の段に「(0.1)」）は、前の行の議決権の続き。
                if let last = rows.indices.last, previousRawName == rawName, rows[last].section == section {
                    rows[last].votingRatio = rows[last].votingRatio ?? ratio.total
                    rows[last].votingRatioIndirect = rows[last].votingRatioIndirect ?? ratio.indirect
                    rows[last].votingRatioCloseParties = rows[last].votingRatioCloseParties ?? ratio.closeParties
                    continue
                }
                previousRawName = rawName
                let business = layout.businessColumn.map { compactLabel(row[$0]) }.flatMap {
                    $0.isEmpty || isDash($0) ? nil : $0
                }
                var draft = CompanyRelationDraft(
                    section: section, kind: kind ?? relationKindUnclassified,
                    position: rows.count, nameRaw: name, segmentLabel: business, votingRatio: ratio.total,
                    votingRatioIndirect: ratio.indirect, votingRatioCloseParties: ratio.closeParties)
                if kind == nil {
                    draft.decidedBy = relationDecidedByJev
                    draft.needsReview = true
                    pendingRows.append(rows.count)
                    pendingCells.append(row.map(compactLabel))
                }
                rows.append(draft)
            }
            carriedKind = headingKind
            if !pendingRows.isEmpty {
                pending.append(
                    PendingGroupTable(
                        rowIndices: pendingRows, header: layout.header.map(compactLabel),
                        rows: pendingCells,
                        precedingText: segment.precedingParagraphs.joined(separator: "\n"),
                        followingText: segments.indices.contains(index + 1)
                            ? segments[index + 1].precedingParagraphs.joined(separator: "\n") : ""))
            }
        }
        return GroupExtraction(rows: rows, pending: pending)
    }

    /// 議決権の割合のセル。`total` は間接所有を含む合計、`indirect` は（ ）の内数、`closeParties` は［ ］の外数。
    struct VotingRatioCell: Equatable {
        var total: Double? = nil
        var indirect: Double? = nil
        var closeParties: Double? = nil
    }

    /// 「100.0(66.5)」「(0.79) 51.49」「※2 100.0 [66.5]」「被所有 46.3 (14.9) [0.6]」「－ [100.0]」「20.6 (0.1) 〔0.8〕」を読む。
    /// 注記の印（※2・(注2)・(注)3、6・＊1）は外す。全部が間接所有の「(100.0)」は合計も 100.0。
    /// 割合として読めないセル（100 を超える数・数が余る）は nil。
    static func votingRatioCell(_ text: String) -> VotingRatioCell? {
        var t = singleLine(text.precomposedStringWithCompatibilityMapping)
        for pattern in votingRatioNoisePatterns {
            t = pattern.stringByReplacingMatches(
                in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " ")
        }
        func takeGroup(_ pattern: NSRegularExpression) -> (found: Bool, value: Double?, ok: Bool) {
            let ns = t as NSString
            let matches = pattern.matches(in: t, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return (false, nil, true) }
            var values: [Double] = []
            for m in matches { values += numbers(in: ns.substring(with: m.range(at: 1))) }
            t = pattern.stringByReplacingMatches(
                in: t, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
            return (true, values.first, values.count <= 1)
        }
        let close = takeGroup(votingRatioBracketPattern)
        let indirect = takeGroup(votingRatioParenPattern)
        let rest = numbers(in: t)
        guard close.ok, indirect.ok, rest.count <= 1 else { return nil }
        var cell = VotingRatioCell(total: rest.first, indirect: indirect.value, closeParties: close.value)
        if cell.total == nil, rest.isEmpty, !close.found { cell.total = cell.indirect }
        let values = [cell.total, cell.indirect, cell.closeParties].compactMap { $0 }
        guard values.allSatisfy({ $0 <= 100 }) else { return nil }
        return values.isEmpty ? nil : cell
    }

    private static let votingRatioNoisePatterns: [NSRegularExpression] = [
        #"\(\s*注\s*\)\s*[0-9]+(?:\s*[、,.・]\s*[0-9]+)*"#,
        #"\(\s*注\s*[0-9]+(?:\s*[、,.・]\s*[0-9]+)*\s*\)"#,
        #"注\s*[0-9]+(?:\s*[、,.・]\s*[0-9]+)*(?=\s|$|\()"#,
        // 「※2 100.0」は印。間を空けない「※15.01」は数字の前の印だけ（※ の付いた 15.01）。
        #"[※*]\s*[0-9]+(?:\s*[、,・]\s*[0-9]+)*(?=\s|\(|\[|〔)"#,
        #"(?<=\s)[※*]\s*[0-9]+\s*$"#,
        #"被所有|所有|%|,"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let votingRatioParenPattern = try! NSRegularExpression(pattern: #"\(([^()]*)\)"#)
    private static let votingRatioBracketPattern = try! NSRegularExpression(pattern: #"[\[〔]([^\[\]〔〕]*)[\]〕]"#)

    private static func numbers(in text: String) -> [Double] {
        let ns = text as NSString
        return numberPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Double(ns.substring(with: $0.range)) }
    }

    /// 「主要な損益情報等」の表（売上高・総資産額などの列）。関係会社表の続きとして読まない。
    static func isFinancialInfoTable(_ grid: [[String]]) -> Bool {
        grid.prefix(3).contains { row in
            row.contains { cell in
                let c = compactCell(cell)
                return c.contains("損益情報") || c.hasPrefix("売上高") || c.hasPrefix("(1)売上高")
                    || c.hasPrefix("①売上高") || c.hasPrefix("売上収益")
            }
        }
    }

    /// 全列が同じ文字列の行（区分語のない、表の幅いっぱいの見出し）。
    private static func isSpanningLabelRow(_ row: [String]) -> Bool {
        let cells = row.map(compactCell)
        guard row.count >= 3, let first = cells.first, !first.isEmpty else { return false }
        return cells.allSatisfy { $0 == first }
    }

    struct GroupTableLayout {
        var header: [String]
        var headerRow: Int
        var headerName: String
        var columnCount: Int
        var nameColumn: Int
        var ownedRatioColumn: Int?
        var passiveRatioColumn: Int?
        var businessColumn: Int?
    }

    private static let groupNameHeaders: Set<String> = ["名称", "会社名", "社名", "商号", "名称又は氏名"]

    static func groupTableLayout(_ grid: [[String]]) -> GroupTableLayout? {
        for (r, row) in grid.enumerated() {
            guard let nameCol = row.firstIndex(where: { groupNameHeaders.contains(compactCell($0)) })
            else { continue }
            let last = lastHeaderRow(grid, from: r, nameColumn: nameCol)
            let headerRows = grid[r...last]
            let joined = row.indices.map { c in headerRows.map { compactCell($0[c]) }.joined() }
            let lastRow = grid[last].map(compactCell)
            let ratioCols = row.indices.filter { c in
                c != nameCol
                    && (joined[c].contains("議決権") || joined[c].contains("所有割合")
                        || joined[c].contains("持分割合") || joined[c].contains("所有持分"))
            }
            var owned: Int?
            var passive: Int?
            if ratioCols.count >= 2 {
                passive = ratioCols.first { isPassiveRatioHeader(lastRow[$0]) }
                owned = ratioCols.first { $0 != passive && !isPassiveRatioHeader(lastRow[$0]) }
            }
            if owned == nil, passive == nil, let only = ratioCols.first {
                owned = only
                passive = only
            }
            let business = row.indices.first { c in
                c != nameCol && joined[c].contains("事業")
            }
            return GroupTableLayout(
                header: grid[last], headerRow: last, headerName: row[nameCol],
                columnCount: row.count, nameColumn: nameCol, ownedRatioColumn: owned ?? passive,
                passiveRatioColumn: passive ?? owned, businessColumn: business)
        }
        return nil
    }

    /// 「被所有割合」だけの列か（「所有(被所有)割合」のような両用の見出しは除く）。
    private static func isPassiveRatioHeader(_ text: String) -> Bool {
        guard text.contains("被所有") else { return false }
        let both = ["所有(被所有)", "所有又は被所有", "所有又は 被所有", "所有・被所有"]
        return !both.contains { text.contains($0) }
    }

    /// 区分語から kind を決める（一般規則。順序が意味を持つ: 非連結子会社・持分法適用非連結子会社は affiliate）。
    static func groupKind(from text: String) -> String? {
        let t = compactCell(text)
        guard !t.isEmpty else { return nil }
        if t.contains("その他の関係会社") { return relationKindOtherRelated }
        if t.contains("持分法") { return relationKindAffiliate }
        if t.contains("非連結子会社") { return relationKindAffiliate }
        if t.contains("関連会社") { return relationKindAffiliate }
        if t.contains("親会社") { return relationKindParent }
        if t.contains("子会社") { return relationKindSubsidiary }
        return nil
    }

    /// 表内の区分見出し行（名称列だけに区分語があり、他の列が空か同じ文字列）。
    private static func headingRowKind(_ row: [String], nameColumn: Int) -> String? {
        let name = compactCell(row[nameColumn])
        guard !name.isEmpty, name.count <= 24, let kind = groupKind(from: name) else { return nil }
        let others = row.indices.filter { $0 != nameColumn }.map { compactCell(row[$0]) }
        guard others.allSatisfy({ $0.isEmpty || $0 == name }) else { return nil }
        return kind
    }

    private static let kindPrefixPattern = try! NSRegularExpression(
        pattern: #"^\s*[（(]([^）)]{2,24})[）)]\s*"#)

    /// 名称の頭の「（連結子会社）」等を外す。区分語でない括弧（「(株)」等）は残す。
    static func stripKindPrefix(_ name: String) -> (kind: String?, name: String) {
        let ns = name as NSString
        guard let match = kindPrefixPattern.firstMatch(
            in: name, range: NSRange(location: 0, length: ns.length)),
            let kind = groupKind(from: ns.substring(with: match.range(at: 1)))
        else { return (nil, name) }
        return (kind, ns.substring(from: match.range.upperBound))
    }

    /// 表の外の直前の見出し（短い段落のうち最後に区分語を含むもの）。注記の長文は見ない。
    /// 「※特定子会社です」「（注）…」のような表と表の間の注記は見出しにしない（続きの表の区分を上書きしない）。
    static func outsideHeadingKind(_ paragraphs: [String]) -> String? {
        for paragraph in paragraphs.reversed() {
            let compact = compactCell(paragraph)
            guard !compact.isEmpty, compact.count <= 40, !isNoteParagraph(compact) else { continue }
            if let kind = groupKind(from: compact) { return kind }
        }
        return nil
    }

    private static let notePrefixes = ["※", "*", "＊", "(注", "（注", "注"]
    private static let sentenceMarkers = ["です", "ます", "である", "。", "当該", "該当"]

    static func isNoteParagraph(_ text: String) -> Bool {
        notePrefixes.contains { text.hasPrefix($0) } || sentenceMarkers.contains { text.contains($0) }
    }

    // MARK: - 提出会社の親会社等の情報

    static func extractParentCompanyInfo(xbrlDir: URL) -> [CompanyRelationDraft] {
        let blocks = textBlocksByContext(in: xbrlDir, tag: parentCompanyInfoTag)
        guard let html = filingDateBlock(blocks) else {
            return [.status(section: relationSectionParentCompanyInfo, relationSectionStatusNotFound)]
        }
        let parsed = parseAffiliatedEntities(
            html: html, section: relationSectionParentCompanyInfo, defaultKind: relationKindParent)
        // 親会社等の節は区分が決まっているので Jev には回さない。
        let rows = parsed.rows.filter { $0.kind == relationKindParent }
        if !rows.isEmpty {
            return rows.enumerated().map { index, row in
                var row = row
                row.position = index
                return row
            }
        }
        return [.status(section: relationSectionParentCompanyInfo, omissionStatus(html))]
    }

    // MARK: - 政策保有株式

    private struct PolicyHoldingCategory {
        let namePrefix: String
        let sharesPrefix: String
        let bookValuePrefix: String
        /// 保有目的タグ判定用のキーワード（`isPolicyHoldingPurposeTag`）。
        let purposeKeyword: String
        let isDeemed: Bool
    }

    /// 特定投資株式を先、みなし保有株式を後（開示本文の表の並び）。
    private static let policyHoldingCategories: [PolicyHoldingCategory] = [
        PolicyHoldingCategory(
            namePrefix: "NameOfSecuritiesDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            sharesPrefix: "NumberOfSharesHeldDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            bookValuePrefix: "BookValueDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            purposeKeyword: "DetailsOfSpecifiedInvestmentSharesHeldForPurposesOtherThanPureInvestment",
            isDeemed: false),
        PolicyHoldingCategory(
            namePrefix: "NameOfSecuritiesDetailsOfDeemedHoldingsOfEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            sharesPrefix: "NumberOfSharesHeldDetailsOfDeemedHoldingsOfEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            bookValuePrefix: "BookValueDetailsOfDeemedHoldingsOfEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            purposeKeyword: "DetailsOfDeemedHoldingsOfSharesHeldForPurposesOtherThanPureInvestment",
            isDeemed: true),
    ]

    /// 保有主体（タグの末尾）。`LargestHoldingCompany` は `SecondLargestHoldingCompany` の末尾一致でもある。
    private static let policyHoldingHolders: [(suffix: String, holder: String)] = [
        ("ReportingCompany", relationHolderReportingCompany),
        ("LargestHoldingCompany", relationHolderLargestHoldingCompany),
        ("SecondLargestHoldingCompany", relationHolderSecondLargestHoldingCompany),
    ]

    /// 非上場株式以外（上場）の銘柄数（純投資目的以外）。銘柄名タグが無いときの「表だけ」の判定に使う。
    private static let policyHoldingListedIssueCountPrefix =
        "NumberOfIssuesSharesOtherThanThoseNotListedInvestmentSharesHeldForPurposesOtherThanPureInvestment"

    private static func isPolicyHoldingPurposeTag(_ tag: String, purposeKeyword: String, suffix: String) -> Bool {
        guard tag.hasPrefix("PurposeOfShareholding"), tag.contains(purposeKeyword), tag.hasSuffix(suffix)
        else { return false }
        if suffix == "LargestHoldingCompany" && tag.hasSuffix("SecondLargestHoldingCompany") { return false }
        return true
    }

    private static let currentYearRowPattern = try! NSRegularExpression(
        pattern: "^CurrentYearInstant_Row([0-9]+)Member$")

    static func currentYearRowNumber(_ contextRef: String) -> Int? {
        captureInt(currentYearRowPattern, contextRef)
    }

    /// 銘柄名タグから出資先の行を作る（当期の行だけ。前期は落とす）。
    /// 株数・計上額は `nilAsZero: false`（当期に全数売却した銘柄の xsi:nil を 0 にしない）。
    static func extractPolicyHoldings(xbrlDir: URL) -> [CompanyRelationDraft] {
        let textFacts = textFactsByContext(in: xbrlDir) {
            $0.hasPrefix("NameOfSecuritiesDetailsOfSpecifiedInvestment")
                || $0.hasPrefix("NameOfSecuritiesDetailsOfDeemedHoldings")
                || $0.hasPrefix("PurposeOfShareholding")
        }
        let numeric = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        var rows: [CompanyRelationDraft] = []
        for category in policyHoldingCategories {
            for (suffix, holder) in policyHoldingHolders {
                guard let names = textFacts[category.namePrefix + suffix], !names.isEmpty else { continue }
                let shares = numeric[category.sharesPrefix + suffix] ?? [:]
                let bookValues = numeric[category.bookValuePrefix + suffix] ?? [:]
                let purposeTag = textFacts.keys.sorted().first {
                    isPolicyHoldingPurposeTag($0, purposeKeyword: category.purposeKeyword, suffix: suffix)
                }
                let purposes = purposeTag.flatMap { textFacts[$0] } ?? [:]
                let ordered = names.compactMap { ctx, name -> (Int, String, String)? in
                    currentYearRowNumber(ctx).map { ($0, ctx, name) }
                }.sorted { $0.0 < $1.0 }
                for (_, ctx, name) in ordered {
                    let issuer = name.replacingOccurrences(of: "\r\n", with: "")
                        .replacingOccurrences(of: "\n", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    guard !issuer.isEmpty else { continue }
                    rows.append(
                        CompanyRelationDraft(
                            section: relationSectionPolicyHoldings, kind: relationKindInvestee,
                            position: rows.count, nameRaw: issuer, shares: shares[ctx],
                            bookValueYen: bookValues[ctx], purpose: purposes[ctx],
                            isDeemed: category.isDeemed, holder: holder))
                }
            }
        }
        if !rows.isEmpty { return rows }
        let listedCount = policyHoldingHolders.compactMap {
            numeric[policyHoldingListedIssueCountPrefix + $0.suffix]?["CurrentYearInstant"]
        }.reduce(0, +)
        return [
            .status(
                section: relationSectionPolicyHoldings,
                listedCount > 0 ? relationSectionStatusUntaggedTable : relationSectionStatusNoTags)
        ]
    }

    // MARK: - 大株主の状況

    static let majorShareholderNameTag = "NameMajorShareholders"
    static let majorShareholderAddressTag = "AddressMajorShareholders"
    static let majorShareholderSharesTag = "NumberOfSharesHeld"
    static let majorShareholderRatioTag = "ShareholdingRatio"

    private static let majorShareholderContextPattern = try! NSRegularExpression(
        pattern: "^CurrentYearInstant_No([0-9]+)MajorShareholdersMember$")

    static func majorShareholderRank(_ contextRef: String) -> Int? {
        captureInt(majorShareholderContextPattern, contextRef)
    }

    /// 構造化タグから上位株主を順位順に作る（当期 context だけ。表の HTML は読まない）。
    static func extractMajorShareholders(xbrlDir: URL) -> [CompanyRelationDraft] {
        let textFacts = textFactsByContext(in: xbrlDir) {
            $0 == majorShareholderNameTag || $0 == majorShareholderAddressTag
        }
        let numeric = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let names = textFacts[majorShareholderNameTag] ?? [:]
        let addresses = textFacts[majorShareholderAddressTag] ?? [:]
        let shares = numeric[majorShareholderSharesTag] ?? [:]
        let ratios = numeric[majorShareholderRatioTag] ?? [:]
        let ordered = names.compactMap { ctx, name -> (Int, String, String)? in
            majorShareholderRank(ctx).map { ($0, ctx, name) }
        }.sorted { $0.0 < $1.0 }
        var rows: [CompanyRelationDraft] = []
        for (rank, ctx, name) in ordered {
            let cleaned = singleLine(name)
            guard !cleaned.isEmpty else { continue }
            rows.append(
                CompanyRelationDraft(
                    section: relationSectionMajorShareholders, kind: relationKindMajorShareholder,
                    position: rows.count, nameRaw: cleaned, shares: shares[ctx], ratio: ratios[ctx],
                    rank: rank, address: addresses[ctx].map(singleLine)))
        }
        if !rows.isEmpty { return rows }
        return [.status(section: relationSectionMajorShareholders, relationSectionStatusNoTags)]
    }

    // MARK: - TextBlock / text fact（訂正 overlay 込み）

    /// 指定 TextBlock の HTML を contextRef 別に返す（エンティティ復号済み）。
    /// 訂正 overlay に同じ tag + context があれば提出が新しい訂正で置き換える。
    static func textBlocksByContext(in xbrlDir: URL, tag: String) -> [String: String] {
        var result = textBlocksByContextUnlayered(in: xbrlDir, tag: tag)
        for overlay in overlayDirectoryEntries(in: xbrlDir) {
            for (ctx, html) in textBlocksByContextUnlayered(in: overlay.url, tag: tag) {
                result[ctx] = html
            }
        }
        return result
    }

    private static func textBlocksByContextUnlayered(in dir: URL, tag: String) -> [String: String] {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        guard let pattern = try? NSRegularExpression(
            pattern: "<[^>]*:" + escaped + "\\s([^>]*)>(.*?)</[^>]*:" + escaped + "\\s*>",
            options: [.dotMatchesLineSeparators])
        else { return [:] }
        var result: [String: String] = [:]
        for file in XBRLUtils.findXbrlFiles(in: dir) {
            guard let raw = try? String(contentsOf: file, encoding: .utf8), raw.contains(tag) else { continue }
            let ns = raw as NSString
            for match in pattern.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let attrs = ns.substring(with: match.range(at: 1))
                guard let ctx = attributeValue("contextRef", in: attrs) else { continue }
                result[ctx] = ns.substring(with: match.range(at: 2)).htmlEntityDecoded
            }
        }
        return result
    }

    /// 当期の TextBlock（連結 → 個別 → その他の当期 context）。当期が無ければ nil。
    static func currentPeriodBlock(_ blocks: [String: String]) -> String? {
        if let html = blocks["CurrentYearDuration"] { return html }
        if let html = blocks["CurrentYearDuration_NonConsolidatedMember"] { return html }
        return blocks.keys.sorted().first { $0.hasPrefix("CurrentYear") }.flatMap { blocks[$0] }
    }

    /// 提出日時点の TextBlock（関係会社の状況・親会社等の情報）。無ければ当期・最初の context。
    static func filingDateBlock(_ blocks: [String: String]) -> String? {
        if let html = blocks["FilingDateInstant"] { return html }
        if let html = currentPeriodBlock(blocks) { return html }
        return blocks.keys.sorted().first.flatMap { blocks[$0] }
    }

    /// 指定条件に一致するテキスト fact を {tag: {contextRef: text}} で集める（訂正 overlay 込み。
    /// `Row{N}Member` / `No{N}MajorShareholdersMember` の表は訂正にその表があれば行ごと置換）。
    static func textFactsByContext(
        in xbrlDir: URL, isRelevantTag: @escaping (String) -> Bool
    ) -> [String: [String: String]] {
        var result = textFactsUnlayered(in: xbrlDir, isRelevantTag: isRelevantTag)
        for overlay in overlayDirectoryEntries(in: xbrlDir) {
            result = overlayKeyedFacts(
                base: result, overlay: textFactsUnlayered(in: overlay.url, isRelevantTag: isRelevantTag))
        }
        return result
    }

    private static func textFactsUnlayered(
        in dir: URL, isRelevantTag: @escaping (String) -> Bool
    ) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for file in XBRLUtils.findXbrlFiles(in: dir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let delegate = RelationTextFactParser(isRelevantTag: isRelevantTag)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            for (tag, ctxMap) in delegate.results {
                for (ctx, text) in ctxMap { result[tag, default: [:]][ctx] = text }
            }
        }
        return result
    }

    // MARK: - HTML 表

    struct ParsedTable {
        var grid: [[String]]
        var columnCount: Int { grid.first?.count ?? 0 }
    }

    struct HTMLSegment {
        /// この表の直前（前の表の後ろから）の段落テキスト。
        var precedingParagraphs: [String]
        var table: ParsedTable?
        var precedingText: String { precedingParagraphs.joined(separator: " ") }
    }

    private static let tablePattern = try! NSRegularExpression(
        pattern: #"<table\b.*?</table>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// TextBlock を「直前の段落＋表」の並びに分ける。最後の要素は表の後ろの段落だけ（`table == nil`）。
    static func splitTables(_ html: String) -> [HTMLSegment] {
        let ns = html as NSString
        var segments: [HTMLSegment] = []
        var cursor = 0
        for match in tablePattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let tableHTML = ns.substring(with: match.range)
            segments.append(
                HTMLSegment(precedingParagraphs: paragraphs(before), table: parseTable(tableHTML)))
            cursor = match.range.upperBound
        }
        segments.append(HTMLSegment(precedingParagraphs: paragraphs(ns.substring(from: cursor)), table: nil))
        return segments
    }

    private static func paragraphs(_ html: String) -> [String] {
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body() else { return [] }
        let ps = (try? body.select("p, h1, h2, h3, h4, h5, h6"))?.array() ?? []
        let texts = ps.map { BreakdownExtractor.bs4Text($0, strip: true) }.filter { !$0.isEmpty }
        if !texts.isEmpty { return texts }
        let whole = BreakdownExtractor.bs4Text(body, strip: true)
        return whole.isEmpty ? [] : [whole]
    }

    /// rowspan / colspan を展開したセル文字列の二次元グリッド（セル内の改行・段落は空白 1 つに潰す）。
    static func parseTable(_ html: String) -> ParsedTable? {
        guard let doc = try? SwiftSoup.parseBodyFragment(html),
            let table = try? doc.select("table").first(),
            let trs = try? table.select("tr")
        else { return nil }
        var grid: [Int: [Int: String]] = [:]
        var rowIdx = 0
        for tr in trs {
            let cells = (try? tr.select("td, th"))?.array() ?? []
            var colIdx = 0
            for cell in cells {
                while grid[rowIdx]?[colIdx] != nil { colIdx += 1 }
                let text = cellText(cell)
                let rowspan = max(XBRLUtils.parseHtmlIntAttribute(cell, "rowspan"), 1)
                let colspan = max(XBRLUtils.parseHtmlIntAttribute(cell, "colspan"), 1)
                for r in 0..<rowspan {
                    for c in 0..<colspan { grid[rowIdx + r, default: [:]][colIdx + c] = text }
                }
                colIdx += colspan
            }
            rowIdx += 1
        }
        guard let maxRow = grid.keys.max(), let maxCol = grid.values.compactMap({ $0.keys.max() }).max()
        else { return nil }
        return ParsedTable(
            grid: (0...maxRow).map { r in (0...maxCol).map { c in grid[r]?[c] ?? "" } })
    }

    private static func cellText(_ cell: Element) -> String {
        let paragraphs = (try? cell.select("p"))?.array() ?? []
        let parts = paragraphs.isEmpty
            ? [BreakdownExtractor.bs4Text(cell, strip: false)]
            : paragraphs.map { BreakdownExtractor.bs4Text($0, strip: false) }
        return parts.map(singleLine).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - 文字列の小道具

    /// 改行・連続空白（全角空白・NBSP 含む）を半角空白 1 つにする。
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 比較用（NFKC・空白なし）。
    static func compactCell(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 表示用ラベル（空白を 1 つに潰すだけ。NFKC はかけない）。
    static func compactLabel(_ text: String) -> String { singleLine(text) }

    private static let noteMarkerPatterns: [NSRegularExpression] = [
        // （注）４，６ / (注)2 / （注１） / (注) / 注１
        try! NSRegularExpression(pattern: #"[（(]\s*注\s*[0-9０-９]*\s*[）)][\s0-9０-９,，、．.・]*"#),
        // ※１、※４ / ※1
        try! NSRegularExpression(pattern: #"※\s*[0-9０-９]*[\s,，、]*"#),
        // *1 / ＊２
        try! NSRegularExpression(pattern: #"[*＊]\s*[0-9０-９]+[\s,，、]*"#),
    ]

    /// 名称セルから注記マーカー（「(注)４，６」「※１、※４」「*1」）を落とし、空白を潰す。
    static func cleanCounterpartyName(_ text: String) -> String {
        var s = singleLine(text)
        for pattern in noteMarkerPatterns {
            let ns = s as NSString
            s = pattern.stringByReplacingMatches(
                in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }
        return singleLine(s)
    }

    private static let aggregateRowPattern = try! NSRegularExpression(
        pattern: #"^(その他|他)(の)?[0-9０-９]+社|^[0-9０-９]+社$|^\(.*\)[0-9０-９]+社$|^その他.*[0-9０-９]+社$"#)

    /// 相手の名前として採るか（合計・計・その他・単位行・注記行・数字だけを落とす）。
    static func isCounterpartyName(_ name: String) -> Bool {
        let c = compactCell(name)
        guard !c.isEmpty, !isDash(c) else { return false }
        if ["合計", "計", "小計", "総計", "その他", "その他計"].contains(c) { return false }
        if c.hasSuffix("合計") && c.count <= 6 { return false }
        if c.contains("単位") { return false }
        if c.hasPrefix("注") || c.hasPrefix("(注") || c.hasPrefix("※") { return false }
        // 表の中に入った注記の文（「…を記載しております。」）。社名は句点で終わらない。
        if c.hasSuffix("。") { return false }
        if c.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) { return false }
        let ns = c as NSString
        if aggregateRowPattern.firstMatch(in: c, range: NSRange(location: 0, length: ns.length)) != nil {
            return false
        }
        return true
    }

    static func isDash(_ text: String) -> Bool {
        ["―", "－", "-", "−", "—", "─", "‐", "ー"].contains(compactCell(text))
    }

    private static let unitPattern = try! NSRegularExpression(
        pattern: #"単位\s*[:：]?\s*(千円|百万円|億円|円)"#)
    private static let headerUnitPattern = try! NSRegularExpression(
        pattern: #"[（(]\s*(千円|百万円|億円|円)\s*[）)]"#)

    /// 「(単位：千円)」「売上高(百万円)」を円への倍率にする。
    static func amountUnitMultiplier(in text: String) -> Double? {
        let t = text.precomposedStringWithCompatibilityMapping
        let ns = t as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = unitPattern.firstMatch(in: t, range: range) {
            return unitMultiplier(ns.substring(with: m.range(at: 1)))
        }
        if let m = headerUnitPattern.firstMatch(in: t, range: range) {
            return unitMultiplier(ns.substring(with: m.range(at: 1)))
        }
        return nil
    }

    /// 金額セルの末尾の単位（「89,058百万円」）。
    static func amountUnitMultiplier(inCell cell: String) -> Double? {
        let c = compactCell(cell)
        for unit in ["百万円", "千円", "億円"] where c.hasSuffix(unit) { return unitMultiplier(unit) }
        return nil
    }

    private static func unitMultiplier(_ unit: String) -> Double? {
        switch unit {
        case "千円": return 1_000
        case "百万円": return 1_000_000
        case "億円": return 100_000_000
        case "円": return 1
        default: return nil
        }
    }

    private static let numberPattern = try! NSRegularExpression(pattern: #"[0-9]+(?:\.[0-9]+)?"#)

    /// セルの最初の数値（「100.0 (25.0)」→ 100.0。「―」は nil）。
    static func firstNumber(_ text: String) -> Double? {
        let t = text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: ",", with: "")
        let ns = t as NSString
        guard let m = numberPattern.firstMatch(in: t, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return Double(ns.substring(with: m.range))
    }

    private static func isCurrentPeriodHeading(_ text: String) -> Bool {
        let t = compactCell(text)
        return t.contains("当連結会計年度") || t.contains("当事業年度") || t.contains("当期")
    }

    /// 表が無いときの状態。省略文（「記載を省略」「該当事項はありません」等）は omitted、それ以外の文は no_table。
    static func omissionStatus(_ html: String) -> String {
        let body = (try? SwiftSoup.parseBodyFragment(html))?.body()
        let text = compactCell(body.map { BreakdownExtractor.bs4Text($0, strip: true) } ?? html)
        let omission = ["省略", "該当事項はありません", "該当事項はない", "ありません", "ないため", "なし"]
        return omission.contains { text.contains($0) }
            ? relationSectionStatusOmitted : relationSectionStatusNoTable
    }

    private static func attributeValue(_ name: String, in attrs: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: name + #"\s*=\s*["']([^"']+)["']"#)
        else { return nil }
        let ns = attrs as NSString
        guard let m = pattern.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func captureInt(_ pattern: NSRegularExpression, _ text: String) -> Int? {
        let ns = text as NSString
        guard let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }
}

/// 指定条件に一致するタグの生テキストを contextRef 別に集める XMLParserDelegate。
private final class RelationTextFactParser: NSObject, XMLParserDelegate {
    var results: [String: [String: String]] = [:]
    private let isRelevantTag: (String) -> Bool
    private var currentTag = ""
    private var currentCtx = ""
    private var currentText = ""
    private var capturing = false

    init(isRelevantTag: @escaping (String) -> Bool) {
        self.isRelevantTag = isRelevantTag
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        capturing = false
        let localTag = XBRLUtils.localName(of: elementName)
        guard isRelevantTag(localTag), let ctx = attributeDict["contextRef"], !ctx.isEmpty else { return }
        currentTag = localTag
        currentCtx = ctx
        currentText = ""
        capturing = true
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { currentText += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturing else { return }
        capturing = false
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        results[currentTag, default: [:]][currentCtx] = trimmed
    }
}
