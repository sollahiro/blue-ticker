import Testing
import Foundation
@testable import BlueTickerCore

// Python の tests/test_half_year_record_count.py に対応する Swift 版テスト。

@Suite struct HalfYearTests {

    // MARK: - Helpers

    private func period(_ fyEnd: String, half: String?) -> HalfPeriod {
        let label = String(fyEnd.prefix(4)) + (half ?? "FY")
        let entry = YearEntry(fyEnd: fyEnd, financialPeriod: label, rawData: RawData(), calculatedData: CalculatedData())
        return HalfPeriod(label: label, half: half, fyEnd: fyEnd, yearEntry: entry)
    }

    // MARK: - halfYearTrimPeriods

    @Test func trimKeepsNCompletePairsPlusCurrentH1() {
        // 6 完結ペア + 当期 H1 → years=3 で 3 ペア + 当期 H1
        let periods = [
            period("2022-03-31", half: "H1"), period("2022-03-31", half: "H2"),
            period("2023-03-31", half: "H1"), period("2023-03-31", half: "H2"),
            period("2024-03-31", half: "H1"), period("2024-03-31", half: "H2"),
            period("2025-03-31", half: "H1"), period("2025-03-31", half: "H2"),
            period("2026-03-31", half: "H1"),  // 当期 H1（FY 未公開）
        ]
        let result = halfYearTrimPeriods(periods, to: 3)
        let fyEnds = result.map { $0.fyEnd! }

        // 完結ペアは最新 3 年（2023, 2024, 2025）
        #expect(fyEnds.filter { $0 == "2023-03-31" }.count == 2)
        #expect(fyEnds.filter { $0 == "2024-03-31" }.count == 2)
        #expect(fyEnds.filter { $0 == "2025-03-31" }.count == 2)
        #expect(!fyEnds.contains("2022-03-31"))

        // 当期 H1 が末尾に追加される
        #expect(result.last?.fyEnd == "2026-03-31")
        #expect(result.last?.half == "H1")
        #expect(result.count == 7)
    }

    @Test func trimNoCurrentH1() {
        // 当期 H1 なし → 完結ペアのみ
        let periods = [
            period("2023-03-31", half: "H1"), period("2023-03-31", half: "H2"),
            period("2024-03-31", half: "H1"), period("2024-03-31", half: "H2"),
            period("2025-03-31", half: "H1"), period("2025-03-31", half: "H2"),
        ]
        let result = halfYearTrimPeriods(periods, to: 3)
        #expect(result.count == 6)
        #expect(result.allSatisfy { $0.half == "H1" || $0.half == "H2" })
    }

    @Test func trimCurrentH1DoesNotDisplaceCompletePair() {
        // 当期 H1 がペア数を圧迫しない
        let periods = [
            period("2023-03-31", half: "H1"), period("2023-03-31", half: "H2"),
            period("2024-03-31", half: "H1"), period("2024-03-31", half: "H2"),
            period("2025-03-31", half: "H1"), period("2025-03-31", half: "H2"),
            period("2026-03-31", half: "H1"),
        ]
        let result = halfYearTrimPeriods(periods, to: 3)
        let h2Ends = Set(result.filter { $0.half == "H2" }.compactMap { $0.fyEnd })

        // H2 が 3 年分あること
        #expect(h2Ends == ["2023-03-31", "2024-03-31", "2025-03-31"])

        // 当期 H1 が末尾に追加
        #expect(result.last?.fyEnd == "2026-03-31")
        #expect(result.last?.half == "H1")
        // 合計: 3 ペア × 2 + 当期 H1 = 7
        #expect(result.count == 7)
    }

    @Test func trimExcludesFYOnlyYears() {
        // FY-only（half=nil）は除外される
        let periods = [
            period("2023-03-31", half: "H1"), period("2023-03-31", half: "H2"),
            period("2024-03-31", half: "H1"), period("2024-03-31", half: "H2"),
            period("2025-03-31", half: nil),   // FY-only
        ]
        let result = halfYearTrimPeriods(periods, to: 3)
        // 完結ペア 2 件のみ（FY-only は含まれない）
        #expect(result.count == 4)
        #expect(result.allSatisfy { $0.half == "H1" || $0.half == "H2" })
    }

    @Test func trimFewerThanRequestedYears() {
        // 完結ペアが要求より少ない場合は取得できた分だけ返す
        let periods = [
            period("2024-03-31", half: "H1"), period("2024-03-31", half: "H2"),
        ]
        let result = halfYearTrimPeriods(periods, to: 3)
        #expect(result.count == 2)
    }
}
