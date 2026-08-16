// XBRL ユニットテスト共通ヘルパー

import Foundation
import SwiftSoup
@testable import BlueTickerCore

enum XBRLTestSupport {

    /// HTML 文字列から最初の <table> 要素を返す。
    /// SwiftSoup はテストファイル側で import しないこと（SwiftSoup.Comment が
    /// swift-testing の #expect マクロ展開が生成する Comment と曖昧衝突するため）。
    static func parseFirstTable(_ html: String) throws -> Element {
        guard let table = try SwiftSoup.parse(html).select("table").first() else {
            throw NSError(domain: "XBRLTestSupport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "<table> が見つかりません"])
        }
        return table
    }

    /// HTML 文字列から <tr> 要素の配列を返す（HtmlFinancialTable 系テスト用）。
    static func parseTableRows(_ html: String) throws -> [Element] {
        try SwiftSoup.parse(html).select("tr").array()
    }

    /// HTML 文字列の最初の <tr> のセル（td / th）配列を返す。
    static func parseFirstRowCells(_ html: String) throws -> [Element] {
        guard let row = try SwiftSoup.parse(html).select("tr").first() else {
            throw NSError(domain: "XBRLTestSupport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "<tr> が見つかりません"])
        }
        return try row.select("td, th").array()
    }

    static let nsXbrli = "http://www.xbrl.org/2003/instance"
    static let nsJppfs = "http://disclosure.edinet-fsa.go.jp/taxonomy/jppfs/2022-11-01/jppfs_cor"
    static let nsJpifrs = "http://disclosure.edinet-fsa.go.jp/taxonomy/jpifrs/2022-11-01/jpifrs_cor"
    static let nsJpcrp = "http://disclosure.edinet-fsa.go.jp/taxonomy/jpcrp/2022-11-01/jpcrp_cor"

    private static func contextXml(id: String, period: String) -> String {
        """
          <xbrli:context id="\(id)">
            <xbrli:entity>
              <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
            </xbrli:entity>
            <xbrli:period>\(period)</xbrli:period>
          </xbrli:context>
        """
    }

    private static let durationCurrent = "<xbrli:startDate>2023-04-01</xbrli:startDate><xbrli:endDate>2024-03-31</xbrli:endDate>"
    private static let durationPrior = "<xbrli:startDate>2022-04-01</xbrli:startDate><xbrli:endDate>2023-03-31</xbrli:endDate>"
    private static let instantCurrent = "<xbrli:instant>2024-03-31</xbrli:instant>"
    private static let instantPrior = "<xbrli:instant>2023-03-31</xbrli:instant>"

    private static func wrap(_ elementsXml: String, contexts: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(nsXbrli)"
            xmlns:jppfs_cor="\(nsJppfs)"
            xmlns:jpifrs_cor="\(nsJpifrs)"
            xmlns:jpcrp_cor="\(nsJpcrp)">
        \(contexts.joined(separator: "\n"))
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          \(elementsXml)
        </xbrli:xbrl>
        """
    }

    /// Duration コンテキスト（当期/前期 × 連結/個別）を持つ最小 XBRL インスタンスを生成する。
    static func makeXbrlDuration(_ elementsXml: String) -> String {
        wrap(elementsXml, contexts: [
            contextXml(id: "CurrentYearDuration", period: durationCurrent),
            contextXml(id: "Prior1YearDuration", period: durationPrior),
            contextXml(id: "CurrentYearDuration_NonConsolidatedMember", period: durationCurrent),
            contextXml(id: "Prior1YearDuration_NonConsolidatedMember", period: durationPrior),
        ])
    }

    /// Instant コンテキスト（当期/前期 × 連結/個別）を持つ最小 XBRL インスタンスを生成する。
    static func makeXbrlInstant(_ elementsXml: String) -> String {
        wrap(elementsXml, contexts: [
            contextXml(id: "CurrentYearInstant", period: instantCurrent),
            contextXml(id: "Prior1YearInstant", period: instantPrior),
            contextXml(id: "CurrentYearInstant_NonConsolidatedMember", period: instantCurrent),
            contextXml(id: "Prior1YearInstant_NonConsolidatedMember", period: instantPrior),
        ])
    }

    /// 一時ディレクトリに XBRL を書き込み、body を実行後に削除する。
    static func withXbrlDir(
        _ xml: String? = nil,
        extraFiles: [String: String] = [:],
        _ body: (URL) throws -> Void
    ) rethrows {
        guard let dir = try? ServiceTestSupport.makeTempDir() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }

        if let xml = xml {
            try? xml.write(to: dir.appendingPathComponent("instance.xml"), atomically: true, encoding: .utf8)
        }
        for (name, content) in extraFiles {
            try? content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try body(dir)
    }

    /// XBRL ディレクトリから Duration FieldSet と会計基準を構築する（IndividualAnalyzer と同じ流儀）。
    static func durationFieldSet(in dir: URL) -> (fieldSet: FieldSet, standard: String) {
        let tags = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
        let std = detectAccountingStandard(tags)
        var fs = fieldSetFromDuration(tags)
        if std == "US-GAAP" {
            for (tag, fv) in USGAAPHtml.parsePLFields(in: dir) { fs[tag] = fv }
        }
        return (fs, std)
    }

    /// XBRL ディレクトリから Instant FieldSet と会計基準を構築する。
    static func instantFieldSet(in dir: URL) -> (fieldSet: FieldSet, standard: String) {
        let tags = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
        let std = detectAccountingStandard(tags)
        var fs = fieldSetFromInstant(tags)
        if std == "US-GAAP" {
            for (tag, fv) in USGAAPHtml.parseBSFields(in: dir) { fs[tag] = fv }
        }
        return (fs, std)
    }
}

/// (tag, current, prior) の組から FieldSet を構築する。
func makeFieldSet(_ entries: (tag: String, current: Double?, prior: Double?)...) -> FieldSet {
    var fs: FieldSet = [:]
    for (tag, current, prior) in entries {
        fs[tag] = FieldValue(current: current, prior: prior)
    }
    return fs
}
