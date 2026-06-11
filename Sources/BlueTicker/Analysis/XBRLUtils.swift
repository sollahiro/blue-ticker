// XBRL 解析共通ユーティリティ
// Python の blue_ticker/analysis/xbrl_utils.py 相当

import Foundation
import SwiftSoup

// MARK: - Module-level label/role cache

// nonisolated(unsafe): access is serialized by _cacheLock
nonisolated(unsafe) private var _labelCache: [URL: [String: String]] = [:]
nonisolated(unsafe) private var _roleCache: [URL: [String: [String]]] = [:]
private let _cacheLock = NSLock()

// MARK: - Core Utilities

enum XBRLUtils {

    // MARK: Value Parsers

    /// XBRL数値テキストを Double に変換。nil・空文字は nil を返す。
    static func parseXbrlValue(_ text: String?) -> Double? {
        guard let t = text, !t.isEmpty else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "nil" { return nil }
        return Double(trimmed)
    }

    /// HTML表セルの数値テキストを Double に変換（百万円単位のまま）。
    /// "22,548" → 22548.0 / "△8,752" → -8752.0 / "－" → nil
    static func parseHtmlNumber(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        let unitSuffixes = ["百万円", "十万円", "億円", "兆円", "千円", "百円", "万円", "円"]
        for suffix in unitSuffixes {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        s = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
        if s.hasPrefix("△") { s = "-" + s.dropFirst() }
        if ["－", "-", "―", "—", ""].contains(s) { return nil }
        return Double(s)
    }

    /// HTML要素の整数属性を安全に読む。
    static func parseHtmlIntAttribute(_ element: Element, _ attr: String, default defaultValue: Int = 1) -> Int {
        guard let value = try? element.attr(attr) else { return defaultValue }
        return Int(value) ?? defaultValue
    }

    // MARK: Name Utilities

    /// XML タグから local name を取り出す。"{URI}Name" → "Name" / "prefix:Name" → "Name"
    static func localName(of name: String) -> String {
        if let range = name.range(of: "}") {
            return String(name[range.upperBound...])
        }
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }

    /// linkbase の href フラグメントから XBRL 要素の local name を取り出す。
    static func conceptLocalName(from href: String) -> String {
        let fragment = href.split(separator: "#").last.map(String.init) ?? href
        if fragment.contains(":") {
            return String(fragment.split(separator: ":").last ?? Substring(fragment))
        }
        let parts = fragment.split(separator: "_").map(String.init)
        for part in parts.reversed() where !part.isEmpty && part.first!.isUppercase {
            return part
        }
        return fragment
    }

    /// role URI から section 名を取り出す。"rol_" プレフィックスは除去。
    static func sectionNameFromRole(_ role: String) -> String {
        var s = role
        while s.hasSuffix("/") { s.removeLast() }
        if let idx = s.lastIndex(of: "/") {
            s = String(s[s.index(after: idx)...])
        }
        return s.hasPrefix("rol_") ? String(s.dropFirst(4)) : s
    }

    /// contextRef と role リストから連結/個別を推論する。
    static func inferConsolidation(contextRef: String, roles: [String]) -> String {
        let roleText = roles.map { sectionNameFromRole($0) }.joined(separator: " ")
        if contextRef.contains("_NonConsolidated") || roleText.contains("ReportingCompany") {
            return "non_consolidated"
        }
        if roleText.contains("Consolidated") { return "consolidated" }
        return "unknown"
    }

    // MARK: File Discovery

    /// xbrlDir 内で指定プレフィックス（0105010 等）で始まる HTML ファイルを返す。
    /// PublicDoc 直下と XBRL/PublicDoc の両方を探索する。
    static func findHtmlByPrefix(in dir: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        let candidates = [dir, dir.appendingPathComponent("XBRL/PublicDoc")]
        for searchDir in candidates {
            guard let entries = try? fm.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil) else { continue }
            let files = entries
                .filter {
                    ["htm", "html"].contains($0.pathExtension.lowercased())
                        && $0.lastPathComponent.hasPrefix(prefix)
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let f = files.first { return f }
        }
        return nil
    }

    /// XBRL ディレクトリからインスタンス文書（.xml / .xbrl）を返す。
    /// ラベル・プレゼンテーション・計算・定義リンクベースは除外する。
    static func findXbrlFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let excludeSuffixes = ["_lab", "_pre", "_cal", "_def"]
        var result: [URL] = []
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if ext == "xml" {
                if !excludeSuffixes.contains(where: { name.contains($0) }) {
                    result.append(url)
                }
            } else if ext == "xbrl" {
                result.append(url)
            }
        }
        return result
    }

    private static func linkbaseXmlFiles(in dir: URL, suffix: String) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if url.pathExtension.lowercased() == "xml" && name.contains(suffix) {
                result.append(url)
            }
        }
        return result
    }

    // MARK: Linkbase Loaders

    /// ラベルリンクベースから {local_tag: Japanese label} を作る。同一ディレクトリはキャッシュを返す。
    static func loadLabelsByTag(in dir: URL) -> [String: String] {
        _cacheLock.lock()
        if let cached = _labelCache[dir] { _cacheLock.unlock(); return cached }
        _cacheLock.unlock()

        var labelsByTag: [String: String] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_lab") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = LabelLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (tag, text) in parser.labelsByTag {
                labelsByTag[tag] = text
            }
        }

        _cacheLock.lock()
        _labelCache[dir] = labelsByTag
        _cacheLock.unlock()
        return labelsByTag
    }

    /// プレゼンテーションリンクベースから {local_tag: roleURI list} を作る。同一ディレクトリはキャッシュを返す。
    static func loadRolesByTag(in dir: URL) -> [String: [String]] {
        _cacheLock.lock()
        if let cached = _roleCache[dir] { _cacheLock.unlock(); return cached }
        _cacheLock.unlock()

        var roleSetsByTag: [String: Set<String>] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_pre") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = PresentationLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (tag, roles) in parser.roleSetsByTag {
                roleSetsByTag[tag, default: []].formUnion(roles)
            }
        }

        let result = roleSetsByTag.mapValues { Array($0).sorted() }
        _cacheLock.lock()
        _roleCache[dir] = result
        _cacheLock.unlock()
        return result
    }

    // MARK: Fact Collection

    /// XMLファイルから {local_tag: {contextRef: XbrlFact}} の辞書を返す。
    static func collectNumericFacts(
        in file: URL,
        allowedTags: Set<String>? = nil,
        nilAsZero: Bool = false,
        labelsByTag: [String: String] = [:],
        rolesByTag: [String: [String]] = [:]
    ) -> XbrlFactIndex {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let delegate = XBRLNumericsParser(
            allowedTags: allowedTags,
            nilAsZero: nilAsZero,
            labelsByTag: labelsByTag,
            rolesByTag: rolesByTag,
            sourceFile: file.lastPathComponent
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    /// XMLファイルから {local_tag: {contextRef: value}} の辞書を返す。
    static func collectNumericElements(
        in file: URL,
        allowedTags: Set<String>? = nil,
        nilAsZero: Bool = false
    ) -> XbrlTagElements {
        factIndexToNumericElements(collectNumericFacts(in: file, allowedTags: allowedTags, nilAsZero: nilAsZero))
    }

    /// XBRLディレクトリ内の全数値 fact をメタ情報付きで返す。
    static func collectAllNumericFacts(in dir: URL, nilAsZero: Bool = true) -> XbrlFactIndex {
        var allFacts: XbrlFactIndex = [:]
        let labelsByTag = loadLabelsByTag(in: dir)
        let rolesByTag = loadRolesByTag(in: dir)
        for file in findXbrlFiles(in: dir) {
            for (tag, ctxMap) in collectNumericFacts(
                in: file,
                allowedTags: nil,
                nilAsZero: nilAsZero,
                labelsByTag: labelsByTag,
                rolesByTag: rolesByTag
            ) {
                for (ctx, fact) in ctxMap {
                    allFacts[tag, default: [:]][ctx] = fact
                }
            }
        }
        return allFacts
    }

    /// XBRLディレクトリ内の全ファイルを一括パースし、全タグの数値要素を返す。
    static func collectAllNumericElements(in dir: URL, nilAsZero: Bool = true) -> XbrlTagElements {
        factIndexToNumericElements(collectAllNumericFacts(in: dir, nilAsZero: nilAsZero))
    }

    // MARK: Index Transforms

    /// fact index を既存抽出器互換の {tag: {contextRef: value}} に変換する。
    static func factIndexToNumericElements(_ facts: XbrlFactIndex) -> XbrlTagElements {
        facts.mapValues { ctxMap in ctxMap.mapValues { $0.value } }
    }

    /// statement/role section を優先して fact index を絞り込む。
    static func filterFactIndexBySections(
        _ facts: XbrlFactIndex,
        preferred: [String],
        fallback: [String] = []
    ) -> XbrlFactIndex {
        func filter(sections: [String]) -> XbrlFactIndex {
            let sectionSet = Set(sections)
            var result: XbrlFactIndex = [:]
            for (tag, ctxMap) in facts {
                for (ctx, fact) in ctxMap {
                    let factSections = factSectionSet(fact)
                    guard !factSections.isDisjoint(with: sectionSet) else { continue }
                    result[tag, default: [:]][ctx] = fact
                }
            }
            return result
        }
        let pref = filter(sections: preferred)
        if !pref.isEmpty { return pref }
        if !fallback.isEmpty { return filter(sections: fallback) }
        return [:]
    }

    private static func factSectionSet(_ fact: XbrlFact) -> Set<String> {
        var result = Set<String>()
        if let s = fact.section { result.insert(s) }
        if let ss = fact.sections { result.formUnion(ss) }
        return result
    }

    // MARK: IFRS TextBlock

    /// IFRS Summary型XBRLのTextBlock HTMLテーブルをパースする。
    /// ラベル → (当期値, 前期値) を返す。値は百万円単位。
    static func extractIfrsTextblockTable(
        in dir: URL,
        textblockTag: String
    ) -> [String: (current: Double?, prior: Double?)] {
        let pattern = try? NSRegularExpression(
            pattern: "<[^>]*:" + NSRegularExpression.escapedPattern(for: textblockTag) + "[^>]*>(.*?)</[^>]*:" + NSRegularExpression.escapedPattern(for: textblockTag) + ">",
            options: [.dotMatchesLineSeparators]
        )

        for xbrlFile in findXbrlFiles(in: dir) {
            guard let raw = try? String(contentsOf: xbrlFile, encoding: .utf8) else { continue }
            guard let match = pattern?.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { continue }

            let htmlContent = String(raw[range]).htmlEntityDecoded
            guard let soup = try? SwiftSoup.parse(htmlContent) else { continue }

            var result: [String: (current: Double?, prior: Double?)] = [:]
            guard let rows = try? soup.select("tr") else { continue }
            for row in rows {
                guard let cells = try? row.select("td"), cells.count >= 3 else { continue }
                guard let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true),
                      !label.isEmpty else { continue }
                let dataCells = Array(cells.dropFirst())
                guard dataCells.count >= 2 else { continue }
                let currentV = parseIfrsTextblockCellValue(try? dataCells.last?.text())
                let priorV = parseIfrsTextblockCellValue(try? dataCells[dataCells.count - 2].text())
                if currentV != nil || priorV != nil {
                    result[label] = (currentV, priorV)
                }
            }
            return result
        }
        return [:]
    }

    private static func parseIfrsTextblockCellValue(_ text: String?) -> Double? {
        guard let t = text else { return nil }
        var s = t.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.isEmpty || ["－", "-", "—", "―"].contains(s) { return nil }
        let negative = s.hasPrefix("△") || s.hasPrefix("▲")
        s = s.replacingOccurrences(of: "△", with: "").replacingOccurrences(of: "▲", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        guard let val = Double(s) else { return nil }
        return negative ? -val : val
    }

    // MARK: HTML Label Extraction

    /// soup の全 <tr> を走査し label_map に一致する行の当期/前期値を返す。
    static func extractHtmlLabels(
        from element: Element,
        labelMap: [String: String]
    ) -> FieldSet {
        var fieldSet: FieldSet = [:]
        var remaining = Set(labelMap.keys)

        // 仮想タグ → 対応ラベルの集合（一括除去用）
        var tagToLabels: [String: Set<String>] = [:]
        for (lbl, vtag) in labelMap {
            tagToLabels[vtag, default: []].insert(lbl)
        }

        guard let rows = try? element.select("tr") else { return fieldSet }
        for row in rows {
            guard !remaining.isEmpty else { break }
            guard let cells = try? row.select("td, th"), !cells.isEmpty else { continue }
            let texts = cells.array().compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }
                .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
            guard !texts.isEmpty else { continue }

            var matched: String?
            for label in remaining where texts[0] == label { matched = label; break }
            if matched == nil {
                for label in remaining.sorted(by: { $0.count > $1.count }) {
                    if texts[0].contains(label) { matched = label; break }
                }
            }
            guard let lbl = matched else { continue }

            let numbers = texts.map { parseHtmlNumber($0) }
            let allNums = numbers.compactMap { $0 }
            guard !allNums.isEmpty else { continue }
            let financial = allNums.filter { abs($0) >= 200 }
            let found = financial.isEmpty ? allNums : financial
            let current = found.last! * Financial.millionYen
            let prior: Double? = found.count >= 2 ? found[found.count - 2] * Financial.millionYen : nil
            let vtag = labelMap[lbl]!
            fieldSet[vtag] = FieldValue(current: current, prior: prior)
            remaining.subtract(tagToLabels[vtag] ?? [])
        }
        return fieldSet
    }
}

