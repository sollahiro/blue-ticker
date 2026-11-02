// 実 EDINET XBRL での銀行業種 KPI（期末預貸率・OHR）golden。
//
// 期待値の一次資料は有報の jppfs BNK 数値。調査ページの % は同じ入力からの計算。
// 連結粗利益は XBRL 構成要素の和（GrossProfitExtractor と同じ）。MD&A「国内・海外別収支」
// 合計とは金銭の信託運用見合費用の扱いで 1百万円〜177百万円ずれることがある。
// ずれても OHR を 2 桁 % に丸めると調査値と一致するか、不一致なら原因を残す。
//
// 千葉銀行 8331 / S100YDSE、三菱UFJ 8306 / S100YJQO、三井住友FG 8316 / S100YERK、
// めぶきFG 7167 / S100YAVM、楽天銀行 5838 / S100YGME。いずれも 2026-03 期。
//
// `BLT_EDINET_API_KEY` または R2 があれば不足キャッシュを取得し、無ければ SKIP。
// CI の unit-tests はこのファイルを golden-filter で skip する。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlBankIndustryKpiTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func ensureAvailable(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        let dir = xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return nil
        }
        return dir
    }

    private static let million = Financial.millionYen

    struct BankCase: Sendable {
        let name: String
        let docID: String
        let loans: Double
        let deposits: Double
        let ncd: Double
        let opex: Double
        let researchGP: Double
        let researchLDR: Double
        let researchOHR: Double
    }

    static let cases: [BankCase] = [
        // source: code=8331 fy_end=2026-03-31 doc_id=S100YDSE page=0 field=industry_kpi.ldr_ohr
        .init(
            name: "千葉銀行", docID: "S100YDSE",
            loans: 14_082_336, deposits: 16_830_424, ncd: 180_766,
            opex: 104_888, researchGP: 223_274,
            researchLDR: 82.78, researchOHR: 46.98),
        // source: code=8306 fy_end=2026-03-31 doc_id=S100YJQO page=0 field=industry_kpi.ldr_ohr
        .init(
            name: "三菱UFJ", docID: "S100YJQO",
            loans: 133_799_490, deposits: 239_439_246, ncd: 17_601_483,
            opex: 3_489_570, researchGP: 5_944_462,
            researchLDR: 52.05, researchOHR: 58.70),
        // source: code=8316 fy_end=2026-03-31 doc_id=S100YERK page=0 field=industry_kpi.ldr_ohr
        .init(
            name: "三井住友FG", docID: "S100YERK",
            loans: 117_629_215, deposits: 185_674_241, ncd: 15_667_132,
            opex: 2_651_514, researchGP: 4_844_692,
            researchLDR: 58.42, researchOHR: 54.73),
        // source: code=7167 fy_end=2026-03-31 doc_id=S100YAVM page=0 field=industry_kpi.ldr_ohr
        .init(
            name: "めぶきFG", docID: "S100YAVM",
            loans: 13_997_655, deposits: 17_831_757, ncd: 276_180,
            opex: 116_766, researchGP: 214_151,
            researchLDR: 77.30, researchOHR: 54.53),
        // source: code=5838 fy_end=2026-03-31 doc_id=S100YGME page=0 field=industry_kpi.ldr_ohr
        .init(
            name: "楽天銀行", docID: "S100YGME",
            loans: 5_943_070, deposits: 13_046_850, ncd: 7_428,
            opex: 56_934, researchGP: 165_732,
            researchLDR: 45.53, researchOHR: 34.35),
    ]

    @Test(arguments: cases)
    func fy2026ConsolidatedLDRAndOHR(_ bank: BankCase) async throws {
        guard let dir = await Self.ensureAvailable(bank.docID) else { return }
        guard case .resolved(let payload, let source, _) =
            BankIndustryKpiExtractor.resolve(xbrlDir: dir)
        else {
            Issue.record("\(bank.name) \(bank.docID): expected resolved bank KPI")
            return
        }
        #expect(source == industryKpiSourceXbrlFacts)
        #expect(payload.industryGroup == industryKpiGroupBank)
        let scope = industryKpiScopeConsolidated
        let loans = try #require(payload.fact(key: industryKpiKeyLoans, scope: scope)?.value)
        let deposits = try #require(payload.fact(key: industryKpiKeyDeposits, scope: scope)?.value)
        let ncd = try #require(payload.fact(key: industryKpiKeyNegotiableCDs, scope: scope)?.value)
        let opex = try #require(payload.fact(key: industryKpiKeyOperatingExpenses, scope: scope)?.value)
        let gp = try #require(payload.fact(key: industryKpiKeyGrossBusinessProfit, scope: scope)?.value)
        #expect(loans == bank.loans * Self.million)
        #expect(deposits == bank.deposits * Self.million)
        #expect(ncd == bank.ncd * Self.million)
        #expect(opex == bank.opex * Self.million)

        let ldr = try #require(payload.fact(key: industryKpiKeyLDR, scope: scope))
        let ohr = try #require(payload.fact(key: industryKpiKeyOHR, scope: scope))
        #expect(ldr.unit == AmountUnit.Code.percent.rawValue)
        #expect(ohr.unit == AmountUnit.Code.percent.rawValue)
        #expect(ldr.periodBasis == industryKpiPeriodBasisPeriodEnd)
        #expect(ohr.periodBasis == industryKpiPeriodBasisDuration)
        #expect(round2(ldr.value) == bank.researchLDR)

        let gpMillion = gp / Self.million
        let xbrlOHR = round2(opex / gp * 100)
        #expect(round2(ohr.value) == xbrlOHR)
        if gpMillion != bank.researchGP {
            print(
                "\(bank.name) \(bank.docID): XBRL 連結粗利益 \(gpMillion) 百万円 vs 調査 MD&A \(bank.researchGP) 百万円"
            )
        }
        #expect(round2(ohr.value) == bank.researchOHR)
        #expect(
            payload.fact(key: industryKpiKeyNetInterestIncome, scope: scope) != nil)
        #expect(
            payload.fact(key: industryKpiKeyOperatingExpenses, scope: scope)?.sourceRef
                == "GeneralAndAdministrativeExpensesOEBNK")
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
