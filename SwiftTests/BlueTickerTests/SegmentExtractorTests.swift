// SegmentExtractor のユニットテスト
// Python tests/test_segment_extractor.py 相当＋TextBlock/dimension fact 統合テスト

import Testing
import Foundation
import SwiftSoup
@testable import BlueTickerCore

@Suite struct SegmentExtractorTests {

    private func makeTable(_ html: String) throws -> Element {
        let soup = try SwiftSoup.parse(html)
        return try #require(try soup.select("table").first())
    }

    // MARK: - gridToMarkdown

    @Test func gridToMarkdownSimple2x2() {
        let md = SegmentExtractor.gridToMarkdown([["A", "B"], ["1", "2"]])
        #expect(md.contains("| A | B |"))
        #expect(md.contains("| 1 | 2 |"))
        #expect(md.contains("---"))
    }

    @Test func gridToMarkdownEmptyGridReturnsEmpty() {
        #expect(SegmentExtractor.gridToMarkdown([]) == "")
    }

    @Test func gridToMarkdownHeaderSeparatorAfterFirstRow() {
        let md = SegmentExtractor.gridToMarkdown([["Header"], ["Value"]])
        #expect(md.split(separator: "\n").count == 3)  // header / separator / value
    }

    @Test func gridToMarkdownColumnsArePaddedToMaxWidth() {
        let md = SegmentExtractor.gridToMarkdown([["Short", "A very long column header"]])
        #expect(md.contains("A very long column header"))
    }

    @Test func gridToMarkdownSingleRow() {
        let md = SegmentExtractor.gridToMarkdown([["Only", "Row"]])
        #expect(md.contains("Only"))
        #expect(md.contains("Row"))
    }

    // MARK: - detectPeriodFromGrid

