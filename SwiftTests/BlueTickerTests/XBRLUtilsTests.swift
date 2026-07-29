import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct XBRLUtilsTests {

    private static let xbrlDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl/S100LM4N_xbrl")
    }()

    private static var xbrlCacheAvailable: Bool {
        FileManager.default.fileExists(atPath: xbrlDir.path)
    }

    @Test(.enabled(if: Self.xbrlCacheAvailable, "XBRL cache not available"))
    func testFindXbrlFiles() throws {
        let files = XBRLUtils.findXbrlFiles(in: Self.xbrlDir)
        #expect(files.count == 5, "Python で確認した 5 ファイルと一致すること")
    }

    @Test(.enabled(if: Self.xbrlCacheAvailable, "XBRL cache not available"))
    func testCollectAllNumericElements() throws {
        let elements = XBRLUtils.collectAllNumericElements(in: Self.xbrlDir)

        // Python: Tags found = 264
        #expect(elements.count >= 200, "タグ数が妥当な範囲にあること")

        // Python: NetSales[CurrentYearDuration_NonConsolidatedMember] = 148129000000.0
        let netSales = elements["NetSales"]
        #expect(netSales != nil)
        #expect(netSales?["CurrentYearDuration_NonConsolidatedMember"] == 148_129_000_000.0, "NetSales 当期値が Python と一致すること")
        #expect(netSales?["Prior1YearDuration_NonConsolidatedMember"] == 158_662_000_000.0, "NetSales 前期値が Python と一致すること")

        // Python: GrossProfit[CurrentYearDuration_NonConsolidatedMember] = 256741000000.0
        let grossProfit = elements["GrossProfit"]
        #expect(grossProfit != nil)
        #expect(grossProfit?["CurrentYearDuration_NonConsolidatedMember"] == 256_741_000_000.0)
    }

    @Test func testParseXbrlValue() {
        #expect(XBRLUtils.parseXbrlValue("100") == 100.0)
        #expect(XBRLUtils.parseXbrlValue(" -8752 ") == -8752.0)
        #expect(XBRLUtils.parseXbrlValue("nil") == nil)
        #expect(XBRLUtils.parseXbrlValue("") == nil)
        #expect(XBRLUtils.parseXbrlValue(nil) == nil)
    }

    @Test func testParseHtmlNumber() {
        #expect(XBRLUtils.parseHtmlNumber("22,548") == 22548.0)
        #expect(XBRLUtils.parseHtmlNumber("22,548百万円") == 22548.0)
        #expect(XBRLUtils.parseHtmlNumber("△8,752") == -8752.0)
        #expect(XBRLUtils.parseHtmlNumber("▲1,234") == -1234.0)
        #expect(XBRLUtils.parseHtmlNumber("－") == nil)
        #expect(XBRLUtils.parseHtmlNumber("") == nil)
    }

    @Test func testFilterFinancialTableAmountsFallsBackWhenAllBelowThreshold() {
        let small = [50.0, 80.0, 120.0]
        #expect(XBRLUtils.filterFinancialTableAmounts(small) == small)
        let mixed = [50.0, 300.0, 120.0]
        #expect(XBRLUtils.filterFinancialTableAmounts(mixed) == [300.0])
    }

    @Test func testDecodeHtmlEntitiesPreservesDoubleEncodedLessThan() {
        // &amp;lt; はリテラル &lt; として残し、過剰デコードで < にしない
        #expect(decodeHtmlEntities("&amp;lt;") == "&lt;")
        #expect(decodeHtmlEntities("&lt;p&gt;") == "<p>")
        #expect(decodeHtmlEntities("&amp;amp;") == "&amp;")
    }

    @Test func testExtractTextblockHtmlDoesNotMatchLongerTagName() throws {
        let xbrl = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xbrli:xbrl xmlns:xbrli="http://www.xbrl.org/2003/instance"
                xmlns:test="http://example.com/test">
              <test:NetSalesTextBlock contextRef="C">12345</test:NetSalesTextBlock>
              <test:NetSalesTextBlockExtra contextRef="C">99999</test:NetSalesTextBlockExtra>
            </xbrli:xbrl>
            """
        try XBRLTestSupport.withXbrlDir(xbrl) { dir in
            let html = XBRLUtils.extractTextblockHtml(in: dir, textblockTag: "NetSalesTextBlock")
            #expect(html == "12345")
        }
    }

    @Test func testExtractTextblockHtmlMatchesClosingTagWithoutSpaceAfterName() throws {
        let xbrl = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xbrli:xbrl xmlns:xbrli="http://www.xbrl.org/2003/instance"
                xmlns:test="http://example.com/test">
              <test:BorrowingsTextBlock contextRef="C">&lt;table&gt;data&lt;/table&gt;</test:BorrowingsTextBlock>
            </xbrli:xbrl>
            """
        try XBRLTestSupport.withXbrlDir(xbrl) { dir in
            let html = XBRLUtils.extractTextblockHtml(in: dir, textblockTag: "BorrowingsTextBlock")
            #expect(html == "<table>data</table>")
        }
    }

    @Test func testLocalNameStripsNamespacePrefixOrURI() {
        // ElementTree format
        #expect(XBRLUtils.localName(of: "{http://xbrl.org}NetSales") == "NetSales")
        // SAX prefix format
        #expect(XBRLUtils.localName(of: "jppfs:NetSales") == "NetSales")
        // no namespace
        #expect(XBRLUtils.localName(of: "NetSales") == "NetSales")
    }

    @Test func testContextHelpers() {
        #expect(ContextHelpers.isConsolidatedDuration("CurrentYearDuration"))
        #expect(!(ContextHelpers.isConsolidatedDuration("CurrentYearDuration_NonConsolidatedMember")))
        #expect(!(ContextHelpers.isConsolidatedDuration("CurrentYearDuration_SomeMember")))
        #expect(ContextHelpers.isConsolidatedInstant("CurrentYearInstant"))
        #expect(!(ContextHelpers.isConsolidatedInstant("CurrentYearInstant_NonConsolidated")))
        #expect(ContextHelpers.isNonConsolidatedDuration("CurrentYearDuration_NonConsolidatedMember"))
    }

    // MARK: - Label/Role cache (bounded FIFO) behavior

    /// 最小のラベルリンクベース（_lab.xml）を生成する。NetSales → "売上高" の1エントリのみ。
    private static func makeLabelLinkbase() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <link:linkbase xmlns:link="http://www.xbrl.org/2003/linkbase" xmlns:xlink="http://www.w3.org/1999/xlink">
          <link:labelLink xlink:type="extended" xlink:role="http://www.xbrl.org/2003/role/link">
            <link:loc xlink:type="locator" xlink:href="jppfs_cor.xsd#jppfs_cor_NetSales" xlink:label="loc_NetSales"/>
            <link:label xlink:type="resource" xlink:label="label_NetSales" xlink:role="http://www.xbrl.org/2003/role/label" xml:lang="ja">売上高</link:label>
            <link:labelArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/concept-label" xlink:from="loc_NetSales" xlink:to="label_NetSales"/>
          </link:labelLink>
        </link:linkbase>
        """
    }

    /// loadLabelsByTag は同一 dir への複数回の要求で常に同じ結果を返すこと（cache hit・evict 後の再パースいずれでも正しさは不変）。
    @Test func loadLabelsByTagReturnsSameResultOnRepeatedCalls() throws {
        try XBRLTestSupport.withXbrlDir(
            nil,
            extraFiles: ["taxonomy_lab.xml": Self.makeLabelLinkbase()]
        ) { dir in
            let first = XBRLUtils.loadLabelsByTag(in: dir)
            let second = XBRLUtils.loadLabelsByTag(in: dir)
            #expect(first == second)
            #expect(first["NetSales"] == "売上高")
        }
    }

    /// キャッシュ容量（16）を超える distinct dir を要求してもクラッシュせず、各 dir の結果が正しく返ること
    /// （FIFO evict 後の再パースを含む）。
    @Test func loadLabelsByTagHandlesManyDistinctDirsWithoutCrash() throws {
        var dirs: [URL] = []
        defer { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }

        for _ in 0..<20 {
            let dir = try ServiceTestSupport.makeTempDir()
            try Self.makeLabelLinkbase().write(
                to: dir.appendingPathComponent("taxonomy_lab.xml"), atomically: true, encoding: .utf8)
            dirs.append(dir)
        }

        for dir in dirs {
            let labels = XBRLUtils.loadLabelsByTag(in: dir)
            #expect(labels["NetSales"] == "売上高")
        }

        // 先頭（最も古い）dir を再要求しても evict 後の再パースで同じ結果が返ること
        let firstAgain = XBRLUtils.loadLabelsByTag(in: dirs[0])
        #expect(firstAgain["NetSales"] == "売上高")
    }

    // MARK: - Presentation linkbase 表示順（loadPresentationOrder）

    private static let incomeStatementRole =
        "http://disclosure.edinet-fsa.go.jp/role/jppfs/rol_ConsolidatedStatementOfIncome"

    /// 深さ2のツリー（Root→GroupA/GroupB→Leaf*）を持つプレゼンテーションリンクベースを生成する。
    /// `<loc>`/`<presentationArc>` の**文書内の出現順をわざと木の論理順と一致させない**
    /// （GroupB・LeafB2 を先に書く）ことで、実装が文書順ではなく `order` 属性に従うことを検証できる
    /// ようにする。GroupA(order=1)配下は Root の直後に来るのに対し、GroupB(order=2)は Root の
    /// 「子」の中では2番目だが GroupA のサブツリー全体より後になる（深さ優先）ため、この形は
    /// 幅優先実装（Root→GroupA/GroupBを先に全部→Leaf達）とも区別できる
    /// （深さ優先: Root,GroupA,LeafA1,LeafA2,GroupB,LeafB1,LeafB2 / 幅優先だと GroupB が LeafA2 より前に来る）。
    private static func makePresentationLinkbase() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <link:linkbase xmlns:link="http://www.xbrl.org/2003/linkbase" xmlns:xlink="http://www.w3.org/1999/xlink">
          <link:presentationLink xlink:type="extended" xlink:role="\(incomeStatementRole)">
            <link:loc xlink:type="locator" xlink:href="jppfs_cor.xsd#jppfs_cor_GroupB" xlink:label="loc_GroupB"/>
            <link:loc xlink:type="locator" xlink:href="jppfs_cor.xsd#jppfs_cor_LeafB2" xlink:label="loc_LeafB2"/>
            <link:loc xlink:type="locator" xlink:href="jppfs_cor.xsd#jppfs_cor_LeafB1" xlink:label="loc_LeafB1"/>
            <link:loc xlink:type="locator" xlink:href="jppfs_cor.xsd#jppfs_cor_StatementOfIncomeAbstract" xlink:label="loc_Root"/>
            <link:loc xlink:type="locator" xlink:href="jppfs_cor.xsd#jppfs_cor_GroupA" xlink:label="loc_GroupA"/>
            <link:loc xlink:type="locator" xlink:href="jppfs_cor.xsd#jppfs_cor_LeafA2" xlink:label="loc_LeafA2"/>
            <link:loc xlink:type="locator" xlink:href="jppfs_cor.xsd#jppfs_cor_LeafA1" xlink:label="loc_LeafA1"/>
            <link:presentationArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/parent-child" xlink:from="loc_GroupB" xlink:to="loc_LeafB2" order="2"/>
            <link:presentationArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/parent-child" xlink:from="loc_GroupB" xlink:to="loc_LeafB1" order="1"/>
            <link:presentationArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/parent-child" xlink:from="loc_Root" xlink:to="loc_GroupB" order="2"/>
            <link:presentationArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/parent-child" xlink:from="loc_GroupA" xlink:to="loc_LeafA2" order="2"/>
            <link:presentationArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/parent-child" xlink:from="loc_Root" xlink:to="loc_GroupA" order="1"/>
            <link:presentationArc xlink:type="arc" xlink:arcrole="http://www.xbrl.org/2003/arcrole/parent-child" xlink:from="loc_GroupA" xlink:to="loc_LeafA1" order="1"/>
          </link:presentationLink>
        </link:linkbase>
        """
    }

    /// presentationArc の order 属性を深さ優先で辿り、role 内の表示順を 0 始まりの通し番号として復元する。
    /// 文書内の要素出現順や幅優先走査ではなく、`order` 属性に基づく深さ優先順序であることを検証する。
    @Test func loadPresentationOrderReconstructsDepthFirstOrderFromArcs() throws {
        try XBRLTestSupport.withXbrlDir(
            nil,
            extraFiles: ["taxonomy_pre.xml": Self.makePresentationLinkbase()]
        ) { dir in
            let orderByRoleTag = XBRLUtils.loadPresentationOrder(in: dir)
            let order = try #require(orderByRoleTag[Self.incomeStatementRole])

            let expected = [
                "StatementOfIncomeAbstract", "GroupA", "LeafA1", "LeafA2", "GroupB", "LeafB1", "LeafB2",
            ]
            let actual = expected.compactMap { order[$0] }
            #expect(actual.count == expected.count, "全ノードに order が割り当てられていること")
            #expect(actual == actual.sorted(), "文書内の宣言順ではなく order 属性に基づく深さ優先順であること")
            #expect(order["LeafA2"]! < order["GroupB"]!, "深さ優先: GroupAの子孫を辿り終えてからGroupBへ進む（幅優先ならGroupBの方が先）")
        }
    }

    /// 同一 dir への複数回の要求で常に同じ結果を返すこと（loadLabelsByTag と同型のキャッシュ挙動）。
    @Test func loadPresentationOrderReturnsSameResultOnRepeatedCalls() throws {
        try XBRLTestSupport.withXbrlDir(
            nil,
            extraFiles: ["taxonomy_pre.xml": Self.makePresentationLinkbase()]
        ) { dir in
            let first = XBRLUtils.loadPresentationOrder(in: dir)
            let second = XBRLUtils.loadPresentationOrder(in: dir)
            #expect(first == second)
        }
    }
}
