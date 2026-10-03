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
        // bs4Text joins descendant text with no separator; that glued cell is the prod root cause.
        #expect(!grid.contains { $0.contains("油脂・乳製品調味料") })
        #expect(!grid.contains { $0.contains("410,4831,592,960") })
        #expect(grid.filter { $0.contains("油脂・乳製品") }.count == 1)
    }

    @Test func headerStackedParagraphsWithoutAmountsStayOneRow() throws {
        let html = """
            <table>
              <tr>
                <td></td>
                <td><p>医薬品販売</p><p>による収益</p></td>
                <td><p>ライセンス供与</p><p>による収益</p></td>
              </tr>
              <tr><td>日本</td><td>226,140</td><td>1,725</td></tr>
            </table>
            """
        let grid = BreakdownExtractor.expandTable(try XBRLTestSupport.parseFirstTable(html))
        #expect(grid.count == 2)
        #expect(grid[0].contains { $0.contains("医薬品販売による収益") })
        #expect(!grid.contains { $0.contains("医薬品販売") && !$0.contains("による収益") && $0.contains("226,140") })
    }

    @Test func periodAndUnitStackedParagraphsDoNotExplodeGeographyHeader() throws {
        let html = """
            <table>
              <tr>
                <td></td>
                <td><p>前連結会計年度</p><p>（百万円）</p></td>
                <td><p>当連結会計年度</p><p>（百万円）</p></td>
              </tr>
              <tr><td>日本</td><td>100</td><td>110</td></tr>
            </table>
            """
        let grid = BreakdownExtractor.expandTable(try XBRLTestSupport.parseFirstTable(html))
        #expect(grid.count == 2)
        #expect(grid[0].contains { $0.contains("前連結会計年度") && $0.contains("百万円") })
        #expect(grid[1] == ["日本", "100", "110"])
    }

    @Test func remainingPerformanceAndContractCostTablesAreSkipped() {
        let remaining = [
            ["", "1年以内", "1年超", "合計"],
            ["残存履行義務", "10", "20", "30"],
        ]
        #expect(RevenueRecognitionCandidates.isContractBalanceTable(remaining))
        let costAsset = [
            ["", "当期末"],
            ["契約の履行のためのコストから認識した資産", "1,000"],
        ]
        #expect(RevenueRecognitionCandidates.isContractBalanceTable(costAsset))
        let product = [
            ["", "金額"],
            ["油脂・乳製品", "410,483"],
            ["顧客との契約から生じる収益", "4,751,616"],
        ]
        #expect(!RevenueRecognitionCandidates.isContractBalanceTable(product))
    }

    @Test func emptyLeadingCellStillReadsProductLabel() {
        let table = RevenueRecognitionCandidates.parse(tables: [
            BreakdownTable(
                heading: BreakdownExtractor.revenueRecognitionHeading,
                markdown: """
                    |  |  | (単位：百万円) |
                    |  | サーマルシステム | 1,780,351 |
                    |  | パワトレインシステム | 1,479,737 |
                    |  | 自動車分野計 | 7,391,068 |
                    |  | 非車載事業分野 | 148,907 |
                    |  | 合計 | 7,539,975 |
                    """,
                period: "当期")
        ])
        let parsed = table[0]
        #expect(parsed.items.map(\.label).contains("サーマルシステム"))
        #expect(parsed.items.map(\.label).contains("パワトレインシステム"))
        #expect(Set(parsed.totals.map(\.label)).contains("合計"))
        #expect(Set(parsed.totals.map(\.label)).contains("自動車分野計"))
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

    /// 7413 S100YKKP: prod currently stores labels shifted by one row (油脂 instead of
    /// 油脂・乳製品) after Luna re-split a cell that `bs4Text` had glued. Pin the disclosed
    /// labels and 千円 amounts, not the shifted ones.
    @Test func ykkp7413CandidatesAndRows() async throws {
        let snapshot = try await assert7413(
            docID: "S100YKKP", fyEnd: "2026-03-31",
            amounts: [410_483, 1_592_960, 1_080_049, 259_850, 1_233_827, 118_499, 55_945],
            total: 4_751_616)
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments[0].label == "油脂・乳製品")
        #expect(segments[0].categoryGroup == "油脂・乳製品")
        #expect(segments[0].label != "油脂")
        #expect(segments[0].amount == 410_483 * 1_000)
        #expect(segments[1].label == "調味料")
        #expect(segments[1].amount == 1_592_960 * 1_000)
        #expect(!segments.contains { $0.label?.contains("油脂・乳製品調味料") == true })
        #expect(!segments.contains { $0.label == "油脂" })
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

    /// 272A S100YSCR: prod currently stores amounts 1000× too large (百万円 applied to a
    /// 千円 table) after the same glued `<p>` cell. Pin 千円 ×1,000, not ×1,000,000.
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
        #expect(snapshot.rows[0].amount == 1_698_931 * 1_000)
        #expect(snapshot.rows[0].amount != 1_698_931 * Financial.millionYen)
        #expect(snapshot.denominator != 21_925_876 * Financial.millionYen)
        #expect(snapshot.rows[0].label == "工事表示板・標識")
        #expect(!snapshot.rows.contains { $0.label?.contains("工事表示板・標識仮設防護柵") == true })
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
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t1_c1", confidence: 0.49)
        let (snapshot, audit) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 7_000, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100LOW")
        let row = try #require(snapshot)
        #expect(row.needsReview)
        #expect(row.warnings.contains(RevenueRecognitionColumnNormalizer.warningLowConfidence))
        #expect(audit?.jev?.calls.first?.probability == 0.49)
        #expect(audit?.columnJev?.calls.first?.probability == 0.49)
        #expect(RevenueRecognitionColumnNormalizer.confidenceThreshold == 0.5)
        #expect(RevenueRecognitionColumnNormalizer.confidenceThreshold < 0.75)
    }

    @Test func atConfidenceThresholdDoesNotSetNeedsReview() async throws {
        let html = priorAndCurrent(
            currentCaption: "当連結会計年度（自 2025年4月1日 至 2026年3月31日）",
            unit: "千円",
            currentBody: stackedRow(labels: Self.cat7413, amounts: [410_483, 1_592_960, 1_080_049, 259_850, 1_233_827, 118_499, 55_945])
                + totalRow("顧客との契約から生じる収益", 4_751_616))
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t1_c1", confidence: 0.5)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 4_751_616_000, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100EDGE")
        let row = try #require(snapshot)
        #expect(row.needsReview == false)
        #expect(!row.warnings.contains(RevenueRecognitionColumnNormalizer.warningLowConfidence))
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
            selected: RevenueRecognitionColumnNormalizer.noneOfThese, confidence: 0.95,
            pNone: 0.9)
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
        #expect(snapshot.rows[1].label == "うち中国")
        #expect(snapshot.rows[1].amount == 300 * Financial.millionYen)
    }

    @Test func noneOfTheseLowPNoneTakesBestColumnAndNeedsReview() async throws {
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
            selected: RevenueRecognitionColumnNormalizer.noneOfThese, confidence: 0.4,
            pNone: 0.6)
        let (snapshot, audit) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 7_000, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100YRWH")
        let row = try #require(snapshot)
        #expect(row.needsReview)
        #expect(row.warnings.contains(RevenueRecognitionColumnNormalizer.warningNoneOfTheseOverridden))
        #expect(row.rows.isEmpty == false)
        #expect(audit?.columnJev?.calls.first?.selected != RevenueRecognitionColumnNormalizer.noneOfThese)
        #expect(audit?.notes.contains("p_none=0.6") == true)
    }

    @Test func yrwh1436SingleSegmentColumnIsValid() async throws {
        let html = """
            <p>前連結会計年度（自 2025年5月1日 至 2026年4月30日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>報告セグメント</td></tr>
              <tr><td></td><td>再生可能エネルギー事業</td></tr>
              <tr><td>不動産及び設備</td><td>9,765,440</td></tr>
              <tr><td>その他</td><td>1,851,189</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>11,616,630</td></tr>
              <tr><td>外部顧客への売上高</td><td>11,616,630</td></tr>
            </table>
            <p>当連結会計年度（自 2025年5月1日 至 2026年4月30日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>報告セグメント</td></tr>
              <tr><td></td><td>再生可能エネルギー事業</td></tr>
              <tr><td>不動産及び設備</td><td>14,672,799</td></tr>
              <tr><td>その他</td><td>3,685,324</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>18,358,123</td></tr>
              <tr><td>外部顧客への売上高</td><td>18,358,123</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YRWH", fyEnd: "2026-04-30", pick: "t1_c1")
        try assertFlatRows(
            snapshot, groups: ["不動産及び設備", "その他"], amounts: [14_672_799, 3_685_324], unit: 1_000)
        #expect(snapshot.denominator == 18_358_123 * 1_000)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.rows.contains { $0.label == "顧客との契約から生じる収益" })
    }

    @Test func yjhn6904GaibuKokyakuNiTaisuruIsTotal() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>日本</td><td>アジア</td><td>北中米</td><td>欧州</td><td>合計</td></tr>
              <tr><td>製品</td><td>18,508,319</td><td>6,845,303</td><td>12,343,283</td><td>4,466,286</td><td>42,163,192</td></tr>
              <tr><td>その他</td><td>29,116</td><td>－</td><td>－</td><td>－</td><td>29,116</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>18,537,436</td><td>6,845,303</td><td>12,343,283</td><td>4,466,286</td><td>42,192,309</td></tr>
              <tr><td>その他の収益</td><td>－</td><td>－</td><td>－</td><td>－</td><td>－</td></tr>
              <tr><td>外部顧客に対する売上高</td><td>18,537,436</td><td>6,845,303</td><td>12,343,283</td><td>4,466,286</td><td>42,192,309</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YJHN", fyEnd: "2026-03-31", pick: "t0_c5")
        try assertFlatRows(
            snapshot, groups: ["製品", "その他"], amounts: [42_163_192, 29_116], unit: 1_000)
        #expect(snapshot.denominator == 42_192_309 * 1_000)
        #expect(!snapshot.rows.contains { $0.label == "外部顧客に対する売上高" })
        #expect(snapshot.needsReview == false)
        #expect(RevenueRecognitionCandidates.isTotalLabel("外部顧客に対する売上高"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("外部顧客への収益"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("小計"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("売上高"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("（小計）"))
    }

    @Test func y9513092ParenthesizedLinesArePartialUnderBusiness() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>受託商品の販売に係る収益</td><td>仕入商品等の販売に係る収益</td><td>広告事業その他の収益</td><td>合計</td></tr>
              <tr><td>ZOZOTOWN事業</td><td>134,673</td><td>22,743</td><td>－</td><td>157,416</td></tr>
              <tr><td>（買取・製造販売）</td><td>－</td><td>2,630</td><td>－</td><td>2,630</td></tr>
              <tr><td>（受託販売）</td><td>134,673</td><td>－</td><td>－</td><td>134,673</td></tr>
              <tr><td>（USED販売）</td><td>－</td><td>20,113</td><td>－</td><td>20,113</td></tr>
              <tr><td>LINEヤフーコマース</td><td>22,003</td><td>2,176</td><td>－</td><td>24,179</td></tr>
              <tr><td>LYST</td><td>－</td><td>－</td><td>5,776</td><td>5,776</td></tr>
              <tr><td>BtoB事業</td><td>1,325</td><td>－</td><td>－</td><td>1,325</td></tr>
              <tr><td>広告事業</td><td>－</td><td>－</td><td>11,884</td><td>11,884</td></tr>
              <tr><td>その他</td><td>－</td><td>－</td><td>27,791</td><td>27,791</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>158,001</td><td>24,919</td><td>45,452</td><td>228,373</td></tr>
              <tr><td>外部顧客への売上高</td><td>158,001</td><td>24,919</td><td>45,452</td><td>228,373</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100Y951", fyEnd: "2026-03-31", pick: "t0_c4")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.contains { $0.categoryGroup == "ZOZOTOWN事業" && $0.category == nil && $0.amount == 157_416 * Financial.millionYen })
        #expect(segments.contains { $0.category == "（買取・製造販売）" && $0.amount == 2_630 * Financial.millionYen })
        #expect(segments.contains { $0.category == "（受託販売）" && $0.amount == 134_673 * Financial.millionYen })
        #expect(segments.contains { $0.category == "（USED販売）" && $0.amount == 20_113 * Financial.millionYen })
        #expect(segments.contains { $0.categoryGroup == "LINEヤフーコマース" && $0.category == nil })
        #expect(!segments.contains { $0.categoryGroup == "（買取・製造販売）" && $0.category == nil })
        let full = segments.filter { $0.category == nil }
        #expect(full.reduce(0) { $0 + $1.amount } == (157_416 + 24_179 + 5_776 + 1_325 + 11_884 + 27_791) * Financial.millionYen)
        #expect(snapshot.denominator == 228_373 * Financial.millionYen)
        #expect(snapshot.needsReview == false)
    }

    @Test func yjc56482HeadingParagraphDoesNotTakeRobotAmounts() throws {
        let html = """
            <table>
              <tr>
                <td></td>
                <td>日本</td><td>米国</td><td>アジア</td><td>欧州</td><td>合計</td>
              </tr>
              <tr>
                <td>
                  <p>製品及びサービス別</p>
                  <p>ロボット</p>
                  <p>特注機</p>
                  <p>部品・保守サービス</p>
                </td>
                <td>
                  <p></p>
                  <p>7,445,494</p>
                  <p>1,482,554</p>
                  <p>2,124,545</p>
                </td>
                <td>
                  <p></p>
                  <p>2,236,732</p>
                  <p>758,274</p>
                  <p>1,084,411</p>
                </td>
                <td>
                  <p></p>
                  <p>4,111,695</p>
                  <p>202,153</p>
                  <p>962,796</p>
                </td>
                <td>
                  <p></p>
                  <p>1,153,399</p>
                  <p>718,954</p>
                  <p>820,362</p>
                </td>
                <td>
                  <p></p>
                  <p>14,947,321</p>
                  <p>3,161,936</p>
                  <p>4,992,115</p>
                </td>
              </tr>
              <tr><td>顧客との契約から生じる収益</td><td>11,052,594</td><td>4,079,418</td><td>5,276,645</td><td>2,692,715</td><td>23,101,373</td></tr>
              <tr><td>外部顧客への売上高</td><td>11,052,594</td><td>4,079,418</td><td>5,276,645</td><td>2,692,715</td><td>23,101,373</td></tr>
            </table>
            """
        let grid = BreakdownExtractor.expandTable(try XBRLTestSupport.parseFirstTable(html))
        #expect(grid.contains { $0.contains("ロボット") && $0.contains("14,947,321") })
        #expect(grid.contains { $0.contains("特注機") && $0.contains("3,161,936") })
        #expect(grid.contains { $0.contains("部品・保守サービス") && $0.contains("4,992,115") })
        #expect(!grid.contains { $0.contains("製品及びサービス別") && $0.contains("14,947,321") })
        #expect(!grid.contains { $0.contains("ロボット") && $0.contains("3,161,936") })
    }

    @Test func yjc56482CandidatesAndRows() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr>
                <td></td>
                <td>日本</td><td>米国</td><td>アジア</td><td>欧州</td><td>合計</td>
              </tr>
              <tr>
                <td>
                  <p>製品及びサービス別</p>
                  <p>ロボット</p>
                  <p>特注機</p>
                  <p>部品・保守サービス</p>
                </td>
                <td>
                  <p></p>
                  <p>7,445,494</p>
                  <p>1,482,554</p>
                  <p>2,124,545</p>
                </td>
                <td>
                  <p></p>
                  <p>2,236,732</p>
                  <p>758,274</p>
                  <p>1,084,411</p>
                </td>
                <td>
                  <p></p>
                  <p>4,111,695</p>
                  <p>202,153</p>
                  <p>962,796</p>
                </td>
                <td>
                  <p></p>
                  <p>1,153,399</p>
                  <p>718,954</p>
                  <p>820,362</p>
                </td>
                <td>
                  <p></p>
                  <p>14,947,321</p>
                  <p>3,161,936</p>
                  <p>4,992,115</p>
                </td>
              </tr>
              <tr><td>顧客との契約から生じる収益</td><td>11,052,594</td><td>4,079,418</td><td>5,276,645</td><td>2,692,715</td><td>23,101,373</td></tr>
              <tr><td>外部顧客への売上高</td><td>11,052,594</td><td>4,079,418</td><td>5,276,645</td><td>2,692,715</td><td>23,101,373</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YJC5", fyEnd: "2026-03-31", pick: "t0_c5")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        #expect(segments.map(\.label) == ["ロボット", "特注機", "部品・保守サービス"])
        #expect(segments.map(\.categoryGroup) == ["製品及びサービス別", "製品及びサービス別", "製品及びサービス別"])
        #expect(segments.map(\.category) == ["ロボット", "特注機", "部品・保守サービス"])
        #expect(segments.map(\.amount) == [14_947_321 * 1_000.0, 3_161_936 * 1_000.0, 4_992_115 * 1_000.0])
        #expect(snapshot.denominator == 23_101_373 * 1_000)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.rows.contains { $0.label == "製品及びサービス別" })
    }

    @Test func yljd7416LabelsInSecondColumn() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td colspan="2"></td><td>報告セグメント</td></tr>
              <tr><td colspan="2"></td><td>衣料品販売事業</td></tr>
              <tr><td></td><td>重衣料</td><td>15,047,573</td></tr>
              <tr><td></td><td>[スーツ・礼服・コート]</td><td></td></tr>
              <tr><td></td><td>中衣料</td><td>3,453,633</td></tr>
              <tr><td></td><td>[ジャケット・スラックス]</td><td></td></tr>
              <tr><td></td><td>軽衣料</td><td>15,795,876</td></tr>
              <tr><td></td><td>補修加工賃収入</td><td>915,569</td></tr>
              <tr><td colspan="2">合計</td><td>35,212,653</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YLJD", fyEnd: "2026-03-31", pick: "t0_c2")
        let labels = snapshot.rows.filter { $0.rowKind == "segment" }.compactMap(\.label)
        #expect(labels.contains("重衣料"))
        #expect(labels.contains("中衣料"))
        #expect(labels.contains("軽衣料"))
        #expect(labels.contains("補修加工賃収入"))
        #expect(snapshot.rows.contains { $0.label == "重衣料" && $0.amount == 15_047_573 * 1_000 })
        #expect(snapshot.denominator == 35_212_653 * 1_000)
    }

    @Test func yjee1807WrappedSameAmountRowsMerge() {
        let merged = RevenueRecognitionCandidates.mergeWrappedRows([
            .init(categoryGroup: "システムインテグレー", category: nil, amount: 1_000, isPartial: false, rowKind: "segment"),
            .init(categoryGroup: "ションサービス", category: nil, amount: 1_000, isPartial: false, rowKind: "segment"),
            .init(categoryGroup: "その他", category: nil, amount: 200, isPartial: false, rowKind: "segment"),
        ])
        #expect(merged.count == 2)
        #expect(merged[0].categoryGroup == "システムインテグレーションサービス")
        #expect(merged[0].amount == 1_000)
        #expect(merged[1].categoryGroup == "その他")
    }

    @Test func tableSumMismatchAgainstOwnTotalSetsNeedsReview() {
        let table = RevenueRecognitionCandidates.ParsedTable(
            tableIndex: 0,
            grid: [
                ["", "金額"],
                ["製品", "100"],
                ["その他", "20"],
                ["顧客との契約から生じる収益", "150"],
            ],
            headerRowCount: 1,
            columnHeaders: [1: "金額"],
            precedingCaption: "当連結会計年度",
            unitCaption: "百万円",
            items: [
                .init(group: "", label: "製品", row: 1, isPartial: false),
                .init(group: "", label: "その他", row: 2, isPartial: false),
            ],
            totals: [.init(label: "顧客との契約から生じる収益", row: 3)],
            groups: []
        )
        let (rows, _) = RevenueRecognitionCandidates.buildRows(table: table, column: 1)
        #expect(RevenueRecognitionCandidates.tableSumMismatch(rows: rows, table: table, column: 1))
        let total = RevenueRecognitionCandidates.tableTotal(table: table, column: 1)
        #expect(total?.label == "顧客との契約から生じる収益")
    }

    @Test func emptyBuiltRowsStillNeedsReviewNotSilentDrop() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>合計</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>100</td></tr>
              <tr><td>外部顧客への売上高</td><td>100</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t0_c1", confidence: 0.9)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 100 * Financial.millionYen, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100YK9A")
        let row = try #require(snapshot)
        #expect(row.needsReview)
        #expect(row.rows.isEmpty)
        #expect(row.warnings.contains(RevenueRecognitionColumnNormalizer.warningNoCategoryRows))
    }

    @Test func replacingJevKeepsColumnJev() {
        let column = SegmentNoteJevAuditPayload(
            code: "", docID: "S100YKKP", axis: "business", model: "typesafe/jev-1.13",
            threshold: 0.5, applied: true, needsReview: false, sentences: [],
            calls: [
                SegmentNoteJevCallPayload(
                    question: "col", options: ["t1_c1", "none_of_these"], selected: "t1_c1",
                    probability: 0.97, sentences: [], applied: true)
            ])
        let note = SegmentNoteJevAuditPayload(
            code: "", docID: "S100YKKP", axis: "business", model: "typesafe/jev-1.13",
            threshold: 0.9, applied: false, needsReview: false, sentences: [],
            calls: [
                SegmentNoteJevCallPayload(
                    question: "breakdown_table", options: ["0", "none_of_these"], selected: "0",
                    probability: 0.99, sentences: [], applied: true)
            ])
        let audit = LLMBreakdownAuditPayload(
            sourceTableIndex: 1, periodColumn: "t1_c1", unit: "千円", profitDisclosed: false,
            notes: "jev_column=t1_c1", jev: column, columnJev: column)
        let merged = audit.replacingJev(note)
        #expect(merged.jev == note)
        #expect(merged.columnJev == column)
        #expect(merged.columnJev?.calls.first?.selected == "t1_c1")
        #expect(merged.jsonObject()["column_jev"] != nil)
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

    @Test func stripNoteMarkerFromTotalAndDisplayLabelIsCategoryOrGroup() {
        #expect(RevenueRecognitionCandidates.stripNoteMarker("その他の収益（注）１") == "その他の収益")
        #expect(RevenueRecognitionCandidates.stripNoteMarker("タイヤ(注１)") == "タイヤ")
        #expect(RevenueRecognitionCandidates.stripNoteMarker("その他(注２)") == "その他")
        #expect(
            RevenueRecognitionCandidates.displayLabel(categoryGroup: "（海外）", category: "北米")
                == "北米")
        #expect(
            BreakdownRowPayload.displayLabel(categoryGroup: "（ディスカウントストア）", category: "家電製品")
                == "家電製品")
        #expect(
            BreakdownRowPayload.displayLabel(categoryGroup: "油脂・乳製品", category: nil)
                == "油脂・乳製品")
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
        #expect(decoded.label == "家電製品")
        let json = row.jsonObject()
        #expect(json["label"] as? String == "家電製品")
        #expect(json["category_group"] as? String == "（ディスカウントストア）")
        #expect(json["category"] as? String == "家電製品")
    }

    // MARK: - helpers

    @discardableResult
    private func assert7413(
        docID: String, fyEnd: String, amounts: [Int], total: Int
    ) async throws -> BreakdownSnapshot {
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
        return snapshot
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
