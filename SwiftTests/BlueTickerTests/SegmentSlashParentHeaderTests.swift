import Testing

@testable import BlueTickerCore

/// 8303 S100YDBB 型: 親見出しが「海外事業／証券投資／その他」のようにスラッシュで事業名を並べた表。
/// 「海外」「その他」を含むだけで地域グループとみなし、親子を無区切りで連結しない。
struct SegmentSlashParentHeaderTests {
    @Test func slashSeparatedBusinessParentKeepsSeparatorBeforeChild() {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td colspan="3">海外事業／証券投資／その他</td></tr>
              <tr><td></td><td>海外事業</td><td>証券投資</td><td>その他</td></tr>
              <tr><td>業務粗利益</td><td>18,794</td><td>15,007</td><td>△9,468</td></tr>
              <tr><td>セグメント利益（△は損失）</td><td>9,479</td><td>10,088</td><td>△11,443</td></tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        let headers = parsed[0].columnHeaders.values.sorted()
        #expect(headers.contains("海外事業／証券投資／その他 / 海外事業"))
        #expect(headers.contains("海外事業／証券投資／その他 / その他"))
        #expect(!headers.contains("海外事業／証券投資／その他海外事業"))
        #expect(!headers.contains("海外事業／証券投資／その他その他"))
    }
}
