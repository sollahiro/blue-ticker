import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import BlueTickerCore

enum PocJevIO {
    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var pocDir: URL { repoRoot().appendingPathComponent("scripts/poc-jev") }
    static var dataDir: URL { pocDir.appendingPathComponent("snapshots") }
    static var outDir: URL { pocDir.appendingPathComponent("out") }

    static func loadJSONArray(_ name: String) throws -> [[String: Any]] {
        let url = dataDir.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "PocJev", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected JSON array in \(name)",
            ])
        }
        return arr
    }

    static func writeJSONL(_ rows: [[String: Any]], to name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appendingPathComponent(name)
        var lines: [String] = []
        lines.reserveCapacity(rows.count)
        for row in rows {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            guard let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func writeText(_ text: String, to name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func copyToArtifacts() {
        let artifacts = URL(fileURLWithPath: "/opt/cursor/artifacts")
        guard FileManager.default.fileExists(atPath: artifacts.path) else { return }
        for name in ["tag_classify.jsonl", "table_select.jsonl", "cell_select.jsonl",
                     "token_sizes.json", "mass_missing_diagnosis.md", "export_report.json"] {
            let src = outDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dest = artifacts.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: src, to: dest)
        }
    }
}

/// R2 GET only. `putObject` is a hard no-op so EDINET fallback never uploads.
struct GetOnlyXbrlStore: XbrlObjectStoring {
    let inner: R2XbrlObjectStore
    func getObject(key: String) async -> Data? { await inner.getObject(key: key) }
    func putObject(_ data: Data, key: String, contentType: String) async -> Bool { false }
}

enum PocJevLabels {
    static func englishLabels(in dir: URL) -> [String: String] {
        var labels: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return labels
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            guard name.contains("lab") && name.contains("-en") && name.hasSuffix(".xml") else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let parser = EnglishLabelParser()
            let xml = XMLParser(data: data)
            xml.delegate = parser
            xml.parse()
            for (tag, text) in parser.labelsByTag where labels[tag] == nil {
                labels[tag] = text
            }
        }
        return labels
    }

    static func qnames(in dir: URL) -> [String: String] {
        var map: [String: String] = [:]
        for file in XBRLUtils.findXbrlFiles(in: dir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let parser = QNameCollector()
            let xml = XMLParser(data: data)
            xml.delegate = parser
            xml.parse()
            for (local, qname) in parser.qnameByLocal where map[local] == nil {
                map[local] = qname
            }
        }
        return map
    }

    /// Child local name → (parent local name, parent ja label) from calculation linkbase.
    static func calcParents(in dir: URL, jaLabels: [String: String]) -> [String: (parent: String, label: String)] {
        let byRole = XBRLUtils.loadCalculationComponents(in: dir)
        var result: [String: (parent: String, label: String)] = [:]
        for (_, parentMap) in byRole {
            for (parent, children) in parentMap {
                for child in children where result[child.tag] == nil {
                    result[child.tag] = (parent, jaLabels[parent] ?? "")
                }
            }
        }
        return result
    }
}

