import Testing
import Foundation
@testable import BlueTicker

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
        #expect(XBRLUtils.parseHtmlNumber("－") == nil)
        #expect(XBRLUtils.parseHtmlNumber("") == nil)
    }

    @Test func testLocalName() {
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
}
