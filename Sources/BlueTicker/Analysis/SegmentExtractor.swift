// 連結財務諸表注記からセグメント・地域別情報を抽出する
// Python の blue_ticker/analysis/segment_extractor.py 相当
//
//   extractSegmentInfo()   → 事業別（報告セグメント別）
//   extractGeographyInfo() → 地域別（所在地別）
//
// 優先: XBRLのTextBlock内のHTML表をそのまま構造化
// フォールバック: XBRLのcontextのdimension付きfact

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SwiftSoup

struct SegmentTable: Equatable {
    var heading: String
    var markdown: String
    var period: String?  // "当期" | "前期" | "比較"
}

struct SegmentFact: Equatable {
    var tag: String
    var contextRef: String
    var dimensions: [String: String]
    var value: Double
    var label: String?
    var unitRef: String?
    var decimals: String?
}

struct SegmentResult: Equatable {
    var method: String  // "html_table" | "xbrl_facts" | "not_found"
    var tables: [SegmentTable]
    var facts: [SegmentFact]

    /// JSONSerialization 互換の辞書に変換する（Python 出力と同じキー構造）。
    func toDictionary() -> [String: Any] {
        let tablesArr: [[String: Any]] = tables.map { t in
            var d: [String: Any] = ["heading": t.heading, "markdown": t.markdown]
            if let p = t.period { d["period"] = p }
            return d
        }
        let factsArr: [[String: Any]] = facts.map { f in
            var d: [String: Any] = [
                "tag": f.tag,
                "contextRef": f.contextRef,
                "dimensions": f.dimensions,
                "value": f.value,
            ]
            if let l = f.label { d["label"] = l }
            if let u = f.unitRef { d["unitRef"] = u }
            if let dec = f.decimals { d["decimals"] = dec }
            return d
        }
        return ["method": method, "tables": tablesArr, "facts": factsArr]
    }
}

enum SegmentExtractor {

    private static let currentPeriodKeywords = ["当連結会計年度", "当期"]
    private static let priorPeriodKeywords = ["前連結会計年度", "前期"]

    // MARK: - 公開 API

    /// filing コマンド・MCP の --sections で使う特殊セクション名（XBRLSectionDef 非経由）。
    static let specialSectionKeys = ["segments", "geography"]

    /// 特殊セクションの表示タイトル。
    static let specialSectionTitles: [String: String] = [
        "segments": "セグメント情報",
        "geography": "地域別情報",
    ]

    /// 特殊セクション名に対応する抽出を実行する。未対応の名前は nil。
    static func extractSpecialSection(_ section: String, xbrlDir: URL) -> SegmentResult? {
        switch section {
        case "segments": return extractSegmentInfo(xbrlDir: xbrlDir)
        case "geography": return extractGeographyInfo(xbrlDir: xbrlDir)
        default: return nil
        }
    }

    /// 連結財務諸表注記から事業別（報告セグメント別）情報を抽出する。
    static func extractSegmentInfo(xbrlDir: URL) -> SegmentResult {
        let tables = extractFromTextBlocks(
            xbrlDir: xbrlDir,
            dedicatedTags: Xbrl.businessSegmentTextBlockTags,
            mixedTags: [],
            dedicatedHeading: "セグメント情報",
            mixedKeywords: []
        )
        return buildResult(xbrlDir: xbrlDir, tables: tables, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords)
    }

    /// 連結財務諸表注記から地域別（所在地別）情報を抽出する。
    static func extractGeographyInfo(xbrlDir: URL) -> SegmentResult {
        let dedicated = Xbrl.geographyTextBlockTags.subtracting(Xbrl.geographyMixedTextBlockTags)
        let tables = extractFromTextBlocks(
            xbrlDir: xbrlDir,
            dedicatedTags: dedicated,
            mixedTags: Xbrl.geographyMixedTextBlockTags,
            dedicatedHeading: "地域ごとの情報",
            mixedKeywords: Xbrl.geographyHeadingKeywords
        )
        return buildResult(xbrlDir: xbrlDir, tables: tables, dimensionKeywords: Xbrl.geographyDimensionKeywords)
    }

    // MARK: - HTML 表の構造化

