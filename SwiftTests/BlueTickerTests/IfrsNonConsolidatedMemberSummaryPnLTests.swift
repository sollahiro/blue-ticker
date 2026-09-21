import Foundation
import Testing

@testable import BlueTickerCore

/// IFRS 本表 P&L が `CurrentYearDuration_NonConsolidatedMember` に載る書類で
/// Summary sales / operating_profit / net_profit が埋まること、plain
/// `CurrentYearDuration` の回帰、同一期の連結優先を固定する。
///
/// 回帰: ベイカレント 6532 / S100TI4B。IFRS 売上収益・営業利益・当期利益は
/// NonConsolidatedMember にあり、Statement は個別 J-GAAP PL を選びがち。
/// 連結 FieldSet が NC を落とすと Summary が全年 null になる。CF は本表行を
/// 直接読むため埋まっていた。
@Suite struct IfrsNonConsolidatedMemberSummaryPnLTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func ensureAvailable(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        let dir = xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return nil
        }
        return dir
    }

    private func ifrsPnLXml(
        revenueCtx: String, opCtx: String, npCtx: String,
        revenue: String, op: String, np: String
    ) -> String {
        XBRLTestSupport.makeXbrlDuration(
            """
            <jpifrs_cor:RevenueIFRS contextRef="\(revenueCtx)"
                unitRef="JPY" decimals="-6">\(revenue)</jpifrs_cor:RevenueIFRS>
            <jpifrs_cor:OperatingProfitLossIFRS contextRef="\(opCtx)"
                unitRef="JPY" decimals="-6">\(op)</jpifrs_cor:OperatingProfitLossIFRS>
            <jpifrs_cor:ProfitLossIFRS contextRef="\(npCtx)"
                unitRef="JPY" decimals="-6">\(np)</jpifrs_cor:ProfitLossIFRS>
            <jpifrs_cor:NetCashProvidedByUsedInOperatingActivitiesIFRS contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">24348000000</jpifrs_cor:NetCashProvidedByUsedInOperatingActivitiesIFRS>
            """
        )
    }

    @Test func s100ti4bStyleNonConsolidatedMemberFillsSummaryPnL() throws {
        let xml = ifrsPnLXml(
            revenueCtx: "CurrentYearDuration_NonConsolidatedMember",
            opCtx: "CurrentYearDuration_NonConsolidatedMember",
            npCtx: "CurrentYearDuration_NonConsolidatedMember",
            revenue: "93909000000", op: "34219000000", np: "25382000000")
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
            #expect(values.sales == 93_909_000_000)
            #expect(values.operatingProfit == 34_219_000_000)
            #expect(values.netProfit == 25_382_000_000)
        }
    }

    @Test func s100vtpaStylePlainCurrentYearDurationStillFills() throws {
        let xml = ifrsPnLXml(
            revenueCtx: "CurrentYearDuration",
            opCtx: "CurrentYearDuration",
            npCtx: "CurrentYearDuration",
            revenue: "116056000000", op: "42615000000", np: "30760000000")
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
            #expect(values.sales == 116_056_000_000)
            #expect(values.operatingProfit == 42_615_000_000)
            #expect(values.netProfit == 30_760_000_000)
        }
    }

    @Test func prefersConsolidatedRevenueIFRSOverNonConsolidatedNetSalesIFRS() throws {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpifrs_cor:RevenueIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">9783370000000</jpifrs_cor:RevenueIFRS>
            <jpifrs_cor:NetSalesIFRS contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">1774233000000</jpifrs_cor:NetSalesIFRS>
            <jpifrs_cor:OperatingProfitLossIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">800</jpifrs_cor:OperatingProfitLossIFRS>
            <jpifrs_cor:ProfitLossAttributableToOwnersOfParentIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">500</jpifrs_cor:ProfitLossAttributableToOwnersOfParentIFRS>
            <jpifrs_cor:ProfitLossIFRS contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">50</jpifrs_cor:ProfitLossIFRS>
            """
        )
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
            #expect(values.sales == 9_783_370_000_000)
            #expect(values.operatingProfit == 800)
            #expect(values.netProfit == 500)
        }
    }

    /// notes / breakdown の Duration FieldSet は Summary の NC P&L 穴埋めを共有しない。
    @Test func notesAndBreakdownDurationFieldSetDoesNotFillNcIfrsPnL() throws {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpifrs_cor:RevenueIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">9783370000000</jpifrs_cor:RevenueIFRS>
            <jpifrs_cor:NetSalesIFRS contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">1774233000000</jpifrs_cor:NetSalesIFRS>
            <jpifrs_cor:OperatingProfitLossIFRS contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">100</jpifrs_cor:OperatingProfitLossIFRS>
            <jpifrs_cor:ResearchAndDevelopmentCostsIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">500000000</jpifrs_cor:ResearchAndDevelopmentCostsIFRS>
            <jpifrs_cor:NetCashProvidedByUsedInOperatingActivitiesIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">1000</jpifrs_cor:NetCashProvidedByUsedInOperatingActivitiesIFRS>
            """
        )
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let allTags = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
            let notesFS = fieldSetFromDuration(allTags)
            #expect(notesFS["NetSalesIFRS"]?.current ?? nil == nil)
            #expect(notesFS["OperatingProfitLossIFRS"]?.current ?? nil == nil)
            #expect(notesFS["RevenueIFRS"]?.current == 9_783_370_000_000)

            let unmaskedSales = resolveItemPreferCurrent(notesFS, tags: Xbrl.netSalesTags)
            #expect(unmaskedSales.current == 9_783_370_000_000)
            #expect(unmaskedSales.tag == "RevenueIFRS")

            let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
            #expect(rd.value == 500_000_000)

            let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
            #expect(values.sales == 9_783_370_000_000)
            #expect(values.operatingProfit == 100)
        }
    }

    @Test func prefersConsolidatedDurationWhenBothExist() throws {
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpifrs_cor:RevenueIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">9783370000000</jpifrs_cor:RevenueIFRS>
            <jpifrs_cor:RevenueIFRS contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">1774233000000</jpifrs_cor:RevenueIFRS>
            <jpifrs_cor:OperatingProfitLossIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">800</jpifrs_cor:OperatingProfitLossIFRS>
            <jpifrs_cor:OperatingProfitLossIFRS contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">100</jpifrs_cor:OperatingProfitLossIFRS>
            <jpifrs_cor:ProfitLossIFRS contextRef="CurrentYearDuration"
                unitRef="JPY" decimals="-6">500</jpifrs_cor:ProfitLossIFRS>
            <jpifrs_cor:ProfitLossIFRS contextRef="CurrentYearDuration_NonConsolidatedMember"
                unitRef="JPY" decimals="-6">50</jpifrs_cor:ProfitLossIFRS>
            """
        )
        try XBRLTestSupport.withXbrlDir(xml) { dir in
            let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
            #expect(values.sales == 9_783_370_000_000)
            #expect(values.operatingProfit == 800)
            #expect(values.netProfit == 500)
        }
    }

    @Test func bayCurrentS100TI4BSummaryPnLMatchesIfrsNonConsolidatedMember() async throws {
        guard let dir = await Self.ensureAvailable("S100TI4B") else { return }
        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(values.sales == 93_909_000_000)
        #expect(values.operatingProfit == 34_219_000_000)
        #expect(values.netProfit == 25_382_000_000)
    }

    @Test func bayCurrentS100VTPASummaryPnLFromPlainCurrentYearDuration() async throws {
        guard let dir = await Self.ensureAvailable("S100VTPA") else { return }
        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(values.sales == 116_056_000_000)
        #expect(values.operatingProfit == 42_615_000_000)
        #expect(values.netProfit == 30_760_000_000)
    }
}
