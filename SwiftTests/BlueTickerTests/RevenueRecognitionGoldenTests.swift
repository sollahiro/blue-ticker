// SPEC_ORACLE: 収益分解の <p> 爆発・2段候補・Jev 列スタブ後の最終行。
// 注記の抜粋のみ（有報全体は使わない）。ネットワークなし。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RevenueRecognitionGoldenTests {
    private static let cat7413 = [
        "油脂・乳製品", "調味料", "嗜好品・飲料", "乾物・雑穀", "副食品", "栄養補助食品", "その他",
    ]

    @Test func explodeStackedParagraphsIntoRows() throws {
        let html = """
            <table>
              <tr><td></td><td>金額</td></tr>
              <tr>
                <td><p>油脂・乳製品</p><p>調味料</p></td>
                <td><p>410,483</p><p>1,592,960</p></td>
              </tr>
            </table>
            """
        let table = try XBRLTestSupport.parseFirstTable(html)
        let grid = BreakdownExtractor.expandTable(table)
        #expect(grid.contains { $0.contains("油脂・乳製品") && $0.contains("410,483") })
        #expect(grid.contains { $0.contains("調味料") && $0.contains("1,592,960") })
        #expect(!grid.contains { $0.contains("油脂・乳製品調味料") })
    }

    @Test func geographyTableWithoutStackedParagraphsIsUnchanged() throws {
        let html = "<table><tr><td>日本</td><td>100</td></tr><tr><td>アジア</td><td>50</td></tr></table>"
        let table = try XBRLTestSupport.parseFirstTable(html)
        #expect(BreakdownExtractor.expandTable(table) == [["日本", "100"], ["アジア", "50"]])
    }

    @Test func ownMediaAdIsCategoryNotPeriodHeading() {
        #expect(RevenueRecognitionCandidates.isPeriodHeadingLabel("自社メディア広告") == false)
        #expect(RevenueRecognitionCandidates.isPeriodHeadingLabel("当連結会計年度") == true)
    }

    @Test func ykkp7413CandidatesAndRows() async throws {
        try await assert7413(
            docID: "S100YKKP", fyEnd: "2026-03-31",
            amounts: [410_483, 1_592_960, 1_080_049, 259_850, 1_233_827, 118_499, 55_945],
            total: 4_751_616)
    }

    @Test func r40s7413CandidatesAndRows() async throws {
        try await assert7413(
            docID: "S100R40S", fyEnd: "2023-03-31",
            amounts: [474_540, 1_622_478, 1_006_172, 274_442, 1_241_889, 140_098, 86_508],
            total: 4_846_130)
    }

    @Test func trf17413CandidatesAndRows() async throws {
        try await assert7413(
            docID: "S100TRF1", fyEnd: "2024-03-31",
            amounts: [446_517, 1_714_175, 1_035_189, 257_642, 1_248_549, 125_000, 56_497],
            total: 4_883_573)
    }

    @Test func w5b97413CandidatesAndRows() async throws {
        try await assert7413(
            docID: "S100W5B9", fyEnd: "2025-03-31",
            amounts: [461_229, 1_748_028, 1_023_946, 256_954, 1_279_501, 124_156, 56_814],
            total: 4_950_632)
    }

    @Test func w6gr5237CandidatesAndRows() async throws {
        let cats = ["押出成形セメント製品関連", "スレート関連", "耐火被覆等", "その他"]
        let amounts = [17_202_907, 940_087, 1_085_092, 2_686_327]
        let html = priorAndCurrent(
            currentCaption: "当連結会計年度（自 2024年4月1日 至 2025年3月31日）",
            unit: "千円",
            currentBody: stackedRow(labels: cats, amounts: amounts)
                + totalRow("顧客との契約から生じる収益", 21_914_415)
                + totalRow("外部顧客への売上高", 21_954_062)
        )
        let snapshot = try await run(html: html, docID: "S100W6GR", fyEnd: "2025-03-31", pick: "t1_c1")
        let parsed = try parsedCurrent(html)
        #expect(parsed.items.map(\.label) == cats)
        #expect(parsed.groups.isEmpty)
        #expect(Set(parsed.totals.map(\.label)).contains("外部顧客への売上高"))
        try assertFlatRows(snapshot, groups: cats, amounts: amounts, unit: 1_000)
        #expect(snapshot.denominator == 21_954_062 * 1_000)
    }

    @Test func yscr272ACandidatesAndRows() async throws {
        let cats = ["工事表示板・標識", "仮設防護柵", "保安灯・警告灯", "防災用品・環境整備用品", "その他商品", "サインメディア"]
        let amounts = [1_698_931, 1_027_294, 454_956, 2_743_990, 7_040_477, 8_960_225]
        let current = """
            <p>当連結会計年度（自 2025年5月1日 至 2026年4月30日）</p>
            <p>（単位：千円）</p>
            <table>
            \(stackedRow(labels: cats, amounts: amounts))
            \(totalRow("顧客との契約から生じる収益", 21_925_876))
            </table>
            """
        let snapshot = try await run(
            html: priorThen(currentHTML: current), docID: "S100YSCR", fyEnd: "2026-04-30",
            pick: "t1_c1")
        let parsed = try parsedCurrent(priorThen(currentHTML: current))
        #expect(parsed.items.map(\.label) == cats)
        #expect(parsed.groups.isEmpty)
        try assertFlatRows(snapshot, groups: cats, amounts: amounts, unit: 1_000)
        #expect(snapshot.denominator == 21_925_876 * 1_000)
    }

    @Test func z42g7532NestedCandidatesAndRows() async throws {
        let html = priorThen(currentHTML: panPacificCurrentTable())
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let current = try #require(parsed.first { $0.tableIndex == 1 } ?? parsed.last)
        #expect(current.groups.map(\.group) == [
            "（ディスカウントストア）", "（ＵＮＹ事業）", "（海外）", "（その他）",
        ])
        #expect(current.items.count == 15)
        #expect(Set(current.totals.map(\.label)).isSuperset(of: [
            "顧客との契約から生じる収益", "その他の収益", "外部顧客への売上高",
        ]))
        let snapshot = try await run(html: html, docID: "S100Z42G", fyEnd: "2026-06-30", pick: "t1_c4")
        let expected: [(String, String, Int)] = [
            ("（ディスカウントストア）", "家電製品", 93_241),
            ("（ディスカウントストア）", "日用雑貨品", 428_832),
            ("（ディスカウントストア）", "食品", 654_814),
            ("（ディスカウントストア）", "時計・ファッション用品", 200_876),
            ("（ディスカウントストア）", "スポーツ・レジャー用品", 105_243),
            ("（ディスカウントストア）", "その他", 22_322),
            ("（ＵＮＹ事業）", "家電製品", 7_544),
            ("（ＵＮＹ事業）", "日用雑貨品", 45_439),
            ("（ＵＮＹ事業）", "食品", 336_289),
            ("（ＵＮＹ事業）", "時計・ファッション用品", 50_719),
            ("（ＵＮＹ事業）", "スポーツ・レジャー用品", 9_583),
            ("（ＵＮＹ事業）", "その他", 202),
            ("（海外）", "北米", 275_028),
            ("（海外）", "アジア", 98_997),
            ("（その他）", "外販事業", 36_578),
        ]
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.count == 15)
        #expect(segments.reduce(0) { $0 + $1.amount } == 2_365_707 * Financial.millionYen)
        for (index, row) in expected.enumerated() {
            #expect(segments[index].categoryGroup == row.0)
            #expect(segments[index].category == row.1)
            #expect(segments[index].amount == Double(row.2) * Financial.millionYen)
            #expect(
                segments[index].label
                    == RevenueRecognitionCandidates.displayLabel(
                        categoryGroup: row.0, category: row.1))
        }
        #expect(snapshot.denominator == 2_445_260 * Financial.millionYen)
        #expect(snapshot.needsReview == false)
    }

    @Test func dedicatedSingleSegmentDoesNotSkipRevenueRecognitionTables() async throws {
        let tagText = "当社グループは単一セグメントであるため、記載を省略しております。"
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment contextRef="CurrentYearDuration">\(tagText)</jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment>
            """)
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = ExtractedBreakdown(
                method: "html_table",
                tables: [
                    BreakdownTable(
                        heading: BreakdownExtractor.revenueRecognitionHeading,
                        markdown: "| 油脂・乳製品 | 100 |\n| 顧客との契約から生じる収益 | 100 |",
                        period: "当期")
                ],
                facts: [])
            let context = BltServerContext(
                apiKey: "test", cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()),
                businessChatClient: UnavailableChatClient(),
                geographyChatClient: UnavailableChatClient())
            let result = await context.segmentsAfterNoteDecision(
                axis: .business, docID: "S100TRF1", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 100, labelsByTag: [:])
            #expect(result.extracted?.tables.isEmpty == false)
            #expect(result.outcome.omissionReason == nil)
        }
    }

    @Test func belowConfidenceThresholdSetsNeedsReview() async throws {
        let html = priorAndCurrent(
            currentCaption: "当連結会計年度（自 2025年4月1日 至 2026年3月31日）",
            unit: "千円",
            currentBody: stackedRow(labels: Self.cat7413, amounts: [1, 1, 1, 1, 1, 1, 1])
                + totalRow("顧客との契約から生じる収益", 7))
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t1_c1", confidence: 0.5)
        let (snapshot, audit) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 7_000, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100LOW")
        let row = try #require(snapshot)
        #expect(row.needsReview)
        #expect(row.warnings.contains(RevenueRecognitionColumnNormalizer.warningLowConfidence))
        #expect(audit?.jev?.calls.first?.probability == 0.5)
        #expect(RevenueRecognitionColumnNormalizer.confidenceThreshold == 0.6)
        #expect(RevenueRecognitionColumnNormalizer.confidenceThreshold < 0.75)
    }

    @Test func noneOfTheseReturnsNoSnapshot() async throws {
        let html = priorAndCurrent(
            currentCaption: "当連結会計年度（自 2025年4月1日 至 2026年3月31日）",
            unit: "千円",
            currentBody: stackedRow(labels: Self.cat7413, amounts: [1, 1, 1, 1, 1, 1, 1])
                + totalRow("顧客との契約から生じる収益", 7))
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(
            selected: RevenueRecognitionColumnNormalizer.noneOfThese, confidence: 0.95)
        let (snapshot, audit) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 7_000, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100NONE")
        #expect(snapshot == nil)
        #expect(audit?.jev?.calls.first?.selected == RevenueRecognitionColumnNormalizer.noneOfThese)
    }

    @Test func uchiItemsAreDisplayOnlyAndSkipSumCheck() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>金額</td></tr>
              <tr><td>海外</td><td>1,000</td></tr>
              <tr><td>うち中国</td><td>300</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>1,000</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100UCHI", fyEnd: "2026-03-31", pick: "t0_c1")
        #expect(snapshot.needsReview == false)
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows[0].categoryGroup == "海外")
        #expect(snapshot.rows[0].category == nil)
        #expect(snapshot.rows[0].amount == 1_000 * Financial.millionYen)
        #expect(snapshot.rows[1].category == "うち中国")
        #expect(snapshot.rows[1].label == "うち中国（海外）")
        #expect(snapshot.rows[1].amount == 300 * Financial.millionYen)
    }

    @Test func shortSumWithoutUchiSetsNeedsReviewAndDoesNotMarkPartial() {
        let table = RevenueRecognitionCandidates.ParsedTable(
            tableIndex: 0,
            grid: [
                ["", "金額"],
                ["日本", "1,000"],
                ["関東", "300"],
                ["関西", "400"],
                ["顧客との契約から生じる収益", "1,000"],
            ],
            headerRowCount: 1,
            columnHeaders: [1: "金額"],
            precedingCaption: "当連結会計年度",
            unitCaption: "百万円",
            items: [
                .init(group: "日本", label: "関東", row: 2, isPartial: false),
                .init(group: "日本", label: "関西", row: 3, isPartial: false),
            ],
            totals: [.init(label: "顧客との契約から生じる収益", row: 4)],
            groups: [.init(group: "日本", row: 1)]
        )
        let (rows, needsReview) = RevenueRecognitionCandidates.buildRows(table: table, column: 1)
        #expect(needsReview)
        #expect(rows.allSatisfy { !$0.isPartial })
        #expect(Set(rows.map(\.category)) == ["関東", "関西"])
        #expect(!RevenueRecognitionCandidates.sumMatches(700, subtotal: 1_000, itemCount: 2))
        #expect(RevenueRecognitionCandidates.sumMatches(998, subtotal: 1_000, itemCount: 2))
    }

    @Test func stripNoteMarkerFromTotalAndDisplayLabelDropsGroupBrackets() {
        #expect(RevenueRecognitionCandidates.stripNoteMarker("その他の収益（注）１") == "その他の収益")
        #expect(
            RevenueRecognitionCandidates.displayLabel(categoryGroup: "（海外）", category: "北米")
                == "北米（海外）")
        #expect(
            BreakdownRowPayload.displayLabel(categoryGroup: "（ディスカウントストア）", category: "家電製品")
                == "家電製品（ディスカウントストア）")
    }

    @Test func payloadOmitsStoredLabelAndJsonObjectRebuildsIt() throws {
        let row = BreakdownRowPayload(
            labelRaw: "家電製品", label: "ignored", amount: 1, profit: nil, rowKind: "segment",
            categoryGroup: "（ディスカウントストア）", category: "家電製品")
        let encoded = try JSONEncoder().encode(row)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["label"] == nil)
        #expect(object["category_group"] as? String == "（ディスカウントストア）")
        #expect(object["category"] as? String == "家電製品")
        let decoded = try JSONDecoder().decode(BreakdownRowPayload.self, from: encoded)
        #expect(decoded.label == "家電製品（ディスカウントストア）")
        let json = row.jsonObject()
        #expect(json["label"] as? String == "家電製品（ディスカウントストア）")
        #expect(json["category_group"] as? String == "（ディスカウントストア）")
        #expect(json["category"] as? String == "家電製品")
    }

    // MARK: - helpers

    private func assert7413(
        docID: String, fyEnd: String, amounts: [Int], total: Int
    ) async throws {
        let html = priorAndCurrent(
            currentCaption: "当連結会計年度（自 \(fyEnd.replacingOccurrences(of: "-", with: "年").dropLast(3) )）",
            unit: "千円",
            currentBody: stackedRow(labels: Self.cat7413, amounts: amounts)
                + totalRow("顧客との契約から生じる収益", total)
        )
        let snapshot = try await run(html: html, docID: docID, fyEnd: fyEnd, pick: "t1_c1")
        let parsed = try parsedCurrent(html)
        #expect(parsed.items.map(\.label) == Self.cat7413)
        #expect(parsed.groups.isEmpty)
        #expect(parsed.totals.map(\.label).contains("顧客との契約から生じる収益"))
        try assertFlatRows(snapshot, groups: Self.cat7413, amounts: amounts, unit: 1_000)
        #expect(snapshot.denominator == Double(total) * 1_000)
        #expect(snapshot.needsReview == false)
    }

    private func parsedCurrent(_ html: String) throws -> RevenueRecognitionCandidates.ParsedTable {
        let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係")
        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        return try #require(parsed.first { $0.tableIndex == 1 } ?? parsed.last)
    }

    private func run(
        html: String, docID: String, fyEnd: String, pick: String
    ) async throws -> BreakdownSnapshot {
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(selected: pick, confidence: 0.9)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: nil, decider: decider, fiscalYearEnd: fyEnd, docID: docID)
        return try #require(snapshot)
    }

    private func assertFlatRows(
        _ snapshot: BreakdownSnapshot, groups: [String], amounts: [Int], unit: Double
    ) throws {
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.count == groups.count)
        for (index, group) in groups.enumerated() {
            #expect(segments[index].categoryGroup == group)
            #expect(segments[index].category == nil)
            #expect(segments[index].label == group)
            #expect(segments[index].amount == Double(amounts[index]) * unit)
        }
    }

    private func stackedRow(labels: [String], amounts: [Int]) -> String {
        let left = labels.map { "<p>\($0)</p>" }.joined()
        let right = amounts.map { "<p>\(format($0))</p>" }.joined()
        return "<tr><td>\(left)</td><td>\(right)</td></tr>"
    }

    private func totalRow(_ label: String, _ amount: Int) -> String {
        "<tr><td>\(label)</td><td>\(format(amount))</td></tr>"
    }

    private func format(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func priorAndCurrent(
        currentCaption: String, unit: String, currentBody: String, extraCurrentPrefix: String = ""
    ) -> String {
        """
        <p>前連結会計年度（自 2023年4月1日 至 2024年3月31日）</p>
        <p>（単位：\(unit)）</p>
        <table>
          <tr><td></td><td>金額</td></tr>
          <tr><td>前期行</td><td>1</td></tr>
          <tr><td>顧客との契約から生じる収益</td><td>1</td></tr>
        </table>
        <p>\(currentCaption)</p>
        <p>（単位：\(unit)）</p>
        \(extraCurrentPrefix)
        <table>
          <tr><td></td><td>金額</td></tr>
          \(currentBody)
        </table>
        """
    }

    private func priorThen(currentHTML: String) -> String {
        """
        <p>前連結会計年度（自 2023年4月1日 至 2024年3月31日）</p>
        <p>（単位：千円）</p>
        <table>
          <tr><td></td><td>金額</td></tr>
          <tr><td>前期行</td><td>1</td></tr>
          <tr><td>顧客との契約から生じる収益</td><td>1</td></tr>
        </table>
        \(currentHTML)
        """
    }

    private func panPacificCurrentTable() -> String {
        let ds = [
            ("家電製品", 93_241), ("日用雑貨品", 428_832), ("食品", 654_814),
            ("時計・ファッション用品", 200_876), ("スポーツ・レジャー用品", 105_243), ("その他", 22_322),
        ]
        let uny = [
            ("家電製品", 7_544), ("日用雑貨品", 45_439), ("食品", 336_289),
            ("時計・ファッション用品", 50_719), ("スポーツ・レジャー用品", 9_583), ("その他", 202),
        ]
        func rows(_ items: [(String, Int)]) -> String {
            items.map { "<tr><td>\($0.0)</td><td></td><td></td><td></td><td>\(format($0.1))</td></tr>" }
                .joined()
        }
        return """
            <p>当連結会計年度（自 2025年7月1日 至 2026年6月30日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>国内事業</td><td>北米事業</td><td>アジア事業</td><td>合計</td></tr>
              <tr><td>（ディスカウントストア）</td><td></td><td></td><td></td><td></td></tr>
              \(rows(ds))
              <tr><td>（ＵＮＹ事業）</td><td></td><td></td><td></td><td></td></tr>
              \(rows(uny))
              <tr><td>（海外）</td><td></td><td></td><td></td><td></td></tr>
              <tr><td>北米</td><td></td><td></td><td></td><td>275,028</td></tr>
              <tr><td>アジア</td><td></td><td></td><td></td><td>98,997</td></tr>
              <tr><td>（その他）</td><td></td><td></td><td></td><td></td></tr>
              <tr><td>外販事業</td><td></td><td></td><td></td><td>36,578</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td></td><td></td><td></td><td>2,365,707</td></tr>
              <tr><td>その他の収益（注）１</td><td></td><td></td><td></td><td>79,554</td></tr>
              <tr><td>外部顧客への売上高</td><td></td><td></td><td></td><td>2,445,260</td></tr>
            </table>
            """
    }
}
