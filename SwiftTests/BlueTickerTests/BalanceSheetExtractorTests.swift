// Python tests/test_xbrl_balance_sheet.py 相当
// BS 6項目の抽出・IFRS/US-GAAP 優先順位・US-GAAP 非流動資産の積み上げを検証する。
// （_apply_balance_sheet は Python analyzer 固有のため対象外。
//   components のタグ名検証は Swift の components がタグを保持しないため対象外）

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct BalanceSheetExtractorTests {

    private func extract(in dir: URL) -> BalanceSheetResultValue {
        let (fs, std) = XBRLTestSupport.instantFieldSet(in: dir)
        return BalanceSheetExtractor.extract(fieldSet: fs, accountingStandard: std)
    }

    @Test func testExtractsJgaapBalanceSheetComponents() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:CurrentAssets contextRef="CurrentYearInstant" unitRef="JPY">2923181000000</jppfs_cor:CurrentAssets>
            <jppfs_cor:NoncurrentAssets contextRef="CurrentYearInstant" unitRef="JPY">3281728000000</jppfs_cor:NoncurrentAssets>
            <jppfs_cor:CurrentLiabilities contextRef="CurrentYearInstant" unitRef="JPY">1770928000000</jppfs_cor:CurrentLiabilities>
            <jppfs_cor:NoncurrentLiabilities contextRef="CurrentYearInstant" unitRef="JPY">1560957000000</jppfs_cor:NoncurrentLiabilities>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant" unitRef="JPY">2873024000000</jppfs_cor:NetAssets>
            <jppfs_cor:TotalAssets contextRef="CurrentYearInstant" unitRef="JPY">6204909000000</jppfs_cor:TotalAssets>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant_NonControllingInterestsMember" unitRef="JPY">250039000000</jppfs_cor:NetAssets>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.accountingStandard == "J-GAAP")
            #expect(result.method == "field_parser")
            #expect(result.currentAssets == 2_923_181 * Financial.millionYen)
            #expect(result.nonCurrentAssets == 3_281_728 * Financial.millionYen)
            #expect(result.totalAssets == 6_204_909 * Financial.millionYen)
            #expect(result.currentLiabilities == 1_770_928 * Financial.millionYen)
            #expect(result.nonCurrentLiabilities == 1_560_957 * Financial.millionYen)
            #expect(result.netAssets == 2_873_024 * Financial.millionYen)
        }
    }

    @Test func testExtractsIfrsBalanceSheetComponents() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:CurrentAssetsIFRS contextRef="CurrentYearInstant" unitRef="JPY">6597843000000</jppfs_cor:CurrentAssetsIFRS>
            <jppfs_cor:NonCurrentAssetsIFRS contextRef="CurrentYearInstant" unitRef="JPY">6686970000000</jppfs_cor:NonCurrentAssetsIFRS>
            <jppfs_cor:TotalCurrentLiabilitiesIFRS contextRef="CurrentYearInstant" unitRef="JPY">5907845000000</jppfs_cor:TotalCurrentLiabilitiesIFRS>
            <jppfs_cor:LiabilitiesIFRS contextRef="CurrentYearInstant" unitRef="JPY">7253396000000</jppfs_cor:LiabilitiesIFRS>
            <jppfs_cor:EquityIFRS contextRef="CurrentYearInstant" unitRef="JPY">6031417000000</jppfs_cor:EquityIFRS>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.accountingStandard == "IFRS")
            #expect(result.currentAssets == 6_597_843 * Financial.millionYen)
            #expect(result.nonCurrentAssets == 6_686_970 * Financial.millionYen)
            #expect(result.currentLiabilities == 5_907_845 * Financial.millionYen)
            // 非流動負債 = LiabilitiesIFRS − TotalCurrentLiabilitiesIFRS
            #expect(result.nonCurrentLiabilities == 1_345_551 * Financial.millionYen)
            #expect(result.netAssets == 6_031_417 * Financial.millionYen)
        }
    }

    @Test func testPrefersIfrsSummaryBalanceSheetValuesOverJgaapSummary() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jpcrp_cor:TotalAssetsIFRSSummaryOfBusinessResults
                contextRef="CurrentYearInstant" unitRef="JPY">1425859000000</jpcrp_cor:TotalAssetsIFRSSummaryOfBusinessResults>
            <jpcrp_cor:TotalEquityIFRSSummaryOfBusinessResults
                contextRef="CurrentYearInstant" unitRef="JPY">720546000000</jpcrp_cor:TotalEquityIFRSSummaryOfBusinessResults>
            <jppfs_cor:TotalAssetsSummaryOfBusinessResults
                contextRef="CurrentYearInstant" unitRef="JPY">988959000000</jppfs_cor:TotalAssetsSummaryOfBusinessResults>
            <jppfs_cor:NetAssets
                contextRef="CurrentYearInstant" unitRef="JPY">365099000000</jppfs_cor:NetAssets>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.accountingStandard == "IFRS")
            #expect(result.totalAssets == 1_425_859 * Financial.millionYen)
            #expect(result.netAssets == 720_546 * Financial.millionYen)
        }
    }

    @Test func testComputesUsgaapNonCurrentAssetsFromXbrlComponents() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:CurrentAssetsUSGAAP contextRef="CurrentYearInstant" unitRef="JPY">1581681000000</jppfs_cor:CurrentAssetsUSGAAP>
            <jppfs_cor:InvestmentsAndLongTermReceivablesUSGAAP contextRef="CurrentYearInstant" unitRef="JPY">1398318000000</jppfs_cor:InvestmentsAndLongTermReceivablesUSGAAP>
            <jppfs_cor:PropertyPlantAndEquipmentNetUSGAAP contextRef="CurrentYearInstant" unitRef="JPY">1785062000000</jppfs_cor:PropertyPlantAndEquipmentNetUSGAAP>
            <jppfs_cor:OtherAssetsUSGAAP contextRef="CurrentYearInstant" unitRef="JPY">484957000000</jppfs_cor:OtherAssetsUSGAAP>
            <jppfs_cor:CurrentLiabilitiesUSGAAP contextRef="CurrentYearInstant" unitRef="JPY">1125940000000</jppfs_cor:CurrentLiabilitiesUSGAAP>
            <jppfs_cor:LongTermLiabilitiesUSGAAP contextRef="CurrentYearInstant" unitRef="JPY">771286000000</jppfs_cor:LongTermLiabilitiesUSGAAP>
            <jppfs_cor:TotalEquityUSGAAP contextRef="CurrentYearInstant" unitRef="JPY">3352682000000</jppfs_cor:TotalEquityUSGAAP>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.accountingStandard == "US-GAAP")
            #expect(result.currentAssets == 1_581_681 * Financial.millionYen)
            // 非流動資産 = XBRL コンポーネント積み上げ: 1398318+1785062+484957
            #expect(result.nonCurrentAssets == 3_668_337 * Financial.millionYen)
            #expect(result.currentLiabilities == 1_125_940 * Financial.millionYen)
            #expect(result.nonCurrentLiabilities == 771_286 * Financial.millionYen)
            #expect(result.netAssets == 3_352_682 * Financial.millionYen)
        }
    }

    @Test func testUsesUsgaapHtmlBalanceSheetRowsWhenXbrlHasOnlySummary() {
        let html = """
        <html><body><table>
          <tr><td>流動資産合計</td><td>1,574,628</td><td>1,581,681</td></tr>
          <tr><td>投資及び長期債権合計</td><td>207,877</td><td>209,294</td></tr>
          <tr><td>有形固定資産合計</td><td>1,395,735</td><td>1,786,475</td></tr>
          <tr><td>その他の資産合計</td><td>1,605,220</td><td>1,672,458</td></tr>
          <tr><td>流動負債合計</td><td>1,165,841</td><td>1,125,940</td></tr>
          <tr><td>固定負債合計</td><td>444,304</td><td>771,286</td></tr>
          <tr><td>純資産合計</td><td>3,173,315</td><td>3,352,682</td></tr>
        </table></body></html>
        """
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jpcrp_cor:EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults
                contextRef="CurrentYearInstant" unitRef="JPY">3348480000000</jpcrp_cor:EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults>
        """)
        XBRLTestSupport.withXbrlDir(xml, extraFiles: ["0105010_honbun_ixbrl.htm": html]) { dir in
            let result = extract(in: dir)
            #expect(result.currentAssets == 1_581_681 * Financial.millionYen)
            // 非流動資産 = HTML 仮想タグ積み上げ: 1786475+209294+1672458
            #expect(result.nonCurrentAssets == 3_668_227 * Financial.millionYen)
            #expect(result.currentLiabilities == 1_125_940 * Financial.millionYen)
            #expect(result.nonCurrentLiabilities == 771_286 * Financial.millionYen)
            #expect(result.netAssets == 3_352_682 * Financial.millionYen)
        }
    }

    @Test func testPrefersUsgaapTotalEquitySummaryOverParentEquitySummary() {
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jpcrp_cor:EquityIncludingPortionAttributableToNonControllingInterestUSGAAPSummaryOfBusinessResults
                contextRef="CurrentYearInstant" unitRef="JPY">3352682000000</jpcrp_cor:EquityIncludingPortionAttributableToNonControllingInterestUSGAAPSummaryOfBusinessResults>
            <jpcrp_cor:EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults
                contextRef="CurrentYearInstant" unitRef="JPY">3348480000000</jpcrp_cor:EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.netAssets == 3_352_682 * Financial.millionYen)
        }
    }

    @Test func testSingleEntityUsesPlainContext() {
        // 単体のみ企業（_NonConsolidatedMember なし）は plain context のBS値を返す
        let xml = XBRLTestSupport.makeXbrlInstant("""
            <jppfs_cor:CurrentAssets contextRef="CurrentYearInstant" unitRef="JPY">184600000000</jppfs_cor:CurrentAssets>
            <jppfs_cor:NoncurrentAssets contextRef="CurrentYearInstant" unitRef="JPY">113568000000</jppfs_cor:NoncurrentAssets>
            <jppfs_cor:CurrentLiabilities contextRef="CurrentYearInstant" unitRef="JPY">42737000000</jppfs_cor:CurrentLiabilities>
            <jppfs_cor:NoncurrentLiabilities contextRef="CurrentYearInstant" unitRef="JPY">60103000000</jppfs_cor:NoncurrentLiabilities>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant" unitRef="JPY">238065000000</jppfs_cor:NetAssets>
        """)
        XBRLTestSupport.withXbrlDir(xml) { dir in
            let result = extract(in: dir)
            #expect(result.currentAssets == 184_600 * Financial.millionYen)
            #expect(result.nonCurrentAssets == 113_568 * Financial.millionYen)
            #expect(result.currentLiabilities == 42_737 * Financial.millionYen)
            #expect(result.nonCurrentLiabilities == 60_103 * Financial.millionYen)
            #expect(result.netAssets == 238_065 * Financial.millionYen)
        }
    }
}
