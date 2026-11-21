import Foundation
import Testing

@testable import SegmentBreakdown

/// 実データ（2026-11 の本番 API）から、判定に要る行だけ抜いた固定入力。
@Suite struct SegmentBreakdownTests {
    // ニチレイ 2871: FY2026 に 加工食品・水産・畜産 → 食品（reorg）。
    private let nichireiJSON = """
        {"code":"2871","metric":"external_sales","years":[
         {"fiscal_year":2026,"fy_end":"2026-03-31","line_cut":true,"segments":[
          {"label":"食品","segment_key":"F","value":426409000000,"prior":{"decision":"reorg"}},
          {"label":"低温物流","segment_key":"L","value":281985000000,"prior":{"decision":"connect","segment_key":"L"}},
          {"label":"不動産","segment_key":"R","value":3342000000,"prior":{"decision":"connect","segment_key":"R"}}]},
         {"fiscal_year":2025,"fy_end":"2025-03-31","line_cut":false,"segments":[
          {"label":"加工食品","segment_key":"P","value":311342000000,"prior":{"decision":"connect","segment_key":"P"}},
          {"label":"水産","segment_key":"M","value":58472000000,"prior":{"decision":"connect","segment_key":"M"}},
          {"label":"畜産","segment_key":"A","value":63836000000,"prior":{"decision":"connect","segment_key":"A"}},
          {"label":"低温物流","segment_key":"L","value":259551000000,"prior":{"decision":"connect","segment_key":"L"}},
          {"label":"不動産","segment_key":"R","value":3275000000,"prior":{"decision":"connect","segment_key":"R"}}]},
         {"fiscal_year":2024,"fy_end":"2024-03-31","line_cut":false,"segments":[
          {"label":"加工食品","segment_key":"P","value":290613000000},
          {"label":"水産","segment_key":"M","value":61577000000},
          {"label":"畜産","segment_key":"A","value":78790000000},
          {"label":"低温物流","segment_key":"L","value":240275000000},
          {"label":"不動産","segment_key":"R","value":2910000000}]}]}
        """

    private func columns(_ json: String) throws -> [BreakdownColumnInput] {
        let response = try JSONDecoder().decode(SegmentWaterfallResponse.self, from: Data(json.utf8))
        return BreakdownBuilder.segmentColumns(response) { "FY\($0.fiscalYear ?? 0)" }
    }

    @Test func decodesAndOrdersColumnsOldestFirst() throws {
        let cols = try columns(nichireiJSON)
        #expect(cols.map(\.label) == ["FY2024", "FY2025", "FY2026"])
        #expect(cols[0].items.allSatisfy { $0.link == .none })
        #expect(cols[1].items.first { $0.key == "L" }?.link == .connect("L"))
        #expect(cols[2].items.first { $0.key == "F" }?.link == .reorg)
    }

    @Test func reorgIsMarkedAndNotConnectedAndPriorRowsAreNotCalledEnded() throws {
        let layout = StackedLayout.make(columns: try columns(nichireiJSON))
        let last = layout.bars[2]
        #expect(last.first { $0.key == "F" }?.mark == .reorg)
        // 組替が出た年は、消えた行を「終了」と断定しない。
        let before = layout.bars[1]
        #expect(["P", "M", "A"].allSatisfy { key in before.first { $0.key == key }?.mark == .reorg })
        #expect(before.first { $0.key == "L" }?.mark == BreakdownMark.none)
        // つなぎは L / R だけ（FY24→25 で 5 本、FY25→26 で 2 本）。食品へは出さない。
        #expect(layout.ribbons.filter { $0.fromColumn == 1 }.map(\.key).sorted() == ["L", "R"])
        #expect(layout.ribbons.filter { $0.fromColumn == 0 }.count == 5)
    }

    @Test func stackingFitsUnderHeadroomAndStartsAtBottom() throws {
        let layout = StackedLayout.make(columns: try columns(nichireiJSON))
        let tops = layout.bars.map { column in column.map(\.y).min() ?? 1 }
        #expect(tops.min()! >= layout.headroom - 1e-9)
        for column in layout.bars {
            let bottom = column.map { $0.y + $0.height }.max()!
            #expect(abs(bottom - 1) < 1e-9)
            // 積み上げは隙間なし。
            let sorted = column.sorted { $0.y < $1.y }
            for pair in zip(sorted, sorted.dropFirst()) {
                #expect(abs(pair.0.y + pair.0.height - pair.1.y) < 1e-9)
            }
        }
        // 最大の合計の列が上端いっぱい。
        #expect(abs(tops.min()! - layout.headroom) < 1e-9)
    }

