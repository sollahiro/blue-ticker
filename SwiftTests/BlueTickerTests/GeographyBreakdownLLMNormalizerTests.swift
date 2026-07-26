// GeographyBreakdownLLMNormalizer の決定的後処理（うち内数の二重計上除去）を検証する。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite("GeographyBreakdownLLMNormalizer")
struct GeographyBreakdownLLMNormalizerTests {

    @Test("親地域とうち内数の二重計上を内数側だけ落とす")
    func dropsOfWhichSubsetSegments() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 254_181, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "北米", amount: 37_897, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "米国", amount: 37_220, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "欧州", amount: 38_201, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "その他", amount: 21_084, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "合計", amount: 351_363, share: nil, profit: nil, rowKind: "subtotal"),
        ]
        let filtered = GeographyBreakdownLLMNormalizer.dropOfWhichSubsetSegments(rows)
        let labels = filtered.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["日本", "北米", "欧州", "その他"])
        #expect(filtered.contains { $0.rowKind == "subtotal" })
    }

    @Test("米大陸とうち米国、その他と中国も内数側を落とす")
    func dropsAmericasAndChinaSubsets() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 84_769, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "北米", amount: 322_540, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "米国", amount: 320_659, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "その他", amount: 45_985, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "中国", amount: 19_341, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "合計", amount: 453_294, share: nil, profit: nil, rowKind: "subtotal"),
        ]
        let filtered = GeographyBreakdownLLMNormalizer.dropOfWhichSubsetSegments(rows)
        let labels = Set(filtered.filter { $0.rowKind == "segment" }.map(\.labelRaw))
        #expect(labels == ["日本", "北米", "その他"])
    }

    @Test("親子関係が無い地域行はそのまま残す")
    func keepsIndependentRegions() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 500, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "北米", amount: 200, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "欧州", amount: 300, share: nil, profit: nil, rowKind: "segment"),
        ]
        let filtered = GeographyBreakdownLLMNormalizer.dropOfWhichSubsetSegments(rows)
        #expect(filtered.map(\.labelRaw) == ["日本", "北米", "欧州"])
    }

    private actor MockChat: ChatCompleting {
        let response: [String: Any]
        init(_ response: [String: Any]) { self.response = response }
        func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
            try JSONSerialization.data(withJSONObject: response)
        }
    }

    @Test("うち二重計上レスポンスでも分母一致なら needs_review にならない")
    func normalizeDropsOfWhichBeforeDenominatorCheck() async throws {
        let sales = 351_363.0 * Financial.millionYen
        let tables = [
            BreakdownTable(
                heading: "地域ごとの情報",
                markdown: "| 日本 | 北米 | (うち米国) | 欧州 | その他 | 合計 |\n",
                period: "当期")
        ]
        let geography = ExtractedBreakdown(method: "html_table", tables: tables, facts: [])
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": 254_181, "row_kind": "segment"],
                ["label": "北米", "amount": 37_897, "row_kind": "segment"],
                ["label": "米国", "amount": 37_220, "row_kind": "segment"],
                ["label": "欧州", "amount": 38_201, "row_kind": "segment"],
                ["label": "その他", "amount": 21_084, "row_kind": "segment"],
                ["label": "合計", "amount": 351_363, "row_kind": "subtotal"],
            ],
            "notes": "test nested of-which",
        ]
        let (snapshot, _) = await GeographyBreakdownLLMNormalizer.normalize(
            geography, consolidatedSales: sales, client: MockChat(response))
        let snap = try #require(snapshot)
        #expect(snap.needsReview == false)
        #expect(!snap.warnings.contains("llm_row_sum_mismatch"))
        let labels = snap.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["日本", "北米", "欧州", "その他"])
    }
}
