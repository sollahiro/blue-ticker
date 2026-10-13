// 実 EDINET XBRL（analysis_cache）: ゆうちょ銀行 7182 / S100Y9G1（26/03）は EDINET 提出者業種が銀行業。
// 貯金を `DepositsLiabilities`（BNK でない）で載せるため預金マーカーだけでは銀行にならなかった。
// 業種を渡すと銀行経路（百万円）:
// - 業務粗利益 1,381,863 =（資金運用収益 2,270,832 − 資金調達費用 988,450）
//   +（役務取引等収益 196,841 − 役務取引等費用 29,254）+（その他業務収益 3,222 − その他業務費用 71,328）
// - 営業経費 946,425（GeneralAndAdministrativeExpensesOEBNK）→ 業務純益 435,438
// - 有利子負債は bank components: 借用金 2,819,400 + リース。貯金 186,108,700 は含めない。
// 業種を渡さなければ従来どおり経常利益 759,150。
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlJapanPostBankTests {
    private static let docID = "S100Y9G1"
    private static let million = 1_000_000.0

    private static func dir() async -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
        await SmokeCacheSupport.ensureCached([docID], cacheDir: root)
        let dir = root.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return nil
        }
        return dir
    }

    @Test func bankIndustryUsesNetBusinessProfit() async throws {
        guard let dir = await Self.dir() else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir, edinetIndustry: "銀行業"))
        #expect(v.grossProfit == 1_381_863 * Self.million)
        #expect(v.grossProfitLabel == "連結業務粗利益")
        #expect(v.sga == 946_425 * Self.million)
        #expect(v.sgaLabel == "営業経費")
        #expect(v.operatingProfit == 435_438 * Self.million)
        #expect(v.operatingProfitLabel == "業務純益")
        #expect(v.salesLabel == "経常収益")
    }

    @Test func withoutIndustryStaysOrdinaryIncome() async throws {
        guard let dir = await Self.dir() else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.operatingProfit == 759_150 * Self.million)
        #expect(v.operatingProfitLabel == "経常利益")
        #expect(v.sga == nil)
    }

    @Test func bankIndustryIbdUsesBankComponentsWithoutSavings() async throws {
        guard let dir = await Self.dir() else { return }
        let inputs = InterestBearingDebtBreakdown.inputs(xbrlDir: dir, edinetIndustry: "銀行業")
        #expect(inputs.isBank)
        #expect(inputs.balanceSheet.isEmpty)
        let tags = inputs.bankComponents.compactMap(\.sourceTag)
        #expect(tags == ["BorrowedMoneyLiabilitiesBNK"])
        #expect(inputs.bankComponents.first?.closing == 2_819_400 * Self.million)
        #expect(!tags.contains("DepositsLiabilities"))

        let ibd = await BreakdownFinancialsResolver.financialsCanonicalInterestBearingDebt(
            xbrlDir: dir, edinetIndustry: "銀行業")
        #expect(ibd.isBank)
        #expect(ibd.total == 2_820_459 * Self.million)  // 借用金 2,819,400 + リース 1,059

        var calc = CalculatedData()
        calc.interestBearingDebt = 2_820_459
        calc.netAssets = 9_260_090
        calc.nopat = 300_000
        var raw = RawData()
        raw.cashEq = 54_000_000
        raw.sales = 2_852_206
        IndividualAnalyzer.applyInterestBearingDebtRatios(to: &calc, raw: raw, isBank: ibd.isBank)
        #expect(calc.netCash == nil && calc.netDE == nil && calc.roic == nil)
        #expect(calc.nopatMargin == nil && calc.investedCapitalTurnover == nil)
    }
}
