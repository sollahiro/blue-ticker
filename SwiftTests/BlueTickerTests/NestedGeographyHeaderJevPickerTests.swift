// 入れ子見出しの閉じた Choice。ネットワークに出ない。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct NestedGeographyHeaderJevPickerTests {
    private func isolatedTable() -> RevenueRecognitionCandidates.ParsedTable {
        let html = """
            <table>
              <tr>
                <td rowspan="2">日本</td>
                <td>欧米</td>
                <td rowspan="2">合計</td>
              </tr>
              <tr><td>米国</td></tr>
              <tr>
                <td>100</td><td>200</td><td>300</td>
              </tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "地域ごとの情報")
        return RevenueRecognitionCandidates.parse(tables: tables)[0]
    }

    @Test func keepParentAndChildRewritesHeader() async {
        let table = isolatedTable()
        #expect(table.unresolvedNestedGeographyHeaders.count == 1)
        let column = table.unresolvedNestedGeographyHeaders[0].column
        let decider = FakeRevenueRecognitionColumnDecider(
            nestedHeaderSelected: NestedGeographyHeaderJevPicker.keepParentAndChild)
        let resolved = await NestedGeographyHeaderJevPicker.resolve(
            tables: [table], decider: decider, docID: "S-iso")
        #expect(resolved.tables[0].columnHeaders[column] == "欧米 / 米国")
        #expect(resolved.tables[0].unresolvedNestedGeographyHeaders.isEmpty)
        #expect(!resolved.needsReview)
        #expect(resolved.audit?.applied == true)
        #expect(resolved.notes.contains { $0.hasPrefix("nested_header_jev=keep") })
    }

    @Test func dropChildKeepsParentOnly() async {
        let table = isolatedTable()
        let column = table.unresolvedNestedGeographyHeaders[0].column
        let decider = FakeRevenueRecognitionColumnDecider(
            nestedHeaderSelected: NestedGeographyHeaderJevPicker.dropChildAsSpanning)
        let resolved = await NestedGeographyHeaderJevPicker.resolve(
            tables: [table], decider: decider, docID: "S-iso-drop")
        #expect(resolved.tables[0].columnHeaders[column] == "欧米")
        #expect(!resolved.needsReview)
        #expect(resolved.notes.contains { $0.hasPrefix("nested_header_jev=drop") })
    }

    @Test func failClosedLeavesParentAndNeedsReview() async {
        let table = isolatedTable()
        let column = table.unresolvedNestedGeographyHeaders[0].column
        let decider = FakeRevenueRecognitionColumnDecider(nestedHeaderFail: true)
        let resolved = await NestedGeographyHeaderJevPicker.resolve(
            tables: [table], decider: decider, docID: "S-iso-fail")
        #expect(resolved.tables[0].columnHeaders[column] == "欧米")
        #expect(resolved.needsReview)
        #expect(resolved.tables[0].unresolvedNestedGeographyHeaders.count == 1)
        #expect(resolved.audit?.needsReview == true)
        #expect(
            resolved.audit?.withheldReason
                == NestedGeographyHeaderJevPicker.warningUnresolved)
    }

    @Test func disagreementFailsClosed() async {
        let table = isolatedTable()
        let decider = FakeRevenueRecognitionColumnDecider(nestedHeaderDisagreement: true)
        let resolved = await NestedGeographyHeaderJevPicker.resolve(
            tables: [table], decider: decider, docID: "S-iso-split")
        #expect(resolved.needsReview)
        #expect(resolved.notes.contains { $0.contains("fail_closed") })
    }

    @Test func belowThresholdFailsClosed() async {
        let table = isolatedTable()
        let decider = FakeRevenueRecognitionColumnDecider(
            nestedHeaderSelected: NestedGeographyHeaderJevPicker.keepParentAndChild,
            nestedHeaderProbability: 0.5)
        let resolved = await NestedGeographyHeaderJevPicker.resolve(
            tables: [table], decider: decider, docID: "S-iso-low")
        #expect(resolved.needsReview)
        let column = table.unresolvedNestedGeographyHeaders[0].column
        #expect(resolved.tables[0].columnHeaders[column] == "欧米")
    }

    @Test func requestJSONDoesNotCallNetwork() {
        let table = isolatedTable()
        let header = table.unresolvedNestedGeographyHeaders[0]
        let body = OpenRouterNestedGeographyHeaderDecider.requestJSON(
            model: "typesafe/jev-1.13", table: table, header: header, docID: "S-iso")
        #expect(body != nil)
        let object = try? JSONSerialization.jsonObject(with: body!) as? [String: Any]
        #expect(object?["model"] as? String == "typesafe/jev-1.13")
    }

    @Test func emptyUnresolvedDoesNotCallDecider() async {
        let table = isolatedTable()
        var clean = table
        clean.unresolvedNestedGeographyHeaders = []
        let decider = FakeRevenueRecognitionColumnDecider(nestedHeaderFail: true)
        let resolved = await NestedGeographyHeaderJevPicker.resolve(
            tables: [clean], decider: decider, docID: "S-none")
        #expect(!resolved.needsReview)
        #expect(resolved.notes.isEmpty)
        #expect(resolved.audit == nil)
    }
}
