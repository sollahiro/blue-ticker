import Foundation
import SwiftSoup

/// 計算リンクベース（`_cal.xml`、`summation-item` arc）由来の合計項目の構成要素。
/// `StatementLineItem.components` 用（`weight` は実データ上 ±1 のみ確認）。
struct CalcComponent {
    let tag: String
    let weight: Int
}

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
        if s.hasPrefix("△") || s.hasPrefix("▲") { s = "-" + s.dropFirst() }
        if ["－", "-", "―", "—", ""].contains(s) { return nil }
        return Double(s)
    }

    /// HTML 表行から財務金額らしい値を選ぶ。閾値未満のみの場合は全数値へフォールバックする。
    static func filterFinancialTableAmounts(_ values: [Double]) -> [Double] {
        let financial = values.filter { abs($0) >= Financial.htmlTableMinAbsMillionYen }
        return financial.isEmpty ? values : financial
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

    /// US-GAAP連結の財務諸表本表 HTML。年次(asr)は 0105010＝第５経理の状況、
    /// 半期(q2r)は 0104010＝第４経理の状況（`USGAAPHtmlFields`・`USGAAPStatementHtml` 共用）。
    static func findUSGAAPStatementHtml(in xbrlDir: URL) -> URL? {
        findHtmlByPrefix(in: xbrlDir, prefix: "0105010")
            ?? findHtmlByPrefix(in: xbrlDir, prefix: "0104010")
    }

    /// 原本ディレクトリに続き、訂正 overlay を提出が古い順で返す。
    static func xbrlSearchRoots(in dir: URL) -> [URL] {
        overlayDirectories(in: dir).isEmpty ? [dir] : [dir] + overlayDirectories(in: dir)
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

    /// dimensions のうち ConsolidatedOrNonConsolidatedAxis 以外の member を行ラベルとする。
    /// 複数該当する場合は dimension キー名の辞書順で先頭を採用し、Dictionary の走査順不定に依存しない。
    static func primaryBreakdownMember(_ dimensions: [String: String]) -> String? {
        dimensions
            .filter { $0.key != "ConsolidatedOrNonConsolidatedAxis" }
            .sorted { $0.key < $1.key }
            .first?.value
    }

    /// `a`・`b`のうち存在する方を足す（両方 nil なら nil）。単純な `(a ?? 0) + (b ?? 0)` だと
    /// 「両方未開示」を `0` として返してしまう。
    static func sumOptional(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return a + b
        }
    }
}
