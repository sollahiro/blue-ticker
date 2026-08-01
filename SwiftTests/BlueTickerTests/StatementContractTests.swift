import Foundation
import Testing

@testable import BlueTickerCore

/// Statement 公開契約（Statement 取り込み 骨組み）のバージョニング・Codable 往復の仕様を検証する。
@Suite struct StatementContractTests {
    @Test func cacheVersionNumberParsesStatementVN() {
        #expect(statementCacheVersionNumber("statement-v1") == 1)
        #expect(statementCacheVersionNumber("statement-v2") == 2)
        #expect(statementCacheVersionNumber("statement-v10") == 10)
        #expect(statementCacheVersionNumber("statement-v") == nil)
        #expect(statementCacheVersionNumber("0.0.0") == nil)
        #expect(statementCacheVersionNumber("statement-v2b") == nil)
    }

    @Test func isServableUsesNumericFloorNotLexicographicOrder() throws {
        #expect(statementMinServableVersion == 1)
        #expect(isServableStatementCacheVersion("statement-v1") == true)
        #expect(isServableStatementCacheVersion("statement-v10") == true)
        #expect(isServableStatementCacheVersion("0.0.0") == false)
        // 数値比較であることの直接確認（文字列辞書順だと "v9" > "v10" になってしまう）。
        let v9 = try #require(statementCacheVersionNumber("statement-v9"))
        let v10 = try #require(statementCacheVersionNumber("statement-v10"))
        #expect(v10 > v9)
        // 現行版番号は床以上（不変条件）。
        let current = try #require(statementCacheVersionNumber(statementCacheVersion))
        #expect(current >= statementMinServableVersion)
    }

    @Test func responseRoundTripsThroughSnakeCaseJson() throws {
        let response = StatementResponse(
            schemaVersion: 1, code: "7203", name: "トヨタ自動車", sector: "輸送用機器",
            market: "プライム",
            years: [
                StatementYear(
                    fyEnd: "2024-03", financialPeriod: "FY", docId: "S100XXXX",
                    balanceSheet: [
                        StatementLineItem(
                            tag: "CashAndDeposits", label: "現金及び預金", value: 1_000_000,
                            unit: "JPY", order: nil)
                    ],
                    incomeStatement: [
                        StatementLineItem(
                            tag: "NetSales", label: "売上高", value: 5_000_000, unit: "JPY",
                            order: nil)
                    ],
                    cashFlow: [])
            ])

        let json = try JSONEncoder().encode(response)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["schema_version"] as? Int == 1)
        let years = try #require(object["years"] as? [[String: Any]])
        #expect(years.first?["fy_end"] as? String == "2024-03")
        #expect(years.first?["doc_id"] as? String == "S100XXXX")
        let balanceSheet = try #require(years.first?["balance_sheet"] as? [[String: Any]])
        #expect(balanceSheet.first?["tag"] as? String == "CashAndDeposits")

        let decoded = try JSONDecoder().decode(StatementResponse.self, from: json)
        #expect(decoded.code == "7203")
        #expect(decoded.years.first?.balanceSheet.first?.value == 1_000_000)
    }

    @Test func notApplicablePlaceholderHasEmptyYears() {
        let placeholder = StatementResponse.notApplicablePlaceholder(code: "9999")
        #expect(placeholder.code == "9999")
        #expect(placeholder.years.isEmpty)
    }

    @Test func decodesLineItemJsonMissingIsTotalKeyAsFalse() throws {
        // 回帰テスト（Opus 監査で発見・修正、2026-07-31）: `is_total`/`components` 追加前に
        // 格納された行（company_statements.payload は JSON カラム）は `is_total` キーを
        // 持たない。合成 `Decodable` のままだと `keyNotFound` で読み取り自体が失敗するため、
        // `isTotal` は非 Optional のまま `decodeIfPresent(default: false)` で読む。
        let json = Data(
            """
            {"tag": "CashAndDeposits", "label": "現金及び預金", "value": 100, "unit": "JPY",
             "order": null, "section": null}
            """.utf8)
        let item = try JSONDecoder().decode(StatementLineItem.self, from: json)
        #expect(item.tag == "CashAndDeposits")
        #expect(item.isTotal == false)
        #expect(item.components == nil)
    }

    @Test func roundTripsIsTotalAndComponentsThroughJson() throws {
        let item = StatementLineItem(
            tag: "AssetsIFRS", label: "資産合計", value: 93_601_350_000_000, unit: "JPY", order: 33,
            section: .assets, isTotal: true,
            components: [
                StatementLineComponent(tag: "CurrentAssetsIFRS", weight: 1),
                StatementLineComponent(tag: "NonCurrentAssetsIFRS", weight: 1),
            ])
        let json = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(StatementLineItem.self, from: json)
        #expect(decoded.isTotal == true)
        #expect(decoded.components?.map(\.tag) == ["CurrentAssetsIFRS", "NonCurrentAssetsIFRS"])
        #expect(decoded.components?.map(\.weight) == [1, 1])
    }
}
