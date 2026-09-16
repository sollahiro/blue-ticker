import Foundation
import Testing

@testable import FundMath

@Suite struct FundMathTests {
    @Test func incompleteQuantityOrPriceIsWatch() {
        #expect(FundMath.isHolding(quantity: 100, acquisitionPriceYen: 1_200))
        #expect(FundMath.isHolding(quantity: 100, acquisitionPriceYen: nil) == false)
        #expect(FundMath.isHolding(quantity: nil, acquisitionPriceYen: 1_200) == false)
        #expect(FundMath.isHolding(quantity: nil, acquisitionPriceYen: nil) == false)
        #expect(FundMath.isHolding(quantity: .nan, acquisitionPriceYen: 1_200) == false)
        #expect(FundMath.isHolding(quantity: 100, acquisitionPriceYen: .infinity) == false)
    }

    @Test func lotAverageIsQuantityWeightedAndIgnoresWatch() {
        let positions = [
            FundMath.Position(id: "a", code: "2802", quantity: 100, acquisitionPriceYen: 1_000),
            FundMath.Position(id: "b", code: "2802", quantity: 50, acquisitionPriceYen: 1_200),
            FundMath.Position(id: "w", code: "2802", quantity: 10, acquisitionPriceYen: nil),
        ]
        let lot = FundMath.lotAverage(positions: positions)
        #expect(lot.quantity == 150)
        #expect(lot.averageAcquisitionYen == 160_000.0 / 150.0)
        let empty = FundMath.lotAverage(positions: [
            FundMath.Position(id: "w", code: "1", quantity: 1, acquisitionPriceYen: nil)
        ])
        #expect(empty.quantity == nil)
        #expect(empty.averageAcquisitionYen == nil)
    }

