// US-GAAP 連結財務諸表 HTML（0105010）→ Statement 行抽出。
//
// EDINET の US-GAAP 連結には ix:nonFraction が無いため、XBRL fact + presentation 経路
// （StatementClassifier）は使えない。開示 HTML テーブルを決定論で読み、
// StatementLineItem として返す（LLM なし。docs/statement-normalization-concept.md）。
//
// 現行 summary 用の USGAAPHtml（選択ラベル→仮想タグ）とは別経路。こちらは全データ行を
// 開示ラベルのまま出す（企業間の科目統一はしない）。

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
                // CF より前に複数 SS 表がある場合（キヤノン: 前期表＋当期表）は最後の表を採用。
                guard statementTypes.contains(.changesInEquity), !sawCF else { continue }
                pendingSS = parseEquityStatementRows(rows)
            case .cashFlow:
                guard !sawCF else { continue }
                if statementTypes.contains(.changesInEquity) {
                    changesInEquity = pendingSS
                }
                if statementTypes.contains(.cashFlow) {
                    cashFlow = parseSimpleStatementRows(
                        rows, sectionType: .cashFlow, sectionForRow: cfSection(for:))
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
        return (balanceSheet, incomeStatement, cashFlow, changesInEquity)
    }

    // MARK: - File discovery

    private static func findStatementHtml(in xbrlDir: URL) -> URL? {
        XBRLUtils.findHtmlByPrefix(in: xbrlDir, prefix: "0105010")
            ?? XBRLUtils.findHtmlByPrefix(in: xbrlDir, prefix: "0104010")
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
    /// 「最初の一致のみ採用」する（呼び出し側）。ここでの分類は表のラベル集合のヒューリスティック。
    private static func classifyTable(_ rows: [[String]]) -> TableKind? {
        let labels = rows.map { rowLabel($0) }.filter { !$0.isEmpty }
        let allCells = rows.flatMap { $0 }.joined(separator: "\n")

        if labels.contains(where: { $0.contains("営業活動によるキャッシュ・フロー") })
            && labels.contains(where: { $0.contains("投資活動によるキャッシュ・フロー") })
        {
            return .cashFlow
        }

        // SS: 複数資本構成員列＋「現在残高」。合計列のみ使う。
        // 「純資産」はヘッダ行の列名に出ることが多く、先頭ラベル列だけだと見えない。
        if labels.contains(where: { $0.contains("現在残高") })
            && (allCells.contains("純資産") || allCells.contains("株主資本"))
            && labels.contains(where: { $0 == "区分" || $0.hasPrefix("区分") })
        {
            let header = rows.first { rowLabel($0) == "区分" || rowLabel($0).hasPrefix("区分") }
                ?? rows.first ?? []
            let headerJoined = header.joined()
            if headerJoined.contains("資本金") || headerJoined.contains("利益剰余金")
                || headerJoined.contains("自己株式") || headerJoined.contains("純資産")
            {
                return .changesInEquity
            }
        }

        if labels.contains(where: { isAssetsSectionHeader($0) })
            && labels.contains(where: {
                $0 == "資産合計" || ($0.hasSuffix("資産合計") && !$0.contains("純資産") && !$0.contains("負債"))
            })
        {
            return .bsAssets
        }
        if labels.contains(where: { isLiabilitiesSectionHeader($0) })
            && (labels.contains(where: { $0.contains("純資産合計") })
                || labels.contains(where: { $0.contains("負債") && $0.contains("合計") }))
        {
            return .bsLiabilitiesAndEquity
        }

        // PL: 売上高＋営業利益。包括利益計算書（当期純利益から始まる OCI 表）は除外。
        if labels.contains(where: { isSalesLabel($0) })
            && labels.contains(where: { $0.contains("営業利益") })
        {
            return .incomeStatement
        }

        return nil
    }

    private static func isSalesLabel(_ label: String) -> Bool {
        let s = USGAAPHtml.stripSectionPrefix(label)
        return s == "売上高" || s.hasSuffix("売上高") || s.contains("製品売上高")
    }

    // MARK: - Row parsing

    private static func tableRows(_ table: Element) -> [[String]] {
        guard let trs = try? table.select("tr") else { return [] }
        return trs.array().compactMap { tr -> [String]? in
            guard let cells = try? tr.select("td, th"), !cells.isEmpty else { return nil }
            return cells.array().map { cell in
                let text = (try? cell.text(trimAndNormaliseWhitespace: true)) ?? ""
                return text.replacingOccurrences(of: "\u{00A0}", with: " ")
            }
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
            order += 1
            items.append(
                StatementLineItem(
                    tag: syntheticTag(.balanceSheet, order: order),
                    label: label,
                    value: yen,
                    unit: "JPY",
                    order: order,
                    section: section,
                    isTotal: isTotalLabel(label, sectionType: .balanceSheet),
                    components: nil))
        }
        return items
    }

    private static func parseSimpleStatementRows(
        _ rows: [[String]],
        sectionType: StatementSectionType,
        sectionForRow: (String) -> StatementLineSection?
    ) -> [StatementLineItem] {
        var order = 0
        var items: [StatementLineItem] = []
        var currentCFSection: StatementLineSection? =
            sectionType == .cashFlow ? .operating : nil

        for row in rows {
            let raw = rowLabel(row)
            let label = normalizeLabel(raw)
            guard !label.isEmpty, !isHeaderLabel(label) else { continue }
            if shouldSkipMetaRow(label) { continue }

            if sectionType == .cashFlow, let s = sectionForRow(label) {
                currentCFSection = s
            }

            guard let yen = currentYenValue(row) else { continue }
            order += 1
            let section: StatementLineSection? =
                sectionType == .cashFlow ? currentCFSection : nil
            items.append(
                StatementLineItem(
                    tag: syntheticTag(sectionType, order: order),
                    label: label,
                    value: yen,
                    unit: "JPY",
                    order: order,
                    section: section,
                    isTotal: isTotalLabel(label, sectionType: sectionType),
                    components: nil))
        }
        return items
    }

    /// SS は合計列（純資産合計）のみ。ヘッダが複行列＋colspan の会社（キヤノン）では
    /// 列 index がずれるため、行末の財務金額を合計列とみなす（実データ: 純資産合計が最右）。
    private static func parseEquityStatementRows(_ rows: [[String]]) -> [StatementLineItem] {
        var order = 0
        var items: [StatementLineItem] = []
        for row in rows {
            let raw = rowLabel(row)
            let label = normalizeLabel(raw)
            guard !label.isEmpty, !isHeaderLabel(label) else { continue }
            if shouldSkipMetaRow(label) { continue }

            let nums = row.dropFirst().compactMap { XBRLUtils.parseHtmlNumber($0) }
            let financial = XBRLUtils.filterFinancialTableAmounts(nums)
            guard let million = financial.last else { continue }

            order += 1
            items.append(
                StatementLineItem(
                    tag: syntheticTag(.changesInEquity, order: order),
                    label: label,
                    value: million * Financial.millionYen,
                    unit: "JPY",
                    order: order,
                    section: nil,
                    isTotal: isTotalLabel(label, sectionType: .changesInEquity),
                    components: nil))
        }
        return items
    }

    private static func currentYenValue(_ row: [String]) -> Double? {
        let nums = row.dropFirst().compactMap { XBRLUtils.parseHtmlNumber($0) }
        guard !nums.isEmpty else { return nil }
        let financial = XBRLUtils.filterFinancialTableAmounts(Array(nums))
        guard let million = financial.last else { return nil }
        return million * Financial.millionYen
    }

    // MARK: - Label / section helpers

    private static func normalizeLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: "　", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }

    private static func isHeaderLabel(_ label: String) -> Bool {
        if label == "区分" || label.hasPrefix("区分") { return true }
        if label.contains("金額") && (label.contains("百万円") || label.contains("％") || label.contains("%")) {
            return true
        }
        if label == "注記番号" || label == "注記 番号" { return true }
        return false
    }

    private static func isAssetsSectionHeader(_ label: String) -> Bool {
        let t = label.replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        // 「純資産の部」は "資産の部" を部分文字列に持つため先に除外する
        return t.contains("資産の部") && !t.contains("純資産") && !t.contains("負債")
    }

    private static func isLiabilitiesSectionHeader(_ label: String) -> Bool {
        let t = label.replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
        return t.contains("負債の部")
    }

    private static func isNetAssetsSectionHeader(_ label: String) -> Bool {
        let t = label.replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
        if t.contains("純資産の部") { return true }
        // 「Ⅰ 株主資本」は部ヘッダ（金額なし）として区分切替に使う
        let stripped = USGAAPHtml.stripSectionPrefix(t)
        return stripped == "株主資本"
    }

    private static func shouldSkipMetaRow(_ label: String) -> Bool {
        let skipExact = [
            "普通株式", "発行可能株式総数", "発行済株式総数",
            "前連結会計年度", "当連結会計年度",
            "契約債務及び偶発債務",
        ]
        if skipExact.contains(label) { return true }
        if label.hasPrefix("（発行") || label.hasPrefix("(発行") { return true }
        if label.contains("自己株式数") { return true }
        // 株数だけがラベルになっている行
        if label.allSatisfy({ $0.isNumber || $0 == "," }) { return true }
        return false
    }

    private static func cfSection(for label: String) -> StatementLineSection? {
        if label.contains("営業活動によるキャッシュ・フロー") { return .operating }
        if label.contains("投資活動によるキャッシュ・フロー") { return .investing }
        if label.contains("財務活動によるキャッシュ・フロー") { return .financing }
        return nil
    }

    private static func isTotalLabel(_ label: String, sectionType: StatementSectionType) -> Bool {
        let s = USGAAPHtml.stripSectionPrefix(label)
        if s.contains("合計") { return true }
        switch sectionType {
        case .incomeStatement:
            return s == "営業利益" || s == "売上総利益" || s.contains("当期純利益")
                || s.contains("税引前") || s.contains("税金等調整前")
        case .cashFlow:
            return s.contains("キャッシュ・フロー") || s.contains("期首残高") || s.contains("期末残高")
                || s.contains("純減少") || s.contains("純増減")
        case .changesInEquity:
            return s.contains("現在残高") || s == "包括利益" || s.contains("当期包括利益")
        case .balanceSheet:
            return false
        }
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
