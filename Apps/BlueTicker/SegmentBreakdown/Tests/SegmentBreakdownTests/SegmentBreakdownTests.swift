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

    @Test func mergedReorgCollapsesPastSegmentsIntoOneAcrossYears() throws {
        let cols = BreakdownBuilder.collapsingReorgs(try columns(nichireiJSON))
        // FY2024・FY2025 の 加工食品・水産・畜産 は 1 本（食品）にまとまり、低温物流・不動産はそのまま。
        #expect(cols[0].items.count == 3)
        #expect(cols[1].items.count == 3)
        let merged25 = try #require(cols[1].items.first { $0.key == "merged|1|F" })
        #expect(merged25.label == "食品")
        #expect(merged25.value == 311_342_000_000 + 58_472_000_000 + 63_836_000_000)
        #expect(merged25.link == .connect("merged|0|F"))
        #expect(cols[2].items.first { $0.key == "F" }?.link == .connect("merged|1|F"))
        #expect(cols[1].items.first { $0.key == "L" }?.link == .connect("L"))

        let layout = StackedLayout.make(columns: cols)
        // 組替・終了の印は残らず、リボンは 3 系列 × 2 区間。
        #expect(layout.bars.joined().allSatisfy { $0.mark == BreakdownMark.none || $0.mark == .new })
        #expect(!layout.bars.joined().contains { $0.mark == .reorg || $0.mark == .ended })
        #expect(layout.ribbons.count == 6)
        // 最新期の前年比は合算した前年に対して出る。
        let rows = BreakdownSummary.segmentRows(columns: cols, layout: layout, profitByKey: [:])
        let food = try #require(rows.first { $0.key == "F" })
        #expect(abs((food.yoy ?? 0) - (426_409.0 / 433_650.0 - 1)) < 1e-9)
    }

    @Test func apiMergeGroupDecidesTheSourcesEvenWhenUnrelatedRowsAreUnconnected() throws {
        // 前年に、統合元ではない「終了」行 Z も残っている。API の merge が示す P・M だけをまとめる。
        let json = """
            {"years":[
             {"fiscal_year":2026,"fy_end":"2026-03-31","segments":[
              {"label":"食品","segment_key":"F","value":300,"prior":{"decision":"reorg","from":["P","M"]}}],
              "reorgs":[{"kind":"merge","from":[{"segment_key":"P","value":100},{"segment_key":"M","value":50}],"to":[{"segment_key":"F","value":300}]}]},
             {"fiscal_year":2025,"fy_end":"2025-03-31","segments":[
              {"label":"加工","segment_key":"P","value":100},{"label":"水産","segment_key":"M","value":50},
              {"label":"終了","segment_key":"Z","value":20}]}]}
            """
        let cols = BreakdownBuilder.collapsingReorgs(try columns(json))
        #expect(cols[0].items.count == 2)
        #expect(cols[0].items.contains { $0.key == "Z" })
        #expect(cols[0].items.first { $0.key == "merged|0|F" }?.value == 150)
    }

    @Test func singleSourceReorgAndSplitAreLeftAlone() throws {
        let json = """
            {"years":[
             {"fiscal_year":2026,"fy_end":"2026-03-31","segments":[
              {"label":"X","segment_key":"X","value":60,"prior":{"decision":"reorg"}},
              {"label":"Y","segment_key":"Y","value":40,"prior":{"decision":"reorg"}}]},
             {"fiscal_year":2025,"fy_end":"2025-03-31","segments":[
              {"label":"旧","segment_key":"O","value":100}]}]}
            """
        let original = try columns(json)
        #expect(BreakdownBuilder.collapsingReorgs(original) == original)
    }

    // 日本郵船 9101: FY2025 に旧 3 区分 → 新 4 区分の regroup。他の区分は connect。
    private let nykJSON = """
        {"years":[
         {"fiscal_year":2025,"fy_end":"2025-03-31","segments":[
          {"label":"航空運送事業","segment_key":"AIR","value":179,"prior":{"decision":"connect","segment_key":"AIR"}},
          {"label":"自動車事業","segment_key":"AUTO","value":532,"prior":{"decision":"reorg","from":["BULK","OTH","RE"]}},
          {"label":"ドライバルク事業","segment_key":"DRY","value":601,"prior":{"decision":"reorg","from":["BULK","OTH","RE"]}},
          {"label":"エネルギー事業","segment_key":"ENE","value":178,"prior":{"decision":"reorg","from":["BULK","OTH","RE"]}},
          {"label":"その他","segment_key":"STDOTH","value":115,"prior":{"decision":"reorg","from":["BULK","OTH","RE"]}}],
          "reorgs":[{"kind":"regroup",
           "from":[{"segment_key":"BULK","value":1231},{"segment_key":"OTH","value":113},{"segment_key":"RE","value":3}],
           "to":[{"segment_key":"AUTO","value":532},{"segment_key":"DRY","value":601},{"segment_key":"ENE","value":178},{"segment_key":"STDOTH","value":115}]}]},
         {"fiscal_year":2024,"fy_end":"2024-03-31","segments":[
          {"label":"航空運送事業","segment_key":"AIR","value":155},
          {"label":"不定期専用船事業","segment_key":"BULK","value":1231},
          {"label":"その他の事業","segment_key":"OTH","value":113},
          {"label":"不動産業","segment_key":"RE","value":3}]}]}
        """

    @Test func regroupIsStackedAdjacentAndJoinedByOneNeutralRibbon() throws {
        let cols = BreakdownBuilder.collapsingReorgs(try columns(nykJSON))
        // regroup は 1 本に集約しない（旧 3・新 4）。
        #expect(cols[0].items.count == 4)
        #expect(cols[1].groups == [BreakdownReorgGroup(
            fromKeys: ["BULK", "OTH", "RE"], toKeys: ["AUTO", "DRY", "ENE", "STDOTH"])])
        let layout = StackedLayout.make(columns: cols)

        func positions(_ column: Int, _ keys: Set<String>) -> [Int] {
            layout.bars[column].enumerated().filter { keys.contains($0.element.key) }.map(\.offset)
        }
        for (column, keys) in [(0, Set(["BULK", "OTH", "RE"])), (1, Set(["AUTO", "DRY", "ENE", "STDOTH"]))] {
            let p = positions(column, keys)
            #expect(p.count == keys.count)
            #expect(p == Array((p.first ?? 0)..<((p.first ?? 0) + p.count)))
        }
        // 組の行に「再編」「終了」の印は出ない。
        let marks = layout.bars.joined().filter { ["BULK", "OTH", "RE", "AUTO", "DRY", "ENE", "STDOTH"].contains($0.key) }.map(\.mark)
        #expect(marks.allSatisfy { $0 == .none })
        // 帯は、航空運送の系列 1 本 + 組の 1 本。
        #expect(layout.ribbons.count == 2)
        let group = try #require(layout.ribbons.first { $0.colorIndex < 0 })
        let oldBars = layout.bars[0].filter { ["BULK", "OTH", "RE"].contains($0.key) }
        #expect(abs(group.leftTop - (oldBars.map(\.y).min() ?? -1)) < 1e-9)
        #expect(abs(group.leftBottom - (oldBars.map { $0.y + $0.height }.max() ?? -1)) < 1e-9)
    }

    // 日本郵船 9101（本番 API 2026-11）: FY2025 に split（不定期専用船 → 3 区分）と merge（その他の事業＋不動産 → その他）。
    private let nykSplitJSON = """
        {"years":[
         {"fiscal_year":2026,"segments":[
          {"label":"航空運送事業","segment_key":"AIR","value":40,"prior":{"decision":"connect","segment_key":"AIR"}},
          {"label":"自動車事業","segment_key":"AUTO","value":526,"prior":{"decision":"connect","segment_key":"AUTO"}},
          {"label":"ドライバルク事業","segment_key":"DRY","value":543,"prior":{"decision":"connect","segment_key":"DRY"}},
          {"label":"エネルギー事業","segment_key":"ENE","value":236,"prior":{"decision":"connect","segment_key":"ENE"}},
          {"label":"定期船事業","segment_key":"LINER","value":175,"prior":{"decision":"connect","segment_key":"LINER"}},
          {"label":"物流事業","segment_key":"LOG","value":802,"prior":{"decision":"connect","segment_key":"LOG"}},
          {"label":"その他","segment_key":"STDOTH","value":102,"prior":{"decision":"connect","segment_key":"STDOTH"}}]},
         {"fiscal_year":2025,"line_cut":true,"segments":[
          {"label":"航空運送事業","segment_key":"AIR","value":179,"prior":{"decision":"connect","segment_key":"AIR"}},
          {"label":"自動車事業","segment_key":"AUTO","value":532,"prior":{"decision":"reorg","from":["BULK"]}},
          {"label":"ドライバルク事業","segment_key":"DRY","value":601,"prior":{"decision":"reorg","from":["BULK"]}},
          {"label":"エネルギー事業","segment_key":"ENE","value":178,"prior":{"decision":"reorg","from":["BULK"]}},
          {"label":"定期船事業","segment_key":"LINER","value":174,"prior":{"decision":"connect","segment_key":"LINER"}},
          {"label":"物流事業","segment_key":"LOG","value":809,"prior":{"decision":"connect","segment_key":"LOG"}},
          {"label":"その他","segment_key":"STDOTH","value":115,"prior":{"decision":"reorg","from":["OTH","RE"]}}],
          "reorgs":[
           {"kind":"split","from":[{"segment_key":"BULK","value":1231}],
            "to":[{"segment_key":"AUTO","value":532},{"segment_key":"DRY","value":601},{"segment_key":"ENE","value":178}]},
           {"kind":"merge","from":[{"segment_key":"OTH","value":113},{"segment_key":"RE","value":3}],
            "to":[{"segment_key":"STDOTH","value":115}]}]},
         {"fiscal_year":2024,"segments":[
          {"label":"航空運送事業","segment_key":"AIR","value":155},
          {"label":"不定期専用船事業","segment_key":"BULK","value":1231},
          {"label":"定期船事業","segment_key":"LINER","value":187},
          {"label":"物流事業","segment_key":"LOG","value":699},
          {"label":"その他の事業","segment_key":"OTH","value":113},
          {"label":"不動産業","segment_key":"RE","value":3}]}]}
        """

    @Test func stackOrderKeepsFamiliesInTheSameSlotAcrossYearsAndMarksReorgYear() throws {
        let cols = BreakdownBuilder.collapsingReorgs(try columns(nykSplitJSON))
        #expect(cols.map(\.reorged) == [false, true, false])
        let layout = StackedLayout.make(columns: cols)
        #expect(layout.columnReorged == [false, true, false])
        // 下から: 物流 → 不定期専用船の血筋（旧年は 1 本、新年は 3 本隣り合わせ）→ 定期船 → その他 → 航空運送。
        func order(_ column: Int) -> [String] {
            layout.bars[column].sorted { $0.y > $1.y }.map(\.key)
        }
        #expect(order(0) == ["LOG", "BULK", "LINER", "merged|0|STDOTH", "AIR"])
        #expect(order(1) == ["LOG", "DRY", "AUTO", "ENE", "LINER", "STDOTH", "AIR"])
        #expect(order(2) == ["LOG", "DRY", "AUTO", "ENE", "LINER", "STDOTH", "AIR"])
    }

    @Test func geographyConnectsAmericasAliasAcrossYears() throws {
        // 三井住友トラスト 8309: 24/03 米州、25/03 米国、26/03 米州。
        func column(_ label: String, _ america: String, previous: Set<String>?) throws -> BreakdownColumnInput {
            let json = """
                {"breakdown":{"rows":[
                 {"label":"日本","row_kind":"segment","amount":100},
                 {"label":"\(america)","row_kind":"segment","amount":40},
                 {"label":"欧州","row_kind":"segment","amount":30}]}}
                """
            let response = try JSONDecoder().decode(BreakdownResponse.self, from: Data(json.utf8))
            return BreakdownBuilder.geographyColumn(label: label, previousLabels: previous, response: response)
        }
        let y24 = try column("FY2024", "米州", previous: nil)
        let y25 = try column("FY2025", "米国", previous: Set(y24.items.map(\.label)))
        let y26 = try column("FY2026", "米州", previous: Set(y25.items.map(\.label)))
        #expect(y25.items.first { $0.label == "米国" }?.link == .connect("米州"))
        #expect(y26.items.first { $0.label == "米州" }?.link == .connect("米国"))
        let layout = StackedLayout.make(columns: [y24, y25, y26])
        #expect(layout.series.count == 3)
        #expect(layout.bars.joined().allSatisfy { $0.mark == BreakdownMark.none })
    }

    @Test func geographyWaterfallConnectsWithinComparableGroupAndMarksBoundary() throws {
        // 8309 型: 25/03「米国」は塊の段2で americas。26/03 と 24/03 は「米州」。
        let json = """
            {"years":[
             {"fy_end":"2026-03-31","comparable_group":0,"line_cut":false,
              "regions":[{"label":"日本","region":"japan","value":100},{"label":"米州","region":"americas","value":40}],
              "comparable_regions":[{"region":"japan","value":100},{"region":"americas","value":40}]},
             {"fy_end":"2025-03-31","comparable_group":0,"line_cut":false,
              "regions":[{"label":"日本","region":"japan","value":90},{"label":"米国","region":"united_states","value":41}],
              "comparable_regions":[{"region":"japan","value":90},{"region":"americas","value":41}]},
             {"fy_end":"2024-03-31","comparable_group":1,"line_cut":true,
              "regions":[{"label":"日本","region":"japan","value":80},{"label":"米州","region":"americas","value":42}],
              "comparable_regions":[{"region":"japan","value":80},{"region":"americas","value":42}]}]}
            """
        let response = try JSONDecoder().decode(GeographyWaterfallResponse.self, from: Data(json.utf8))
        let cols = BreakdownBuilder.geographyColumns(response) { $0.fyEnd ?? "" }
        #expect(cols.map(\.label) == ["2024-03-31", "2025-03-31", "2026-03-31"])
        // 塊が変わる 25/03 だけ「再編」。つなぎも切れる。
        #expect(cols.map(\.reorged) == [false, true, false])
        #expect(cols[1].items.allSatisfy { $0.link == .none })
        #expect(cols[2].items.first { $0.key == "americas" }?.link == .connect("americas"))
        // 表示名: 開示のままの名前、無ければコードの表示名（25/03 は米国→米州）。
        #expect(cols[1].items.first { $0.key == "americas" }?.label == "米州")
        let layout = StackedLayout.make(columns: cols)
        #expect(layout.series.count == 2)
    }

    // 進和 7607: 米国→米州（FY2024）、東南アジア→アジア・パシフィック（FY2025）はどちらも replace。
    @Test func reorgSourcesTakeTheColorOfTheirLatestDescendants() throws {
        let json = """
            {"years":[
             {"fiscal_year":2025,"line_cut":true,"segments":[
              {"label":"米州","segment_key":"AM","value":86,"prior":{"decision":"connect","segment_key":"AM"}},
              {"label":"アジア・パシフィック","segment_key":"AP","value":57,"prior":{"decision":"reorg","from":["SEA"]}},
              {"label":"日本","segment_key":"JP","value":670,"prior":{"decision":"connect","segment_key":"JP"}}],
              "reorgs":[{"kind":"replace","from":[{"segment_key":"SEA","value":46}],"to":[{"segment_key":"AP","value":57}]}]},
             {"fiscal_year":2024,"line_cut":true,"segments":[
              {"label":"米州","segment_key":"AM","value":110,"prior":{"decision":"reorg","from":["US"]}},
              {"label":"日本","segment_key":"JP","value":562,"prior":{"decision":"connect","segment_key":"JP"}},
              {"label":"東南アジア","segment_key":"SEA","value":46,"prior":{"decision":"connect","segment_key":"SEA"}}],
              "reorgs":[{"kind":"replace","from":[{"segment_key":"US","value":72}],"to":[{"segment_key":"AM","value":110}]}]},
             {"fiscal_year":2023,"segments":[
              {"label":"米国","segment_key":"US","value":72},
              {"label":"日本","segment_key":"JP","value":508},
              {"label":"東南アジア","segment_key":"SEA","value":54}]}]}
            """
        let layout = StackedLayout.make(columns: BreakdownBuilder.collapsingReorgs(try columns(json)))
        func color(_ column: Int, _ key: String) -> Int? { layout.bars[column].first { $0.key == key }?.colorIndex }
        #expect(color(0, "US") == color(1, "AM"))
        #expect(color(0, "US") == color(2, "AM"))
        #expect(color(1, "SEA") == color(2, "AP"))
        #expect(color(0, "SEA") == color(2, "AP"))
        #expect(color(0, "JP") == color(2, "JP"))
        // 色は日本・米州・アジアの 3 つだけ。
        #expect(Set(layout.bars.joined().map(\.colorIndex)).count == 3)
    }

    // メディア工房 3815: 旧 4 区分 → 新 2 区分の regroup。大きい順に対応づけ、余りは最後の新区分の色。
    @Test func regroupSourcesAreColoredByRankAndExtrasFollowTheLastDescendant() throws {
        let json = """
            {"years":[
             {"fiscal_year":2024,"line_cut":true,"segments":[
              {"label":"エンタメ","segment_key":"ENT","value":110,"prior":{"decision":"reorg","from":["DC","O2O","SNS"]}},
              {"label":"占い","segment_key":"FT","value":1900,"prior":{"decision":"reorg","from":["DC","O2O","SNS"]}}],
              "reorgs":[{"kind":"regroup","from":[{"segment_key":"DC","value":1265},{"segment_key":"O2O","value":802},{"segment_key":"SNS","value":5}],
               "to":[{"segment_key":"ENT","value":110},{"segment_key":"FT","value":1900}]}]},
             {"fiscal_year":2023,"segments":[
              {"label":"デジタル","segment_key":"DC","value":1265},
              {"label":"One to One","segment_key":"O2O","value":802},
              {"label":"SNS","segment_key":"SNS","value":5}]}]}
            """
        let layout = StackedLayout.make(columns: try columns(json))
        func color(_ column: Int, _ key: String) -> Int? { layout.bars[column].first { $0.key == key }?.colorIndex }
        #expect(color(0, "DC") == color(1, "FT"))
        #expect(color(0, "O2O") == color(1, "ENT"))
        #expect(color(0, "SNS") == color(1, "ENT"))
    }

    // さいか屋 8254: 過去 2 年は報告セグメントが無い（連結合計だけ）。単一セグメントの棒にし、前年とはつながない。
    @Test func yearsWithoutSegmentsBecomeASingleSegmentBar() throws {
        let json = """
            {"years":[
             {"fiscal_year":2026,"segments":[
              {"label":"百貨店","segment_key":"D","value":4583,"prior":{"decision":"connect","segment_key":"D"}},
              {"label":"不動産","segment_key":"R","value":9,"prior":{"decision":"connect","segment_key":"R"}}]},
             {"fiscal_year":2025,"line_cut":true,"segments":[
              {"label":"百貨店","segment_key":"D","value":4624,"prior":{"decision":"break"}},
              {"label":"不動産","segment_key":"R","value":9,"prior":{"decision":"break"}}]},
             {"fiscal_year":2024,"consolidated":{"value":4950},"segments":[]},
             {"fiscal_year":2023,"consolidated":{"value":5205},"segments":[]}]}
            """
        let cols = try columns(json)
        #expect(cols.map { $0.items.count } == [1, 1, 2, 2])
        #expect(cols[0].items[0].key == singleSegmentKey)
        let layout = StackedLayout.make(columns: cols)
        #expect(layout.bars[0][0].mark == .single)
        #expect(layout.bars[0][0].colorIndex < 0)
        #expect(layout.bars[1][0].mark == .single)
        // 単一→複数の年は、つながない。「再編」を出す。
        #expect(layout.bars[2].allSatisfy { $0.colorIndex >= 0 })
        #expect(layout.columnReorged == [false, false, true, false])
        #expect(layout.ribbons.allSatisfy { $0.fromColumn == 2 })
    }
}