    @Test func restYearKeysAreEpsAndBpsYenPerShare() throws {
        let json = Data(
            #"""
            {"fy_end":"2025-03-31","eps":69.77,"bps":751.01,"sales":1000}
            """#.utf8)
        let year = try JSONDecoder().decode(SummaryYearSlice.self, from: json)
        #expect(year.fyEnd == "2025-03-31")
        #expect(year.eps == 69.77)
        #expect(year.bps == 751.01)
    }

    @Test func latestYearPicksNewestFyEndNotNotesFallback() {
        let years = [
            SampleYear(fyEnd: "2024-03-31", eps: 10, bps: 100),
            SampleYear(fyEnd: "2025-03-31", eps: 20, bps: 200),
            SampleYear(fyEnd: "2023-03-31", eps: 30, bps: 300),
        ]
        let latest = FundMath.latestYear(years, fyEnd: \.fyEnd)
        #expect(latest?.fyEnd == "2025-03-31")
        #expect(latest?.eps == 20)
        #expect(latest?.bps == 200)
        #expect(FundMath.latestYear([SampleYear(fyEnd: nil, eps: 1, bps: 1)], fyEnd: \.fyEnd) == nil)
    }

    @Test func rowLookThroughUsesEpsTimesQtyAndBpsTimesQty() {
        let holding = FundMath.Position(
            id: "a", code: "2802", quantity: 100, acquisitionPriceYen: 1_500)
        let share = FundMath.PerShare(fyEnd: "2025-03-31", epsYen: 69.77, bpsYen: 751.01)
        let row = FundMath.rowMetrics(position: holding, perShare: share)
        #expect(row.isHolding)
        let profit = 69.77 * 100
        let book = 751.01 * 100
        #expect(row.lookThroughProfitYen == profit)
        #expect(row.lookThroughBookYen == book)
        #expect(row.investedCapitalYen == 150_000)
    }

    @Test func missingPerShareIsNilAndWatchRowsHaveNoMath() {
        let holding = FundMath.Position(
            id: "a", code: "7203", quantity: 10, acquisitionPriceYen: 2_000)
        let missing = FundMath.rowMetrics(
            position: holding, perShare: FundMath.PerShare(fyEnd: "2025-03-31"))
        #expect(missing.isHolding)
        #expect(missing.lookThroughProfitYen == nil)
        #expect(missing.lookThroughBookYen == nil)
        #expect(missing.investedCapitalYen == 20_000)

        let watch = FundMath.Position(id: "b", code: "7203", quantity: 10, acquisitionPriceYen: nil)
        let watchRow = FundMath.rowMetrics(
            position: watch,
            perShare: FundMath.PerShare(epsYen: 100, bpsYen: 1_000)
        )
        #expect(watchRow.isHolding == false)
        #expect(watchRow.lookThroughProfitYen == nil)
        #expect(watchRow.lookThroughBookYen == nil)
        #expect(watchRow.investedCapitalYen == nil)
    }

    @Test func totalsAggregateByTickerAndExcludeMissingEpsFromProfitAndROE() {
        let positions = [
            FundMath.Position(id: "a1", code: "2802", quantity: 100, acquisitionPriceYen: 1_000),
            FundMath.Position(id: "a2", code: "2802", quantity: 50, acquisitionPriceYen: 1_200),
            FundMath.Position(id: "b", code: "7203", quantity: 10, acquisitionPriceYen: 2_000),
            FundMath.Position(id: "c", code: "9984", quantity: 5, acquisitionPriceYen: nil),
        ]
        let perShare = [
            "2802": FundMath.PerShare(fyEnd: "2025-03-31", epsYen: 10, bpsYen: 100),
            "7203": FundMath.PerShare(fyEnd: "2025-03-31", epsYen: nil, bpsYen: 500),
        ]
        let snap = FundMath.snapshot(positions: positions, perShareByCode: perShare)

        #expect(snap.tickerTotals.count == 2)
        #expect(snap.tickerTotals[0].code == "2802")
        #expect(snap.tickerTotals[0].quantity == 150)
        #expect(snap.tickerTotals[0].lookThroughProfitYen == 1_500)
        #expect(snap.tickerTotals[0].lookThroughBookYen == 15_000)
        #expect(snap.tickerTotals[0].investedCapitalYen == 160_000)

        #expect(snap.tickerTotals[1].code == "7203")
        #expect(snap.tickerTotals[1].lookThroughProfitYen == nil)
        #expect(snap.tickerTotals[1].lookThroughBookYen == 5_000)
        #expect(snap.tickerTotals[1].investedCapitalYen == 20_000)

        #expect(snap.lookThroughProfitYen == 1_500)
        #expect(snap.lookThroughBookYen == 20_000)
        #expect(snap.investedCapitalYen == 180_000)
        let expectedROE = (1_500.0 / 160_000.0) * 100
        #expect(snap.fundROEPercent == expectedROE)
    }

    @Test func fundROEUsesInvestedCapitalNotBookAndIgnoresWatch() {
        let positions = [
            FundMath.Position(id: "h", code: "4901", quantity: 20, acquisitionPriceYen: 2_500),
            FundMath.Position(id: "w", code: "4901", quantity: 1_000, acquisitionPriceYen: nil),
        ]
        let snap = FundMath.snapshot(
            positions: positions,
            perShareByCode: ["4901": FundMath.PerShare(epsYen: 216.67, bpsYen: 2_779.5)]
        )
        let profit = 216.67 * 20.0
        let expectedROE = (profit / 50_000.0) * 100.0
        #expect(snap.lookThroughProfitYen == profit)
        #expect(snap.investedCapitalYen == 50_000)
        #expect(snap.fundROEPercent == expectedROE)
        #expect(snap.tickerTotals.count == 1)
    }

    @Test func emptyHoldingsYieldNilTotals() {
        let snap = FundMath.snapshot(
            positions: [FundMath.Position(id: "w", code: "1", quantity: 1, acquisitionPriceYen: nil)],
            perShareByCode: ["1": FundMath.PerShare(epsYen: 10, bpsYen: 10)]
        )
        #expect(snap.lookThroughProfitYen == nil)
        #expect(snap.lookThroughBookYen == nil)
        #expect(snap.investedCapitalYen == nil)
        #expect(snap.fundROEPercent == nil)
        #expect(snap.tickerTotals.isEmpty)
    }

    @Test func zeroInvestedWithEpsDoesNotInventROE() {
        let snap = FundMath.snapshot(
            positions: [FundMath.Position(id: "z", code: "1", quantity: 0, acquisitionPriceYen: 0)],
            perShareByCode: ["1": FundMath.PerShare(epsYen: 10, bpsYen: 10)]
        )
        #expect(snap.lookThroughProfitYen == 0)
        #expect(snap.investedCapitalYen == 0)
        #expect(snap.fundROEPercent == nil)
    }
}

private struct SummaryYearSlice: Decodable {
    var fyEnd: String?
    var eps: Double?
    var bps: Double?

    enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case eps
        case bps
    }
}

private struct SampleYear: Equatable {
    var fyEnd: String?
    var eps: Double?
    var bps: Double?
}
