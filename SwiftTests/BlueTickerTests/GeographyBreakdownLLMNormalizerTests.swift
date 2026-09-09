// GeographyBreakdownLLMNormalizer の決定的後処理（うち内数の of_which ネスト）を検証する。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite("GeographyBreakdownLLMNormalizer")
struct GeographyBreakdownLLMNormalizerTests {

    @Test("親地域とうち内数を of_which にネストし加算対象から外す")
    func nestsOfWhichSubsetSegments() throws {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 254_181, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "北米", amount: 37_897, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "米国", amount: 37_220, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "欧州", amount: 38_201, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "その他", amount: 21_084, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "合計", amount: 351_363, share: nil, profit: nil, rowKind: "subtotal"),
        ]
        let nested = GeographyBreakdownLLMNormalizer.nestOfWhichSubsetSegments(rows)
        let labels = nested.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["日本", "北米", "欧州", "その他"])
        let usa = try #require(nested.first { $0.labelRaw == "米国" })
        #expect(usa.rowKind == "of_which")
        #expect(usa.parentLabel == "北米")
        #expect(nested.contains { $0.rowKind == "subtotal" })
        let additive = nested.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        #expect(abs(additive - 351_363) < 0.5)
    }

    @Test("うちラベルは比率が低くても内数としてアジアの下にネストする")
    func nestsUchiLabeledChildEvenWhenRatioIsLow() throws {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 38_840, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "アジア", amount: 14_246, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "うち中国", amount: 8_900, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "その他", amount: 6_391, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "合計", amount: 59_479, share: nil, profit: nil, rowKind: "subtotal"),
        ]
        let nested = GeographyBreakdownLLMNormalizer.nestOfWhichSubsetSegments(rows)
        let labels = nested.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["日本", "アジア", "その他"])
        let china = try #require(nested.first { $0.labelRaw == "うち中国" })
        #expect(china.rowKind == "of_which")
        #expect(china.parentLabel == "アジア")
        let additive = nested.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        #expect(abs(additive - 59_479) < 0.5)
    }

    @Test("北米のうち米国（高比率）だけネストし、並列の中国はそのまま残す")
    func nestsOnlyHighRatioAmericasSubset() throws {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 84_769, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "北米", amount: 322_540, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "米国", amount: 320_659, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "その他", amount: 45_985, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "中国", amount: 19_341, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "合計", amount: 453_294, share: nil, profit: nil, rowKind: "subtotal"),
        ]
        let nested = GeographyBreakdownLLMNormalizer.nestOfWhichSubsetSegments(rows)
        let labels = Set(nested.filter { $0.rowKind == "segment" }.map(\.labelRaw))
        // 米国は北米の内数（比率≈99%）。中国はその他の並列地域なので segment のまま。
        #expect(labels == ["日本", "北米", "その他", "中国"])
        let usa = try #require(nested.first { $0.labelRaw == "米国" })
        #expect(usa.rowKind == "of_which")
        #expect(usa.parentLabel == "北米")
    }

    @Test("アジア他と中国が並列のときは中国を落とさない（テルモ型）")
    func keepsChinaBesideAsiaOther() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "米州", amount: 443_405, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "日本", amount: 222_603, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "欧州", amount: 242_655, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "中国", amount: 91_309, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "アジア他", amount: 131_902, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "合計", amount: 1_131_877, share: nil, profit: nil, rowKind: "subtotal"),
        ]
        let filtered = GeographyBreakdownLLMNormalizer.nestOfWhichSubsetSegments(rows)
        let labels = filtered.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["米州", "日本", "欧州", "中国", "アジア他"])
    }

    @Test("親子関係が無い地域行はそのまま残す")
    func keepsIndependentRegions() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 500, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "北米", amount: 200, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "欧州", amount: 300, share: nil, profit: nil, rowKind: "segment"),
        ]
        let filtered = GeographyBreakdownLLMNormalizer.nestOfWhichSubsetSegments(rows)
        #expect(filtered.map(\.labelRaw) == ["日本", "北米", "欧州"])
    }

    private actor MockChat: ChatCompleting {
        let response: [String: Any]
        init(_ response: [String: Any]) { self.response = response }
        func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
            try JSONSerialization.data(withJSONObject: response)
        }
    }

    @Test("うち二重計上レスポンスでもネスト後は分母一致し needs_review にならない")
    func normalizeNestsOfWhichBeforeDenominatorCheck() async throws {
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
        let usa = try #require(snap.rows.first { $0.labelRaw == "米国" })
        #expect(usa.rowKind == "of_which")
        #expect(usa.parentLabel == "北米")
        let additive = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        #expect(abs(additive - sales) < 1)
    }

    @Test("地域注記合計が IS 売上と乖離しても表内小計で分母を揃える（クレディセゾン型）")
    func alignsDenominatorToGeographyTableSubtotal() async throws {
        // 損益計算書の売上高 472,770 百万円 vs 地域注記合計 546,271 百万円
        let isSales = 472_770.0 * Financial.millionYen
        let tables = [
            BreakdownTable(
                heading: "地域ごとの情報",
                markdown: "| 日本 | インド | その他 | 合計 |\n",
                period: "当期")
        ]
        let geography = ExtractedBreakdown(method: "html_table", tables: tables, facts: [])
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": 484_060, "row_kind": "segment"],
                ["label": "インド", "amount": 56_056, "row_kind": "segment"],
                ["label": "その他", "amount": 6_154, "row_kind": "segment"],
                ["label": "合計", "amount": 546_271, "row_kind": "subtotal"],
            ],
            "notes": "credit saison style",
        ]
        let (snapshot, _) = await GeographyBreakdownLLMNormalizer.normalize(
            geography, consolidatedSales: isSales, client: MockChat(response))
        let snap = try #require(snapshot)
        #expect(snap.needsReview == false)
        #expect(snap.warnings.contains("llm_denominator_from_internal_subtotal"))
        #expect(!snap.warnings.contains("llm_row_sum_mismatch"))
        #expect(snap.denominatorTag == "llm_table_subtotal")
        #expect(abs(snap.denominator - 546_271.0 * Financial.millionYen) < 1)
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.compactMap(\.share).reduce(0, +)
        #expect(abs(segmentShare - 1.0) < 0.01)
    }

    @Test("表内小計が無く IS 売上とも合わないときは needs_review のまま")
    func keepsNeedsReviewWhenNoMatchingSubtotal() async throws {
        let isSales = 1_000_000.0 * Financial.millionYen
        let tables = [
            BreakdownTable(heading: "地域ごとの情報", markdown: "| 日本 | 海外 |\n", period: "当期")
        ]
        let geography = ExtractedBreakdown(method: "html_table", tables: tables, facts: [])
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": 400_000, "row_kind": "segment"],
                ["label": "海外", "amount": 100_000, "row_kind": "segment"],
            ],
            "notes": "no subtotal",
        ]
        let (snapshot, _) = await GeographyBreakdownLLMNormalizer.normalize(
            geography, consolidatedSales: isSales, client: MockChat(response))
        let snap = try #require(snapshot)
        #expect(snap.needsReview == true)
        #expect(snap.warnings.contains("llm_row_sum_mismatch"))
        #expect(snap.denominatorTag == "income_statement.sales")
    }

    @Test("脚注マーカーをラベルから決定的に除去する")
    func stripsGeographyLabelFootnotes() {
        #expect(GeographyBreakdownLLMNormalizer.stripGeographyLabelFootnotes("米州（注）2") == "米州")
        #expect(GeographyBreakdownLLMNormalizer.stripGeographyLabelFootnotes("欧州他（注）3") == "欧州他")
        #expect(GeographyBreakdownLLMNormalizer.stripGeographyLabelFootnotes("アジア(注1)") == "アジア")
        #expect(GeographyBreakdownLLMNormalizer.stripGeographyLabelFootnotes("中国（注１）") == "中国")
        #expect(GeographyBreakdownLLMNormalizer.stripGeographyLabelFootnotes("その他※2") == "その他")
        #expect(GeographyBreakdownLLMNormalizer.stripGeographyLabelFootnotes("日本") == "日本")
        #expect(GeographyBreakdownLLMNormalizer.stripGeographyLabelFootnotes("米州（注記）") == "米州（注記）")
    }

    @Test("LLM が脚注付きラベルを返しても正規化後は除去され audit.notes に残る")
    func normalizeStripsFootnotesAndRecordsAudit() async throws {
        let sales = 873_190.0 * Financial.millionYen
        let tables = [
            BreakdownTable(
                heading: "地域ごとの情報",
                markdown: "| 日本 | アメリカ | 米州（注）2 | 欧州他（注）3 | 合計 |\n",
                period: "当期")
        ]
        let geography = ExtractedBreakdown(method: "html_table", tables: tables, facts: [])
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": 395_472, "row_kind": "segment"],
                ["label": "アメリカ", "amount": 92_074, "row_kind": "segment"],
                ["label": "米州（注）2", "amount": 8_482, "row_kind": "segment"],
                ["label": "欧州他（注）3", "amount": 110_982, "row_kind": "segment"],
                ["label": "中国", "amount": 170_772, "row_kind": "segment"],
                ["label": "アジア", "amount": 95_409, "row_kind": "segment"],
                ["label": "合計", "amount": 873_191, "row_kind": "subtotal"],
            ],
            "notes": "帝人型。米州は米国を除く",
        ]
        let (snapshot, audit) = await GeographyBreakdownLLMNormalizer.normalize(
            geography, consolidatedSales: sales, client: MockChat(response))
        let snap = try #require(snapshot)
        let a = try #require(audit)
        let labels = snap.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["日本", "アメリカ", "米州", "欧州他", "中国", "アジア"])
        #expect(a.notes.contains("label_footnotes_stripped:"))
        #expect(a.notes.contains("米州（注）2→米州"))
        #expect(a.notes.contains("欧州他（注）3→欧州他"))
        #expect(a.notes.contains("帝人型"))
    }

    @Test("LLM が of_which と parent_label を返しても加算合計は親だけ")
    func normalizeKeepsExplicitOfWhichUnderParent() async throws {
        let sales = 59_479.0 * Financial.millionYen
        let tables = [
            BreakdownTable(
                heading: "地域ごとの情報",
                markdown: "| 日本 | アジア | うち中国 | その他 | 合計 |\n",
                period: "当期")
        ]
        let geography = ExtractedBreakdown(method: "html_table", tables: tables, facts: [])
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": 0,
            "period_column": "当期",
            "rows": [
                ["label": "日本", "amount": 38_840, "row_kind": "segment"],
                ["label": "アジア", "amount": 14_246, "row_kind": "segment"],
                ["label": "中国", "amount": 8_900, "row_kind": "of_which", "parent_label": "アジア"],
                ["label": "その他", "amount": 6_391, "row_kind": "segment"],
                ["label": "合計", "amount": 59_479, "row_kind": "subtotal"],
            ],
            "notes": "spike nest shape",
        ]
        let (snapshot, _) = await GeographyBreakdownLLMNormalizer.normalize(
            geography, consolidatedSales: sales, client: MockChat(response))
        let snap = try #require(snapshot)
        #expect(snap.needsReview == false)
        #expect(!snap.warnings.contains("llm_row_sum_mismatch"))
        let china = try #require(snap.rows.first { $0.labelRaw == "中国" })
        #expect(china.rowKind == "of_which")
        #expect(china.parentLabel == "アジア")
        let additive = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        #expect(abs(additive - sales) < 1)
        let payload = BreakdownRowPayload(
            labelRaw: china.labelRaw, label: china.labelRaw, amount: china.amount,
            profit: nil, rowKind: china.rowKind, parentLabel: china.parentLabel)
        let json = payload.jsonObject()
        #expect(json["row_kind"] as? String == "of_which")
        #expect(json["parent_label"] as? String == "アジア")
    }
}
