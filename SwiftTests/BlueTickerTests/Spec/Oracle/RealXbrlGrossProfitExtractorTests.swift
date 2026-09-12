// 実 EDINET XBRL（analysis_cache）での売上総利益 golden。
// イオンフィナンシャルサービス 8570 / S100QTUM（23/02 有報）。
// 本表は 営業収益 − 営業費用 = 営業利益 で売上総利益行が無い。役務タグ
// （FeesAndCommissionsOIBNK）だけでは銀行の連結業務粗利益に落ちてはいけない。
//
// 期待値は原本 CurrentYearDuration / Prior1YearDuration の円単位:
//   営業収益 451,767 / 470,657 百万円
//   営業費用 392,907 / 411,804 百万円
//   販管費   342,034 / 347,766 百万円
//   構成粗利 = 営業収益 − 営業費用 + 販管費 → 400,894 / 406,619 百万円
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlGrossProfitExtractorTests {
    private static let docID = "S100QTUM"
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()
    private static var xbrlDir: URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    /// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、それでも無ければ SKIP する。
    private static func ensureAvailable() async -> Bool {
        let dir = xbrlDir
        if FileManager.default.fileExists(atPath: dir.path) {
            let marker = dir.appendingPathComponent(EdinetCacheStore.xbrlExtractCompleteMarker)
            if !FileManager.default.fileExists(atPath: marker.path) {
                FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: nil)
            }
        } else {
            await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        }
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    @Test func aeonFinancialServiceS100QTUMConstructsGrossProfitFromOpexPlusSga() async throws {
        guard await Self.ensureAvailable() else { return }

        let (fs, std) = XBRLTestSupport.durationFieldSet(in: Self.xbrlDir)
        let result = GrossProfitExtractor.extract(
            fieldSet: fs, accountingStandard: std, xbrlDir: Self.xbrlDir)

        #expect(result.method == "operating_revenue_minus_opex_plus_sga")
        #expect(result.grossProfitLabel == "販管費控除前営業利益")
        #expect(result.grossProfit == 400_894_000_000)
        #expect(result.grossProfitPrior == 406_619_000_000)

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: Self.xbrlDir))
        #expect(values.grossProfit == 400_894_000_000)
        #expect(values.grossProfitLabel == "販管費控除前営業利益")
        #expect(values.operatingProfit == 58_859_000_000)
        #expect(values.sga == 342_034_000_000)
        #expect(values.sales == 451_767_000_000)
    }
}
