import Testing

@testable import BlueTicker

@Suite("WaterfallYear.businessProfitWaterfallBars")
struct BusinessProfitWaterfallBarsTests {
    @Test("前年比較に必要な値が揃っていれば前期→当期の5本バーを返す")
    func returnsFiveBarsWhenAllFieldsPresent() {
        let year = WaterfallYear(
            businessProfit: 7_744_095,
            businessProfitChange: 264_765,
            salesChangeImpact: 749_752,
            grossMarginChangeImpact: 282_082,
            sgaChangeImpact: -767_069
        )

        let bars = year.businessProfitWaterfallBars()

        #expect(bars?.count == 5)
        #expect(bars?.map(\.label) == ["前期事業利益", "売上要因", "利益率変化", "販管費", "当期事業利益"])
        #expect(bars?.first?.value == 7_479_330)  // 7,744,095 - 264,765
        #expect(bars?.last?.value == 7_744_095)
    }

    @Test("バーの累計は前期事業利益から当期事業利益へ整合する")
    func barsReconcileFromPriorToCurrentProfit() {
        let year = WaterfallYear(
            businessProfit: 7_744_095,
            businessProfitChange: 264_765,
            salesChangeImpact: 749_752,
            grossMarginChangeImpact: 282_082,
            sgaChangeImpact: -767_069
        )

        let bars = year.businessProfitWaterfallBars() ?? []
        let deltaSum = bars.filter { $0.kind == .delta }.reduce(0) { $0 + $1.value }
        let prior = bars.first(where: { $0.kind == .start })?.value ?? 0

        #expect(prior + deltaSum == year.businessProfit)
    }

    @Test("前年差の入力フィールドが欠けている年度(最古期など)はnilを返す")
    func returnsNilWhenPriorComparisonFieldsAreMissing() {
        let year = WaterfallYear(businessProfit: 3_380_079)

        #expect(year.businessProfitWaterfallBars() == nil)
    }

    @Test("負のデルタバー(販管費)を含めても各バーの描画区間が階段状に連続する")
    func negativeDeltaBarConnectsToNeighboringBars() {
        // 実データ(トヨタ2025年03月期)。販管費は負のデルタで、正面画面(FrontFaceView)の
        // yEnd = cumulativeStart + value の計算と食い違うと1本分ずれて描画される回帰を防ぐ。
        let year = WaterfallYear(
            businessProfit: 7_744_095,
            businessProfitChange: 264_765,
            salesChangeImpact: 749_752,
            grossMarginChangeImpact: 282_082,
            sgaChangeImpact: -767_069
        )
        let bars = year.businessProfitWaterfallBars() ?? []
        let deltaBars = bars.filter { $0.kind == .delta }

        // 各バーの描画区間(向きは問わないので min/max で判定)。
        func drawnInterval(_ bar: WaterfallBar) -> (low: Double, high: Double) {
            let end = bar.cumulativeStart + bar.value
            return (min(bar.cumulativeStart, end), max(bar.cumulativeStart, end))
        }

        let intervals = deltaBars.map(drawnInterval)
        #expect(intervals[0] == (7_479_330, 8_229_082))  // 売上要因
        #expect(intervals[1] == (8_229_082, 8_511_164))  // 利益率変化
        #expect(intervals[2] == (7_744_095, 8_511_164))  // 販管費(負)

        // 隣接バーは high または low で接続し、階段が途切れない。
        for (a, b) in zip(intervals, intervals.dropFirst()) {
            #expect(a.high == b.high || a.high == b.low)
        }

        // 最後のバーの下端は当期事業利益と一致する(負のデルタで着地する)。
        #expect(intervals.last?.low == year.businessProfit)
    }
}

@Suite("WaterfallResponse.series")
struct WaterfallSeriesTests {
    private func makeResponse() -> WaterfallResponse {
        WaterfallResponse(
            code: "7203", name: "トヨタ自動車株式会社", sector: "輸送用機器", market: "上場",
            years: [
                WaterfallYear(financialPeriod: "2025年03月期", businessProfit: 7_744_095),
                WaterfallYear(financialPeriod: "2024年03月期", businessProfit: 7_479_330),
                WaterfallYear(financialPeriod: "2023年03月期", businessProfit: 4_437_747),
            ])
    }

    @Test("APIの新しい順を側面推移用に古い順へ並べ替える")
    func reordersNewestFirstResponseToOldestFirst() {
        let series = makeResponse().series(for: .businessProfit)

        #expect(series.map(\.period) == ["2023年03月期", "2024年03月期", "2025年03月期"])
        #expect(series.map(\.value) == [4_437_747, 7_479_330, 7_744_095])
    }

    @Test("項目ごとに対応するフィールドを取り出す")
    func selectsFieldMatchingRequestedMetric() {
        let response = WaterfallResponse(
            code: "7203", name: "", sector: "", market: "",
            years: [
                WaterfallYear(
                    salesChangeImpact: 749_752, grossMarginChangeImpact: 282_082,
                    sgaChangeImpact: -767_069)
            ])

        #expect(response.series(for: .salesImpact).first?.value == 749_752)
        #expect(response.series(for: .marginImpact).first?.value == 282_082)
        #expect(response.series(for: .sgaImpact).first?.value == -767_069)
    }
}
