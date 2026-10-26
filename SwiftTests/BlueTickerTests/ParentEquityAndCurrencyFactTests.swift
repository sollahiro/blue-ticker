import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct ParentEquityAndCurrencyFactTests {
    /// 外貨建て開示の邦貨併記（6269 S100XU6C 型）: 同じタグ・同じ context に USD と JPY が並ぶとき、
    /// 本表タクソノミの通貨（USD）を残す。並び順に依らない。
    @Test func sameContextCurrencyAlternatesKeepReportingCurrency() throws {
        for jpyFirst in [false, true] {
            let usd = #"<jpcrp_cor:EquityToAssetRatioIFRSSummaryOfBusinessResults contextRef="CurrentYearInstant" unitRef="USDPerShares" decimals="2">21.26</jpcrp_cor:EquityToAssetRatioIFRSSummaryOfBusinessResults>"#
            let jpy = #"<jpcrp_cor:EquityToAssetRatioIFRSSummaryOfBusinessResults contextRef="CurrentYearInstant" unitRef="JPYPerShares" decimals="2">3327.57</jpcrp_cor:EquityToAssetRatioIFRSSummaryOfBusinessResults>"#
            let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <xbrli:xbrl xmlns:xbrli="http://www.xbrl.org/2003/instance" xmlns:jpcrp_cor="c" xmlns:jpigp_cor="i">
                \(jpyFirst ? jpy : usd)
                \(jpyFirst ? usd : jpy)
                <jpigp_cor:EquityIFRS contextRef="CurrentYearInstant" unitRef="USD" decimals="-3">1474043000</jpigp_cor:EquityIFRS>
                <jpigp_cor:AssetsIFRS contextRef="CurrentYearInstant" unitRef="USD" decimals="-3">5000000000</jpigp_cor:AssetsIFRS>
                </xbrli:xbrl>
                """
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("currency-alternates-\(UUID().uuidString).xbrl")
            try xml.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }

            let fact = try #require(
                XBRLUtils.collectNumericFacts(in: file)["EquityToAssetRatioIFRSSummaryOfBusinessResults"]?[
                    "CurrentYearInstant"])
            #expect(fact.unitRef == "USDPerShares")
            #expect(fact.value == 21.26)
        }
    }

    @Test func parentEquityPrefersDirectLineThenSubtractsMinorityAndRights() {
        let ifrs: FieldSet = [
            "EquityAttributableToOwnersOfParentIFRS": FieldValue(current: 1_452_809, prior: nil),
            "NonControllingInterestsIFRS": FieldValue(current: 21_233, prior: nil),
        ]
        #expect(StatementFinancialsResolver.resolveParentEquity(instantFS: ifrs, netAssets: 1_474_043) == 1_452_809)

        let jgaap: FieldSet = [
            "NonControllingInterests": FieldValue(current: 1_119, prior: nil),
            "SubscriptionRightsToShares": FieldValue(current: 30, prior: nil),
        ]
        #expect(StatementFinancialsResolver.resolveParentEquity(instantFS: jgaap, netAssets: 2_725_446) == 2_724_297)
        // 非支配株主持分・新株予約権の行が無い会社は純資産合計そのもの。
        #expect(StatementFinancialsResolver.resolveParentEquity(instantFS: [:], netAssets: 1_000) == 1_000)
        #expect(StatementFinancialsResolver.resolveParentEquity(instantFS: [:], netAssets: nil) == nil)
    }
}