private final class EnglishLabelParser: NSObject, XMLParserDelegate {
    var labelsByTag: [String: String] = [:]
    private var locByLabel: [String: String] = [:]
    private var labelTextByResource: [String: String] = [:]
    private var arcs: [(from: String, to: String)] = []
    private var capturing = false
    private var currentXlinkLabel = ""
    private var currentText = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        capturing = false
        currentText = ""
        let local = XBRLUtils.localName(of: elementName)
        switch local {
        case "loc":
            if let xlinkLabel = attributeDict["xlink:label"], let href = attributeDict["xlink:href"] {
                locByLabel[xlinkLabel] = XBRLUtils.conceptLocalName(from: href)
            }
        case "label":
            let lang = attributeDict["xml:lang"] ?? "en"
            guard lang.lowercased().hasPrefix("en") else { return }
            currentXlinkLabel = attributeDict["xlink:label"] ?? ""
            capturing = true
        case "labelArc":
            if let from = attributeDict["xlink:from"], let to = attributeDict["xlink:to"] {
                arcs.append((from: from, to: to))
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { currentText += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturing, XBRLUtils.localName(of: elementName) == "label" else { return }
        capturing = false
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentXlinkLabel.isEmpty && !text.isEmpty {
            labelTextByResource[currentXlinkLabel] = text
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        for (from, to) in arcs {
            guard let tag = locByLabel[from], let text = labelTextByResource[to] else { continue }
            if labelsByTag[tag] == nil { labelsByTag[tag] = text }
        }
    }
}

private final class QNameCollector: NSObject, XMLParserDelegate {
    var qnameByLocal: [String: String] = [:]

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        guard attributeDict["contextRef"] != nil else { return }
        let local = XBRLUtils.localName(of: elementName)
        if qnameByLocal[local] == nil {
            if elementName.contains(":") {
                qnameByLocal[local] = elementName
            } else if let qName, qName.contains(":") {
                qnameByLocal[local] = qName
            } else {
                qnameByLocal[local] = local
            }
        }
    }
}

enum PocJevFacts {
    static func isCurrentConsolidated(_ ctx: String) -> Bool {
        ContextHelpers.isConsolidatedDuration(ctx) || ContextHelpers.isConsolidatedInstant(ctx)
    }

    static func isCurrentPureNonConsolidated(_ ctx: String) -> Bool {
        ContextHelpers.isPureNonConsolidatedContext(ctx, patterns: Xbrl.durationContextPatterns)
            || ContextHelpers.isPureNonConsolidatedContext(ctx, patterns: Xbrl.instantContextPatterns)
    }

    /// Current-period consolidated facts, with per-tag non-consolidated fallback when that tag has no consolidated current fact.
    static func currentPeriodFacts(from index: XbrlFactIndex) -> [(tag: String, fact: XbrlFact)] {
        var consByTag: [String: XbrlFact] = [:]
        var ncByTag: [String: XbrlFact] = [:]
        for (tag, ctxMap) in index {
            for (_, fact) in ctxMap {
                if isCurrentConsolidated(fact.contextRef) {
                    if consByTag[tag] == nil { consByTag[tag] = fact }
                } else if isCurrentPureNonConsolidated(fact.contextRef) {
                    if ncByTag[tag] == nil { ncByTag[tag] = fact }
                }
            }
        }
        var out: [(String, XbrlFact)] = []
        let tags = Set(consByTag.keys).union(ncByTag.keys)
        let hasAnyCons = !consByTag.isEmpty
        for tag in tags.sorted() {
            if hasAnyCons {
                if let f = consByTag[tag] {
                    out.append((tag, f))
                } else if let f = ncByTag[tag] {
                    out.append((tag, f))
                }
            } else if let f = ncByTag[tag] {
                out.append((tag, f))
            }
        }
        return out
    }

    static func contextCensus(_ index: XbrlFactIndex) -> [String: Int] {
        var counts: [String: Int] = [
            "consolidated_current": 0,
            "pure_nc_current": 0,
            "other": 0,
        ]
        for (_, ctxMap) in index {
            for ctx in ctxMap.keys {
                if isCurrentConsolidated(ctx) {
                    counts["consolidated_current", default: 0] += 1
                } else if isCurrentPureNonConsolidated(ctx) {
                    counts["pure_nc_current", default: 0] += 1
                } else {
                    counts["other", default: 0] += 1
                }
            }
        }
        return counts
    }

    static func fact(forTag tag: String, in index: XbrlFactIndex) -> XbrlFact? {
        guard let ctxMap = index[tag] else { return nil }
        if let f = ctxMap.values.first(where: { isCurrentConsolidated($0.contextRef) }) { return f }
        if let f = ctxMap.values.first(where: { isCurrentPureNonConsolidated($0.contextRef) }) { return f }
        return ctxMap.values.first
    }
}

enum PocJevScoring {
    static func keywords(for field: String) -> [String] {
        switch field {
        case "eps":
            return ["一株", "EPS", "EarningsPerShare", "基本的", "希薄", "PerShare", "当期純利益"]
        case "bps":
            return ["一株", "純資産", "BPS", "PerShare", "株主資本"]
        case "sales":
            return ["売上", "収益", "Revenue", "Sales", "営業収益", "NetSales", "OperatingRevenue"]
        case "net_profit":
            return ["当期純利益", "親会社", "ProfitLoss", "NetIncome", "OwnersOfParent"]
        case "operating_profit":
            return ["営業利益", "OperatingIncome", "OperatingProfit"]
        case "gross_profit":
            return ["売上総利益", "GrossProfit", "営業総利益"]
        case "sga":
            return ["販売費", "一般管理", "SGA", "SellingGeneral"]
        case "cash_equivalents":
            return ["現金", "CashAnd", "預金"]
        case "ppe_total":
            return ["有形固定資産", "PropertyPlant", "PPE"]
        case "accounts_receivable":
            return ["売掛", "受取手形", "Receivable", "売上債権"]
        case "accounts_payable":
            return ["買掛", "支払手形", "Payable"]
        case "inventory":
            return ["棚卸", "Inventor"]
        case "total_assets":
            return ["資産合計", "TotalAssets", "Assets"]
        case "net_assets":
            return ["純資産", "NetAssets", "Equity"]
        case "interest_bearing_debt":
            return ["有利子", "借入", "Borrowing", "社債", "Lease"]
        case "interest_expense":
            return ["支払利息", "InterestExpense", "FinanceCost"]
        case "cfo":
            return ["営業活動", "OperatingActivit"]
        case "cfi":
            return ["投資活動", "InvestingActivit"]
        case "capex":
            return ["設備投資", "CapitalExpenditure", "PurchaseOfProperty"]
        case "rd":
            return ["研究開発", "ResearchAndDevelopment"]
        case "employees":
            return ["従業員", "Employee"]
        case "issued_shares":
            return ["発行済", "IssuedShare", "株式数"]
        case "buyback", "cf_treasury_stock":
            return ["自己株式", "Treasury"]
        case "dividend_ss", "dividend_paid_cf":
            return ["配当", "Dividend"]
        default:
            return []
        }
    }

    static func score(tag: String, ja: String, en: String, parent: String, missing: [String], unit: String?) -> Int {
        let hay = (tag + " " + ja + " " + en + " " + parent).lowercased()
        var n = 0
        for field in missing {
            for kw in keywords(for: field) where hay.contains(kw.lowercased()) {
                n += 3
            }
        }
        if missing.contains("eps"), (unit ?? "").lowercased().contains("share") { n += 8 }
        if missing.contains("sales"), !(unit ?? "").lowercased().contains("share") { n += 1 }
        if tag.hasSuffix("Abstract") { n -= 20 }
        if tag.contains("TextBlock") { n -= 20 }
        return n
    }
}

enum PocJevTokens {
    static func approx(chars: Int) -> [String: Int] {
        [
            "chars": chars,
            "tokens_approx_div4": max(1, (chars + 3) / 4),
        ]
    }
}