    @Test func detectPeriodCurrentPeriod() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["当連結会計年度", "数値"], ["売上高", "1000"]]) == "当期")
    }

    @Test func detectPeriodPriorPeriod() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["前連結会計年度", "数値"], ["売上高", "900"]]) == "前期")
    }

    @Test func detectPeriodComparisonWhenBothPresent() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["前連結会計年度", "当連結会計年度"], ["900", "1000"]]) == "比較")
    }

    @Test func detectPeriodShortFormCurrent() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["当期", "数値"]]) == "当期")
    }

    @Test func detectPeriodShortFormPrior() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["前期", "数値"]]) == "前期")
    }

    @Test func detectPeriodNoKeywordReturnsNil() {
        #expect(SegmentExtractor.detectPeriodFromGrid([["セグメント", "売上高"], ["事業A", "500"]]) == nil)
    }

    @Test func detectPeriodOnlyChecksFirst3Rows() {
        let grid = [
            ["セグメント名", "値"],
            ["事業A", "100"],
            ["事業B", "200"],
            ["当連結会計年度の合計", "300"],
        ]
        #expect(SegmentExtractor.detectPeriodFromGrid(grid) == nil)
    }

    @Test func detectPeriodEmptyGridReturnsNil() {
        #expect(SegmentExtractor.detectPeriodFromGrid([]) == nil)
    }

    // MARK: - applyPeriodOrdering

    @Test func periodOrderingUnlabeledGetsAlternatingLabels() {
        var tables = ["A", "B", "C", "D"].map {
            SegmentTable(heading: "セグメント情報", markdown: "| \($0) |", period: nil)
        }
        SegmentExtractor.applyPeriodOrdering(&tables)
        #expect(tables.map(\.period) == ["前期", "当期", "前期", "当期"])
    }

    @Test func periodOrderingAlreadyLabeledIsNotChanged() {
        var tables = [
            SegmentTable(heading: "X", markdown: "| 1 |", period: "当期"),
            SegmentTable(heading: "X", markdown: "| 2 |", period: nil),
        ]
        SegmentExtractor.applyPeriodOrdering(&tables)
        #expect(tables[0].period == "当期")
        #expect(tables[1].period == "前期")
    }

    @Test func periodOrderingAllLabeledUnchanged() {
        var tables = [SegmentTable(heading: "X", markdown: "| 1 |", period: "比較")]
        SegmentExtractor.applyPeriodOrdering(&tables)
        #expect(tables[0].period == "比較")
    }

    @Test func periodOrderingEmptyListDoesNothing() {
        var tables: [SegmentTable] = []
        SegmentExtractor.applyPeriodOrdering(&tables)
        #expect(tables.isEmpty)
    }

    // MARK: - expandTable

    @Test func expandTableSimple() throws {
        let table = try makeTable("<table><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></table>")
        #expect(SegmentExtractor.expandTable(table) == [["A", "B"], ["1", "2"]])
    }

    @Test func expandTableColspanExpandsCell() throws {
        let table = try makeTable("<table><tr><td colspan='2'>合計</td></tr><tr><td>事業A</td><td>100</td></tr></table>")
        let grid = SegmentExtractor.expandTable(table)
        #expect(grid[0] == ["合計", "合計"])
        #expect(grid[1] == ["事業A", "100"])
    }

    @Test func expandTableRowspanRepeatsCellDownward() throws {
        let table = try makeTable("<table><tr><td rowspan='2'>期間</td><td>Q1</td></tr><tr><td>Q2</td></tr></table>")
        let grid = SegmentExtractor.expandTable(table)
        #expect(grid[0][0] == "期間")
        #expect(grid[1][0] == "期間")
        #expect(grid[0][1] == "Q1")
        #expect(grid[1][1] == "Q2")
    }

    @Test func expandTableEmptyTableReturnsEmpty() throws {
        let table = try makeTable("<table></table>")
        #expect(SegmentExtractor.expandTable(table).isEmpty)
    }

    @Test func expandTableStripsWhitespaceFromCells() throws {
        let table = try makeTable("<table><tr><td>  事業A  </td><td>  100  </td></tr></table>")
        #expect(SegmentExtractor.expandTable(table)[0] == ["事業A", "100"])
    }

    // MARK: - TextBlock 統合（J-GAAP / IFRS）

    /// エスケープ済み HTML テーブルを含む TextBlock 要素の XBRL インスタンスを作る。
    private func textBlockXml(tag: String, escapedHtml: String) -> String {
        XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:\(tag) contextRef="CurrentYearDuration">\(escapedHtml)</jpcrp_cor:\(tag)>
            """
        )
    }

    // div 区切りで前期/当期のテーブルを持つ典型的な TextBlock HTML（エスケープ済み）
    private static let escapedSegmentTable =
        "&lt;div&gt;&lt;p&gt;前連結会計年度&lt;/p&gt;" +
        "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;100&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/div&gt;" +
        "&lt;div&gt;&lt;p&gt;当連結会計年度&lt;/p&gt;" +
        "&lt;table&gt;&lt;tr&gt;&lt;td&gt;事業A&lt;/td&gt;&lt;td&gt;120&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/div&gt;"

    @Test func segmentInfoFromJGAAPTextBlock() throws {
        let xml = textBlockXml(tag: "SegmentInformationTextBlock", escapedHtml: Self.escapedSegmentTable)
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 2)
            #expect(result.tables[0].heading == "セグメント情報")
            #expect(result.tables[0].markdown.contains("| 事業A | 100 |"))
            #expect(result.tables[0].period == "前期")
            #expect(result.tables[1].markdown.contains("| 事業A | 120 |"))
            #expect(result.tables[1].period == "当期")
            #expect(result.facts.isEmpty)
        }
    }

    @Test func segmentInfoFromIFRSTextBlock() {
        let xml = textBlockXml(tag: "SegmentInformationIFRSTextBlock", escapedHtml: Self.escapedSegmentTable)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 2)
            #expect(result.tables.map(\.period) == ["前期", "当期"])
        }
    }

    @Test func geographyMixedBlockFiltersByKeyword() {
        // RelatedInformationTextBlock（混在）は見出しキーワードに続く table のみ抽出する
        let escaped =
            "&lt;p&gt;製品ごとの情報&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;製品X&lt;/td&gt;&lt;td&gt;1&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" +
            "&lt;p&gt;地域ごとの情報&lt;/p&gt;" +
            "&lt;table&gt;&lt;tr&gt;&lt;td&gt;日本&lt;/td&gt;&lt;td&gt;500&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"
        let xml = textBlockXml(tag: "RelatedInformationTextBlock", escapedHtml: escaped)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(result.method == "html_table")
            #expect(result.tables.count == 1)
            #expect(result.tables[0].heading == "地域ごとの情報")
            #expect(result.tables[0].markdown.contains("| 日本 | 500 |"))
            #expect(!result.tables[0].markdown.contains("製品X"))
        }
    }

    @Test func segmentInfoFallsBackToDimensionFacts() throws {
        // TextBlock がない場合は dimension 付き fact にフォールバックする
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="\(XBRLTestSupport.nsXbrli)"
            xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
            xmlns:jppfs_cor="\(XBRLTestSupport.nsJppfs)">
          <xbrli:context id="CurrentYearDuration_SegmentAMember">
            <xbrli:entity>
              <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
            </xbrli:entity>
            <xbrli:period>
              <xbrli:startDate>2023-04-01</xbrli:startDate>
              <xbrli:endDate>2024-03-31</xbrli:endDate>
            </xbrli:period>
            <xbrli:scenario>
              <xbrldi:explicitMember dimension="jppfs_cor:OperatingSegmentsAxis">jppfs_cor:SegmentAMember</xbrldi:explicitMember>
            </xbrli:scenario>
          </xbrli:context>
          <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>
          <jppfs_cor:NetSales contextRef="CurrentYearDuration_SegmentAMember" unitRef="JPY" decimals="-6">1000000</jppfs_cor:NetSales>
        </xbrli:xbrl>
        """
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "xbrl_facts")
            #expect(result.tables.isEmpty)
            let fact = try #require(result.facts.first)
            #expect(fact.tag == "NetSales")
            #expect(fact.contextRef == "CurrentYearDuration_SegmentAMember")
            #expect(fact.dimensions == ["OperatingSegmentsAxis": "SegmentAMember"])
            #expect(fact.value == 1_000_000)
            #expect(fact.unitRef == "JPY")
            #expect(fact.decimals == "-6")

            // 地域別 dimension ではないため geography は not_found
            let geo = SegmentExtractor.extractGeographyInfo(xbrlDir: dir)
            #expect(geo.method == "not_found")
        }
    }

    // MARK: - toDictionary（JSON 出力）

    @Test func toDictionarySerializesWithOptionalKeysOmitted() throws {
        let result = SegmentResult(
            method: "html_table",
            tables: [
                SegmentTable(heading: "セグメント情報", markdown: "| A |", period: "当期"),
                SegmentTable(heading: "セグメント情報", markdown: "| B |", period: nil),
            ],
            facts: [
                SegmentFact(
                    tag: "NetSales", contextRef: "ctx", dimensions: ["Axis": "Member"],
                    value: 100, label: nil, unitRef: nil, decimals: nil
                ),
            ]
        )
        let dict = result.toDictionary()
        #expect(JSONSerialization.isValidJSONObject(dict))

        let tables = try #require(dict["tables"] as? [[String: Any]])
        #expect(tables[0]["period"] as? String == "当期")
        #expect(tables[1]["period"] == nil)  // nil は出力しない（Python NotRequired と同じ）

        let facts = try #require(dict["facts"] as? [[String: Any]])
        #expect(facts[0]["label"] == nil)
        #expect(facts[0]["value"] as? Double == 100)
    }

    @Test func notFoundWhenNoSegmentData() {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jppfs_cor:NetSales contextRef="CurrentYearDuration" unitRef="JPY" decimals="-6">1000000</jppfs_cor:NetSales>
            """
        )
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = SegmentExtractor.extractSegmentInfo(xbrlDir: dir)
            #expect(result.method == "not_found")
            #expect(result.tables.isEmpty)
            #expect(result.facts.isEmpty)
        }
    }
}

// MARK: - Python ゴールデンファイルとのパリティ検証

/// smoke/segment_expected.json（Python 実装の出力）と tmp_cache/edinet/ の
/// キャッシュ済み XBRL から Swift 実装の出力を突き合わせる。
/// どちらかが存在しない環境ではスキップ（既存スモークテストと同じ方式）。
@Suite struct SegmentParityTests {

    @Test func parityWithPythonGolden() throws {
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // BlueTickerTests
            .deletingLastPathComponent()  // SwiftTests
            .deletingLastPathComponent()  // project root
        let goldenPath = projectRoot.appendingPathComponent("smoke/segment_expected.json")
        let xbrlBase = projectRoot.appendingPathComponent("tmp_cache/edinet")

        guard FileManager.default.fileExists(atPath: goldenPath.path) else {
            print("SKIP   smoke/segment_expected.json が見つかりません")
            return
        }
        guard FileManager.default.fileExists(atPath: xbrlBase.path) else {
            print("SKIP   tmp_cache/edinet が見つかりません（SMOKE_PREPARE=1 swift test --filter SmokeCachePrepare で準備）")
            return
        }

        let data = try Data(contentsOf: goldenPath)
        let golden = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])

        var diffs: [String] = []
        var checked = 0

        for (docID, expected) in golden.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
                print("SKIP   \(docID): XBRL キャッシュなし")
                continue
            }
            checked += 1

            let actuals = [
                ("segments", SegmentExtractor.extractSegmentInfo(xbrlDir: xbrlDir)),
                ("geography", SegmentExtractor.extractGeographyInfo(xbrlDir: xbrlDir)),
            ]
            for (kind, actual) in actuals {
                guard let exp = expected[kind] as? [String: Any] else { continue }
                diffs.append(contentsOf: compare(exp, actual, label: "\(docID).\(kind)"))
            }
        }

        print("PARITY \(checked) docs checked, \(diffs.count) diffs")
        for d in diffs.prefix(20) { print("DIFF   \(d)") }
        #expect(diffs.isEmpty, Comment(rawValue: "パリティ差分:\n" + diffs.joined(separator: "\n")))
        #expect(checked > 0 || golden.isEmpty)
    }

    private func compare(_ expected: [String: Any], _ actual: SegmentResult, label: String) -> [String] {
        var diffs: [String] = []

        let expMethod = expected["method"] as? String ?? ""
        if expMethod != actual.method {
            diffs.append("\(label): method \(expMethod) != \(actual.method)")
            return diffs
        }

        // tables: リスト順も含めて比較
        let expTables = expected["tables"] as? [[String: Any]] ?? []
        if expTables.count != actual.tables.count {
            diffs.append("\(label): tables 件数 \(expTables.count) != \(actual.tables.count)")
        } else {
            for (i, (exp, act)) in zip(expTables, actual.tables).enumerated() {
                if exp["heading"] as? String != act.heading {
                    diffs.append("\(label): tables[\(i)].heading \(exp["heading"] ?? "nil") != \(act.heading)")
                }
                if exp["period"] as? String != act.period {
                    diffs.append("\(label): tables[\(i)].period \(exp["period"] ?? "nil") != \(act.period ?? "nil")")
                }
                if exp["markdown"] as? String != act.markdown {
                    diffs.append("\(label): tables[\(i)].markdown 不一致\n--- expected\n\(exp["markdown"] ?? "")\n--- actual\n\(act.markdown)")
                }
            }
        }

        // facts: 順序不定のため (tag, contextRef) でソートして比較
        let expFacts = (expected["facts"] as? [[String: Any]] ?? []).sorted {
            (($0["tag"] as? String ?? ""), ($0["contextRef"] as? String ?? ""))
                < (($1["tag"] as? String ?? ""), ($1["contextRef"] as? String ?? ""))
        }
        if expFacts.count != actual.facts.count {
            diffs.append("\(label): facts 件数 \(expFacts.count) != \(actual.facts.count)")
            return diffs
        }
        for (i, (exp, act)) in zip(expFacts, actual.facts).enumerated() {
            let key = "\(label): facts[\(i)] (\(act.tag), \(act.contextRef))"
            if exp["tag"] as? String != act.tag || exp["contextRef"] as? String != act.contextRef {
                diffs.append("\(key): tag/contextRef 不一致 expected (\(exp["tag"] ?? ""), \(exp["contextRef"] ?? ""))")
                continue
            }
            if exp["dimensions"] as? [String: String] != act.dimensions {
                diffs.append("\(key): dimensions \(exp["dimensions"] ?? [:]) != \(act.dimensions)")
            }
            let expValue = (exp["value"] as? NSNumber)?.doubleValue
            if expValue != act.value {
                diffs.append("\(key): value \(expValue.map { String($0) } ?? "nil") != \(act.value)")
            }
            if exp["label"] as? String != act.label {
                diffs.append("\(key): label \(exp["label"] ?? "nil") != \(act.label ?? "nil")")
            }
            if exp["unitRef"] as? String != act.unitRef {
                diffs.append("\(key): unitRef \(exp["unitRef"] ?? "nil") != \(act.unitRef ?? "nil")")
            }
            if exp["decimals"] as? String != act.decimals {
                diffs.append("\(key): decimals \(exp["decimals"] ?? "nil") != \(act.decimals ?? "nil")")
            }
        }
        return diffs
    }
}