    /// rowspan / colspan を展開してセル文字列の二次元グリッドにする。
    static func expandTable(_ table: Element) -> [[String]] {
        var grid: [Int: [Int: String]] = [:]
        var rowIdx = 0
        guard let trs = try? table.select("tr") else { return [] }
        for tr in trs {
            var colIdx = 0
            let cells = (try? tr.select("td, th"))?.array() ?? []
            for cell in cells {
                while grid[rowIdx]?[colIdx] != nil { colIdx += 1 }
                let text = bs4Text(cell, strip: true)
                let rowspan = XBRLUtils.parseHtmlIntAttribute(cell, "rowspan")
                let colspan = XBRLUtils.parseHtmlIntAttribute(cell, "colspan")
                for r in 0..<max(rowspan, 0) {
                    for c in 0..<max(colspan, 0) {
                        grid[rowIdx + r, default: [:]][colIdx + c] = text
                    }
                }
                colIdx += colspan
            }
            rowIdx += 1
        }
        guard !grid.isEmpty else { return [] }
        let maxRow = grid.keys.max()! + 1
        let maxCol = grid.values.compactMap { $0.keys.max() }.max()! + 1
        return (0..<maxRow).map { r in (0..<maxCol).map { c in grid[r]?[c] ?? "" } }
    }

