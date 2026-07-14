import Foundation
import Testing

@testable import BlueTickerCore

/// HalfFinancialsResponse（半期公開契約）の仕様: [HalfPeriod] との round-trip・全キー JSON・trim。
/// remote CLI はこの 1 型でサーバー応答をデコードし、既存レンダラへ [HalfPeriod] で渡す。
@Suite struct HalfFinancialsContractTests {
    private func period(_ fyEnd: String, _ half: String, sales: Double, roe: Double) -> HalfPeriod {
        var raw = RawData()
        raw.sales = sales
        raw.salesLabel = "売上高"
        var calc = CalculatedData()
        calc.roe = roe
        calc.docID = "S100\(half)"
        let entry = YearEntry(fyEnd: fyEnd, financialPeriod: "\(fyEnd) (\(half))", rawData: raw, calculatedData: calc)
        let yy = String(format: "%02d", (extractYearMonth(fyEnd).0 ?? 0) % 100)
        return HalfPeriod(label: "\(yy)\(half)", half: half, fyEnd: fyEnd, yearEntry: entry)
    }

    @Test func roundTripsLabelHalfAndMetrics() {
        let periods = [
            period("2024-03-31", "H1", sales: 100, roe: 5),
            period("2024-03-31", "H2", sales: 120, roe: 6),
        ]
        let resp = HalfFinancialsResponse(code: "7203", name: "トヨタ", periods: periods)
        let restored = resp.toPeriods()

        #expect(restored.map(\.label) == ["24H1", "24H2"])
        #expect(restored.map(\.half) == ["H1", "H2"])
        #expect(restored[0].fyEnd == "2024-03-31")
        #expect(restored[0].yearEntry.rawData.sales == 100)
        #expect(restored[1].yearEntry.calculatedData.roe == 6)
        #expect(restored[0].yearEntry.calculatedData.docID == "S100H1")
    }

    @Test func jsonObjectCarriesSchemaVersionAndPeriods() throws {
        let resp = HalfFinancialsResponse(
            code: "7203", name: "トヨタ",
            periods: [period("2024-03-31", "H1", sales: 100, roe: 5)])
        let json = resp.jsonObject()
        #expect(json["schema_version"] as? Int == Api.halfFinancialsSchemaVersion)
        #expect(json["code"] as? String == "7203")
        let periods = try #require(json["periods"] as? [[String: Any]])
        #expect(periods.count == 1)
        #expect(periods[0]["label"] as? String == "24H1")
        // year は flatten 形（全キー存在・欠落は null）。
        let year = try #require(periods[0]["year"] as? [String: Any])
        #expect(year["sales"] as? Double == 100)
        #expect(year["net_profit"] is NSNull)
    }

    /// Codable で JSON ↔ 型を往復してもメトリクスが保たれる（remote デコード経路の検証）。
    @Test func decodesFromServerJSON() throws {
        let resp = HalfFinancialsResponse(
            code: "7203", name: "トヨタ",
            periods: [period("2024-03-31", "H2", sales: 120, roe: 6)])
        let data = try JSONSerialization.data(withJSONObject: resp.jsonObject())
        let decoded = try JSONDecoder().decode(HalfFinancialsResponse.self, from: data)
        let p = try #require(decoded.toPeriods().first)
        #expect(p.label == "24H2")
        #expect(p.yearEntry.rawData.sales == 120)
    }

    @Test func cacheVersionNumberParsesHalfVN() {
        #expect(companyHalfFinancialsCacheVersionNumber("half-v1") == 1)
        #expect(companyHalfFinancialsCacheVersionNumber("half-v2") == 2)
        #expect(companyHalfFinancialsCacheVersionNumber("half-v10") == 10)
        #expect(companyHalfFinancialsCacheVersionNumber("half-v") == nil)
        #expect(companyHalfFinancialsCacheVersionNumber("0.0.0") == nil)
        #expect(companyHalfFinancialsCacheVersionNumber("half-v2b") == nil)
    }

