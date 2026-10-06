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

    @Test("うちラベルは比率が低くても内数として落とす")
    func dropsUchiLabeledChildEvenWhenRatioIsLow() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 38_840, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "アジア", amount: 14_246, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "うち中国", amount: 8_900, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "その他", amount: 6_391, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "合計", amount: 59_479, share: nil, profit: nil, rowKind: "subtotal"),
        ]
        let filtered = GeographyBreakdownLLMNormalizer.dropOfWhichSubsetSegments(rows)
        let labels = filtered.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["日本", "アジア", "その他"])
    }

    @Test("北米のうち米国（高比率）だけ落とし、並列の中国はそのまま残す")
    func dropsOnlyHighRatioAmericasSubset() {
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
        // 米国は北米の内数（比率≈99%）。中国はその他の並列地域なので残す（プロンプト側でうち除外）。
        #expect(labels == ["日本", "北米", "その他", "中国"])
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
        let filtered = GeographyBreakdownLLMNormalizer.dropOfWhichSubsetSegments(rows)
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
        let filtered = GeographyBreakdownLLMNormalizer.dropOfWhichSubsetSegments(rows)
        #expect(filtered.map(\.labelRaw) == ["日本", "北米", "欧州"])
    }

    @Test("細目があるとき親の海外行を落とす")
    func dropsCoarseOverseasWhenAsiaExists() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 1_000, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "アジア", amount: 2_000, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "北米", amount: 1_500, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "その他", amount: 500, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "海外", amount: 4_000, share: nil, profit: nil, rowKind: "segment"),
        ]
        let filtered = GeographyBreakdownLLMNormalizer.dropCoarseOverseasWhenFinerRegionsExist(rows)
        #expect(filtered.map(\.labelRaw) == ["日本", "アジア", "北米", "その他"])
    }

    @Test("日本/海外の2区分では海外を残す")
    func keepsOverseasWhenItIsTheOnlyForeignBucket() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 1_000, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "海外", amount: 800, share: nil, profit: nil, rowKind: "segment"),
        ]
        let filtered = GeographyBreakdownLLMNormalizer.dropCoarseOverseasWhenFinerRegionsExist(rows)
        #expect(filtered.map(\.labelRaw) == ["日本", "海外"])
    }

    private static func normalizeHTML(
        _ html: String, sales: Double, heading: String = "地域ごとの情報"
    ) async -> BreakdownSnapshot? {
        var tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: heading)
        if !tables.isEmpty { tables[0].period = "当期" }
        let (snapshot, _) = await GeographyBreakdownLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: tables, facts: []),
            consolidatedSales: sales,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S-geo-unit")
        return snapshot
    }

    @Test("うち二重計上でも分母一致なら needs_review にならない")
    func normalizeDropsOfWhichBeforeDenominatorCheck() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>254,181</td></tr>
              <tr><td>北米</td><td>37,897</td></tr>
              <tr><td>米国</td><td>37,220</td></tr>
              <tr><td>欧州</td><td>38,201</td></tr>
              <tr><td>その他</td><td>21,084</td></tr>
              <tr><td>合計</td><td>351,363</td></tr>
            </table>
            """
        let snap = try #require(
            await Self.normalizeHTML(html, sales: 351_363 * Financial.millionYen))
        #expect(snap.needsReview == false)
        #expect(!snap.warnings.contains("llm_row_sum_mismatch"))
        let labels = snap.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["日本", "北米", "欧州", "その他"])
    }

    @Test("地域注記合計が IS 売上と乖離しても表内小計で分母を揃える（クレディセゾン型）")
    func alignsDenominatorToGeographyTableSubtotal() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>484,060</td></tr>
              <tr><td>インド</td><td>56,056</td></tr>
              <tr><td>その他</td><td>6,154</td></tr>
              <tr><td>合計</td><td>546,271</td></tr>
            </table>
            """
        let snap = try #require(
            await Self.normalizeHTML(html, sales: 472_770 * Financial.millionYen))
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
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>400,000</td></tr>
              <tr><td>海外</td><td>100,000</td></tr>
            </table>
            """
        let snap = try #require(
            await Self.normalizeHTML(html, sales: 1_000_000 * Financial.millionYen))
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

    @Test("表の脚注付きラベルは正規化後に除去され audit.notes に残る")
    func normalizeStripsFootnotesAndRecordsAudit() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>395,472</td></tr>
              <tr><td>アメリカ</td><td>92,074</td></tr>
              <tr><td>米州（注）2</td><td>8,482</td></tr>
              <tr><td>欧州他（注）3</td><td>110,982</td></tr>
              <tr><td>中国</td><td>170,772</td></tr>
              <tr><td>アジア</td><td>95,409</td></tr>
              <tr><td>合計</td><td>873,191</td></tr>
            </table>
            """
        var tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "地域ごとの情報")
        if !tables.isEmpty { tables[0].period = "当期" }
        let (snapshot, audit) = await GeographyBreakdownLLMNormalizer.normalize(
            ExtractedBreakdown(method: "html_table", tables: tables, facts: []),
            consolidatedSales: 873_190 * Financial.millionYen,
            decider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2026-03-31",
            docID: "S-teijin")
        let snap = try #require(snapshot)
        let a = try #require(audit)
        let labels = snap.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        #expect(labels == ["日本", "アメリカ", "米州", "欧州他", "中国", "アジア"])
        #expect(a.jev != nil)
        #expect(!snap.needsReview)
    }

    /// 表の海外計と構成行が食い違うときは fail-closed。セルの桁コピー誤りは
    /// 出ないが、開示側の不一致は needs_review のまま。
    @Test("海外計と構成行が食い違うときは subtotal_mismatch で needs_review")
    func subtotalMismatchOnCopiedDigitMarksNeedsReview() async throws {
        let html = """
            <p>当連結会計年度</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td></tr>
              <tr><td>日本</td><td>29,122,646</td></tr>
              <tr><td>アジア</td><td>13,442,307</td></tr>
              <tr><td>北米</td><td>10,127,597</td></tr>
              <tr><td>欧州</td><td>2,143,634</td></tr>
              <tr><td>その他の地域</td><td>3,760,490</td></tr>
              <tr><td>海外合計</td><td>26,089,588</td></tr>
              <tr><td>連結売上高</td><td>55,212,234</td></tr>
            </table>
            """
        let sales = 55_212_234 * Financial.millionYen
        let snap = try #require(await Self.normalizeHTML(html, sales: sales))
        let segmentSum = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        #expect(segmentSum / sales > 0.90 && segmentSum / sales < 1.10)
        #expect(snap.needsReview == true)
        #expect(snap.warnings.contains(GeographyBreakdownLLMNormalizer.subtotalMismatchWarning))
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceGeographyLLM,
                needsReview: snap.needsReview,
                warnings: snap.warnings) == false)
        let other = try #require(snap.rows.first { $0.labelRaw.contains("その他") })
        #expect(other.amount == 3_760_490 * Financial.millionYen)
    }

    @Test("海外計と構成行が一致するときは subtotal_mismatch を立てない")
    func matchingOverseasSubtotalDoesNotFlag() {
        let rows: [BreakdownRow] = [
            .init(labelRaw: "日本", amount: 29_122_646, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "アジア", amount: 13_442_307, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "北米", amount: 10_127_597, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "欧州", amount: 2_143_634, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "その他の地域", amount: 376_049, share: nil, profit: nil, rowKind: "segment"),
            .init(labelRaw: "海外合計", amount: 26_089_588, share: nil, profit: nil, rowKind: "subtotal"),
            .init(labelRaw: "連結売上高", amount: 55_212_234, share: nil, profit: nil, rowKind: "subtotal"),
        ]
        #expect(GeographyBreakdownLLMNormalizer.extractedSubtotalsMismatch(rows) == false)
        var wrong = rows
        wrong[4] = .init(
            labelRaw: "その他の地域", amount: 3_760_490, share: nil, profit: nil, rowKind: "segment")
        #expect(GeographyBreakdownLLMNormalizer.extractedSubtotalsMismatch(wrong) == true)
    }
}
