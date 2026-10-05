// SPEC_ORACLE: 収益分解の <p> 爆発・2段候補・Jev 列スタブ後の最終行。
// 注記の抜粋のみ（有報全体は使わない）。ネットワークなし。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RevenueRecognitionGoldenTests {
    private static let cat7413: [String] = [
        "油脂・乳製品", "調味料", "嗜好品・飲料", "乾物・雑穀", "副食品", "栄養補助食品", "その他",
    ]

    private func yen(_ n: Int) -> Double { Double(n) * Financial.millionYen }
    private func sen(_ n: Int) -> Double { Double(n) * 1_000.0 }

    private func hasRow(
        _ rows: [BreakdownRow],
        group: String? = nil,
        category: String? = nil,
        nilCategory: Bool = false,
        label: String? = nil,
        amount: Double? = nil
    ) -> Bool {
        rows.contains { row in
            if let group, row.categoryGroup != group { return false }
            if nilCategory, row.category != nil { return false }
            if let category, row.category != category { return false }
            if let label, row.label != label { return false }
            if let amount, row.amount != amount { return false }
            return true
        }
    }

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
        let oils: Bool = grid.contains { $0.contains("油脂・乳製品") && $0.contains("410,483") }
        let seasoning: Bool = grid.contains { $0.contains("調味料") && $0.contains("1,592,960") }
        let gluedLabel: Bool = grid.contains { $0.contains("油脂・乳製品調味料") }
        let gluedAmount: Bool = grid.contains { $0.contains("410,4831,592,960") }
        let oilsCount: Int = grid.filter { $0.contains("油脂・乳製品") }.count
        #expect(oils)
        #expect(seasoning)
        #expect(gluedLabel == false)
        #expect(gluedAmount == false)
        #expect(oilsCount == 1)
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
        let rowCount: Int = grid.count
        let joinedCaption: Bool = grid[0].contains { $0.contains("医薬品販売による収益") }
        let splitCaption: Bool = grid.contains {
            $0.contains("医薬品販売") && !$0.contains("による収益") && $0.contains("226,140")
        }
        #expect(rowCount == 2)
        #expect(joinedCaption)
        #expect(splitCaption == false)
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
        let rowCount: Int = grid.count
        let stackedHeader: Bool = grid[0].contains { $0.contains("前連結会計年度") && $0.contains("百万円") }
        let japanRow: [String] = grid[1]
        let expectedJapan: [String] = ["日本", "100", "110"]
        #expect(rowCount == 2)
        #expect(stackedHeader)
        #expect(japanRow == expectedJapan)
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
        let itemLabels: [String] = parsed.items.map(\.label)
        let hasThermalItem: Bool = parsed.items.contains {
            $0.label == "サーマルシステム" && $0.group == "自動車分野"
        }
        let groups: [String] = parsed.groups.map(\.group)
        let totals: Set<String> = Set(parsed.totals.map(\.label))
        let groupCloserIsGroup: Bool = RevenueRecognitionCandidates.isGroupSubtotalLabel("自動車分野計")
        let groupCloserIsTotal: Bool = RevenueRecognitionCandidates.isTotalLabel("自動車分野計")
        #expect(itemLabels.contains("サーマルシステム"))
        #expect(itemLabels.contains("パワトレインシステム"))
        #expect(hasThermalItem)
        #expect(groups.contains("自動車分野"))
        #expect(totals.contains("合計"))
        #expect(totals.contains("自動車分野計") == false)
        #expect(itemLabels.contains("自動車分野計") == false)
        #expect(groupCloserIsGroup)
        #expect(groupCloserIsTotal == false)
        let (rows, _) = RevenueRecognitionCandidates.buildRows(table: parsed, column: 2)
        let thermalRow: Bool = rows.contains {
            $0.category == "サーマルシステム" && $0.categoryGroup == "自動車分野"
        }
        let otherRow: Bool = rows.contains {
            $0.categoryGroup == "非車載事業分野" && $0.category == nil
        }
        let closerAsRow: Bool = rows.contains {
            $0.categoryGroup.contains("自動車分野計") || $0.category == "自動車分野計"
        }
        let total = RevenueRecognitionCandidates.tableTotal(table: parsed, column: 2)
        let totalLabel: String? = total?.label
        let totalAmount: Double? = total?.amount
        #expect(thermalRow)
        #expect(otherRow)
        #expect(closerAsRow == false)
        #expect(totalLabel == "合計")
        #expect(totalAmount == 7_539_975)
    }

    /// S100Y9T1 0105100 iXBRL: two-column label area. Blank `rowspan=6` outer cell,
    /// inner category, then `自動車分野計` / `非車載事業分野` / `合計` with `colspan=2`.
    /// Figures are the prior-year table in that file (verified from the iXBRL).
    @Test func densoTwoColumnLabelAreaClosesBlankRowspanWithSubtotal() async throws {
        let html = """
            <p>前連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td></td><td>(単位：百万円)</td></tr>
              <tr><td rowspan="6"></td><td>サーマルシステム</td><td>1,728,469</td></tr>
              <tr><td>パワトレインシステム</td><td>1,438,591</td></tr>
              <tr><td>モビリティエレクトロニクス</td><td>2,017,304</td></tr>
              <tr><td>エレクトリフィケーションシステム</td><td>1,354,426</td></tr>
              <tr><td>先進デバイス</td><td>388,803</td></tr>
              <tr><td>その他</td><td>113,659</td></tr>
              <tr><td colspan="2">自動車分野計</td><td>7,041,252</td></tr>
              <tr><td colspan="2">非車載事業分野</td><td>120,525</td></tr>
              <tr><td colspan="2">合計</td><td>7,161,777</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100Y9T1", fyEnd: "2025-03-31", pick: "t0_c2")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let auto: [(String, Int)] = [
            ("サーマルシステム", 1_728_469),
            ("パワトレインシステム", 1_438_591),
            ("モビリティエレクトロニクス", 2_017_304),
            ("エレクトリフィケーションシステム", 1_354_426),
            ("先進デバイス", 388_803),
            ("その他", 113_659),
        ]
        let autoCount: Int = segments.filter { $0.categoryGroup == "自動車分野" }.count
        #expect(autoCount == 6)
        for (name, amount) in auto {
            let expected: Double = yen(amount)
            let found: Bool = hasRow(
                segments, group: "自動車分野", category: name, amount: expected)
            #expect(found)
        }
        let autoSum: Double = segments.filter { $0.categoryGroup == "自動車分野" }
            .reduce(0) { $0 + $1.amount }
        let expectedAutoSum: Double = yen(7_041_252)
        #expect(autoSum == expectedAutoSum)
        let other: Bool = hasRow(
            segments, group: "非車載事業分野", nilCategory: true, amount: yen(120_525))
        let closerAsRow: Bool = segments.contains {
            $0.label == "自動車分野計" || $0.categoryGroup == "自動車分野計"
        }
        let totalAsRow: Bool = segments.contains { $0.categoryGroup == "合計" }
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(7_161_777)
        let needsReview: Bool = snapshot.needsReview
        let priorWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningPriorPeriod)
        #expect(other)
        #expect(closerAsRow == false)
        #expect(totalAsRow == false)
        #expect(denominator == expectedDenom)
        #expect(needsReview)
        #expect(priorWarning)
    }

    /// S100Y9T1 当期。自動車分野計 7,391,068 / 非車載事業分野 148,907 / 合計 7,539,975。
    @Test func y9t1DensoCurrentYearProductTable() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td></td><td>(単位：百万円)</td></tr>
              <tr><td rowspan="6"></td><td>サーマルシステム</td><td>1,780,351</td></tr>
              <tr><td>パワトレインシステム</td><td>1,479,737</td></tr>
              <tr><td>モビリティエレクトロニクス</td><td>2,198,663</td></tr>
              <tr><td>エレクトリフィケーションシステム</td><td>1,433,456</td></tr>
              <tr><td>先進デバイス</td><td>390,274</td></tr>
              <tr><td>その他</td><td>108,587</td></tr>
              <tr><td colspan="2">自動車分野計</td><td>7,391,068</td></tr>
              <tr><td colspan="2">非車載事業分野</td><td>148,907</td></tr>
              <tr><td colspan="2">合計</td><td>7,539,975</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100Y9T1", fyEnd: "2026-03-31", pick: "t0_c2")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let auto: [(String, Int)] = [
            ("サーマルシステム", 1_780_351),
            ("パワトレインシステム", 1_479_737),
            ("モビリティエレクトロニクス", 2_198_663),
            ("エレクトリフィケーションシステム", 1_433_456),
            ("先進デバイス", 390_274),
            ("その他", 108_587),
        ]
        let autoCount: Int = segments.filter { $0.categoryGroup == "自動車分野" }.count
        #expect(autoCount == 6)
        for (name, amount) in auto {
            let expected: Double = yen(amount)
            let found: Bool = hasRow(
                segments, group: "自動車分野", category: name, amount: expected)
            #expect(found)
        }
        let autoSum: Double = segments.filter { $0.categoryGroup == "自動車分野" }
            .reduce(0) { $0 + $1.amount }
        let expectedAutoSum: Double = yen(7_391_068)
        #expect(autoSum == expectedAutoSum)
        let other: Bool = hasRow(
            segments, group: "非車載事業分野", nilCategory: true, amount: yen(148_907))
        let closerAsRow: Bool = segments.contains {
            $0.label == "自動車分野計" || $0.categoryGroup == "自動車分野計"
        }
        let customerKept: Bool = segments.contains { $0.label?.contains("向け") == true }
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(7_539_975)
        let needsReview: Bool = snapshot.needsReview
        #expect(other)
        #expect(closerAsRow == false)
        #expect(customerKept == false)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
    }

    /// オークマ S100YFQC: 品目表が前期（206,822）と当期（235,888）で並ぶ。当期を選ぶ。
    @Test func yfqc6103CurrentYearProductTableIsPreferredOverPrior() async throws {
        let html = """
            <p>前連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td><td>構成比(％)</td></tr>
              <tr><td>ＮＣ旋盤</td><td>37,366</td><td>18.1</td></tr>
              <tr><td>マシニングセンタ</td><td>104,235</td><td>50.4</td></tr>
              <tr><td>複合加工機</td><td>55,653</td><td>26.9</td></tr>
              <tr><td>ＮＣ研削盤</td><td>2,280</td><td>1.1</td></tr>
              <tr><td>その他</td><td>7,287</td><td>3.5</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>206,822</td><td>100.0</td></tr>
              <tr><td>外部顧客への売上高</td><td>206,822</td><td>100.0</td></tr>
            </table>
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>売上高</td><td>構成比(％)</td></tr>
              <tr><td>ＮＣ旋盤</td><td>34,304</td><td>14.5</td></tr>
              <tr><td>マシニングセンタ</td><td>132,309</td><td>56.1</td></tr>
              <tr><td>複合加工機</td><td>60,763</td><td>25.8</td></tr>
              <tr><td>ＮＣ研削盤</td><td>2,424</td><td>1.0</td></tr>
              <tr><td>その他</td><td>6,087</td><td>2.6</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>235,888</td><td>100.0</td></tr>
              <tr><td>外部顧客への売上高</td><td>235,888</td><td>100.0</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let columns = RevenueRecognitionCandidates.amountColumns(in: parsed)
        let constraint = RevenueRecognitionTableStructure.axisConstraint(tables: parsed)
        let offered = RevenueRecognitionColumnNormalizer.offeredColumns(
            columns, tables: parsed, constraint: constraint)
        let offeredIndexes: Set<Int> = Set(offered.map(\.tableIndex))
        #expect(offeredIndexes == [1])
        let selectedTable = try #require(parsed.first { $0.tableIndex == 1 })
        let selectedColumn = try #require(offered.first { $0.tableIndex == 1 })
        let selectedTotal = RevenueRecognitionCandidates.tableTotal(
            table: selectedTable, column: selectedColumn.column)
        #expect(selectedTotal?.amount == 235_888)
        let decider = FakeRevenueRecognitionColumnDecider()
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: yen(235_888), decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100YFQC")
        let row = try #require(snapshot)
        let lathe: Bool = hasRow(
            row.rows.filter { $0.rowKind == "segment" },
            label: "ＮＣ旋盤", amount: yen(34_304))
        let needsReview: Bool = row.needsReview
        let priorWarning: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningPriorPeriod)
        let denominator: Double = row.denominator
        let expectedDenom: Double = yen(235_888)
        #expect(lathe)
        #expect(needsReview == false)
        #expect(priorWarning == false)
        #expect(denominator == expectedDenom)
    }

    /// 製品表と顧客表が両方あるとき、Jev が顧客表を選んでも製品表へ寄せる。
    @Test func y9t1DensoPrefersProductTableOverCustomerAxis() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td></td><td>(単位：百万円)</td></tr>
              <tr><td rowspan="6"></td><td>サーマルシステム</td><td>1,780,351</td></tr>
              <tr><td>パワトレインシステム</td><td>1,479,737</td></tr>
              <tr><td>モビリティエレクトロニクス</td><td>2,198,663</td></tr>
              <tr><td>エレクトリフィケーションシステム</td><td>1,433,456</td></tr>
              <tr><td>先進デバイス</td><td>390,274</td></tr>
              <tr><td>その他</td><td>108,587</td></tr>
              <tr><td colspan="2">自動車分野計</td><td>7,391,068</td></tr>
              <tr><td colspan="2">非車載事業分野</td><td>148,907</td></tr>
              <tr><td colspan="2">合計</td><td>7,539,975</td></tr>
            </table>
            <p>顧客別</p>
            <table>
              <tr><td></td><td>当連結会計年度</td></tr>
              <tr><td>トヨタグループ向け</td><td>6,000,000</td></tr>
              <tr><td>その他</td><td>1,391,068</td></tr>
              <tr><td>市販・非車載事業</td><td>148,907</td></tr>
              <tr><td>合計</td><td>7,539,975</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let productAxis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        let customerAxis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[1])
        let constraint: RevenueRecognitionTableStructure.AxisConstraint =
            RevenueRecognitionTableStructure.axisConstraint(tables: parsed)
        #expect(productAxis == .productOrBusiness)
        #expect(customerAxis == .customer)
        #expect(constraint == .productOnly)
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t1_c1", confidence: 0.77)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: nil, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100Y9T1")
        let row = try #require(snapshot)
        let segments = row.rows.filter { $0.rowKind == "segment" }
        let thermal: Bool = hasRow(
            segments, group: "自動車分野", category: "サーマルシステム", amount: yen(1_780_351))
        let toyota: Bool = segments.contains { $0.label?.contains("トヨタ") == true }
        let denominator: Double = row.denominator
        let expectedDenom: Double = yen(7_539_975)
        let needsReview: Bool = row.needsReview
        #expect(thermal)
        #expect(toyota == false)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
    }

    /// Outer rowspan has text: that cell is category_group, the inner cell is category.
    /// (Two-column label area. Tokyo Electron S100YEOO is a different, single-column
    /// parallel-dimension shape — see `yeooTokyoElectronParallelDimensionsPickProductBlock`.)
    @Test func outerRowspanTextIsCategoryGroupInnerIsCategory() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td></td><td>当期</td></tr>
              <tr><td rowspan="2">製品及びサービス</td><td>新規装置</td><td>1,817,250</td></tr>
              <tr><td>フィールドソリューション他</td><td>626,282</td></tr>
              <tr><td colspan="2">合計</td><td>2,443,533</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YEOO", fyEnd: "2026-03-31", pick: "t0_c2")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let equipment: Bool = hasRow(
            segments, group: "製品及びサービス", category: "新規装置", amount: yen(1_817_250))
        let solutions: Bool = hasRow(
            segments, group: "製品及びサービス", category: "フィールドソリューション他")
        let geo: Bool = segments.contains { $0.categoryGroup == "地理的区分" }
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(2_443_533)
        let needsReview: Bool = snapshot.needsReview
        #expect(equipment)
        #expect(solutions)
        #expect(geo == false)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
    }

    /// S100YEOO 0105010: 単一ラベル列。地理的区分と製品及びサービスは同じ全社合計の並行次元。
    @Test func yeooTokyoElectronParallelDimensionsPickProductBlock() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>地理的区分</td><td></td><td></td></tr>
              <tr><td>日本</td><td>189,979</td><td>239,427</td></tr>
              <tr><td>北米</td><td>242,964</td><td>166,446</td></tr>
              <tr><td>欧州</td><td>75,524</td><td>67,407</td></tr>
              <tr><td>韓国</td><td>409,009</td><td>543,858</td></tr>
              <tr><td>台湾</td><td>410,627</td><td>499,853</td></tr>
              <tr><td>中国</td><td>1,015,060</td><td>832,555</td></tr>
              <tr><td>その他</td><td>88,402</td><td>93,985</td></tr>
              <tr><td>外部顧客への売上高</td><td>2,431,568</td><td>2,443,533</td></tr>
              <tr><td></td><td></td><td></td></tr>
              <tr><td>製品及びサービス</td><td></td><td></td></tr>
              <tr><td>新規装置 (注)1</td><td>1,893,080</td><td>1,817,250</td></tr>
              <tr><td>フィールドソリューション他 (注)1</td><td>538,488</td><td>626,282</td></tr>
              <tr><td>外部顧客への売上高</td><td>2,431,568</td><td>2,443,533</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YEOO", fyEnd: "2026-03-31", pick: "t0_c2")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let segmentCount: Int = segments.count
        let expectedEquipment: Double = yen(1_817_250)
        let expectedSolutions: Double = yen(626_282)
        let equipment: Bool = segments.contains {
            ($0.categoryGroup == "新規装置" || $0.category == "新規装置")
                && $0.amount == expectedEquipment
        }
        let solutions: Bool = segments.contains {
            ($0.categoryGroup == "フィールドソリューション他" || $0.category == "フィールドソリューション他")
                && $0.amount == expectedSolutions
        }
        let noteInLabel: Bool = segments.contains { $0.label?.contains("注") == true }
        let geoKept: Bool = segments.contains {
            $0.categoryGroup == "地理的区分" || $0.categoryGroup == "日本"
        }
        let headingKept: Bool = segments.contains { $0.categoryGroup == "製品及びサービス" }
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(2_443_533)
        let needsReview: Bool = snapshot.needsReview
        #expect(segmentCount == 2)
        #expect(equipment)
        #expect(solutions)
        #expect(noteInLabel == false)
        #expect(geoKept == false)
        #expect(headingKept == false)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
    }

    /// 三菱商事横結合: `合計` 列は報告セグメント小計 13,939,592。分母は `連結金額` 13,948,091。
    @Test func mitsubishiConsolidatedAmountBeatsReportableSubtotalColumn() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr>
                <td></td><td>地球環境エネルギー</td><td>金属資源</td><td>S.L.C.</td>
                <td>化学品</td><td>合計</td><td>その他</td><td>調整・消去</td><td>連結金額</td>
              </tr>
              <tr>
                <td>顧客との契約から認識した収益</td>
                <td>1,851,642</td><td>1,243,344</td><td>2,513,397</td>
                <td>8,331,169</td><td>13,939,592</td><td>8,539</td><td>△40</td><td>13,948,091</td>
              </tr>
              <tr>
                <td>その他の源泉から認識した収益</td>
                <td>1,415,653</td><td>2,839,985</td><td>746</td>
                <td>0</td><td>4,967,904</td><td>－</td><td>－</td><td>4,967,904</td>
              </tr>
              <tr>
                <td>合計</td>
                <td>3,267,295</td><td>4,083,329</td><td>2,514,143</td>
                <td>8,331,169</td><td>18,907,496</td><td>8,539</td><td>△40</td><td>18,915,995</td>
              </tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YB25", fyEnd: "2026-03-31", pick: "t0_c5")
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(13_948_091)
        let metal: Bool = hasRow(snapshot.rows, group: "金属資源", amount: yen(1_243_344))
        let totalAsRow: Bool = snapshot.rows.contains {
            $0.categoryGroup == "合計" || $0.categoryGroup == "連結金額"
        }
        let needsReview: Bool = snapshot.needsReview
        #expect(denominator == expectedDenom)
        #expect(metal)
        #expect(totalAsRow == false)
        #expect(needsReview == false)
    }

    @Test func geographyTableWithoutStackedParagraphsIsUnchanged() throws {
        let html = "<table><tr><td>日本</td><td>100</td></tr><tr><td>アジア</td><td>50</td></tr></table>"
        let table = try XBRLTestSupport.parseFirstTable(html)
        let grid: [[String]] = BreakdownExtractor.expandTable(table)
        let expected: [[String]] = [["日本", "100"], ["アジア", "50"]]
        #expect(grid == expected)
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
        let amount0: Double = segments[0].amount
        let expected0: Double = sen(410_483)
        #expect(amount0 == expected0)
        #expect(segments[1].label == "調味料")
        let amount1: Double = segments[1].amount
        let expected1: Double = sen(1_592_960)
        #expect(amount1 == expected1)
        let glued: Bool = segments.contains { $0.label?.contains("油脂・乳製品調味料") == true }
        let oilsOnly: Bool = segments.contains { $0.label == "油脂" }
        #expect(glued == false)
        #expect(oilsOnly == false)
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
        let labels: [String] = parsed.items.map(\.label)
        #expect(labels == cats)
        #expect(parsed.groups.isEmpty)
        let totals: Set<String> = Set(parsed.totals.map(\.label))
        #expect(totals.contains("外部顧客への売上高"))
        try assertFlatRows(snapshot, groups: cats, amounts: amounts, unit: 1_000)
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(21_954_062)
        #expect(denominator == expectedDenom)
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
        let parsedLabels: [String] = parsed.items.map(\.label)
        #expect(parsedLabels == cats)
        #expect(parsed.groups.isEmpty)
        try assertFlatRows(snapshot, groups: cats, amounts: amounts, unit: 1_000)
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(21_925_876)
        let amount0: Double = snapshot.rows[0].amount
        let expected0: Double = sen(1_698_931)
        let notMillion: Double = yen(1_698_931)
        let denomNotMillion: Double = yen(21_925_876)
        let glued: Bool = snapshot.rows.contains { $0.label?.contains("工事表示板・標識仮設防護柵") == true }
        #expect(denominator == expectedDenom)
        #expect(amount0 == expected0)
        #expect(amount0 != notMillion)
        #expect(denominator != denomNotMillion)
        #expect(snapshot.rows[0].label == "工事表示板・標識")
        #expect(glued == false)
    }

    @Test func z42g7532NestedCandidatesAndRows() async throws {
        let html = priorThen(currentHTML: panPacificCurrentTable())
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let current = try #require(parsed.first { $0.tableIndex == 1 } ?? parsed.last)
        let groups: [String] = current.groups.map(\.group)
        let expectedGroups: [String] = [
            "（ディスカウントストア）", "（ＵＮＹ事業）", "（海外）", "（その他）",
        ]
        #expect(groups == expectedGroups)
        let itemCount: Int = current.items.count
        #expect(itemCount == 15)
        let totals: Set<String> = Set(current.totals.map(\.label))
        let expectedTotals: Set<String> = [
            "顧客との契約から生じる収益", "その他の収益", "外部顧客への売上高",
        ]
        #expect(totals.isSuperset(of: expectedTotals))
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
        let segmentCount: Int = segments.count
        #expect(segmentCount == 15)
        let segmentSum: Double = segments.reduce(0) { $0 + $1.amount }
        let expectedSum: Double = yen(2_365_707)
        #expect(segmentSum == expectedSum)
        for (index, row) in expected.enumerated() {
            let group: String? = segments[index].categoryGroup
            let category: String? = segments[index].category
            let amount: Double = segments[index].amount
            let expectedAmount: Double = yen(row.2)
            let expectedLabel: String = RevenueRecognitionCandidates.displayLabel(
                categoryGroup: row.0, category: row.1)
            let label: String? = segments[index].label
            #expect(group == row.0)
            #expect(category == row.1)
            #expect(amount == expectedAmount)
            #expect(label == expectedLabel)
        }
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(2_445_260)
        let needsReview: Bool = snapshot.needsReview
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
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

    /// 8771 S100YKOI: 収益認識表は顧客契約 / その他 / 外部顧客の合計だけ。
    /// Jev が当期列を選んでもカテゴリ行は無く、専用タグがあるので main と同じ F。
    @Test func ykoi8771TotalsOnlyFallsBackToSingleSegmentDisclosed() async throws {
        let tagText = "当社グループは単一セグメントであるため、記載を省略しております。"
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment contextRef="CurrentYearDuration">\(tagText)</jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment>
            """)
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>80</td><td>90</td></tr>
              <tr><td>その他の源泉から生じる収益</td><td>10</td><td>12</td></tr>
              <tr><td>外部顧客への売上高</td><td>90</td><td>102</td></tr>
            </table>
            """
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = ExtractedBreakdown(
                method: "html_table",
                tables: BreakdownExtractor.allTablesFromHtml(
                    html, defaultHeading: BreakdownExtractor.revenueRecognitionHeading),
                facts: [])
            let context = BltServerContext(
                apiKey: "test", cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()),
                businessChatClient: UnavailableChatClient(),
                geographyChatClient: UnavailableChatClient())
            let gate = await context.segmentsAfterNoteDecision(
                axis: .business, docID: "S100YKOI", extracted: extracted, xbrlDir: dir,
                consolidatedSales: 102 * Financial.millionYen, labelsByTag: [:])
            #expect(gate.extracted?.tables.isEmpty == false)
            #expect(gate.outcome.omissionReason == nil)

            let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
            #expect(parsed[0].items.isEmpty)
            let totals: Set<String> = Set(parsed[0].totals.map(\.label))
            let expectedTotals: Set<String> = [
                "顧客との契約から生じる収益", "その他の源泉から生じる収益", "外部顧客への売上高",
            ]
            #expect(totals.isSuperset(of: expectedTotals))
            let transposed = RevenueRecognitionCandidates.transposeMetricRow(
                table: parsed[0], wholeCompanyColumn: 2)
            let transposedEmpty: Bool = transposed.rows.isEmpty
            let periodAsCategory: Bool = transposed.rows.contains {
                $0.categoryGroup.contains("前連結会計年度")
            }
            #expect(transposedEmpty)
            #expect(periodAsCategory == false)

            let decider = FakeRevenueRecognitionColumnDecider(selected: "t0_c2", confidence: 0.97)
            let (snapshot, _, audit) = await BusinessBreakdownResolver.resolve(
                segments: extracted, consolidatedSales: 102 * Financial.millionYen,
                client: UnavailableChatClient(), columnDecider: decider,
                fiscalYearEnd: "2026-03-31", docID: "S100YKOI")
            #expect(snapshot?.rows.contains { $0.rowKind == "segment" } != true)
            let tag = try #require(
                BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir))
            #expect(BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                snapshot: snapshot, dedicatedTagText: tag))
            #expect(!BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                snapshot: snapshot, dedicatedTagText: nil))
            let dropped = BreakdownSnapshot(
                axis: breakdownAxisProductService, denominator: 102 * Financial.millionYen,
                denominatorTag: "llm_table_subtotal", rows: [], sourceKind: "revenue_recognition",
                needsReview: true,
                warnings: [
                    RevenueRecognitionColumnNormalizer.warningNoCategoryRows,
                    RevenueRecognitionColumnNormalizer.warningParallelDimensions,
                    RevenueRecognitionColumnNormalizer.warningCategoryRowsDropped,
                ])
            #expect(!BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                snapshot: dropped, dedicatedTagText: tag))
            let outcome = SegmentNoteDecision.dedicatedTagBusinessOutcome(
                docID: "S100YKOI", tagText: tag)
            #expect(outcome.omissionReason == breakdownNotApplicableSingleSegmentDisclosed)
            #expect(outcome.audit?.decisionSource == SegmentNoteDecision.dedicatedTagDecisionSource)
            #expect(outcome.audit?.calls.isEmpty == true)
            #expect(audit?.columnJev?.calls.first?.selected == "t0_c2"
                || audit?.jev?.calls.first?.selected == "t0_c2")
        }
    }

    /// 8771 S100R95J: 単一セグメント専用タグがあっても製品行がある表は残す（意図した変更）。
    @Test func r95j8771ProductRowsKeptDespiteDedicatedSingleSegmentTag() async throws {
        let tagText = "当社グループは単一セグメントであるため、記載を省略しております。"
        let xml = XBRLTestSupport.makeXbrlDuration(
            """
            <jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment contextRef="CurrentYearDuration">\(tagText)</jpcrp_cor:DescriptionOfFactThatCompanysBusinessComprisesSingleSegment>
            """)
        let html = """
            <p>当連結会計年度（自 2023年4月1日 至 2024年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>当連結会計年度</td></tr>
              <tr><td>事業法人向け保証サービス</td><td>80</td></tr>
              <tr><td>金融法人向け保証サービス</td><td>20</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>100</td></tr>
            </table>
            """
        try await XBRLTestSupport.withXbrlDir(xml) { dir in
            let extracted = ExtractedBreakdown(
                method: "html_table",
                tables: BreakdownExtractor.allTablesFromHtml(
                    html, defaultHeading: BreakdownExtractor.revenueRecognitionHeading),
                facts: [])
            let decider = FakeRevenueRecognitionColumnDecider(selected: "t0_c1", confidence: 0.97)
            let (snapshot, _, _) = await BusinessBreakdownResolver.resolve(
                segments: extracted, consolidatedSales: 100 * Financial.millionYen,
                client: UnavailableChatClient(), columnDecider: decider,
                fiscalYearEnd: "2024-03-31", docID: "S100R95J")
            let row = try #require(snapshot)
            let tag = try #require(
                BreakdownExtractor.dedicatedSingleSegmentDisclosureText(xbrlDir: dir))
            #expect(!BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
                snapshot: row, dedicatedTagText: tag))
            let segments = row.rows.filter { $0.rowKind == "segment" }
            let segmentCount: Int = segments.count
            let corporate: Bool = hasRow(
                segments, group: "事業法人向け保証サービス", nilCategory: true, amount: yen(80))
            let finance: Bool = hasRow(
                segments, group: "金融法人向け保証サービス", nilCategory: true, amount: yen(20))
            let needsReview: Bool = row.needsReview
            #expect(segmentCount == 2)
            #expect(corporate)
            #expect(finance)
            #expect(needsReview == false)
        }
    }

    /// 2467 S100YMA4: その他収益は「－」の調整末尾であり並行次元ではない。製品 4 行。
    @Test func yma42467OtherRevenueIsNotParallelCloser() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>サイバートレーニングソリューション</td><td>485,325</td><td>389,248</td></tr>
              <tr><td>セキュリティ診断・調査ソリューション</td><td>391,293</td><td>438,605</td></tr>
              <tr><td>セキュリティコンサルティングソリューション</td><td>590,022</td><td>537,970</td></tr>
              <tr><td>その他</td><td>138,442</td><td>－</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>1,605,082</td><td>1,365,823</td></tr>
              <tr><td>その他収益</td><td>－</td><td>－</td></tr>
              <tr><td>外部顧客への売上高</td><td>1,605,082</td><td>1,365,823</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YMA4", fyEnd: "2026-03-31", pick: "t0_c2")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let segmentCount: Int = segments.count
        let names: [String] = [
            "サイバートレーニングソリューション", "セキュリティ診断・調査ソリューション",
            "セキュリティコンサルティングソリューション", "その他",
        ]
        #expect(segmentCount == 4)
        for name in names {
            let found: Bool = segments.contains {
                $0.category == name || $0.categoryGroup == name
            }
            #expect(found)
        }
        let cyber: Bool = hasRow(segments, label: "サイバートレーニングソリューション", amount: sen(389_248))
        let diag: Bool = hasRow(segments, label: "セキュリティ診断・調査ソリューション", amount: sen(438_605))
        let cons: Bool = hasRow(segments, label: "セキュリティコンサルティングソリューション", amount: sen(537_970))
        let other: Bool = segments.contains {
            ($0.category == "その他" || $0.categoryGroup == "その他") && $0.amount == 0
        }
        let otherRevenue: Bool = segments.contains { $0.label == "その他収益" }
        let kei: Bool = segments.contains { $0.label == "計" || $0.categoryGroup == "計" }
        let isOtherRevenueTotal: Bool = RevenueRecognitionCandidates.isTotalLabel("その他収益")
        let isOtherProductTotal: Bool = RevenueRecognitionCandidates.isTotalLabel("その他")
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(1_365_823)
        let needsReview: Bool = snapshot.needsReview
        let parallel: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningParallelDimensions)
        #expect(cyber)
        #expect(diag)
        #expect(cons)
        #expect(other)
        #expect(otherRevenue == false)
        #expect(kei == false)
        #expect(isOtherRevenueTotal)
        #expect(isOtherProductTotal == false)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
        #expect(parallel == false)
    }

    /// 6287 S100YE10: 時点ブロックと見出し無し製品ブロックが同じ 計 で閉じる。製品 2 行を残す。
    @Test func ye106287TimingBlockIsNotProductWhenParallel() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr>
                <td colspan="2">セグメント</td>
                <td>自動認識ソリューション事業（日本）</td>
                <td>自動認識ソリューション事業（海外）</td>
                <td>合 計</td>
              </tr>
              <tr><td colspan="2">主要な財又はサービスのライン</td><td></td><td></td><td></td></tr>
              <tr><td></td><td>メカトロ製品</td><td>36,769</td><td>29,683</td><td>66,453</td></tr>
              <tr><td></td><td>サプライ製品</td><td>48,269</td><td>48,712</td><td>96,981</td></tr>
              <tr><td></td><td>計</td><td>85,038</td><td>78,396</td><td>163,434</td></tr>
              <tr><td colspan="2">収益認識の時期</td><td></td><td></td><td></td></tr>
              <tr><td></td><td>一時点で移転される財又はサービス</td><td>77,021</td><td>76,294</td><td>153,316</td></tr>
              <tr><td></td><td>一定の期間にわたり移転される財又はサービス</td><td>8,016</td><td>2,101</td><td>10,118</td></tr>
              <tr><td></td><td>計</td><td>85,038</td><td>78,396</td><td>163,434</td></tr>
              <tr><td colspan="2">外部顧客への売上高</td><td>85,038</td><td>78,396</td><td>163,434</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YE10", fyEnd: "2026-03-31", pick: "t0_c4")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let segmentCount: Int = segments.count
        let mechatro: Bool = hasRow(segments, label: "メカトロ製品", amount: yen(66_453))
        let supply: Bool = hasRow(segments, label: "サプライ製品", amount: yen(96_981))
        let timing: Bool = segments.contains { $0.label?.contains("一時点") == true }
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(163_434)
        let needsReview: Bool = snapshot.needsReview
        let parallel: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningParallelDimensions)
        #expect(segmentCount == 2)
        #expect(mechatro)
        #expect(supply)
        #expect(timing == false)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
        #expect(parallel == false)
    }

    /// 7050: 一時点ラベルにサービスが含まれるが時点軸。顧客/時点だけの表は needs_review。
    @Test func ysv97050TimingOnlyAxisNeedsReview() async throws {
        let html = """
            <p>当連結会計年度（自 2025年5月1日 至 2026年4月30日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>プロモーション事業</td></tr>
              <tr><td>一時点で移転される財又はサービス</td><td>27,880,877</td></tr>
              <tr><td>一定の期間にわたり移転される財又はサービス</td><td>2,067,725</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>29,948,603</td></tr>
              <tr><td>その他の収益</td><td>－</td></tr>
              <tr><td>外部顧客への売上高</td><td>29,948,603</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        let constraint: RevenueRecognitionTableStructure.AxisConstraint =
            RevenueRecognitionTableStructure.axisConstraint(tables: parsed)
        let timingWins: Bool = RevenueRecognitionTableStructure.isTimingAxisLabel(
            "一時点で移転される財又はサービス")
        let notProduct: Bool = RevenueRecognitionTableStructure.isProductAxisLabel(
            "一時点で移転される財又はサービス")
        #expect(axis == .timing)
        #expect(constraint == .customerOrTimingOnly)
        #expect(timingWins)
        #expect(notProduct == false)
        let snapshot = try await run(html: html, docID: "S100YSV9", fyEnd: "2026-04-30", pick: "t0_c1")
        let needsReview: Bool = snapshot.needsReview
        let axisWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningCustomerOrTimingAxis)
        #expect(needsReview)
        #expect(axisWarning)
    }

    /// 7096 S100YI32: 時期別の区分だけ。表選択の確率を外しても軸チェックで止める。
    @Test func yi327096TimingOnlyAxisNeedsReview() async throws {
        let html = """
            <table><tr><td>（単位：千円）</td></tr></table>
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <table>
              <tr><td></td><td>当期</td></tr>
              <tr><td>一時点で移転される財又はサービス</td><td>2,269,035</td></tr>
              <tr><td>一定の期間にわたり移転される財又はサービス</td><td>542,308</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>2,811,343</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let data = try #require(parsed.first { !$0.items.isEmpty } ?? parsed.last)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: data)
        let constraint: RevenueRecognitionTableStructure.AxisConstraint =
            RevenueRecognitionTableStructure.axisConstraint(tables: parsed)
        #expect(axis == .timing)
        #expect(constraint == .customerOrTimingOnly)
        let snapshot = try await run(
            html: html, docID: "S100YI32", fyEnd: "2026-03-31", pick: "t0_c1")
        let needsReview: Bool = snapshot.needsReview
        let axisWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningCustomerOrTimingAxis)
        #expect(needsReview)
        #expect(axisWarning)
    }

    /// 2224 S100YICN: 販売経路別の行。表選択を外しても顧客軸として残し needs_review。
    @Test func yicn2224SalesChannelAxisNeedsReview() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <table>
              <tr><td>主たる販売経路</td><td>金額（千円）</td></tr>
              <tr><td>生活協同組合</td><td>2,471,069</td></tr>
              <tr><td>自動販売機オペレーター</td><td>1,844,578</td></tr>
              <tr><td>量販店</td><td>980,838</td></tr>
              <tr><td>卸問屋</td><td>648,023</td></tr>
              <tr><td>その他</td><td>1,379,243</td></tr>
              <tr><td>合計</td><td>7,323,751</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        let constraint: RevenueRecognitionTableStructure.AxisConstraint =
            RevenueRecognitionTableStructure.axisConstraint(tables: parsed)
        #expect(axis == .customer)
        #expect(constraint == .customerOrTimingOnly)
        let snapshot = try await run(
            html: html, docID: "S100YICN", fyEnd: "2026-03-31", pick: "t0_c1")
        let needsReview: Bool = snapshot.needsReview
        let axisWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningCustomerOrTimingAxis)
        #expect(needsReview)
        #expect(axisWarning)
    }

    /// 7377 S100Z4Q1: 官公庁・民間の顧客区分。表選択を外しても顧客軸として残し needs_review。
    @Test func z4q17377GovernmentCustomerAxisNeedsReview() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>金額</td></tr>
              <tr><td>国内</td><td></td></tr>
              <tr><td>中央省庁</td><td>13,610,272</td></tr>
              <tr><td>地方自治体</td><td>12,103,821</td></tr>
              <tr><td>高速道路会社</td><td>3,047,854</td></tr>
              <tr><td>電力関連会社</td><td>3,561,442</td></tr>
              <tr><td>民間その他</td><td>5,481,387</td></tr>
              <tr><td>海外</td><td>259,495</td></tr>
              <tr><td>合計</td><td>38,064,271</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        let constraint: RevenueRecognitionTableStructure.AxisConstraint =
            RevenueRecognitionTableStructure.axisConstraint(tables: parsed)
        #expect(axis == .customer)
        #expect(constraint == .customerOrTimingOnly)
        let snapshot = try await run(
            html: html, docID: "S100Z4Q1", fyEnd: "2026-03-31", pick: "t0_c1")
        let needsReview: Bool = snapshot.needsReview
        let axisWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningCustomerOrTimingAxis)
        #expect(needsReview)
        #expect(axisWarning)
    }

    /// 6620 S100R5UA: 付随収入 1 行 7,000 千円 vs 連結売上 1.319e9。表合計が無く
    /// table_sum_mismatch は沈黙するので、分母カバー不足で needs_review。
    @Test func r5ua6620UndercoverageVsDenominatorNeedsReview() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>金額</td></tr>
              <tr><td>不動産賃貸管理事業に付随する収入</td><td>7,000</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t0_c1", confidence: 0.9)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 1_319_000_000, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100R5UA")
        let row = try #require(snapshot)
        let needsReview: Bool = row.needsReview
        let undercoverage: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningDenominatorUndercoverage)
        let mismatch: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningTableSumMismatch)
        let emitted: Double = row.rows.filter { $0.rowKind == "segment" }.reduce(0) { $0 + $1.amount }
        #expect(needsReview)
        #expect(undercoverage)
        #expect(mismatch == false)
        #expect(emitted == sen(7_000))
        #expect(row.denominator == 1_319_000_000)
        #expect(row.warnings.contains(RevenueRecognitionColumnNormalizer.warningSingleRowTable))
        #expect(
            isPubliclyInsufficientRevenueRecognition(
                segmentCount: 1, emittedSum: emitted))
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceRevenueRecognitionLLM, needsReview: row.needsReview,
                warnings: row.warnings)
                == false)
    }

    /// 6620 S100YJZT 本番 filing_sections の当期表（表選択後に ColumnNormalizer へ渡る入力）。
    /// 付随収入 0、その他の収益（注）391、外部顧客 391（百万円）。ゴールデンが closers を
    /// 落としていたので grid 免除が沈黙し、本番はカバー床を跳ねていた。
    @Test func yjzt6620ProductionCurrentTableNeedsReview() async throws {
        let markdown = """
            |                  | 営業収益 |
            |------------------|------|
            | 不動産賃貸管理事業に付随する収入 | 0    |
            | 顧客との契約から生じる収益    | 0    |
            | その他の収益（注）        | 391  |
            | 外部顧客への売上高        | 391  |
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(
                    heading: BreakdownExtractor.revenueRecognitionHeading,
                    markdown: markdown, period: "当期", unitCaption: "百万円")
            ],
            facts: [])
        let parsed = try #require(RevenueRecognitionCandidates.parse(tables: extracted.tables).first)
        #expect(RevenueRecognitionColumnNormalizer.hasRecognizedOtherRevenue(parsed) == false)
        let itemLabels: [String] = parsed.items.map(\.label)
        #expect(itemLabels == ["不動産賃貸管理事業に付随する収入"])
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t0_c1", confidence: 0.85)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 391_000_000, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100YJZT")
        let row = try #require(snapshot)
        let needsReview: Bool = row.needsReview
        let undercoverage: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningDenominatorUndercoverage)
        let singleRow: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningSingleRowTable)
        let zeroSum: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningZeroEmittedSum)
        let emitted: Double = row.rows.filter { $0.rowKind == "segment" }.reduce(0) { $0 + $1.amount }
        #expect(needsReview)
        #expect(undercoverage)
        #expect(singleRow)
        #expect(zeroSum)
        #expect(emitted == 0)
        #expect(row.denominator == 391_000_000)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceRevenueRecognitionLLM, needsReview: false, warnings: [],
                rows: [
                    BreakdownRowPayload(
                        labelRaw: "不動産賃貸管理事業に付随する収入",
                        label: "不動産賃貸管理事業に付随する収入", amount: 0, profit: nil,
                        rowKind: "segment")
                ]) == false)
    }

    /// 6620 S100TUOL 相当。W6EQ 前期表として本番に残っている markdown（付随収入 7、外部顧客 1,137）。
    @Test func tuol6620ProductionShapedTableNeedsReview() async throws {
        let markdown = """
            |                  | 営業収益  |
            |------------------|-------|
            | 不動産賃貸管理事業に付随する収入 | 7     |
            | 顧客との契約から生じる収益    | 7     |
            | その他の収益（注）        | 1,130 |
            | 外部顧客への売上高        | 1,137 |
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: [
                BreakdownTable(
                    heading: BreakdownExtractor.revenueRecognitionHeading,
                    markdown: markdown, period: "当期", unitCaption: "百万円")
            ],
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t0_c1", confidence: 0.82)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 1_137_000_000, decider: decider,
            fiscalYearEnd: "2024-03-31", docID: "S100TUOL")
        let row = try #require(snapshot)
        let needsReview: Bool = row.needsReview
        let undercoverage: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningDenominatorUndercoverage)
        let singleRow: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningSingleRowTable)
        let emitted: Double = row.rows.filter { $0.rowKind == "segment" }.reduce(0) { $0 + $1.amount }
        #expect(needsReview)
        #expect(undercoverage)
        #expect(singleRow)
        #expect(emitted == yen(7))
        #expect(row.denominator == yen(1_137))
    }

    /// 金額 0 の単一行はカバー床が無くても公開しない。
    @Test func zeroAmountSingleRowTableNeedsReviewAndIsNotPublic() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>金額</td></tr>
              <tr><td>不動産賃貸管理事業に付随する収入</td><td>0</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t0_c1", confidence: 0.9)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: 391_000_000, decider: decider,
            fiscalYearEnd: "2026-03-31", docID: "S100ZERO")
        let row = try #require(snapshot)
        let needsReview: Bool = row.needsReview
        let singleRow: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningSingleRowTable)
        let zeroSum: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningZeroEmittedSum)
        let emitted: Double = row.rows.filter { $0.rowKind == "segment" }.reduce(0) { $0 + $1.amount }
        #expect(needsReview)
        #expect(singleRow)
        #expect(zeroSum)
        #expect(emitted == 0)
        #expect(
            isPubliclyInsufficientRevenueRecognition(segmentCount: 1, emittedSum: 0))
    }

    /// 6273 S100YLC6: 仕向地別の日本/米国/中国/アジア(中国を除く)/欧州。事業軸に出さない。
    @Test func ylc66273GeographyOnlyRowsNeedReview() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>仕向地別売上高</td><td></td><td></td></tr>
              <tr><td>日本</td><td>158,116</td><td>158,823</td></tr>
              <tr><td>米国</td><td>88,937</td><td>83,708</td></tr>
              <tr><td>中国</td><td>208,690</td><td>234,939</td></tr>
              <tr><td>アジア(中国を除く)</td><td>151,612</td><td>158,955</td></tr>
              <tr><td>欧州</td><td>144,414</td><td>162,250</td></tr>
              <tr><td>その他</td><td>40,336</td><td>43,864</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>792,108</td><td>842,541</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        let constraint: RevenueRecognitionTableStructure.AxisConstraint =
            RevenueRecognitionTableStructure.axisConstraint(tables: parsed)
        #expect(axis == .geography)
        #expect(constraint == .geographyOnly)
        let snapshot = try await run(
            html: html, docID: "S100YLC6", fyEnd: "2026-03-31", pick: "t0_c2")
        let needsReview: Bool = snapshot.needsReview
        let geoWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningGeographyAxisOnly)
        #expect(needsReview)
        #expect(geoWarning)
    }

    /// FANUC 型: 「アジア（中国以外）」が地域ラベルとして残る。事業軸に出さない。
    @Test func asiaExcludingChinaWithIgaiIsGeographyAxis() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>当連結会計年度</td></tr>
              <tr><td>国内</td><td>110,782</td></tr>
              <tr><td>中国</td><td>171,598</td></tr>
              <tr><td>アジア（中国以外）</td><td>80,000</td></tr>
              <tr><td>米州</td><td>199,448</td></tr>
              <tr><td>欧州</td><td>152,371</td></tr>
              <tr><td>その他</td><td>10,000</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>724,199</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        #expect(axis == .geography)
        let snapshot = try await run(
            html: html, docID: "S100YG3Q", fyEnd: "2026-03-31", pick: "t0_c1")
        #expect(snapshot.needsReview)
        #expect(
            snapshot.warnings.contains(RevenueRecognitionColumnNormalizer.warningGeographyAxisOnly)
                || snapshot.warnings.contains(
                    SegmentInfoPublishGuards.warningGeographyWhileProductExists))
    }

    /// アステラス型: 収益の種類（医薬品の販売 / プロフィットシェア）を事業内訳にしない。
    @Test func revenueTypeCategoriesNeedReview() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>当連結会計年度</td></tr>
              <tr><td>医薬品の販売</td><td>1,800,000</td></tr>
              <tr><td>プロフィットシェア収入</td><td>109,487</td></tr>
              <tr><td>その他</td><td>50,000</td></tr>
              <tr><td>合計</td><td>1,959,487</td></tr>
            </table>
            """
        let snapshot = try await run(
            html: html, docID: "S100YBPK", fyEnd: "2026-03-31", pick: "t0_c1")
        #expect(snapshot.needsReview)
        #expect(snapshot.warnings.contains(SegmentInfoPublishGuards.warningRevenueTypeCategories))
    }

    /// 6532 S100VTPA: 金融 / 情報通信・メディア・ハイテクは顧客業種。公開しない。
    @Test func vtpa6532CustomerIndustryAxisNeedsReview() async throws {
        let html = """
            <p>当連結会計年度（自 2024年3月1日 至 2025年2月28日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>前事業年度</td><td>当連結会計年度</td></tr>
              <tr><td>金融(銀行・証券・保険等)</td><td>24,702</td><td>33,870</td></tr>
              <tr><td>情報通信・メディア・ハイテク</td><td>29,506</td><td>37,127</td></tr>
              <tr><td>その他</td><td>39,701</td><td>45,059</td></tr>
              <tr><td>合計</td><td>93,909</td><td>116,056</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        #expect(axis == .customer)
        let snapshot = try await run(
            html: html, docID: "S100VTPA", fyEnd: "2025-02-28", pick: "t0_c2")
        let needsReview: Bool = snapshot.needsReview
        let axisWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningCustomerOrTimingAxis)
        #expect(needsReview)
        #expect(axisWarning)
    }

    /// 3538 S100P7P6: 業販と新車/中古車が混在。顧客軸として needs_review（当期未検証でも止める）。
    @Test func p7p63538MixedChannelProductNeedsReview() async throws {
        let html = """
            <p>前連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>金額</td></tr>
              <tr><td>車輌販売</td><td></td></tr>
              <tr><td>新車</td><td>19,576,333</td></tr>
              <tr><td>中古車</td><td>11,009,224</td></tr>
              <tr><td>業販</td><td>3,605,008</td></tr>
              <tr><td>車輌整備</td><td>5,058,873</td></tr>
              <tr><td>その他</td><td>446,719</td></tr>
              <tr><td>合計</td><td>39,696,157</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        #expect(axis == .customer)
        let snapshot = try await run(
            html: html, docID: "S100P7P6", fyEnd: "2025-03-31", pick: "t0_c1")
        let needsReview: Bool = snapshot.needsReview
        let axisWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningCustomerOrTimingAxis)
        let priorWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningPriorPeriod)
        #expect(needsReview)
        #expect(axisWarning)
        #expect(priorWarning)
    }

    /// 9517 S100OHPV: 電力小売/卸売は販路。当期表を原本で確認できないときも公開しない。
    @Test func ohpv9517WholesaleRetailChannelNeedsReview() async throws {
        let html = """
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>金額</td></tr>
              <tr><td>電力小売</td><td>93,890</td></tr>
              <tr><td>電力卸売</td><td>133,308</td></tr>
              <tr><td>その他</td><td>3,302</td></tr>
              <tr><td>合計</td><td>230,500</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let parsed = RevenueRecognitionCandidates.parse(tables: extracted.tables)
        let axis: RevenueRecognitionTableStructure.TableAxis =
            RevenueRecognitionTableStructure.tableAxis(of: parsed[0])
        #expect(axis == .customer)
        let snapshot = try await run(
            html: html, docID: "S100OHPV", fyEnd: "2026-03-31", pick: "t0_c1")
        let needsReview: Bool = snapshot.needsReview
        let axisWarning: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningCustomerOrTimingAxis)
        #expect(needsReview)
        #expect(axisWarning)
    }

    /// 7464 S100YJG0: 品目別 5 行。表選択 0.73 相当でも列選択と合計で出す。
    @Test func yjg07464ProductRowsAreAdopted() async throws {
        let cats = ["標識・標示板", "安全機材", "保安警告サイン", "安全防災用品", "その他"]
        let amounts = [1_377_658, 578_768, 643_259, 832_457, 1_073_255]
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：千円）</p>
            <table>
              <tr><td></td><td>金額</td></tr>
              <tr><td>（品目別）</td><td></td></tr>
              <tr><td>標識・標示板</td><td>1,377,658</td></tr>
              <tr><td>安全機材</td><td>578,768</td></tr>
              <tr><td>保安警告サイン</td><td>643,259</td></tr>
              <tr><td>安全防災用品</td><td>832,457</td></tr>
              <tr><td>その他</td><td>1,073,255</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>4,505,397</td></tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YJG0", fyEnd: "2026-03-31", pick: "t0_c1")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let segmentCount: Int = segments.count
        #expect(segmentCount == 5)
        for (index, name) in cats.enumerated() {
            let row = segments[index]
            let group: String? = row.categoryGroup
            let category: String? = row.category
            let amount: Double = row.amount
            let expectedAmount: Double = sen(amounts[index])
            #expect(group == "（品目別）")
            #expect(category == name)
            #expect(amount == expectedAmount)
        }
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(4_505_397)
        let needsReview: Bool = snapshot.needsReview
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
    }

    /// 332A S100YKM2: 単位スタブ表 + 品目 2 行。表選択 0.88 相当でも出す。
    @Test func ykm2332AProductRowsAreAdopted() async throws {
        let html = """
            <table><tr><td>（単位：千円）</td></tr></table>
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>IoT/DXプラットフォームサービス</td><td>1,800,000</td><td>2,030,053</td></tr>
              <tr><td>MVNEサービス</td><td>4,800,000</td><td>5,120,400</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>6,600,000</td><td>7,150,453</td></tr>
            </table>
            """
        let snapshot = try await run(
            html: html, docID: "S100YKM2", fyEnd: "2026-03-31", pick: "t0_c2")
        try assertFlatRows(
            snapshot,
            groups: ["IoT/DXプラットフォームサービス", "MVNEサービス"],
            amounts: [2_030_053, 5_120_400],
            unit: 1_000)
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(7_150_453)
        let needsReview: Bool = snapshot.needsReview
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
    }

    /// 2139 S100YHNL: 金額セル接尾辞の千円。表選択 0.68 相当でも出す。
    @Test func yhnl2139ProductRowsAreAdopted() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <table>
              <tr><td></td><td>前連結会計年度</td><td>当連結会計年度</td></tr>
              <tr><td>自社メディア広告</td><td>6,553,546千円</td><td>6,693,644千円</td></tr>
              <tr><td>セールスプロモーション等</td><td>5,000,000千円</td><td>5,280,268千円</td></tr>
              <tr><td>その他</td><td>150,000千円</td><td>179,516千円</td></tr>
              <tr><td>顧客との契約から生じる収益</td><td>11,703,546千円</td><td>12,153,428千円</td></tr>
            </table>
            """
        let snapshot = try await run(
            html: html, docID: "S100YHNL", fyEnd: "2026-03-31", pick: "t0_c2")
        try assertFlatRows(
            snapshot,
            groups: ["自社メディア広告", "セールスプロモーション等", "その他"],
            amounts: [6_693_644, 5_280_268, 179_516],
            unit: 1_000)
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(12_153_428)
        let needsReview: Bool = snapshot.needsReview
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
    }

    /// 4519 S100XTBJ: 製商品売上高と日本/海外、その他の売上収益とその内訳は親子。子だけ出す。
    @Test func xtbj4519ParentFollowedByChildrenEmitsChildren() async throws {
        let html = """
            <p>当連結会計年度（自 2025年1月1日 至 2025年12月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>合計</td></tr>
              <tr><td>製商品売上高</td><td>1,077,803</td></tr>
              <tr><td>日本</td><td>472,365</td></tr>
              <tr><td>海外</td><td>605,437</td></tr>
              <tr><td>その他の売上収益</td><td>180,138</td></tr>
              <tr><td>ロイヤルティ及びプロフィットシェア収入</td><td>172,679</td></tr>
              <tr><td>その他の営業収入</td><td>7,460</td></tr>
            </table>
            """
        let extracted = ExtractedBreakdown(
            method: "html_table",
            tables: BreakdownExtractor.allTablesFromHtml(html, defaultHeading: "収益認識関係"),
            facts: [])
        let decider = FakeRevenueRecognitionColumnDecider(selected: "t0_c1", confidence: 0.9)
        let (snapshot, _) = await RevenueRecognitionColumnNormalizer.normalize(
            extracted, consolidatedSales: yen(1_257_941), decider: decider,
            fiscalYearEnd: "2025-12-31", docID: "S100XTBJ")
        let row = try #require(snapshot)
        let segments = row.rows.filter { $0.rowKind == "segment" }
        let labels: [String] = segments.compactMap(\.label)
        let japan: Bool = hasRow(segments, label: "日本", amount: yen(472_365))
        let overseas: Bool = hasRow(segments, label: "海外", amount: yen(605_437))
        let royalty: Bool = hasRow(segments, label: "ロイヤルティ及びプロフィットシェア収入", amount: yen(172_679))
        let otherIncome: Bool = hasRow(segments, label: "その他の営業収入", amount: yen(7_460))
        let parentGoods: Bool = segments.contains { $0.label == "製商品売上高" }
        let parentOther: Bool = segments.contains { $0.label == "その他の売上収益" }
        let segmentCount: Int = segments.count
        let needsReview: Bool = row.needsReview
        let mismatch: Bool = row.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningTableSumMismatch)
        #expect(segmentCount == 4)
        #expect(japan)
        #expect(overseas)
        #expect(royalty)
        #expect(otherIncome)
        #expect(parentGoods == false)
        #expect(parentOther == false)
        #expect(labels.contains("日本"))
        #expect(needsReview == false)
        #expect(mismatch == false)
    }

    @Test func emittedSumExceedingDenominatorSetsTableSumMismatch() {
        let rows: [RevenueRecognitionCandidates.BuiltRow] = [
            .init(categoryGroup: "製商品売上高", category: nil, amount: 1_077_803, isPartial: false, rowKind: "segment"),
            .init(categoryGroup: "日本", category: nil, amount: 472_365, isPartial: false, rowKind: "segment"),
            .init(categoryGroup: "海外", category: nil, amount: 605_437, isPartial: false, rowKind: "segment"),
        ]
        let exceeds: Bool = RevenueRecognitionCandidates.emittedSumExceedsCap(
            rows, cap: 1_257_941)
        let collapsed = RevenueRecognitionCandidates.collapseParentChildRows(rows)
        let collapsedCount: Int = collapsed.count
        let collapsedExceeds: Bool = RevenueRecognitionCandidates.emittedSumExceedsCap(
            collapsed, cap: 1_257_941)
        #expect(exceeds)
        #expect(collapsedCount == 2)
        #expect(collapsedExceeds == false)
    }

    /// 6140: 列見出しの単位キャプションは結合しない。
    @Test func yjmm6140UnitCaptionIsDroppedFromHeaderJoin() async throws {
        let joined: String = RevenueRecognitionCandidates.joinHeaderParts(
            ["(単位：百万円)", "その他"])
        let stubAndUnit: String = RevenueRecognitionCandidates.joinHeaderParts(
            ["業界の名称", "(単位：百万円)", "電子・半導体"])
        #expect(joined == "その他")
        #expect(stubAndUnit == "電子・半導体")
        #expect(RevenueRecognitionCandidates.isUnitCaptionHeader("(単位：百万円)"))
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td></td><td></td><td></td><td></td><td colspan="2">(単位：百万円)</td></tr>
              <tr><td rowspan="2"></td><td colspan="5">業界の名称</td><td rowspan="2">合計</td></tr>
              <tr>
                <td>電子・半導体</td><td>輸送機器</td><td>機械</td>
                <td>石材・建設</td><td>その他</td>
              </tr>
              <tr>
                <td>売上高</td><td>16,978</td><td>9,632</td><td>10,373</td>
                <td>3,885</td><td>1,113</td><td>41,983</td>
              </tr>
            </table>
            """
        let snapshot = try await run(html: html, docID: "S100YJMM", fyEnd: "2026-03-31", pick: "t0_c6")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let leaked: Bool = segments.contains { ($0.label ?? "").contains("単位") }
        let other: Bool = segments.contains { $0.label == "その他" || $0.categoryGroup == "その他" }
        #expect(leaked == false)
        #expect(other)
    }


    /// 5936 S100YKHR: 品種別ブロックを製品軸として残し、地域ブロックは加算しない。
    @Test func ykhr5936ProductKindBlockIsBusinessDimension() async throws {
        let html = """
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <p>（単位：百万円）</p>
            <table>
              <tr><td></td><td>当連結会計年度</td></tr>
              <tr><td>品種別</td><td></td></tr>
              <tr><td>甲</td><td>10</td></tr>
              <tr><td>乙</td><td>20</td></tr>
              <tr><td>丙</td><td>15</td></tr>
              <tr><td>丁</td><td>12</td></tr>
              <tr><td>戊</td><td>8</td></tr>
              <tr><td>己</td><td>7</td></tr>
              <tr><td>庚</td><td>6</td></tr>
              <tr><td>辛</td><td>5</td></tr>
              <tr><td>外部顧客への売上高</td><td>83</td></tr>
              <tr><td>地域別</td><td></td></tr>
              <tr><td>日本</td><td>50</td></tr>
              <tr><td>海外</td><td>33</td></tr>
              <tr><td>外部顧客への売上高</td><td>83</td></tr>
            </table>
            """
        let heading: Bool = RevenueRecognitionTableStructure.isProductOrBusinessHeading("品種別")
        #expect(heading)
        let snapshot = try await run(html: html, docID: "S100YKHR", fyEnd: "2026-03-31", pick: "t0_c1")
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let segmentCount: Int = segments.count
        let names: [String] = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛"]
        #expect(segmentCount == 8)
        for name in names {
            let found: Bool = segments.contains {
                $0.category == name || $0.categoryGroup == name
            }
            #expect(found)
        }
        let japan: Bool = segments.contains { $0.label == "日本" }
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(83)
        let needsReview: Bool = snapshot.needsReview
        #expect(japan == false)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
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
        #expect(audit?.columnJev?.calls.first?.selected == RevenueRecognitionColumnNormalizer.noneOfThese)
        #expect(audit?.columnJev != nil)
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
        let needsReview: Bool = snapshot.needsReview
        let singleRow: Bool = snapshot.warnings.contains(
            RevenueRecognitionColumnNormalizer.warningSingleRowTable)
        #expect(needsReview)
        #expect(singleRow)
        let segments = snapshot.rows.filter { $0.rowKind == "segment" }
        let segmentCount: Int = segments.count
        #expect(segmentCount == 1)
        #expect(snapshot.rows[0].categoryGroup == "海外")
        #expect(snapshot.rows[0].category == nil)
        let overseas: Double = snapshot.rows[0].amount
        let expectedOverseas: Double = yen(1_000)
        #expect(overseas == expectedOverseas)
        let china: Bool = snapshot.rows.contains { $0.category == "うち中国" }
        #expect(china == false)
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
        #expect(snapshot.needsReview == false)
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(18_358_123)
        #expect(denominator == expectedDenom)
        let totalAsRow: Bool = snapshot.rows.contains { $0.label == "顧客との契約から生じる収益" }
        #expect(totalAsRow == false)
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
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(42_192_309)
        let totalAsRow: Bool = snapshot.rows.contains { $0.label == "外部顧客に対する売上高" }
        #expect(denominator == expectedDenom)
        #expect(totalAsRow == false)
        #expect(snapshot.needsReview == false)
        #expect(RevenueRecognitionCandidates.isTotalLabel("外部顧客に対する売上高"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("外部顧客への収益"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("小計"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("売上高"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("（小計）"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("計"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("その他の収益"))
        #expect(RevenueRecognitionCandidates.isTotalLabel("その他収益"))
        #expect(!RevenueRecognitionCandidates.isTotalLabel("自動車分野計"))
        #expect(RevenueRecognitionCandidates.isGroupSubtotalLabel("自動車分野計"))
        #expect(RevenueRecognitionCandidates.groupNameFromSubtotal("自動車分野計") == "自動車分野")
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
        let zozo: Bool = hasRow(
            segments, group: "ZOZOTOWN事業", nilCategory: true, amount: yen(157_416))
        let buy: Bool = hasRow(segments, category: "（買取・製造販売）", amount: yen(2_630))
        let consigned: Bool = hasRow(segments, category: "（受託販売）", amount: yen(134_673))
        let used: Bool = hasRow(segments, category: "（USED販売）", amount: yen(20_113))
        let yahoo: Bool = hasRow(segments, group: "LINEヤフーコマース", nilCategory: true)
        let parenAsGroup: Bool = hasRow(segments, group: "（買取・製造販売）", nilCategory: true)
        let segmentSum: Double = segments.reduce(0) { $0 + $1.amount }
        let expectedSum: Double = yen(228_371)
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = yen(228_373)
        let needsReview: Bool = snapshot.needsReview
        #expect(zozo == false)
        #expect(buy)
        #expect(consigned)
        #expect(used)
        #expect(yahoo)
        #expect(parenAsGroup == false)
        #expect(segmentSum == expectedSum)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
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
        let robot: Bool = grid.contains { $0.contains("ロボット") && $0.contains("14,947,321") }
        let custom: Bool = grid.contains { $0.contains("特注機") && $0.contains("3,161,936") }
        let parts: Bool = grid.contains { $0.contains("部品・保守サービス") && $0.contains("4,992,115") }
        let headingTakesAmount: Bool = grid.contains {
            $0.contains("製品及びサービス別") && $0.contains("14,947,321")
        }
        let robotTakesCustom: Bool = grid.contains { $0.contains("ロボット") && $0.contains("3,161,936") }
        #expect(robot)
        #expect(custom)
        #expect(parts)
        #expect(headingTakesAmount == false)
        #expect(robotTakesCustom == false)
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
        let labels: [String?] = segments.map(\.label)
        let expectedLabels: [String?] = ["ロボット", "特注機", "部品・保守サービス"]
        let groups: [String?] = segments.map(\.categoryGroup)
        let expectedGroups: [String?] = ["製品及びサービス別", "製品及びサービス別", "製品及びサービス別"]
        let categories: [String?] = segments.map(\.category)
        let expectedCategories: [String?] = ["ロボット", "特注機", "部品・保守サービス"]
        let amounts: [Double] = segments.map(\.amount)
        let expectedAmounts: [Double] = [sen(14_947_321), sen(3_161_936), sen(4_992_115)]
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(23_101_373)
        let needsReview: Bool = snapshot.needsReview
        let headingAsRow: Bool = snapshot.rows.contains { $0.label == "製品及びサービス別" }
        #expect(labels == expectedLabels)
        #expect(groups == expectedGroups)
        #expect(categories == expectedCategories)
        #expect(amounts == expectedAmounts)
        #expect(denominator == expectedDenom)
        #expect(needsReview == false)
        #expect(headingAsRow == false)
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
        let heavy: Bool = hasRow(snapshot.rows, label: "重衣料", amount: sen(15_047_573))
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(35_212_653)
        #expect(heavy)
        #expect(denominator == expectedDenom)
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
            code: "", docID: "S100YKKP", axis: breakdownAxisProductService, model: "typesafe/jev-1.13",
            threshold: 0.5, applied: true, needsReview: false, sentences: [],
            calls: [
                SegmentNoteJevCallPayload(
                    question: "col", options: ["t1_c1", "none_of_these"], selected: "t1_c1",
                    probability: 0.97, sentences: [], applied: true)
            ])
        let note = SegmentNoteJevAuditPayload(
            code: "", docID: "S100YKKP", axis: breakdownAxisProductService, model: "typesafe/jev-1.13",
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
        let noPartial: Bool = rows.allSatisfy { !$0.isPartial }
        let categories: Set<String?> = Set(rows.map(\.category))
        let expectedCategories: Set<String?> = ["関東", "関西"]
        let sumOff: Bool = RevenueRecognitionCandidates.sumMatches(700, subtotal: 1_000, itemCount: 2)
        let sumOn: Bool = RevenueRecognitionCandidates.sumMatches(998, subtotal: 1_000, itemCount: 2)
        #expect(noPartial)
        #expect(categories == expectedCategories)
        #expect(sumOff == false)
        #expect(sumOn)
    }

    @Test func stripNoteMarkerFromTotalAndDisplayLabelIsCategoryOrGroup() {
        #expect(RevenueRecognitionCandidates.stripNoteMarker("その他の収益（注）１") == "その他の収益")
        #expect(RevenueRecognitionCandidates.stripNoteMarker("タイヤ(注１)") == "タイヤ")
        #expect(RevenueRecognitionCandidates.stripNoteMarker("その他(注２)") == "その他")
        #expect(RevenueRecognitionCandidates.stripNoteMarker("その他の収入(注)") == "その他の収入")
        #expect(RevenueRecognitionCandidates.stripNoteMarker("その他の収入（注）") == "その他の収入")
        let header: String = RevenueRecognitionCandidates.joinHeaderParts(
            ["業界の名称", "電子・半導体"])
        #expect(header == "電子・半導体")
        #expect(RevenueRecognitionCandidates.isStubAxisHeader("業界の名称"))
        #expect(RevenueRecognitionCandidates.isStubAxisHeader("報告セグメント"))
        #expect(RevenueRecognitionCandidates.isStubAxisHeader("報告セグメント（耐火物関連事業）"))
        #expect(RevenueRecognitionCandidates.joinHeaderParts(["報告セグメント", "日本事業"]) == "日本事業")
        #expect(RevenueRecognitionCandidates.joinHeaderParts(["その他", "その他"]) == "その他")
        #expect(
            RevenueRecognitionCandidates.joinHeaderParts(
                ["みずほフィナンシャルグループ（連結）", "リテール・事業法人カンパニー"])
                == "リテール・事業法人カンパニー")
        #expect(
            RevenueRecognitionCandidates.joinHeaderParts(
                ["当連結会計年度", "建設機械・車両"])
                == "建設機械・車両")
        #expect(
            RevenueRecognitionCandidates.joinHeaderParts(
                ["北東アジア・欧州／米州・アジアパシフィック", "板紙"])
                == "板紙")
        let unitHeader: String = RevenueRecognitionCandidates.joinHeaderParts(
            ["(単位：百万円)", "その他"])
        #expect(unitHeader == "その他")
        let north: String = RevenueRecognitionCandidates.displayLabel(
            categoryGroup: "（海外）", category: "北米")
        let appliance: String = BreakdownRowPayload.displayLabel(
            categoryGroup: "（ディスカウントストア）", category: "家電製品")
        let oils: String = BreakdownRowPayload.displayLabel(
            categoryGroup: "油脂・乳製品", category: nil)
        #expect(north == "北米")
        #expect(appliance == "家電製品")
        #expect(oils == "油脂・乳製品")
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
        let labels: [String] = parsed.items.map(\.label)
        let expectedLabels: [String] = Self.cat7413
        #expect(labels == expectedLabels)
        #expect(parsed.groups.isEmpty)
        #expect(parsed.totals.map(\.label).contains("顧客との契約から生じる収益"))
        try assertFlatRows(snapshot, groups: Self.cat7413, amounts: amounts, unit: 1_000)
        let denominator: Double = snapshot.denominator
        let expectedDenom: Double = sen(total)
        #expect(denominator == expectedDenom)
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
            let rowGroup: String? = segments[index].categoryGroup
            let rowCategory: String? = segments[index].category
            let rowLabel: String? = segments[index].label
            let amount: Double = segments[index].amount
            let expectedAmount: Double = Double(amounts[index]) * unit
            #expect(rowGroup == group)
            #expect(rowCategory == nil)
            #expect(rowLabel == group)
            #expect(amount == expectedAmount)
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
