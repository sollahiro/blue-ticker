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

extension SegmentResult {
    /// toDictionary() の逆変換。remote CLI が filing-content の JSON をローカル同等に描画するために使う。
    init(dictionary: [String: Any]) {
        method = dictionary["method"] as? String ?? "not_found"
        tables = (dictionary["tables"] as? [[String: Any]] ?? []).map { t in
            SegmentTable(
                heading: t["heading"] as? String ?? "",
                markdown: t["markdown"] as? String ?? "",
                period: t["period"] as? String
            )
        }
        facts = (dictionary["facts"] as? [[String: Any]] ?? []).map { f in
            SegmentFact(
                tag: f["tag"] as? String ?? "",
                contextRef: f["contextRef"] as? String ?? "",
                dimensions: f["dimensions"] as? [String: String] ?? [:],
                value: f["value"] as? Double ?? 0,
                label: f["label"] as? String,
                unitRef: f["unitRef"] as? String,
                decimals: f["decimals"] as? String
            )
        }
    }
}

enum SegmentExtractor {

    private static let currentPeriodKeywords = ["当連結会計年度", "当期"]
    private static let priorPeriodKeywords = ["前連結会計年度", "前期"]

    // MARK: - 公開 API

    /// filing コマンド・REST API の sections で使う特殊セクション名（XBRLSectionDef 非経由）。
    static let specialSectionKeys = ["segments", "geography", "revenue_recognition"]

    /// 特殊セクションの表示タイトル。
    static let specialSectionTitles: [String: String] = [
        "segments": "セグメント情報",
        "geography": "地域別情報",
        "revenue_recognition": "収益認識関係",
    ]

    /// 特殊セクション名に対応する抽出を実行する。未対応の名前は nil。
    static func extractSpecialSection(_ section: String, xbrlDir: URL) -> SegmentResult? {
        switch section {
        case "segments": return extractSegmentInfo(xbrlDir: xbrlDir)
        case "geography": return extractGeographyInfo(xbrlDir: xbrlDir)
        case "revenue_recognition": return extractRevenueRecognitionInfo(xbrlDir: xbrlDir)
        default: return nil
        }
    }