// MARK: - HTML entity decode helper

private extension String {
    var htmlEntityDecoded: String {
        // Simple HTML entity unescaping for textblock content
        var s = self
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", "\u{00A0}"),
        ]
        for (entity, char) in entities { s = s.replacingOccurrences(of: entity, with: char) }
        return s
    }
}

// MARK: - SAX Parsers (private)

private final class XBRLNumericsParser: NSObject, XMLParserDelegate {
    var results: XbrlFactIndex = [:]

    private let allowedTags: Set<String>?
    private let nilAsZero: Bool
    private let labelsByTag: [String: String]
    private let rolesByTag: [String: [String]]
    private let sourceFile: String

    private var currentLocalTag = ""
    private var currentCtx = ""
    private var currentText = ""
    private var currentAttrs: [String: String] = [:]
    private var capturing = false

    init(
        allowedTags: Set<String>?,
        nilAsZero: Bool,
        labelsByTag: [String: String],
        rolesByTag: [String: [String]],
        sourceFile: String
    ) {
        self.allowedTags = allowedTags
        self.nilAsZero = nilAsZero
        self.labelsByTag = labelsByTag
        self.rolesByTag = rolesByTag
        self.sourceFile = sourceFile
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        capturing = false
        let localTag = XBRLUtils.localName(of: elementName)
        if let allowed = allowedTags, !allowed.contains(localTag) { return }
        guard let ctx = attributeDict["contextRef"], !ctx.isEmpty else { return }
        currentLocalTag = localTag
        currentCtx = ctx
        currentText = ""
        currentAttrs = attributeDict
        capturing = true
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturing else { return }
        capturing = false

        var value = XBRLUtils.parseXbrlValue(currentText)
        if value == nil && nilAsZero {
            let nilVal = currentAttrs["xsi:nil"] ?? currentAttrs["nil"]
            if nilVal?.lowercased() == "true" { value = 0.0 }
        }
        guard let v = value else { return }

        let roles = rolesByTag[currentLocalTag] ?? []
        let sections = roles.map { XBRLUtils.sectionNameFromRole($0) }

        var fact = XbrlFact(
            tag: currentLocalTag,
            contextRef: currentCtx,
            value: v,
            consolidation: XBRLUtils.inferConsolidation(contextRef: currentCtx, roles: roles)
        )
        fact.unitRef = currentAttrs["unitRef"]
        fact.decimals = currentAttrs["decimals"]
        if !roles.isEmpty { fact.role = roles[0]; fact.roles = roles }
        if !sections.isEmpty { fact.section = sections[0]; fact.sections = sections }
        fact.label = labelsByTag[currentLocalTag]
        fact.sourceFile = sourceFile

        results[currentLocalTag, default: [:]][currentCtx] = fact
    }
}

