import XCTest
@testable import BlueTicker

final class XBRLUtilsTests: XCTestCase {

    private var xbrlDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl/S100LM4N_xbrl")
    }

    func testFindXbrlFiles() throws {
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            throw XCTSkip("XBRL cache not available")
        }
        let files = XBRLUtils.findXbrlFiles(in: xbrlDir)
        XCTAssertEqual(files.count, 5, "Python で確認した 5 ファイルと一致すること")
    }

    func testCollectAllNumericElements() throws {
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            throw XCTSkip("XBRL cache not available")
        }
        let elements = XBRLUtils.collectAllNumericElements(in: xbrlDir)

        // Python: Tags found = 264
        XCTAssertGreaterThanOrEqual(elements.count, 200, "タグ数が妥当な範囲にあること")

        // Python: NetSales[CurrentYearDuration_NonConsolidatedMember] = 148129000000.0
        let netSales = elements["NetSales"]
        XCTAssertNotNil(netSales)
        XCTAssertEqual(
            netSales?["CurrentYearDuration_NonConsolidatedMember"],
            148_129_000_000.0,
            "NetSales 当期値が Python と一致すること"
        )
        XCTAssertEqual(
            netSales?["Prior1YearDuration_NonConsolidatedMember"],
            158_662_000_000.0,
            "NetSales 前期値が Python と一致すること"
        )

        // Python: GrossProfit[CurrentYearDuration_NonConsolidatedMember] = 256741000000.0
        let grossProfit = elements["GrossProfit"]
        XCTAssertNotNil(grossProfit)
        XCTAssertEqual(
            grossProfit?["CurrentYearDuration_NonConsolidatedMember"],
            256_741_000_000.0
        )
    }

    func testParseXbrlValue() {
        XCTAssertEqual(XBRLUtils.parseXbrlValue("100"), 100.0)
        XCTAssertEqual(XBRLUtils.parseXbrlValue(" -8752 "), -8752.0)
        XCTAssertNil(XBRLUtils.parseXbrlValue("nil"))
        XCTAssertNil(XBRLUtils.parseXbrlValue(""))
        XCTAssertNil(XBRLUtils.parseXbrlValue(nil))
    }

    func testParseHtmlNumber() {
        XCTAssertEqual(XBRLUtils.parseHtmlNumber("22,548"), 22548.0)
        XCTAssertEqual(XBRLUtils.parseHtmlNumber("22,548百万円"), 22548.0)
        XCTAssertEqual(XBRLUtils.parseHtmlNumber("△8,752"), -8752.0)
        XCTAssertNil(XBRLUtils.parseHtmlNumber("－"))
        XCTAssertNil(XBRLUtils.parseHtmlNumber(""))
    }

    func testLocalName() {
        // ElementTree format
        XCTAssertEqual(XBRLUtils.localName(of: "{http://xbrl.org}NetSales"), "NetSales")
        // SAX prefix format
        XCTAssertEqual(XBRLUtils.localName(of: "jppfs:NetSales"), "NetSales")
        // no namespace
        XCTAssertEqual(XBRLUtils.localName(of: "NetSales"), "NetSales")
    }

    func testContextHelpers() {
        XCTAssertTrue(ContextHelpers.isConsolidatedDuration("CurrentYearDuration"))
        XCTAssertFalse(ContextHelpers.isConsolidatedDuration("CurrentYearDuration_NonConsolidatedMember"))
        XCTAssertFalse(ContextHelpers.isConsolidatedDuration("CurrentYearDuration_SomeMember"))
        XCTAssertTrue(ContextHelpers.isConsolidatedInstant("CurrentYearInstant"))
        XCTAssertFalse(ContextHelpers.isConsolidatedInstant("CurrentYearInstant_NonConsolidated"))
        XCTAssertTrue(ContextHelpers.isNonConsolidatedDuration("CurrentYearDuration_NonConsolidatedMember"))
    }
}
