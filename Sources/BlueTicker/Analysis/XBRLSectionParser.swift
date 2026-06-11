// XBRL セクション抽出
// Python の blue_ticker/analysis/xbrl_parser.py 相当

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SwiftSoup

struct XBRLParser {

    // MARK: - Section Extraction (HTML-based)

    /// XBRLディレクトリから指定セクションを HTML でテキスト抽出する。
    func extractSection(in xbrlDir: URL, sectionName: String) -> String? {
        let fm = FileManager.default
        var htmlFiles = [URL]()
        if let enumerator = fm.enumerator(at: xbrlDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if ext == "html" || ext == "htm" { htmlFiles.append(url) }
            }
        }
        guard !htmlFiles.isEmpty else { return nil }

        // honbun / ixbrl を含むファイルを優先
        let priorityFiles = htmlFiles.filter {
            $0.lastPathComponent.contains("honbun") || $0.lastPathComponent.contains("ixbrl")
        }
        let targets = priorityFiles.isEmpty ? htmlFiles : priorityFiles

        for htmlFile in targets {
            guard let content = try? String(contentsOf: htmlFile, encoding: .utf8),
                  let soup = try? SwiftSoup.parse(content) else { continue }
            if let text = findSection(in: soup, sectionTitle: sectionName) {
                let cleaned = cleanText(text)
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        return nil
    }

    // MARK: - Sections by Type (TextBlock-based)

    /// XBRLディレクトリから全セクションを XBRL TextBlock 経由で抽出する。
    func extractSectionsByType(in xbrlDir: URL, reportType: String? = nil) -> [String: String] {
        let fm = FileManager.default
        var xmlFiles = [URL]()
        if let enumerator = fm.enumerator(at: xbrlDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                if ext == "xml" || ext == "xbrl" {
                    let excludeSuffixes = ["_lab.xml", "_pre.xml", "_cal.xml", "_def.xml"]
                    if !excludeSuffixes.contains(where: { name.hasSuffix($0) }) {
                        xmlFiles.append(url)
                    }
                }
            }
        }
        guard !xmlFiles.isEmpty else { return [:] }

        let isInterim = (reportType ?? detectReportType(in: xbrlDir)) == "interim"

        // 全 TextBlock 要素を収集
        var allTextBlocks: [String: String] = [:]
        for xmlFile in xmlFiles {
            let collector = TextBlockCollector()
            let parser = XMLParser(data: (try? Data(contentsOf: xmlFile)) ?? Data())
            parser.delegate = collector
            parser.parse()
            for (tag, text) in collector.textBlocks where text.count > 50 {
                allTextBlocks[tag] = text
            }
        }

        // セクション定義に基づいて抽出
        var result: [String: String] = [:]
        for (sectionID, sectionDef) in xbrlSections {
            var sectionText: String? = nil

            for (blockName, blockText) in allTextBlocks {
                let elementMatch = sectionDef.xbrlElements.contains(where: {
                    blockName.contains($0) || blockName.hasSuffix($0)
                })
                let titlePatterns = [
                    sectionDef.title,
                    "【\(sectionDef.title)】",
                    "\(sectionDef.title)】",
                    "【\(sectionDef.title)",
                ]
                let titleMatch = titlePatterns.contains(where: {
                    blockText.prefix(500).contains($0)
                })
                if elementMatch || titleMatch {
                    sectionText = blockText
                    break
                }
            }

            if let text = sectionText {
                result[sectionID] = ensureStartsWithTitle(text, title: sectionDef.title)
            } else if !isInterim {
                result[sectionID] = ""
            }
        }
        return result
    }

    // MARK: - Report Type Detection

    func detectReportType(in xbrlDir: URL) -> String {
        let fm = FileManager.default
        var xmlFiles = [URL]()
        if let enumerator = fm.enumerator(at: xbrlDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                if (ext == "xml" || ext == "xbrl"),
                   !["_lab.xml", "_pre.xml", "_cal.xml", "_def.xml"].contains(where: { name.hasSuffix($0) }) {
                    xmlFiles.append(url)
                }
            }
        }

        // ファイル名から判定
        for xmlFile in xmlFiles {
            let name = xmlFile.lastPathComponent
            if name.contains("jpcrp040300") || name.contains("040300") ||
               name.contains("jpcrp030000") || name.contains("030000") {
                return "annual"
            }
            if name.contains("jpcrp030300") || name.contains("030300") ||
               name.contains("jpcrp040400") || name.contains("040400") ||
               name.contains("jpcrp040500") || name.contains("040500") {
                return "interim"
            }
        }