    @Test func endedSeriesIsMarkedAndKeepsItsColorAboveOthers() throws {
        // ソニー: FY2026 で「金融」が消える（reorg の行は無い）。
        let json = """
            {"years":[
             {"fiscal_year":2026,"segments":[
              {"label":"ゲーム","segment_key":"G","value":4570053,"prior":{"decision":"connect","segment_key":"G"}},
              {"label":"音楽","segment_key":"M","value":2090534,"prior":{"decision":"connect","segment_key":"M"}}]},
             {"fiscal_year":2025,"segments":[
              {"label":"ゲーム","segment_key":"G","value":4543571},
              {"label":"音楽","segment_key":"M","value":1820263},
              {"label":"金融","segment_key":"F","value":922147}]}]}
            """
        let layout = StackedLayout.make(columns: try columns(json))
        #expect(layout.bars[0].first { $0.key == "F" }?.mark == .ended)
        #expect(layout.bars[0].first { $0.key == "G" }?.mark == BreakdownMark.none)
        #expect(layout.series.map(\.label) == ["ゲーム", "音楽", "金融"])
        #expect(layout.ribbons.count == 2)
    }

    @Test func renamedSeriesKeepsColorAndRibbon() throws {
        let json = """
            {"years":[
             {"fiscal_year":2026,"segments":[
              {"label":"AIコンピューティング","segment_key":"B","value":100,"prior":{"decision":"rename","segment_key":"A"}}]},
             {"fiscal_year":2025,"segments":[{"label":"アーム","segment_key":"A","value":80}]}]}
            """
        let layout = StackedLayout.make(columns: try columns(json))
        #expect(layout.series.count == 1)
        #expect(layout.bars[0][0].colorIndex == layout.bars[1][0].colorIndex)
        #expect(layout.ribbons.count == 1)
        #expect(layout.bars[1][0].mark == BreakdownMark.none)
    }

    @Test func summaryRowsComputeYoYAndMarginOnlyWhereConnected() throws {
        let cols = try columns(nichireiJSON)
        let layout = StackedLayout.make(columns: cols)
        let rows = BreakdownSummary.segmentRows(
            columns: cols, layout: layout, profitByKey: ["F": 19_852_000_000, "L": 18_583_000_000])
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        #expect(rows.first?.key == "F")  // 売上の大きい順
        #expect(byKey["F"]?.yoy == nil)  // 組替は前年比を出さない
        #expect(byKey["F"]?.mark == .reorg)
        let l = byKey["L"]!
        #expect(abs(l.yoy! - (281_985.0 / 259_551.0 - 1)) < 1e-9)
        #expect(abs(l.margin! - 18_583.0 / 281_985.0) < 1e-9)
        #expect(byKey["R"]?.profit == nil)
        #expect(byKey["R"]?.margin == nil)
    }

    @Test func geographyConnectsOnlySameLabelsAndSharesSumToOne() throws {
        // トヨタ: FY2025 は 5 区分、FY2026 は 日本/米国/その他 の 3 区分（区分が変わる）。
        func body(_ rows: [(String, Double)]) -> BreakdownResponse {
            BreakdownResponse(
                docId: nil,
                breakdown: .init(
                    rows: rows.map {
                        BreakdownResponse.Row(
                            label: $0.0, rowKind: "segment", segmentKey: nil, segmentBasis: nil, amount: $0.1,
                            externalSales: nil, profit: nil)
                    } + [
                        BreakdownResponse.Row(
                            label: "計", rowKind: "subtotal", segmentKey: nil, segmentBasis: nil, amount: 999,
                            externalSales: nil, profit: nil)
                    ], segmentStructure: nil))
        }
        let y25 = BreakdownBuilder.geographyColumn(
            label: "FY2025", previousLabels: nil,
            response: body([("日本", 10_719_120), ("北米", 18_930_253), ("欧州", 6_110_052), ("アジア", 7_903_360), ("その他", 4_373_919)]))
        let y26 = BreakdownBuilder.geographyColumn(
            label: "FY2026", previousLabels: Set(y25.items.map(\.label)),
            response: body([("日本", 10_985_614), ("米国", 18_493_969), ("その他", 21_205_369)]))
        #expect(y25.items.count == 5)  // 小計は含めない
        #expect(y26.items.first { $0.key == "日本" }?.link == .connect("日本"))
        #expect(y26.items.first { $0.key == "米国" }?.link == BreakdownLink.none)
        let cols = [y25, y26]
        let layout = StackedLayout.make(columns: cols)
        let rows = BreakdownSummary.shareRows(columns: cols, layout: layout)
        #expect(abs(rows.map(\.share).reduce(0, +) - 1) < 1e-9)
        #expect(rows.first { $0.key == "日本" }?.deltaPoints != nil)
        #expect(rows.first { $0.key == "米国" }?.deltaPoints == nil)
        #expect(rows.first { $0.key == "その他" }?.deltaPoints != nil)
    }

    @Test func emptyAndSingleColumnAreSafe() {
        #expect(StackedLayout.make(columns: []).bars.isEmpty)
        let single = StackedLayout.make(columns: [
            BreakdownColumnInput(label: "FY2026", items: [BreakdownItemInput(key: "a", label: "A", value: 1, link: .none)])
        ])
        #expect(single.bars.count == 1)
        #expect(single.ribbons.isEmpty)
        #expect(single.bars[0][0].mark == BreakdownMark.none)
    }
}
