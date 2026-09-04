// 実 XBRL の「事業の内容」抽出。鍵があれば SmokeCacheSupport で取得し、無ければ SKIP。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct RealXbrlDescriptionOfBusinessTests {
    @Test func toyotaBusinessDescriptionDoesNotLeakRelatedCompanies() async throws {
        try await StatementNotesOracleSupport.withSmokeCache("S100Y8NY") { dir in
            let text = DescriptionOfBusinessExtractor.extract(in: dir)
            #expect(!text.isEmpty)
            #expect(text.contains("自動車") || text.contains("車両"))
            #expect(!text.contains("【関係会社の状況】"))
            #expect(!text.contains("【従業員の状況】"))
        }
    }

    @Test func mufgBusinessDescriptionIsNotThin() async throws {
        try await StatementNotesOracleSupport.withSmokeCache("S100YJQO") { dir in
            let text = DescriptionOfBusinessExtractor.extract(in: dir)
            #expect(text.count >= companyOverviewInputThinChars)
            #expect(text.contains("銀行") || text.contains("信託") || text.contains("証券"))
        }
    }

    @Test func ajinomotoBusinessDescriptionMentionsFood() async throws {
        try await StatementNotesOracleSupport.withSmokeCache("S100Y992") { dir in
            let text = DescriptionOfBusinessExtractor.extract(in: dir)
            #expect(
                text.contains("調味料") || text.contains("アミノ酸") || text.contains("冷凍"))
        }
    }
}