    @Test func isServableUsesNumericFloorNotLexicographicOrder() throws {
        #expect(companyHalfFinancialsMinServableVersion == 1)
        #expect(isServableCompanyHalfFinancialsCacheVersion("half-v1") == true)
        #expect(isServableCompanyHalfFinancialsCacheVersion("half-v2") == true)
        #expect(isServableCompanyHalfFinancialsCacheVersion("half-v10") == true)
        #expect(isServableCompanyHalfFinancialsCacheVersion("0.0.0") == false)
        // 現行版番号は床以上（不変条件）。
        let current = try #require(
            companyHalfFinancialsCacheVersionNumber(companyHalfFinancialsCacheVersion))
        #expect(current >= companyHalfFinancialsMinServableVersion)
    }

    // MARK: - Summarize / Analyze の境界（docs/feature-tiers.md）

    @Test func summaryJsonObjectExcludesAnalysisOnlyKeys() throws {
        var p = period("2024-03-31", "H1", sales: 100, roe: 5)
        p.yearEntry.calculatedData.businessProfitChange = 3
        p.yearEntry.calculatedData.workingCapital = 50
        let resp = HalfFinancialsResponse(code: "7203", name: "トヨタ", periods: [p])

        let periods = try #require(resp.summaryJsonObject()["periods"] as? [[String: Any]])
        let year = try #require(periods[0]["year"] as? [String: Any])
        for key in FinancialsYear.analysisOnlyKeys {
            #expect(year.keys.contains(key) == false, "\(key) は Analyze 専用のため Summarize に含めない")
        }
        #expect(year["roe"] as? Double == 5)
    }

    /// ④⑤の前期は「隣接期」ではなく「同じ半期の直近過去期」でなければならない。
    /// H1・H2 が交互に並ぶ列で、隣接インデックスの差分を取ると誤った値になる退行を検出する。
    @Test func analysisJsonObjectUsesSameHalfPriorNotAdjacentPeriod() throws {
        func withNetCash(_ p: HalfPeriod, _ value: Double) -> HalfPeriod {
            var copy = p
            copy.yearEntry.calculatedData.netCash = value
            return copy
        }
        let periods = [
            withNetCash(period("2023-03-31", "H1", sales: 80, roe: 4), 10),
            withNetCash(period("2023-03-31", "H2", sales: 90, roe: 4), 20),
            withNetCash(period("2024-03-31", "H1", sales: 100, roe: 5), 30),
            withNetCash(period("2024-03-31", "H2", sales: 120, roe: 6), 40),
        ]
        let resp = HalfFinancialsResponse(code: "7203", name: "トヨタ", periods: periods)
        let json = try #require(resp.analysisJsonObject()["periods"] as? [[String: Any]])
        #expect(json.count == 4)

        // 先頭の H1/H2（同じ半期の前期が無い）は null。
        #expect((json[0]["year"] as? [String: Any])?["net_cash_change"] is NSNull)
        #expect((json[1]["year"] as? [String: Any])?["net_cash_change"] is NSNull)

        // 2024H1 の前期は 2023H1（隣接の 2023H2 ではない）: 30 - 10 = 20。
        #expect((json[2]["year"] as? [String: Any])?["net_cash_change"] as? Double == 20)
        // 2024H2 の前期は 2023H2（隣接の 2024H1 ではない）: 40 - 20 = 20。
        // 隣接誤りなら 40 - 30 = 10 になってしまう。
        #expect((json[3]["year"] as? [String: Any])?["net_cash_change"] as? Double == 20)
    }

    /// trimmed は halfYearTrimPeriods に委譲する（完結 H1+H2 ペアを新しい順に n 件）。
    @Test func trimmedKeepsLatestNFiscalYears() {
        let periods = [
            period("2023-03-31", "H1", sales: 80, roe: 4),
            period("2023-03-31", "H2", sales: 90, roe: 4),
            period("2024-03-31", "H1", sales: 100, roe: 5),
            period("2024-03-31", "H2", sales: 120, roe: 6),
        ]
        let resp = HalfFinancialsResponse(code: "7203", name: "トヨタ", periods: periods)
        let trimmed = resp.trimmed(toYears: 1).toPeriods()
        #expect(Set(trimmed.compactMap(\.fyEnd)) == ["2024-03-31"])
        #expect(trimmed.count == 2)  // 最新年の H1+H2
    }
}