    /// グリッドを列幅揃えの Markdown テーブル文字列にする。
    static func gridToMarkdown(_ grid: [[String]]) -> String {
        guard !grid.isEmpty else { return "" }
        let colCount = grid.map(\.count).max()!
        let colWidths = (0..<colCount).map { c in
            grid.map { row in c < row.count ? row[c].unicodeScalars.count : 0 }.max()!
        }
        var lines: [String] = []
        for (i, row) in grid.enumerated() {
            let cells = (0..<colCount).map { c -> String in
                let text = c < row.count ? row[c] : ""
                return text + String(repeating: " ", count: max(0, colWidths[c] - text.unicodeScalars.count))
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if i == 0 {
                lines.append("|" + colWidths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 当期/前期判定

    /// グリッド先頭3行のテキストから当期/前期を判定する。
    static func detectPeriodFromGrid(_ grid: [[String]]) -> String? {
        for row in grid.prefix(3) {
            let joined = row.joined()
            let hasCurrent = currentPeriodKeywords.contains(where: joined.contains)
            let hasPrior = priorPeriodKeywords.contains(where: joined.contains)
            if hasCurrent && hasPrior { return "比較" }
            if hasCurrent { return "当期" }
            if hasPrior { return "前期" }
        }
        return nil
    }

    /// テーブル前の兄弟要素（短いもの）から当期/前期を判定する。
    /// Python 同様、親要素の先頭側の兄弟から順に走査する。
    private static func detectPeriodFromPreceding(_ table: Element) -> String? {
        guard let parent = table.parent() else { return nil }
        for node in parent.getChildNodes() {
            guard node.siblingIndex < table.siblingIndex else { break }
            let text: String
            if let el = node as? Element {
                text = bs4Text(el, strip: true)
            } else if let tn = node as? TextNode {
                text = tn.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                continue
            }
            if text.isEmpty || text.unicodeScalars.count > 100 { continue }
            if currentPeriodKeywords.contains(where: text.contains) { return "当期" }
            if priorPeriodKeywords.contains(where: text.contains) { return "前期" }
        }
        return nil
    }

    /// 当期/前期が未ラベルのテーブルに順序ルール（前期→当期の繰り返し）を適用する。
    static func applyPeriodOrdering(_ tables: inout [SegmentTable]) {
        var i = 0
        for idx in tables.indices where tables[idx].period == nil {
            tables[idx].period = i % 2 == 0 ? "前期" : "当期"
            i += 1
        }
    }

    // MARK: - TextBlock → テーブル抽出

    private static func findNextTable(after element: Element) -> Element? {
        var sibling = try? element.nextElementSibling()
        while let s = sibling {
            if s.tagName() == "table" { return s }
            if let found = (try? s.select("table"))?.first() { return found }
            sibling = try? s.nextElementSibling()
        }
        return nil
    }

    /// HTML内の全 <table> を Markdown 化して返す。
    static func allTablesFromHtml(_ html: String, defaultHeading: String) -> [SegmentTable] {
        guard let soup = try? SwiftSoup.parse(html),
              let tableEls = try? soup.select("table") else { return [] }
        var tables: [SegmentTable] = []
        for table in tableEls {
            let grid = expandTable(table)
            let md = gridToMarkdown(grid)
            if md.isEmpty { continue }
            let period = detectPeriodFromPreceding(table) ?? detectPeriodFromGrid(grid)
            tables.append(SegmentTable(heading: defaultHeading, markdown: md, period: period))
        }
        applyPeriodOrdering(&tables)
        return tables
    }

    /// 見出しキーワードに続く <table> を Markdown 化して返す。
    static func keywordTablesFromHtml(_ html: String, keywords: [String]) -> [SegmentTable] {
        guard let soup = try? SwiftSoup.parse(html) else { return [] }
        var tables: [SegmentTable] = []
        var seen = Set<ObjectIdentifier>()
        for keyword in keywords {
            guard let elems = try? soup.select("*") else { continue }
            for elem in elems {
                let text = bs4Text(elem, strip: false)
                guard text.contains(keyword), text.unicodeScalars.count <= 300 else { continue }
                guard let table = findNextTable(after: elem),
                      !seen.contains(ObjectIdentifier(table)) else { continue }
                seen.insert(ObjectIdentifier(table))
                let grid = expandTable(table)
                let md = gridToMarkdown(grid)
                if md.isEmpty { continue }
                let period = detectPeriodFromPreceding(table) ?? detectPeriodFromGrid(grid)
                tables.append(SegmentTable(heading: keyword, markdown: md, period: period))
            }
        }
        applyPeriodOrdering(&tables)
        return tables
    }

    /// TextBlock要素からHTML表を抽出する汎用ロジック。
    ///
    /// dedicatedTags に一致するブロックは全 table を返す。
    /// mixedTags に一致するブロックは mixedKeywords で見出しを絞る。
    private static func extractFromTextBlocks(
        xbrlDir: URL,
        dedicatedTags: Set<String>,
        mixedTags: Set<String>,
        dedicatedHeading: String,
        mixedKeywords: [String]
    ) -> [SegmentTable] {
        var tables: [SegmentTable] = []
        let targets = dedicatedTags.union(mixedTags)
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let collector = TextBlockSAXCollector(targetTags: targets)
            let parser = XMLParser(data: data)
            parser.delegate = collector
            parser.parse()
            for block in collector.blocks {
                guard !block.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      block.content.lowercased().contains("<table") else { continue }
                if dedicatedTags.contains(block.tag) {
                    tables.append(contentsOf: allTablesFromHtml(block.content, defaultHeading: dedicatedHeading))
                } else if mixedTags.contains(block.tag) {
                    tables.append(contentsOf: keywordTablesFromHtml(block.content, keywords: mixedKeywords))
                }
            }
        }
        return tables
    }

    // MARK: - dimension 付き fact 抽出（フォールバック）

    /// contextRef → {dimension局所名: member局所名} のマップを作る。
    static func loadDimensionContextMap(xbrlDir: URL) -> [String: [String: String]] {
        var contextMap: [String: [String: String]] = [:]
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let collector = ContextDimensionSAXCollector()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = collector
            parser.parse()
            contextMap.merge(collector.contextMap) { _, new in new }
        }
        return contextMap
    }

    private static func extractFactsByDimension(
        xbrlDir: URL,
        dimensionKeywords: [String],
        contextMap: [String: [String: String]]
    ) -> [SegmentFact] {
        let allFacts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        var results: [SegmentFact] = []
        for (tag, ctxMap) in allFacts {
            for (ctxID, fact) in ctxMap {
                guard let dims = contextMap[ctxID], !dims.isEmpty else { continue }
                guard dims.keys.contains(where: { dim in dimensionKeywords.contains(where: dim.contains) }) else { continue }
                results.append(SegmentFact(
                    tag: tag,
                    contextRef: ctxID,
                    dimensions: dims,
                    value: fact.value,
                    label: fact.label,
                    unitRef: fact.unitRef,
                    decimals: fact.decimals
                ))
            }
        }
        // Swift Dictionary は走査順が不定のため、出力を決定的にする
        return results.sorted { ($0.tag, $0.contextRef) < ($1.tag, $1.contextRef) }
    }

    private static func buildResult(
        xbrlDir: URL,
        tables: [SegmentTable],
        dimensionKeywords: [String]
    ) -> SegmentResult {
        if !tables.isEmpty {
            return SegmentResult(method: "html_table", tables: tables, facts: [])
        }
        let contextMap = loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = extractFactsByDimension(xbrlDir: xbrlDir, dimensionKeywords: dimensionKeywords, contextMap: contextMap)
        if !facts.isEmpty {
            return SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        }
        return SegmentResult(method: "not_found", tables: [], facts: [])
    }

    // MARK: - bs4 互換テキスト抽出

    /// BeautifulSoup の get_text() 互換: 子孫テキストノードを区切りなしで連結する。
    /// strip=true は各テキストノードを個別に trim して空を除く（全体 trim ではない）。
    static func bs4Text(_ node: Node, strip: Bool) -> String {
        var parts: [String] = []
        collectTextNodes(node, into: &parts)
        if strip {
            return parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined()
        }
        return parts.joined()
    }

    private static func collectTextNodes(_ node: Node, into parts: inout [String]) {
        if let textNode = node as? TextNode {
            parts.append(textNode.getWholeText())
            return
        }
        for child in node.getChildNodes() {
            collectTextNodes(child, into: &parts)
        }
    }
}

// MARK: - SAX コレクター (private)

/// 指定 local tag の TextBlock 要素のインナーコンテンツを全件収集する。
/// EDINET の TextBlock はエスケープ済み HTML がテキストとして埋め込まれているため、
/// foundCharacters の連結でデコード済み HTML 文字列が得られる。
private final class TextBlockSAXCollector: NSObject, XMLParserDelegate {
    private let targetTags: Set<String>
    private(set) var blocks: [(tag: String, content: String)] = []
    private var capturingTag: String?
    private var buffer = ""
    private var depth = 0

    init(targetTags: Set<String>) {
        self.targetTags = targetTags
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if capturingTag != nil {
            depth += 1
            let attrs = attributeDict.map { " \($0.key)=\"\($0.value)\"" }.joined()
            buffer += "<\(elementName)\(attrs)>"
            return
        }
        if targetTags.contains(XBRLUtils.localName(of: elementName)) {
            capturingTag = XBRLUtils.localName(of: elementName)
            buffer = ""
            depth = 0
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let tag = capturingTag else { return }
        if depth == 0 {
            blocks.append((tag: tag, content: buffer))
            capturingTag = nil
            buffer = ""
        } else {
            depth -= 1
            buffer += "</\(elementName)>"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingTag != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturingTag != nil {
            buffer += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}

/// xbrli:context の xbrldi:explicitMember から dimension マップを収集する。
/// shouldProcessNamespaces = true で使うこと（elementName が local name になる）。
private final class ContextDimensionSAXCollector: NSObject, XMLParserDelegate {
    private static let xbrldiNS = "http://xbrl.org/2006/xbrldi"

    private(set) var contextMap: [String: [String: String]] = [:]
    private var currentContextID: String?
    private var currentDims: [String: String] = [:]
    private var contextDepth = 0
    private var memberDimension: String?
    private var memberText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if currentContextID != nil {
            contextDepth += 1
            if elementName == "explicitMember", namespaceURI == Self.xbrldiNS {
                memberDimension = attributeDict["dimension"]
                memberText = ""
            }
        } else if elementName == "context", let id = attributeDict["id"] {
            currentContextID = id
            currentDims = [:]
            contextDepth = 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if memberDimension != nil { memberText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if let dim = memberDimension, elementName == "explicitMember", namespaceURI == Self.xbrldiNS {
            let dimLocal = localPart(dim)
            let valLocal = localPart(memberText.trimmingCharacters(in: .whitespacesAndNewlines))
            if !dimLocal.isEmpty && !valLocal.isEmpty {
                currentDims[dimLocal] = valLocal
            }
            memberDimension = nil
            memberText = ""
        }
        guard currentContextID != nil else { return }
        if contextDepth == 0 {
            if !currentDims.isEmpty {
                contextMap[currentContextID!] = currentDims
            }
            currentContextID = nil
        } else {
            contextDepth -= 1
        }
    }

    private func localPart(_ qname: String) -> String {
        guard let idx = qname.lastIndex(of: ":") else { return qname }
        return String(qname[qname.index(after: idx)...])
    }
}
