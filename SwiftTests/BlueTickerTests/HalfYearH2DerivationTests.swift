// 半期 H2 導出の回帰テスト。
//
// H2 の BS 運転資本（売掛金・棚卸資産・買掛金）は残高なので FY 期末スナップショットを使う。
// H2 の CF 自己株式取得・配当（SS/CF）はフローのため FY − H1 で導出する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct HalfYearH2DerivationTests {

    private func makeAnalyzer() -> HalfYearAnalyzer {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        return HalfYearAnalyzer(
            edinetClient: EdinetAPIClient(apiKey: nil),
            cacheManager: CacheManager(cacheDir: tmp)
        )
    }

    private func entry(
        ar: Double?, inv: Double?, ap: Double?,
        cfTs: Double?, divSS: Double?, divCF: Double?
    ) -> YearEntry {
        var calc = CalculatedData()
        calc.accountsReceivable = ar
        calc.inventory = inv
        calc.accountsPayable = ap
        calc.cfTreasuryStock = cfTs
        calc.dividendSS = divSS
        calc.dividendPaidCF = divCF
        return YearEntry(fyEnd: "2024-03-31", financialPeriod: "test",
                         rawData: RawData(), calculatedData: calc)
    }

    @Test func h2BalanceSheetWorkingCapitalUsesFyYearEndSnapshot() {
        // H1 のスナップショットではなく FY 期末値を H2 に引き継ぐ。
        let fy = entry(ar: 300, inv: 200, ap: 100, cfTs: nil, divSS: nil, divCF: nil)
        let h1 = entry(ar: 280, inv: 190, ap: 90, cfTs: nil, divSS: nil, divCF: nil)

        let h2 = makeAnalyzer().buildH2Entry(fy: fy, h1: h1, fyEnd: "2024-03-31")
        #expect(h2.calculatedData.accountsReceivable == 300)
        #expect(h2.calculatedData.inventory == 200)
        #expect(h2.calculatedData.accountsPayable == 100)
    }

    @Test func h2CashFlowAndDividendFlowsAreFyMinusH1() {
        let fy = entry(ar: nil, inv: nil, ap: nil, cfTs: 50, divSS: 80, divCF: 80)
        let h1 = entry(ar: nil, inv: nil, ap: nil, cfTs: 20, divSS: 30, divCF: 30)

        let h2 = makeAnalyzer().buildH2Entry(fy: fy, h1: h1, fyEnd: "2024-03-31")
        #expect(h2.calculatedData.cfTreasuryStock == 30)
        #expect(h2.calculatedData.dividendSS == 50)
        #expect(h2.calculatedData.dividendPaidCF == 50)
    }
}
