// 実 EDINET XBRL（analysis_cache）での売上総利益 golden。
//
// イオンフィナンシャルサービス 8570 / S100QTUM（23/02 有報）:
// 本表は 営業収益 − 営業費用 = 営業利益 で売上総利益行が無い。役務タグ
// （FeesAndCommissionsOIBNK）だけでは銀行の連結業務粗利益に落ちてはいけない。
// 期待値は原本 CurrentYearDuration / Prior1YearDuration の円単位:
//   営業収益 451,767 / 470,657 百万円
//   営業費用 392,907 / 411,804 百万円
//   販管費   342,034 / 347,766 百万円
//   構成粗利 = 営業収益 − 営業費用 + 販管費 → 400,894 / 406,619 百万円
//
// イオン 8267 / S100Y5VH（26/02 有報）:
// 売上総利益（売上高 − 売上原価）2,649,178 と営業総利益（営業収益合計 − 営業原価合計）
// 3,910,376 が両方ある。GP は売上総利益のまま。営業総利益に置き換えない。
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlGrossProfitExtractorTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    /// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、それでも無ければ SKIP する。
    /// 展開途中ディレクトリに `.extract_complete` を書かない。`ensureCached` は
    /// マーカー無しなら再取得し、壊れたキャッシュを信頼しない。
    private static func ensureAvailable(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        let dir = xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return nil
        }
        return dir
    }

    @Test func aeonFinancialServiceS100QTUMConstructsGrossProfitFromOpexPlusSga() async throws {
        guard let dir = await Self.ensureAvailable("S100QTUM") else { return }

        let (fs, std) = XBRLTestSupport.durationFieldSet(in: dir)
        let result = GrossProfitExtractor.extract(
            fieldSet: fs, accountingStandard: std, xbrlDir: dir)

        #expect(result.method == "operating_revenue_minus_opex_plus_sga")
        #expect(result.grossProfitLabel == "販管費控除前営業利益")
        #expect(result.grossProfit == 400_894_000_000)
        #expect(result.grossProfitPrior == 406_619_000_000)

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(values.grossProfit == 400_894_000_000)
        #expect(values.grossProfitLabel == "販管費控除前営業利益")
        #expect(values.operatingProfit == 58_859_000_000)
        #expect(values.sga == 342_034_000_000)
        #expect(values.sales == 451_767_000_000)
    }

    @Test func aeonS100Y5VHKeepsMerchandiseGrossProfit() async throws {
        guard let dir = await Self.ensureAvailable("S100Y5VH") else { return }

        let (fs, std) = XBRLTestSupport.durationFieldSet(in: dir)
        let result = GrossProfitExtractor.extract(
            fieldSet: fs, accountingStandard: std, xbrlDir: dir)

        #expect(result.method == "direct")
        #expect(result.grossProfitLabel == nil)
        #expect(result.grossProfit == 2_649_178_000_000)

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(values.grossProfit == 2_649_178_000_000)
        #expect(values.grossProfitLabel == nil)
        #expect(values.operatingProfit == 270_459_000_000)
        #expect(values.sga == 3_639_916_000_000)
        #expect(values.sales == 9_355_439_000_000)
    }
}