private final class LabelLinkbaseParser: NSObject, XMLParserDelegate {
    var labelsByTag: [String: String] = [:]

    private var locByLabel: [String: String] = [:]
    private var labelTextByResource: [String: (role: String, text: String)] = [:]
    private var arcs: [(from: String, to: String)] = []

    private var capturingLabel = false
    private var currentXlinkLabel = ""
    private var currentRole = ""
    private var currentText = ""

    private let roleLabel = "http://www.xbrl.org/2003/role/label"

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        capturingLabel = false
        currentText = ""
        let local = XBRLUtils.localName(of: elementName)

        switch local {
        case "loc":
            if let xlinkLabel = attributeDict["xlink:label"], let href = attributeDict["xlink:href"] {
                locByLabel[xlinkLabel] = XBRLUtils.conceptLocalName(from: href)
            }
        case "label":
            let lang = attributeDict["xml:lang"]
            if let l = lang, l != "ja" { return }
            currentXlinkLabel = attributeDict["xlink:label"] ?? ""
            currentRole = attributeDict["xlink:role"] ?? ""
            capturingLabel = true
        case "labelArc":
            if let from = attributeDict["xlink:from"], let to = attributeDict["xlink:to"] {
                arcs.append((from: from, to: to))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingLabel { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturingLabel, XBRLUtils.localName(of: elementName) == "label" else { return }
        capturingLabel = false
        let text = currentText.trimmingCharacters(in: .whitespaces)
        if !currentXlinkLabel.isEmpty && !text.isEmpty {
            labelTextByResource[currentXlinkLabel] = (currentRole, text)
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        for (from, to) in arcs {
            guard let tag = locByLabel[from], let pair = labelTextByResource[to] else { continue }
            if pair.role == roleLabel || labelsByTag[tag] == nil {
                labelsByTag[tag] = pair.text
            }
        }
    }
}

private final class PresentationLinkbaseParser: NSObject, XMLParserDelegate {
    var roleSetsByTag: [String: Set<String>] = [:]

    private var currentRole = ""
    private var inPresentationLink = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let local = XBRLUtils.localName(of: elementName)

        switch local {
        case "presentationLink":
            currentRole = attributeDict["xlink:role"] ?? ""
            inPresentationLink = !currentRole.isEmpty
        case "loc" where inPresentationLink:
            if let href = attributeDict["xlink:href"] {
                let tag = XBRLUtils.conceptLocalName(from: href)
                roleSetsByTag[tag, default: []].insert(currentRole)
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if XBRLUtils.localName(of: elementName) == "presentationLink" {
            inPresentationLink = false
        }
    }
}
