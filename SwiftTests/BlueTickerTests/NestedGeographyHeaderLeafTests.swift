// 親の地域見出し（colspan）の下に子の地域が並ぶ表。列単位の join は既知地域名を spanning として
// 落とすが、兄弟列に異なる子があれば 親 / 子 に戻す。製品列の下に同じ「日本」が載る縦結合は触らない。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct NestedGeographyHeaderLeafTests {
    @Test func perColumnJoinStillDropsBareGeographyLeaf() {
        #expect(RevenueRecognitionCandidates.joinHeaderParts(["欧米", "米国"]) == "欧米")
        #expect(
            RevenueRecognitionCandidates.joinHeaderParts(["欧米", "アイルランド"])
                == "欧米 / アイルランド")
        #expect(RevenueRecognitionCandidates.joinHeaderParts(["欧米", "その他"]) == "欧米 / その他")
        #expect(RevenueRecognitionCandidates.joinHeaderParts(["日本", "日本"]) == "日本")
        #expect(RevenueRecognitionCandidates.joinHeaderParts(["合計", "合計"]) == "合計")
    }

    @Test func siblingNestedChildrenRestoreDroppedBareGeographyLeaf() {
        let html = """
            <table>
              <tr>
                <td rowspan="2"></td>
                <td rowspan="2">日本</td>
                <td colspan="3">欧米</td>
                <td rowspan="2">アジア</td>
                <td rowspan="2">合計</td>
              </tr>
              <tr>
                <td>米国</td><td>アイルランド</td><td>その他</td>
              </tr>
              <tr>
                <td>売上高</td>
                <td>1</td><td>2</td><td>3</td><td>4</td><td>5</td><td>15</td>
              </tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "地域ごとの情報")
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        let headers = parsed[0].columnHeaders.values.sorted()
        #expect(headers.contains("欧米 / 米国"))
        #expect(headers.contains("欧米 / アイルランド"))
        #expect(headers.contains("欧米 / その他"))
        #expect(!headers.contains("欧米"))
        #expect(parsed[0].unresolvedNestedGeographyHeaders.isEmpty)
    }

    @Test func allKnownGeographyChildrenUnderSameParentAreRestored() {
        let html = """
            <table>
              <tr>
                <td rowspan="2">日本</td>
                <td colspan="3">欧米</td>
                <td rowspan="2">合計</td>
              </tr>
              <tr>
                <td>米国</td><td>欧州</td><td>中国</td>
              </tr>
              <tr>
                <td>10</td><td>20</td><td>30</td><td>40</td><td>100</td>
              </tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "地域ごとの情報")
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        let headers = Set(parsed[0].columnHeaders.values)
        #expect(headers.contains("欧米 / 米国"))
        #expect(headers.contains("欧米 / 欧州"))
        #expect(headers.contains("欧米 / 中国"))
        #expect(!headers.contains("欧米"))
        #expect(parsed[0].unresolvedNestedGeographyHeaders.isEmpty)
    }

    @Test func spanningGeographyUnderDifferentProductParentsIsNotJoined() {
        let html = """
            <table>
              <tr>
                <td rowspan="2"></td>
                <td>電子・半導体</td>
                <td>パルプ・古紙</td>
                <td rowspan="2">合計</td>
              </tr>
              <tr>
                <td>日本</td><td>日本</td>
              </tr>
              <tr>
                <td>外部顧客に対する売上高</td>
                <td>80</td><td>20</td><td>100</td>
              </tr>
            </table>
            """
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "セグメント情報")
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        let headers = Set(parsed[0].columnHeaders.values)
        #expect(headers.contains("電子・半導体"))
        #expect(headers.contains("パルプ・古紙"))
        #expect(!headers.contains(where: { $0.contains("日本") && $0.contains("/") }))
    }

    @Test func isolatedDroppedLeafStaysUnresolvedForJev() {
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
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        let unresolved = parsed[0].unresolvedNestedGeographyHeaders
        #expect(unresolved.count == 1)
        #expect(unresolved[0].parent == "欧米")
        #expect(unresolved[0].child == "米国")
        #expect(parsed[0].columnHeaders.values.contains("欧米"))
        #expect(!parsed[0].columnHeaders.values.contains("欧米 / 米国"))
    }
}