    /// 連結財務諸表注記から事業別（報告セグメント別）情報を抽出する。
    ///
    /// 報告セグメント（xbrl_facts 経路）のメンバーが全て地域名の場合（オークマ型:
    /// docs/segment-normalization-concept.md 学び10）、その内容は「事業別」ではなく
    /// 「地域別」であるため、収益認識関係注記（`extractRevenueRecognitionInfo`）に本当の
    /// 事業別（製品別）データがあればそちらを優先する。見つからない場合は元の地域別
    /// xbrl_facts をそのまま返す（未検証企業での誤判定時に表示が消える regression を避けるため）。
    static func extractSegmentInfo(xbrlDir: URL) -> SegmentResult {
        let tables = extractFromTextBlocks(
            xbrlDir: xbrlDir,
            dedicatedTags: Xbrl.businessSegmentTextBlockTags,
            mixedTags: Xbrl.businessSegmentMixedTextBlockTags,
            dedicatedHeading: "セグメント情報",
            mixedKeywords: Xbrl.businessSegmentHeadingKeywords,
            mixedHeadingExclusionKeywords: Xbrl.businessSegmentHeadingExclusionKeywords
        )
        let result = buildResult(xbrlDir: xbrlDir, tables: tables, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords)

        guard result.method == "xbrl_facts", isGeographyAxis(result.facts) else { return result }
        let revenueRecognition = extractRevenueRecognitionInfo(xbrlDir: xbrlDir)
        return revenueRecognition.method == "html_table" ? revenueRecognition : result
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

    /// 連結財務諸表注記（収益認識関係）から「顧客との契約から生じる収益を分解した情報」を抽出する。
    /// オークマ型（報告セグメントが地域別）の会社で、本当の事業別（製品別）データの実在ソース。
    static func extractRevenueRecognitionInfo(xbrlDir: URL) -> SegmentResult {
        let tables = extractFromTextBlocks(
            xbrlDir: xbrlDir,
            dedicatedTags: Xbrl.revenueRecognitionTextBlockTags,
            mixedTags: [],
            dedicatedHeading: "収益認識関係",
            mixedKeywords: []
        )
        return buildResult(xbrlDir: xbrlDir, tables: tables, dimensionKeywords: [])
    }

    /// segment 行（小計・調整行を除く）の member ラベルが全て地域名キーワードに一致するか。
    /// `SegmentNormalizer.classifyAxis` と同じ「全一致 → geography」判定だが、数値による
    /// 小計判定（consolidatedSales が要る2次判定）は使わず、標準タクソノミの小計・調整
    /// member 名（1次判定）のみで segment 行を絞る。raw 抽出層では sales を持たないため。
    private static func isGeographyAxis(_ facts: [SegmentFact]) -> Bool {
        let segmentMembers = facts.compactMap { fact -> String? in
            guard let member = primaryMember(fact.dimensions),
                  !Xbrl.segmentSubtotalMemberNames.contains(member),
                  !Xbrl.segmentReconcilingMemberNames.contains(member)
            else { return nil }
            return member
        }
        guard !segmentMembers.isEmpty else { return false }
        let uniqueMembers = Set(segmentMembers)
        return uniqueMembers.allSatisfy { member in
            Xbrl.segmentGeographyMemberKeywords.contains(where: member.contains)
        }
    }

    /// dimensions のうち ConsolidatedOrNonConsolidatedAxis 以外の member を行ラベルとする。
    /// `SegmentNormalizer.primaryMember` と同じ規約（dimension キー名の辞書順で先頭を採用）。
    private static func primaryMember(_ dimensions: [String: String]) -> String? {
        dimensions
            .filter { $0.key != "ConsolidatedOrNonConsolidatedAxis" }
            .sorted { $0.key < $1.key }
            .first?.value
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
    /// 同じ親の下に複数テーブルが並ぶ場合、テーブルに最も近い（最後に見つかった）
    /// 見出しを採用する（先頭の見出しに固定されるとテーブルが増えるほど誤判定が広がるため）。
    private static func detectPeriodFromPreceding(_ table: Element) -> String? {
        guard let parent = table.parent() else { return nil }
        var result: String?
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
            if text.isEmpty || text.unicodeScalars.count > Xbrl.noteShortCaptionMaxLength { continue }
            if currentPeriodKeywords.contains(where: text.contains) {
                result = "当期"
            } else if priorPeriodKeywords.contains(where: text.contains) {
                result = "前期"
            }
        }
        return result
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

    /// table の直後に、短いラベル（例:「第125期」）だけを挟んで次の表が続いていないかを調べる。
    /// 「第n期及び第n+1期における...は以下のとおりであります」のように前期・当期を1つの見出しで
    /// まとめて紹介し、表ごとに個別の <div> でラップされているケースで必要（実データ: キヤノン
    /// 地域別注記）。table 自身の nextElementSibling だけでは辿れない（table が div の唯一の
    /// 子だと兄弟が無い）ため、table 自身の兄弟 → 1段親（ラッパー div 等）の兄弟の順に探す。
    /// 挟まる要素のテキストが長ければ無関係な話題への移行とみなし nil を返す。
    private static func findImmediatelyChainedTable(after table: Element) -> Element? {
        let startPoints: [Element] = [table, table.parent()].compactMap { $0 }
        for start in startPoints {
            var sibling = try? start.nextElementSibling()
            var hops = 0
            while let s = sibling, hops < Xbrl.noteTableChainMaxGapElements {
                hops += 1
                if s.tagName() == "table" { return s }
                if let found = (try? s.select("table"))?.first() { return found }
                let text = bs4Text(s, strip: true)
                // この起点（table 自身 or 1段親）での探索を打ち切るだけで、次の起点は引き続き試す
                // （1段目で長文に当たっても、2段目（親の兄弟）側は無関係とは限らないため）。
                if text.unicodeScalars.count > Xbrl.noteShortCaptionMaxLength { break }
                sibling = try? s.nextElementSibling()
            }
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
    ///
    /// headingExclusionKeywords: 見出し候補の文字列がこれらを含む場合はスキップする
    /// （例: 事業別セグメント用の検索で「地域別セグメント情報」という地域注記の見出しを誤って拾わないようにする）。
    static func keywordTablesFromHtml(
        _ html: String,
        keywords: [String],
        headingExclusionKeywords: [String] = []
    ) -> [SegmentTable] {
        guard let soup = try? SwiftSoup.parse(html) else { return [] }
        var tables: [SegmentTable] = []
        var seen = Set<ObjectIdentifier>()
        for keyword in keywords {
            guard let elems = try? soup.select("*") else { continue }
            for elem in elems {
                let text = bs4Text(elem, strip: false)
                guard text.contains(keyword), text.unicodeScalars.count <= 300 else { continue }
                if headingExclusionKeywords.contains(where: text.contains) { continue }
                // 直後の表が除外対象（ノイズ）だった場合、同じ見出しの下にある次の表を
                // 一定回数まで探す（見出し直後にノイズ表→本表と並ぶ構成を取りこぼさないため）。
                var candidate = findNextTable(after: elem)
                var attempts = 0
                while let table = candidate, attempts < Xbrl.noteTableLookaheadLimit {
                    attempts += 1
                    guard !seen.contains(ObjectIdentifier(table)) else {
                        candidate = findNextTable(after: table)
                        continue
                    }
                    seen.insert(ObjectIdentifier(table))
                    let grid = expandTable(table)
                    let md = gridToMarkdown(grid)
                    if md.isEmpty || Xbrl.noteTableExclusionKeywords.contains(where: md.contains) {
                        candidate = findNextTable(after: table)
                        continue
                    }
                    let period = detectPeriodFromPreceding(table) ?? detectPeriodFromGrid(grid)
                    tables.append(SegmentTable(heading: keyword, markdown: md, period: period))

                    // 同じ開示が前期・当期の表を1つの見出しでまとめて紹介しているケース
                    // （学び参照）: 直後に短いラベルだけを挟んで続く表があり、かつ見出し行
                    // （grid 先頭行）が完全一致するなら「同じ表の続き」とみなして拾い続ける。
                    // 見出し行が違う/直後に表が続かないなら別の開示とみなし打ち切る。
                    if let chained = findImmediatelyChainedTable(after: table),
                       !seen.contains(ObjectIdentifier(chained)) {
                        let chainedGrid = expandTable(chained)
                        if chainedGrid.first == grid.first {
                            candidate = chained
                            continue
                        }
                    }
                    break
                }
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
        mixedKeywords: [String],
        mixedHeadingExclusionKeywords: [String] = []
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
                    tables.append(contentsOf: keywordTablesFromHtml(
                        block.content,
                        keywords: mixedKeywords,
                        headingExclusionKeywords: mixedHeadingExclusionKeywords
                    ))
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
