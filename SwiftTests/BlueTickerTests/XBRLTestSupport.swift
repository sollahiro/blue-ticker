// XBRL ユニットテスト共通ヘルパー
// Python tests/test_xbrl_*.py の _make_xbrl / _fs ヘルパー相当

import Foundation
@testable import BlueTicker

enum XBRLTestSupport {

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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

/// (tag, current, prior) の組から FieldSet を構築する（Python の _fs 相当）。
func makeFieldSet(_ entries: (tag: String, current: Double?, prior: Double?)...) -> FieldSet {
    var fs: FieldSet = [:]
    for (tag, current, prior) in entries {
        fs[tag] = FieldValue(current: current, prior: prior)
    }
    return fs
}
