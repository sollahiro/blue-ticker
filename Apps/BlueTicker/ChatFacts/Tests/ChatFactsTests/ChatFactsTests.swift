import Testing

@testable import ChatFacts

@Suite struct ChatFactsTests {
    /// 億円表記（テスト用）。アプリは `Format.autoYen` を渡す。
    private static let oku: @Sendable (Double) -> String = { value in
        "\(Int((value / 100_000_000).rounded()))億円"
    }

    @Test func latestTwoPeriodsWithChange() throws {
        let facts = try #require(ChatFacts(
            years: [
                ChatFactYear(fyEnd: "2026-03-31", sales: 115_000_000_000, operatingMargin: 9.0),
                ChatFactYear(fyEnd: "2025-03-31", sales: 100_000_000_000, operatingMargin: 10.2),
            ],
            amountText: Self.oku
        ))
        #expect(facts.latestPeriod == "26年3月期")
        #expect(facts.previousPeriod == "25年3月期")

        let sales = try #require(facts.rows.first { $0.metric == .sales })
        #expect(sales.previous == "1000億円")
        #expect(sales.latest == "1150億円")
        #expect(sales.change == "+15.0%")
        #expect(sales.direction == .up)

        let margin = try #require(facts.rows.first { $0.metric == .operatingMargin })
        #expect(margin.latest == "9.0%")
        #expect(margin.change == "−1.2pt")
        #expect(margin.direction == .down)
    }

    @Test func rowsSkipMetricsMissingInLatestYear() throws {
        let facts = try #require(ChatFacts(
            years: [
                ChatFactYear(fyEnd: "2025-03-31", sales: 1, roe: 5),
                ChatFactYear(fyEnd: "2026-03-31", sales: 2),
            ],
            amountText: Self.oku
        ))
        #expect(facts.rows.map(\.metric) == [.sales])
    }

    @Test func singleYearHasNoChange() throws {
        let facts = try #require(ChatFacts(
            years: [ChatFactYear(fyEnd: "2026-03-31", sales: 100_000_000_000)],
            amountText: Self.oku
        ))
        #expect(facts.previousPeriod == nil)
        #expect(facts.rows[0].previous == "—")
        #expect(facts.rows[0].change == nil)
        #expect(facts.promptLines == "売上高: 26年3月期 1000億円")
    }

    @Test func noValuesReturnsNil() {
        #expect(ChatFacts(years: [], amountText: Self.oku) == nil)
        #expect(ChatFacts(years: [ChatFactYear(fyEnd: "2026-03-31")], amountText: Self.oku) == nil)
    }

    @Test func signFlipIsTurnaroundNotPercent() throws {
        let facts = try #require(ChatFacts(
            years: [
                ChatFactYear(fyEnd: "2025-03-31", netProfit: -2_000_000_000),
                ChatFactYear(fyEnd: "2026-03-31", netProfit: 3_000_000_000),
            ],
            amountText: Self.oku
        ))
        let net = try #require(facts.rows.first)
        #expect(net.change == nil)
        #expect(net.direction == .turnedPositive)
        #expect(facts.promptLines.contains("（黒字化）"))
    }

    @Test func streakNeedsThreeConsecutivePeriods() {
        let rising = [
            ChatFactYear(fyEnd: "2023-03-31", sales: 1),
            ChatFactYear(fyEnd: "2024-03-31", sales: 2),
            ChatFactYear(fyEnd: "2025-03-31", sales: 3),
            ChatFactYear(fyEnd: "2026-03-31", sales: 4),
        ]
        #expect(ChatFacts.streak(metric: .sales, years: rising) == "3期連続で増加")
        #expect(ChatFacts.streak(metric: .sales, years: Array(rising.suffix(2))) == nil)

        let broken = [
            ChatFactYear(fyEnd: "2024-03-31", operatingMargin: 10),
            ChatFactYear(fyEnd: "2025-03-31", operatingMargin: nil),
            ChatFactYear(fyEnd: "2026-03-31", operatingMargin: 8),
        ]
        #expect(ChatFacts.streak(metric: .operatingMargin, years: broken) == nil)

        let falling = [
            ChatFactYear(fyEnd: "2024-03-31", operatingMargin: 10),
            ChatFactYear(fyEnd: "2025-03-31", operatingMargin: 9),
            ChatFactYear(fyEnd: "2026-03-31", operatingMargin: 8),
        ]
        #expect(ChatFacts.streak(metric: .operatingMargin, years: falling) == "2期連続で低下")
    }

    @Test func promptLineCarriesComputedWords() throws {
        let facts = try #require(ChatFacts(
            years: [
                ChatFactYear(fyEnd: "2024-03-31", sales: 90_000_000_000),
                ChatFactYear(fyEnd: "2025-03-31", sales: 100_000_000_000),
                ChatFactYear(fyEnd: "2026-03-31", sales: 115_000_000_000),
            ],
            amountText: Self.oku
        ))
        #expect(
            facts.promptLines
                == "売上高: 25年3月期 1000億円 → 26年3月期 1150億円（前期比 +15.0%、増加。2期連続で増加）"
        )
    }

    @Test func yearDetailForToolCall() throws {
        let facts = try #require(ChatFacts(
            years: [
                ChatFactYear(fyEnd: "2025-03-31", sales: 100_000_000_000, roe: 8.26, employees: 12345),
                ChatFactYear(fyEnd: "2026-03-31", sales: 115_000_000_000),
            ],
            amountText: Self.oku
        ))
        #expect(facts.yearDetail(fiscalYear: 2025).split(separator: "\n").first == "25年3月期: 売上高 1000億円、ROE 8.3%、従業員数 12,345人")
        #expect(facts.yearDetail(fiscalYear: 2019) == "その決算期のデータはありません。取得できる決算期: 25年3月期、26年3月期")
    }

    @Test func periodLabelFallsBackToRaw() {
        #expect(ChatFacts.periodLabel("2025-12-31") == "25年12月期")
        #expect(ChatFacts.periodLabel("bad") == "bad")
    }

    @Test func clippedCutsAtSentenceEnd() {
        let text = "一文目です。二文目はとても長い文章になっています。"
        #expect(ChatContext.clipped(text, maxCharacters: 100) == text)
        #expect(ChatContext.clipped(text, maxCharacters: 10) == "一文目です。")
        #expect(ChatContext.clipped("句点のない長い文章", maxCharacters: 5) == "句点のな…")
    }

    @Test func carriedExchangesKeepNewestWithinBudget() {
        let exchanges = [
            ChatContext.Exchange(question: "古い質問", answer: String(repeating: "あ", count: 50)),
            ChatContext.Exchange(question: "新しい質問", answer: "新しい回答"),
        ]
        let carried = ChatContext.carriedExchanges(exchanges, maxCharacters: 40)
        #expect(carried == "利用者: 新しい質問\n回答: 新しい回答")
        #expect(ChatContext.carriedExchanges([], maxCharacters: 40) == nil)
    }

    @Test func driversExplainMarginChange() throws {
        let facts = try #require(ChatFacts(
            years: [
                ChatFactYear(
                    fyEnd: "2025-03-31", sales: 100_000_000_000, employees: 1000,
                    grossProfitMargin: 35.0, sga: 25_000_000_000,
                    netMargin: 5.0, assetTurnover: 0.8, financialLeverage: 2.0
                ),
                ChatFactYear(
                    fyEnd: "2026-03-31", sales: 110_000_000_000, employees: 1000,
                    grossProfitMargin: 36.0, sga: 26_400_000_000,
                    businessProfitChange: 1_200_000_000,
                    salesChangeImpact: 3_500_000_000,
                    grossMarginChangeImpact: 1_100_000_000,
                    sgaChangeImpact: -1_400_000_000,
                    netMargin: 5.5, assetTurnover: 0.85, financialLeverage: 2.0
                ),
            ],
            amountText: Self.oku
        ))
        #expect(facts.driverLines == [
            "26年3月期の事業利益（売上総利益−販管費）の前期差: +12億円。内訳は 売上の増減による分 +35億円、粗利率（売上総利益率）の変化による分 +11億円、販管費の増減による分 -14億円（プラスは利益を押し上げ、マイナスは押し下げ）",
            "粗利率（売上総利益率）: 25年3月期 35.0% → 26年3月期 36.0%（前期差 +1.0pt、上昇）",
            "販管費率（売上高に対する販管費）: 25年3月期 25.0% → 26年3月期 24.0%（前期差 −1.0pt、低下）",
            "ROEの分解（ROE = 純利益率 × 総資産回転率 × 財務レバレッジ）: 純利益率 5.0% → 5.5%、総資産回転率 0.80倍 → 0.85倍、財務レバレッジ 2.00倍 → 2.00倍",
            "従業員1人あたり売上高: 1億円 → 1億円",
        ])
        #expect(facts.yearDetail(fiscalYear: 2026).contains("販管費の増減による分 -14億円"))
    }

    @Test func driversEmptyWithoutInputs() {
        let lines = ChatFacts.drivers(latest: ChatFactYear(fyEnd: "2026-03-31", sales: 1), previous: nil, amountText: Self.oku)
        #expect(lines.isEmpty)
    }

    @Test func twoDigitFiscalYearIsTwentyFirstCentury() throws {
        let facts = try #require(ChatFacts(
            years: [ChatFactYear(fyEnd: "2026-03-31", sales: 100_000_000_000)],
            amountText: Self.oku
        ))
        #expect(facts.yearDetail(fiscalYear: 26).hasPrefix("26年3月期: 売上高 1000億円"))
        #expect(ChatFacts.normalizedFiscalYear(2025) == 2025)
    }

    @Test func yenTextUsesOkuNotJuuoku() {
        #expect(ChatFacts.yenText(1_584_000_000_000) == "15,840億円")
        #expect(ChatFacts.yenText(-25_100_000_000) == "-251億円")
        #expect(ChatFacts.yenText(42_000_000) == "42百万円")
    }

    @Test func fullWidthDigitsBecomeAscii() {
        #expect(ChatContext.normalizedDigits("前期差で－２５１億円、＋５．１pt") == "前期差で-251億円、+5.1pt")
    }
}