        // XML 内容から判定（最初の5ファイル）
        let detector = DocumentTypeDetectorFull()
        for xmlFile in xmlFiles.prefix(5) {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = XMLParser(data: data)
            parser.delegate = detector
            parser.parse()
            if let docType = detector.documentType { return docType }
        }
        return "annual"
    }

    // MARK: - Private Helpers

    private func findSection(in soup: Document, sectionTitle: String) -> String? {
        // パターン1: 見出しタグ
        if let headings = try? soup.select("h1, h2, h3, h4, h5, h6") {
            for heading in headings {
                guard (try? heading.text())?.contains(sectionTitle) == true else { continue }
                var content: [String] = []
                var current = heading.nextSibling()
                while let node = current {
                    if let elem = node as? Element,
                       ["h1","h2","h3","h4","h5","h6"].contains(elem.tagName()) { break }
                    if let text = try? (node as? Element)?.text() ?? node.description, !text.isEmpty {
                        content.append(text)
                    }
                    current = node.nextSibling()
                }
                if !content.isEmpty { return content.joined(separator: "\n") }
            }
        }

        // パターン2: div / p / section
        if let elements = try? soup.select("div, p, section") {
            for elem in elements {
                guard let text = try? elem.text(), text.contains(sectionTitle) else { continue }
                return (try? elem.text(trimAndNormaliseWhitespace: true)) ?? text
            }
        }
        return nil
    }

    private func cleanText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return joined.count > 10_000 ? String(joined.prefix(10_000)) + "..." : joined
    }

    private func ensureStartsWithTitle(_ text: String, title: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(title) { return s }

        let patterns = ["【\(title)】", "\(title)】", "【\(title)", title]
        var bestIdx = s.endIndex
        var bestPattern: String? = nil
        for pattern in patterns {
            if let range = s.range(of: pattern), range.lowerBound < bestIdx {
                bestIdx = range.lowerBound
                bestPattern = pattern
            }
        }

        guard bestPattern != nil, bestIdx < s.endIndex else {
            return title + " " + s
        }
        s = String(s[bestIdx...])
        if s.hasPrefix("【\(title)】") {
            s = title + " " + String(s.dropFirst("【\(title)】".count)).trimmingCharacters(in: .whitespaces)
        } else if s.hasPrefix("【\(title)") {
            if let end = s.range(of: "】") {
                s = title + " " + String(s[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        } else if s.hasPrefix("\(title)】") {
            s = title + " " + String(s.dropFirst("\(title)】".count)).trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - SAX: TextBlock Collector

private final class TextBlockCollector: NSObject, XMLParserDelegate {
    var textBlocks: [String: String] = [:]

    private var currentLocalTag = ""
    private var currentText = ""
    private var capturing = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        capturing = false
        let local = XBRLUtils.localName(of: elementName)
        if local.contains("TextBlock") {
            currentLocalTag = local
            currentText = ""
            capturing = true
        }
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
        let text = extractTextFromHtml(currentText)
        if text.count > 50 {
            textBlocks[currentLocalTag] = text
        }
    }

    private func extractTextFromHtml(_ raw: String) -> String {
        guard let soup = try? SwiftSoup.parse(raw.htmlEntityDecoded) else {
            return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return (try? soup.text()) ?? raw
    }
}

// MARK: - SAX: Document Type Detector

private final class DocumentTypeDetectorFull: NSObject, XMLParserDelegate {
    var documentType: String? = nil
    private var capturing = false
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        capturing = false
        let local = XBRLUtils.localName(of: elementName)
        if local == "DocumentType" || local == "documentType" {
            currentText = ""
            capturing = true
        }
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
        let text = currentText.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if text.contains("有価証券報告書") || lower.contains("annual") || text.contains("040300") {
            documentType = "annual"
        } else if text.contains("半期報告書") || lower.contains("interim") || lower.contains("quarterly") || text.contains("030300") {
            documentType = "interim"
        }
    }
}

private extension String {
    var htmlEntityDecoded: String {
        var s = self
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", "\u{00A0}"),
        ]
        for (entity, char) in entities { s = s.replacingOccurrences(of: entity, with: char) }
        return s
    }
}
