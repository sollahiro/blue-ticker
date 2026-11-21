import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct SegmentV3Tests {
    private func row(
        _ local: String, _ kind: String, amount: Double, decimals: Int? = nil, profit: Double? = nil
    ) -> BreakdownRow {
        BreakdownRow(
            labelRaw: local, label: local, amount: amount, share: nil, profit: profit,
            rowKind: kind, decimals: decimals)
    }

    private func payloadRow(
        _ local: String, _ kind: String, amount: Double, profit: Double? = nil
    ) -> BreakdownRowPayload {
        BreakdownRowPayload(
            labelRaw: local, label: local, amount: amount, profit: profit, rowKind: kind)
    }

    private func restatedPayload(
        key: String, value: Double, priorYear: Double? = nil
    ) -> BreakdownSnapshotPayload {
        var row = payloadRow("AMember", "segment", amount: value)
        row.segmentKey = key
        row.externalSales = BreakdownMetricCellPayload(
            value: value, basis: breakdownSourceXbrlFacts, source: "Sales", decimals: -6)
        if let priorYear {
            row.priorYearExternalSales = BreakdownMetricCellPayload(
                value: priorYear, basis: breakdownSourceXbrlFacts, source: "Sales", decimals: -6)
        }
        return BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: value, denominatorTag: "Sales",
            rows: [row], sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    @Test func sameKeyWithRestatedPriorValueBreaksTheLine() throws {
        let key = "E1:ext:AMember"
        let years: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)] = [
            ("2026-03-31", "D2", restatedPayload(key: key, value: 40_000_000_000, priorYear: 30_000_000_000)),
            ("2025-03-31", "D1", restatedPayload(key: key, value: 180_000_000_000)),
        ]
        let object = SegmentWaterfall.jsonObject(
            code: "9999", metric: segmentWaterfallMetricExternalSales, years: years)
        let newest = try #require((object["years"] as? [[String: Any]])?.first)
        #expect(newest[segmentWaterfallLineCutKey] as? Bool == true)
        let segment = try #require((newest[segmentWaterfallSegmentsKey] as? [[String: Any]])?.first)
        let prior = try #require(segment[segmentWaterfallPriorKey] as? [String: Any])
        #expect(prior["decision"] as? String == segmentTransitionDecisionBreak)
        #expect(prior["basis"] as? String == segmentTransitionMatchedRestated)
    }

    @Test func sameKeyWithMatchingPriorValueStaysConnected() throws {
        let key = "E1:ext:AMember"
        let years: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)] = [
            ("2026-03-31", "D2", restatedPayload(key: key, value: 40_000_000_000, priorYear: 180_000_000_000)),
            ("2025-03-31", "D1", restatedPayload(key: key, value: 180_000_000_000)),
        ]
        let object = SegmentWaterfall.jsonObject(
            code: "9999", metric: segmentWaterfallMetricExternalSales, years: years)
        let newest = try #require((object["years"] as? [[String: Any]])?.first)
        #expect(newest[segmentWaterfallLineCutKey] as? Bool == false)
        let segment = try #require((newest[segmentWaterfallSegmentsKey] as? [[String: Any]])?.first)
        let prior = try #require(segment[segmentWaterfallPriorKey] as? [String: Any])
        #expect(prior["decision"] as? String == segmentTransitionDecisionConnect)
    }

    @Test func priorYearColumnIsReadWithThisFilingsSegments() throws {
        func fact(_ ctx: String, _ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers", contextRef: ctx,
                dimensions: ["OperatingSegmentsAxis": member], value: value, decimals: "-6")
        }
        let facts = [
            fact("CurrentYearDuration_AMember", "AMember", 40),
            fact("Prior1YearDuration_AMember", "AMember", 30),
            fact("Prior1YearDuration_BMember", "BMember", 70),
        ]
        let snapshot = try #require(SegmentExternalSales.priorYear(facts: facts))
        let values = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.labelRaw, $0.amount) })
        #expect(values["AMember"] == 30)
        #expect(values["BMember"] == 70)
    }

    @Test func roundingGapIsOmittedFromDifferenceAndKeptRaw() throws {
        let sales = [
            row("AMember", "segment", amount: 936_926_000_000, decimals: -6),
            row("BMember", "segment", amount: 290_308_000_000, decimals: -6),
            row("CMember", "segment", amount: 341_504_000_000, decimals: -6),
            row("DMember", "segment", amount: 14_979_000_000, decimals: -6),
            row(Xbrl.entityTotalMemberName, breakdownRowKindEntityTotal,
                amount: 1_583_719_000_000, decimals: -6),
        ]
        let external = BreakdownSnapshot(
            axis: breakdownAxisSegment, denominator: 1_583_719_000_000,
            denominatorTag: "SalesToExternalCustomersIFRS", rows: sales,
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 1_583_719_000_000,
            denominatorTag: "NetSalesIFRS",
            rows: sales.dropLast().map {
                payloadRow($0.labelRaw, $0.rowKind, amount: $0.amount)
            },
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: external, edinetCode: "E00436", memberPrefixes: [:], labelsByTag: [:])
        #expect(assembled.rows.contains { $0.rowKind == breakdownRowKindDifference } == false)
        #expect(assembled.roundingGaps?[segmentCellExternalSales] == 2_000_000)
        let object = assembled.jsonObject()
        #expect(object["amount"] == nil)
        let gaps = try #require(object[segmentRoundingGapsKey] as? [String: Any])
        #expect((gaps[segmentCellExternalSales] as? NSNumber)?.int64Value == 2_000_000)
        let rows = try #require(object["rows"] as? [[String: Any]])
        #expect(rows.contains { $0["row_kind"] as? String == breakdownRowKindDifference } == false)
        let first = try #require(rows[0][segmentCellExternalSales] as? [String: Any])
        #expect((first["value"] as? NSNumber)?.int64Value == 936_926_000_000)
        #expect(first["decimals"] as? Int == -6)
        #expect(object[segmentSalesBasisKey] as? String == segmentSalesBasisExternal)
    }

    @Test func gapBeyondToleranceIsADifferenceRow() throws {
        let sales = [
            row("AMember", "segment", amount: 100, decimals: -6),
            row(Xbrl.entityTotalMemberName, breakdownRowKindEntityTotal, amount: 1_000_000,
                decimals: -6),
        ]
        let external = BreakdownSnapshot(
            axis: breakdownAxisSegment, denominator: 1_000_000,
            denominatorTag: "SalesToExternalCustomersIFRS", rows: sales,
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 1_000_000, denominatorTag: "NetSalesIFRS",
            rows: [payloadRow("AMember", "segment", amount: 100)],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: external, edinetCode: "E00001", memberPrefixes: [:], labelsByTag: [:])
        let difference = try #require(assembled.rows.first { $0.rowKind == breakdownRowKindDifference })
        #expect(difference.externalSales?.value == 999_900)
        #expect(assembled.roundingGaps == nil)
    }

    @Test func waterfallKeepsRoundingGapOffTheDifferenceRow() throws {
        let sales = [
            row("AMember", "segment", amount: 936_926_000_000, decimals: -6),
            row("BMember", "segment", amount: 290_308_000_000, decimals: -6),
            row("CMember", "segment", amount: 341_504_000_000, decimals: -6),
            row("DMember", "segment", amount: 14_979_000_000, decimals: -6),
            row(Xbrl.entityTotalMemberName, breakdownRowKindEntityTotal,
                amount: 1_583_719_000_000, decimals: -6),
        ]
        let external = BreakdownSnapshot(
            axis: breakdownAxisSegment, denominator: 1_583_719_000_000,
            denominatorTag: "SalesToExternalCustomersIFRS", rows: sales,
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 1_583_719_000_000,
            denominatorTag: "NetSalesIFRS",
            rows: sales.dropLast().map {
                payloadRow($0.labelRaw, $0.rowKind, amount: $0.amount)
            },
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: external, edinetCode: "E00436", memberPrefixes: [:], labelsByTag: [:])
        let year = SegmentWaterfall.yearObject(
            fyEnd: "2026-03-31", docID: "S100Y992", payload: assembled,
            metric: segmentWaterfallMetricExternalSales, key: nil)
        let segments = try #require(year[segmentWaterfallSegmentsKey] as? [[String: Any]])
        #expect(year[breakdownRowKindDifference] == nil)
        let gaps = try #require(year[segmentRoundingGapsKey] as? [String: Any])
        #expect((gaps[segmentCellExternalSales] as? NSNumber)?.int64Value == 2_000_000)
        let first = try #require(segments[0]["value"] as? NSNumber)
        #expect(first.int64Value == 936_926_000_000)
        #expect(segments[0]["decimals"] as? Int == -6)
        #expect(year["fiscal_year"] as? Int == 2026)
        let consolidated = try #require(year[segmentWaterfallConsolidatedKey] as? [String: Any])
        #expect((consolidated["value"] as? NSNumber)?.int64Value == 1_583_719_000_000)
    }

    @Test func inclusiveRevenueIsNotLabeledExternal() {
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 1, denominatorTag: "RevenueIFRS",
            rows: [payloadRow("AMember", "segment", amount: 1)],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        #expect(
            SegmentV3.salesBasis(of: segment, external: nil)
                == segmentSalesBasisIntersegmentInclusive)
    }
}

@Suite struct SegmentKeyTests {
    @Test func kindsFromPrefix() {
        #expect(SegmentKey.kind(forPrefix: "jpcrp_cor") == .std)
        #expect(SegmentKey.kind(forPrefix: "jpcrp030000-asr_E00436-000") == .ext)
        #expect(SegmentKey.kind(forPrefix: nil) == .txt)
        #expect(
            SegmentKey.make(
                edinetCode: "E00436", localName: "FooMember",
                prefix: "jpcrp030000-asr_E00436-000"
            ).description == "E00436:ext:FooMember")
    }

    @Test func labelMatchKeepsRelatedAndDepartment() {
        #expect(SegmentLabelMatch.matches("航空事業", segmentLabel: "航空事業"))
        #expect(SegmentLabelMatch.matches("航空事業", segmentLabel: "航空関連事業") == false)
        #expect(SegmentLabelMatch.stripTrailingBusiness("航空関連事業").hasSuffix("関連事業"))
    }
}

@Suite struct SegmentV3AssemblyRegressionTests {
    private func snapshot(_ rows: [BreakdownRow], denominator: Double, tag: String) -> BreakdownSnapshot {
        BreakdownSnapshot(
            axis: breakdownAxisSegment, denominator: denominator, denominatorTag: tag, rows: rows,
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    /// HTML が総額 1 行だけ（カテゴリ行なし）のときは、タグ付き fact のカテゴリ行を使う
    /// （5283 / 4680 / 3199: HTML を先に採ると概要のカテゴリが全部消える）。
    @Test func overviewKeepsFactCategoriesWhenHtmlHasOnlyATotal() {
        let html = snapshot([], denominator: 1_621_000_000, tag: "html")
        let facts = snapshot(
            [
                BreakdownRow(
                    labelRaw: "AMember", label: "建設関連", amount: 227_000_000, share: nil,
                    profit: nil, rowKind: "segment")
            ], denominator: 1_621_000_000, tag: "CapitalExpendituresOverviewOfCapitalExpendituresEtc")
        #expect(SegmentV3.pickOverview(html: html, facts: facts)?.denominatorTag == facts.denominatorTag)
        #expect(SegmentV3.pickOverview(html: html, facts: nil)?.denominatorTag == "html")
        let htmlWithRows = snapshot(
            [
                BreakdownRow(
                    labelRaw: "全社", label: "全社", amount: 1, share: nil, profit: nil,
                    rowKind: "reconciling")
            ], denominator: 1, tag: "html")
        #expect(SegmentV3.pickOverview(html: htmlWithRows, facts: facts)?.denominatorTag == "html")
    }

    /// 骨格が本文・Jev 由来（labelRaw が日本語ラベル）でも、同じ表示名の member を別の行にしない。
    @Test func memberCellsMergeIntoProseRowsByLabel() {
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 300, denominatorTag: "llm",
            rows: [
                BreakdownRowPayload(
                    labelRaw: "DXクラウド事業", label: "DXクラウド事業", amount: 100, profit: 10,
                    rowKind: "segment"),
                BreakdownRowPayload(
                    labelRaw: "広告・メディア事業", label: "広告・メディア事業", amount: 200, profit: 20,
                    rowKind: "segment"),
            ],
            sourceKind: breakdownSourceSegmentInfoLLM, needsReview: false, warnings: [])
        let external = snapshot(
            [
                BreakdownRow(
                    labelRaw: "DXcloudReportableSegmentMember", label: "DXクラウド事業", amount: 100,
                    share: nil, profit: nil, rowKind: "segment"),
                BreakdownRow(
                    labelRaw: "AdMediaReportableSegmentMember", label: "広告・メディア 事業", amount: 200,
                    share: nil, profit: nil, rowKind: "segment"),
                BreakdownRow(
                    labelRaw: Xbrl.entityTotalMemberName, label: "連結", amount: 300, share: nil,
                    profit: nil, rowKind: breakdownRowKindEntityTotal),
            ], denominator: 300, tag: "RevenuesFromExternalCustomers")
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: external, edinetCode: "E27894",
            memberPrefixes: [
                "DXcloudReportableSegmentMember": "jpcrp030000-asr_E27894-000",
                "AdMediaReportableSegmentMember": "jpcrp030000-asr_E27894-000",
            ], labelsByTag: [:])
        let segments = assembled.rows.filter { $0.rowKind == "segment" }
        #expect(segments.count == 2)
        #expect(segments.map { $0.externalSales?.value } == [100, 200])
        #expect(segments.map(\.profit) == [10, 20])
        #expect(segments[0].segmentKey == "E27894:ext:DXcloudReportableSegmentMember")
        #expect(assembled.rows.contains { $0.rowKind == breakdownRowKindDifference } == false)
    }

    /// 2602 S100YB17: 表由来の行は「親 / 子」ラベルと注記の印（「その他(注)１」）を持つ。XBRL の member ラベルは
    /// 「油脂・油糧事業」「その他」で完全一致しないため、利益なしの重複行が足されていた。
    @Test func llmSkeletonRowsAreNotDuplicatedByXbrlMembers() {
        func llm(_ label: String, _ amount: Double, _ profit: Double) -> BreakdownRowPayload {
            BreakdownRowPayload(
                labelRaw: label, label: label, amount: amount, profit: profit, rowKind: "segment")
        }
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 554_251, denominatorTag: "llm_table_subtotal",
            rows: [
                llm("グローバル油脂・加工油脂事業", 138_848, 4_766),
                llm("油脂・油糧および加工食品・素材事業 / 油脂・油糧", 311_544, 6_706),
                llm("油脂・油糧および加工食品・素材事業 / 加工食品・素材", 78_042, 4_418),
                llm("油脂・油糧および加工食品・素材事業", 389_586, 11_124),
                llm("その他(注)１", 10_307, 524),
            ],
            sourceKind: breakdownSourceSegmentInfoLLM, needsReview: false, warnings: [])
        func member(_ local: String, _ label: String, _ amount: Double) -> BreakdownRow {
            BreakdownRow(
                labelRaw: local, label: label, amount: amount, share: nil, profit: nil,
                rowKind: "segment")
        }
        let external = snapshot(
            [
                member("GlobalMember", "グローバル油脂・加工油脂事業", 138_848),
                member("OilsMember", "油脂・油糧事業", 311_544),
                member("FoodsMember", "加工食品・素材事業", 78_042),
                member("OtherMember", "その他", 10_307),
                BreakdownRow(
                    labelRaw: Xbrl.entityTotalMemberName, label: "連結", amount: 554_251,
                    share: nil, profit: nil, rowKind: breakdownRowKindEntityTotal),
            ], denominator: 554_251, tag: "RevenuesFromExternalCustomers")
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: external, edinetCode: "E00001", memberPrefixes: [:], labelsByTag: [:])
        let segments = assembled.rows.filter { $0.rowKind == "segment" }
        #expect(segments.count == 5)
        #expect(segments.allSatisfy { $0.profit != nil })
        let oils = segments.first { $0.label == "油脂・油糧および加工食品・素材事業 / 油脂・油糧" }
        #expect(oils?.externalSales?.value == 311_544)
        let other = segments.first { $0.label == "その他(注)１" }
        #expect(other?.externalSales?.value == 10_307)
    }

    /// 本番の Normalizer が返す sourceKind は "segment_info"。この値でも XBRL member 行を足さない。
    @Test func normalizerSourceKindAlsoSkipsXbrlOnlyMembers() {
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 300, denominatorTag: "llm_table_subtotal",
            rows: [BreakdownRowPayload(
                labelRaw: "A事業", label: "A事業", amount: 300, profit: 1, rowKind: "segment")],
            sourceKind: "segment_info", needsReview: false, warnings: [])
        let external = snapshot(
            [BreakdownRow(
                labelRaw: "AMemberReportableSegmentMember", label: "AMemberReportableSegmentMember",
                amount: 300, share: nil, profit: nil, rowKind: "segment")],
            denominator: 300, tag: "RevenuesFromExternalCustomers")
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: external, edinetCode: "E00003", memberPrefixes: [:], labelsByTag: [:])
        #expect(assembled.rows.filter { $0.rowKind == "segment" }.count == 1)
    }

    /// 8303: 名前に Corporate を含む報告セグメント member（法人業務）が調整行として足されない。
    @Test func corporateNamedSegmentMemberIsNotAddedAsReconcilingRow() {
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 300, denominatorTag: "llm_table_subtotal",
            rows: [BreakdownRowPayload(
                labelRaw: "法人業務 / 法人営業", label: "法人業務 / 法人営業", amount: 300, profit: 1,
                rowKind: "segment")],
            sourceKind: "segment_info", needsReview: false, warnings: [])
        let external = snapshot(
            [BreakdownRow(
                labelRaw: "CorporateBusinessReportableSegmentMember",
                label: "CorporateBusinessReportableSegmentMember",
                amount: 300, share: nil, profit: nil, rowKind: "segment")],
            denominator: 300, tag: "RevenuesFromExternalCustomers")
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: external, edinetCode: "E00004", memberPrefixes: [:], labelsByTag: [:])
        #expect(assembled.rows.contains { $0.rowKind == "reconciling" } == false)
    }

    /// 同じ末尾ラベルが複数の親にあるとき（親ごとの「日本」）は、どの行にも載せず、行も足さない。
    @Test func ambiguousLeafLabelIsNotMatchedOrCreated() {
        func llm(_ label: String, _ amount: Double) -> BreakdownRowPayload {
            BreakdownRowPayload(
                labelRaw: label, label: label, amount: amount, profit: 1, rowKind: "segment")
        }
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 300, denominatorTag: "llm_table_subtotal",
            rows: [llm("A事業 / 日本", 100), llm("B事業 / 日本", 200)],
            sourceKind: breakdownSourceSegmentInfoLLM, needsReview: false, warnings: [])
        let external = snapshot(
            [BreakdownRow(
                labelRaw: "JapanMember", label: "日本", amount: 300, share: nil, profit: nil,
                rowKind: "segment")], denominator: 300, tag: "RevenuesFromExternalCustomers")
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: external, edinetCode: "E00002", memberPrefixes: [:], labelsByTag: [:])
        let segments = assembled.rows.filter { $0.rowKind == "segment" }
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.externalSales == nil })
    }
}

@Suite struct SingleSegmentTests {
    /// 専用タグが無くても、注記の地の文が単一セグメントと言っていれば単一と決める。否定文は除く。
    @Test func singleSegmentStatementIsFoundInProse() {
        #expect(
            BreakdownExtractor.singleSegmentStatement(in: [
                "【セグメント情報】",
                "当社グループの報告セグメントは、レストラン事業のみの単一セグメントであり重要性が乏しいため、セグメント情報の記載を省略しております。",
            ])?.contains("レストラン事業") == true)
        #expect(
            BreakdownExtractor.singleSegmentStatement(in: ["当社グループの報告セグメントは単一であるため、記載を省略しております。"])
                != nil)
        #expect(
            BreakdownExtractor.singleSegmentStatement(in: ["当社グループは単一セグメントではなく、2つの報告セグメントを有しております。"])
                == nil)
        #expect(
            BreakdownExtractor.singleSegmentStatement(in: ["セグメント情報に同様の情報を開示しているため、記載を省略しております。"])
                == nil)
    }

    /// 単一セグメントで事業名が取れないときは、セグメント行を作らず会社全体の行だけにする。
    @Test func unnamedSingleSegmentReturnsConsolidatedRowOnly() throws {
        let pattern = SegmentNotePatternOutcome.deterministic(
            .singleSegment, evidence: "当社グループは単一セグメントであるため、記載を省略しております。")
        let snapshot = try #require(
            SegmentBreakdownResolver.oneRowSnapshot(
                reportable: ExtractedBreakdown(method: "not_found", tables: [], facts: []),
                consolidatedSales: 9_881_044_000, labelsByTag: [:], pattern: pattern))
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows[0].rowKind == breakdownRowKindEntityTotal)
        #expect(snapshot.rows[0].amount == 9_881_044_000)
        #expect(snapshot.rows.contains { $0.rowKind == "segment" } == false)
    }

    /// 事業名が取れるときは従来どおり事業名の 1 行。
    @Test func namedSingleSegmentKeepsTheBusinessRow() throws {
        let pattern = SegmentNotePatternOutcome.deterministic(
            .singleSegment,
            evidence: "当社グループの報告セグメントは、レストラン事業のみの単一セグメントであり重要性が乏しいため、セグメント情報の記載を省略しております。")
        let snapshot = try #require(
            SegmentBreakdownResolver.oneRowSnapshot(
                reportable: ExtractedBreakdown(method: "not_found", tables: [], facts: []),
                consolidatedSales: 9_881_044_000, labelsByTag: [:], pattern: pattern))
        #expect(snapshot.rows.map(\.label) == ["レストラン事業"])
        #expect(snapshot.rows[0].rowKind == "segment")
    }

    /// 報告セグメント以外の事業を「重要性が乏しい」として省略している書類は、開示された 1 つだけを
    /// 返し、省略の印を付ける（4694）。単一セグメントと言っている文は対象外（2764 / 1914）。
    @Test func otherSegmentsOmittedStatementAndName() throws {
        let bml = "当企業集団の報告セグメントである「検査事業」以外の事業に関しては、重要性が乏しいと考えられるため、記載を省略しております。"
        #expect(BreakdownExtractor.otherSegmentsOmittedStatement(in: [bml]) == bml)
        #expect(BreakdownExtractor.reportableSegmentName(inOmittedStatement: bml) == "検査事業")
        #expect(
            BreakdownExtractor.reportableSegmentName(
                inOmittedStatement: "銀行業務以外の事業については重要性が乏しいことから、セグメント情報の記載を省略しております。")
                == "銀行業務")
        #expect(
            BreakdownExtractor.otherSegmentsOmittedStatement(in: [
                "当社グループは、報告セグメントが管工機材卸売業のみであり、その他の事業は重要性が乏しいためセグメント情報の記載を省略しております。"
            ]) != nil)
        for single in [
            "当社グループの報告セグメントは、レストラン事業のみの単一セグメントであり重要性が乏しいため、セグメント情報の記載を省略しております。",
            "当社グループにおける報告セグメントは「建設工事」のみであり、開示情報としての重要性が乏しいため、セグメント情報の記載を省略している。",
            "のれんの償却額に関しては、重要性が乏しいため、その他の事業を含め記載を省略しております。",
        ] {
            #expect(BreakdownExtractor.otherSegmentsOmittedStatement(in: [single]) == nil)
        }

        let snapshot = try #require(
            SegmentBreakdownResolver.oneRowSnapshot(
                reportable: ExtractedBreakdown(method: "not_found", tables: [], facts: []),
                consolidatedSales: 150_262_000_000, labelsByTag: [:],
                pattern: .deterministic(.singleSegment, evidence: bml)))
        #expect(snapshot.rows.map(\.label) == ["検査事業"])
        #expect(snapshot.disclosureBasis == breakdownDisclosureBasisOtherSegmentsOmitted)
        #expect(snapshot.rows[0].disclosureBasis == breakdownDisclosureBasisOtherSegmentsOmitted)

        let unnamed = try #require(
            SegmentBreakdownResolver.oneRowSnapshot(
                reportable: ExtractedBreakdown(method: "not_found", tables: [], facts: []),
                consolidatedSales: 100, labelsByTag: [:],
                pattern: .deterministic(
                    .singleSegment,
                    evidence: "当社グループは、報告セグメントが管工機材卸売業のみであり、その他の事業は重要性が乏しいためセグメント情報の記載を省略しております。")))
        #expect(unnamed.rows.map(\.rowKind) == [breakdownRowKindEntityTotal])
        #expect(unnamed.disclosureBasis == breakdownDisclosureBasisOtherSegmentsOmitted)
    }

    @Test func structureMarker() {
        #expect(SegmentV3.segmentStructure(classification: .singleSegment, rows: []) == "single")
        #expect(SegmentV3.segmentStructure(classification: .multipleSegments, rows: []) == "multiple")
        #expect(SegmentV3.segmentStructure(classification: .omittedDominant90pct, rows: []) == nil)
        let two = ["A", "B"].map {
            BreakdownRowPayload(labelRaw: $0, label: $0, amount: 1, profit: nil, rowKind: "segment")
        }
        #expect(SegmentV3.segmentStructure(classification: nil, rows: two) == "multiple")
        #expect(SegmentV3.segmentStructure(classification: nil, rows: []) == nil)
    }

    /// 概要のカテゴリ（報告セグメントではない member や「新設によるもの」）で行を増やさない。
    @Test func overviewCategoriesDoNotCreateSegmentRows() {
        let segment = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 100, denominatorTag: "income_statement.sales",
            rows: [
                BreakdownRowPayload(
                    labelRaw: "AMember", label: "A事業", amount: 100, profit: nil, rowKind: "segment")
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let overview = BreakdownSnapshot(
            axis: breakdownAxisSegment, denominator: 30, denominatorTag: "overview",
            rows: [
                BreakdownRow(
                    labelRaw: "AMember", label: "A事業", amount: 10, share: nil, profit: nil,
                    rowKind: "segment"),
                BreakdownRow(
                    labelRaw: "OverviewOnlyMember", label: "概要だけの事業", amount: 20, share: nil,
                    profit: nil, rowKind: "segment"),
            ],
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        let assembled = SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: overview, overviewTotal: nil,
            equityMethod: nil, external: nil, edinetCode: "E1", memberPrefixes: [:],
            labelsByTag: [:])
        #expect(assembled.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw) == ["AMember"])
        #expect(assembled.rows[0].capitalExpenditures?.value == 10)
        let categories = assembled.overview?.categories ?? []
        #expect(categories.count == 2)
        #expect(categories.first { $0.label == "概要だけの事業" }?.unassigned == true)
    }

    @Test func combinedEliminationAndCorporateIsReconciling() {
        #expect(
            SegmentMemberKind.rowKind(
                SegmentMemberKind.classify(localName: "XReportableSegmentMember", label: "消去又は全社"))
                == "reconciling")
    }
}

@Suite struct SegmentExternalSalesResolveTests {
    private func fact(_ tag: String, _ member: String?, _ value: Double) -> BreakdownFact {
        BreakdownFact(
            tag: tag,
            contextRef: member.map { "CurrentYearDuration_\($0)" } ?? "CurrentYearDuration",
            dimensions: member.map { ["OperatingSegmentsAxis": $0] } ?? [:],
            value: value, label: nil, unitRef: "JPY", decimals: "-3")
    }

    /// 350A 型: 外部顧客 5,409,674、その他の収益を含む計 7,113,916 = 連結売上高。計を採る。
    @Test func totalMatchingConsolidatedSalesWinsOverExternalRow() throws {
        let facts = [
            fact("RevenuesFromExternalCustomers", "AReportableSegmentMember", 4_080_731_000),
            fact("RevenuesFromExternalCustomers", "BReportableSegmentMember", 810_932_000),
            fact("RevenuesFromExternalCustomers", "OtherReportableSegmentsMember", 518_010_000),
            fact("RevenuesFromExternalCustomers", nil, 5_409_674_000),
            fact("OtherRevenueSegmentInformation", "AReportableSegmentMember", 1_803_678_000),
            fact("OtherRevenueSegmentInformation", "BReportableSegmentMember", -99_435_000),
            fact("NetSales", "AReportableSegmentMember", 5_884_409_000),
            fact("NetSales", "BReportableSegmentMember", 711_496_000),
            fact("NetSales", "OtherReportableSegmentsMember", 518_010_000),
            fact("NetSales", nil, 7_113_916_000),
        ]
        let resolved = try #require(
            SegmentExternalSales.resolve(facts: facts, consolidatedSales: 7_113_916_000))
        #expect(resolved.salesBasis == segmentSalesBasisExternalIncludingOtherRevenue)
        #expect(resolved.snapshot.denominatorTag == "NetSales")
        #expect(
            resolved.snapshot.rows.first { $0.labelRaw == "AReportableSegmentMember" }?.amount
                == 5_884_409_000)
    }

    /// 6349 型: 計はセグメント間を含み、連結売上高（= 外部顧客の合計）に一致しない。外部顧客のまま。
    @Test func intersegmentInclusiveTotalIsNotUsed() throws {
        let facts = [
            fact("RevenuesFromExternalCustomers", "JapanReportableSegmentsMember", 55_271_000_000),
            fact("RevenuesFromExternalCustomers", "EuropeReportableSegmentsMember", 63_340_000_000),
            fact("RevenuesFromExternalCustomers", nil, 118_611_000_000),
            fact("NetSales", "JapanReportableSegmentsMember", 87_044_000_000),
            fact("NetSales", "EuropeReportableSegmentsMember", 65_825_000_000),
            fact("NetSales", nil, 152_869_000_000),
        ]
        let resolved = try #require(
            SegmentExternalSales.resolve(facts: facts, consolidatedSales: 118_611_000_000))
        #expect(resolved.salesBasis == segmentSalesBasisExternal)
        #expect(resolved.snapshot.denominatorTag == "RevenuesFromExternalCustomers")
    }

    /// 4097 型: 計は連結売上高と 0.7% ずれ、連結売上高は外部顧客に一致する。近いだけでは採らない。
    @Test func nearbyTotalIsNotUsedWhenExternalMatchesConsolidatedSales() throws {
        let facts = [
            fact("RevenuesFromExternalCustomers", "GasReportableSegmentsMember", 72_797_000_000),
            fact("RevenuesFromExternalCustomers", "ChemReportableSegmentsMember", 25_204_000_000),
            fact("RevenuesFromExternalCustomers", nil, 98_001_000_000),
            fact("NetSalesAndOperatingRevenue", "GasReportableSegmentsMember", 73_470_000_000),
            fact("NetSalesAndOperatingRevenue", "ChemReportableSegmentsMember", 25_208_000_000),
            fact("NetSalesAndOperatingRevenue", nil, 98_678_000_000),
        ]
        let resolved = try #require(
            SegmentExternalSales.resolve(facts: facts, consolidatedSales: 98_001_000_000))
        #expect(resolved.salesBasis == segmentSalesBasisExternal)
    }

    /// 3199 型: 外部顧客売上に連結値のタグが無い。計の連結値が連結売上高に一致しても、
    /// セグメントの和（セグメント間を含む）が連結値に合わないので採らない。
    @Test func totalIsNotUsedWhenExternalHasNoConsolidatedFact() throws {
        let facts = [
            fact("RevenuesFromExternalCustomers", "RetailReportableSegmentMember", 77_034_000_000),
            fact("RevenuesFromExternalCustomers", "ConstructionReportableSegmentMember", 58_417_000_000),
            fact("NetSales", "RetailReportableSegmentMember", 77_277_000_000),
            fact("NetSales", "ConstructionReportableSegmentMember", 58_636_000_000),
            fact("NetSales", nil, 135_451_000_000),
        ]
        let resolved = try #require(
            SegmentExternalSales.resolve(facts: facts, consolidatedSales: 135_451_000_000))
        #expect(resolved.salesBasis == segmentSalesBasisExternal)
        #expect(resolved.snapshot.denominatorTag == "RevenuesFromExternalCustomers")
    }

    /// 連結売上高が分からないときは外部顧客のまま。
    @Test func unknownConsolidatedSalesKeepsExternal() throws {
        let facts = [
            fact("RevenuesFromExternalCustomers", "AReportableSegmentMember", 10),
            fact("RevenuesFromExternalCustomers", nil, 10),
            fact("NetSales", "AReportableSegmentMember", 30),
            fact("NetSales", nil, 30),
        ]
        let resolved = try #require(
            SegmentExternalSales.resolve(facts: facts, consolidatedSales: nil))
        #expect(resolved.salesBasis == segmentSalesBasisExternal)
    }
}

@Suite struct SegmentTransitionMatcherTests {
    @Test func sameKeyIsImplicitAndNotEmitted() {
        let old = [
            BreakdownRowPayload(
                labelRaw: "AMember", label: "A", amount: 1, profit: nil, rowKind: "segment")
        ]
        var oldRow = old[0]
        oldRow.segmentKey = "E1:ext:AMember"
        var newRow = oldRow
        newRow.amount = 99
        let drafts = SegmentTransitionMatcher.match(
            oldRows: [oldRow], newRows: [newRow], fyEnd: "2026-03-31")
        #expect(drafts.isEmpty)
    }

    /// 差額行・調整行・連結行は年によって出たり消えたりする。つなぎの対象にしない
    /// （対象にすると、差額行が出ただけの年に break が付いて折れ線が切れる）。
    @Test func nonSegmentRowsAreNotMatched() {
        func row(_ local: String, kind: String, key: String) -> BreakdownRowPayload {
            var row = BreakdownRowPayload(
                labelRaw: local, label: local, amount: 1, profit: nil, rowKind: kind)
            row.segmentKey = key
            return row
        }
        let segment = row("AMember", kind: "segment", key: "E1:ext:AMember")
        let drafts = SegmentTransitionMatcher.match(
            oldRows: [
                segment,
                row("ReconcilingItemsMember", kind: "reconciling", key: "E1:std:ReconcilingItemsMember"),
            ],
            newRows: [
                segment,
                row("EliminationMember", kind: "reconciling", key: "E1:std:EliminationMember"),
                row("差額", kind: breakdownRowKindDifference, key: "E1:txt:差額"),
                row(
                    Xbrl.entityTotalMemberName, kind: breakdownRowKindEntityTotal,
                    key: "E1:std:\(Xbrl.entityTotalMemberName)"),
            ],
            fyEnd: "2026-03-31")
        #expect(drafts.isEmpty)
    }

    @Test func duplicateKeysDoNotCrash() {
        var a = BreakdownRowPayload(
            labelRaw: "AMember", label: "A", amount: 1, profit: nil, rowKind: "segment")
        a.segmentKey = "E1:ext:AMember"
        let drafts = SegmentTransitionMatcher.match(
            oldRows: [a, a], newRows: [a], fyEnd: "2026-03-31")
        #expect(drafts.isEmpty)
    }

    @Test func valueOnlyDifferentLabelIsNeedsReviewNotConnect() {
        var oldRow = BreakdownRowPayload(
            labelRaw: "OldMember", label: "旧", amount: 100, profit: nil, rowKind: "segment")
        oldRow.segmentKey = "E1:ext:OldMember"
        var newRow = BreakdownRowPayload(
            labelRaw: "NewMember", label: "新", amount: 100, profit: nil, rowKind: "segment")
        newRow.segmentKey = "E1:ext:NewMember"
        let drafts = SegmentTransitionMatcher.match(
            oldRows: [oldRow], newRows: [newRow], fyEnd: "2026-03-31")
        #expect(drafts.count == 1)
        #expect(drafts[0].decision == segmentTransitionDecisionNeedsReview)
        #expect(drafts[0].basis == segmentTransitionBasisDeterministic)
    }

    @Test func jevConnectRequiresConfidence() {
        let draft = SegmentTransitionDraft(
            oldKey: "a", newKey: "b", fyEnd: "2026-03-31",
            decision: segmentTransitionDecisionNeedsReview,
            basis: segmentTransitionBasisDeterministic,
            matched: segmentTransitionMatchedUnmatched)
        let connected = SegmentTransitionMatcher.applyJev(
            draft, decision: segmentTransitionDecisionConnect, confident: true)
        #expect(connected.decision == segmentTransitionDecisionConnect)
        let low = SegmentTransitionMatcher.applyJev(
            draft, decision: segmentTransitionDecisionConnect, confident: false)
        #expect(low.decision == segmentTransitionDecisionNeedsReview)
    }
}

@Suite struct SegmentWaterfallAPITests {
    private func cellRow(
        _ local: String, kind: String, value: Double, key: String
    ) -> BreakdownRowPayload {
        var row = BreakdownRowPayload(
            labelRaw: local, label: local, amount: value, profit: nil, rowKind: kind)
        row.segmentKey = key
        row.externalSales = BreakdownMetricCellPayload(
            value: value, basis: breakdownSourceXbrlFacts, source: local, decimals: -6)
        return row
    }

    private func yearPayload(_ rows: [BreakdownRowPayload]) -> BreakdownSnapshotPayload {
        var payload = BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 1, denominatorTag: "Sales",
            rows: rows, sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
        payload.salesBasis = segmentSalesBasisExternal
        return payload
    }

    @Test func yearsAreNewestFirstAndSkipMissingYears() throws {
        let a = cellRow("A", kind: "segment", value: 1, key: "E1:ext:A")
        let object = SegmentWaterfall.jsonObject(
            code: "2802",
            metric: segmentWaterfallMetricExternalSales,
            years: [
                (fyEnd: "2024-03-31", docID: "S1", payload: yearPayload([a])),
                (fyEnd: "2026-03-31", docID: "S3", payload: yearPayload([a])),
            ],
            limit: 5)
        let years = try #require(object["years"] as? [[String: Any]])
        #expect(years.map { $0["fy_end"] as? String } == ["2026-03-31", "2024-03-31"])
        #expect(years.count == 2)
        #expect(years[0][segmentWaterfallLineCutKey] as? Bool == true)
    }

    @Test func fiscalYearSelectsOneYear() throws {
        let a = cellRow("A", kind: "segment", value: 1, key: "E1:ext:A")
        let object = SegmentWaterfall.jsonObject(
            code: "2802",
            metric: segmentWaterfallMetricExternalSales,
            years: [
                (fyEnd: "2025-03-31", docID: "S2", payload: yearPayload([a])),
                (fyEnd: "2026-03-31", docID: "S3", payload: yearPayload([a])),
            ],
            fiscalYear: "2025")
        let years = try #require(object["years"] as? [[String: Any]])
        #expect(years.count == 1)
        #expect(years[0]["fy_end"] as? String == "2025-03-31")
        #expect(years[0]["fiscal_year"] as? Int == 2025)
    }

    @Test func sameKeyIsConnectWithoutLineCut() throws {
        let old = cellRow("A", kind: "segment", value: 10, key: "E1:ext:A")
        let new = cellRow("A", kind: "segment", value: 12, key: "E1:ext:A")
        let object = SegmentWaterfall.jsonObject(
            code: "2802",
            metric: segmentWaterfallMetricExternalSales,
            years: [
                (fyEnd: "2025-03-31", docID: "S2", payload: yearPayload([old])),
                (fyEnd: "2026-03-31", docID: "S3", payload: yearPayload([new])),
            ])
        let years = try #require(object["years"] as? [[String: Any]])
        #expect(years[0][segmentWaterfallLineCutKey] as? Bool == false)
        let segments = try #require(years[0][segmentWaterfallSegmentsKey] as? [[String: Any]])
        let prior = try #require(segments[0][segmentWaterfallPriorKey] as? [String: Any])
        #expect(prior[breakdownRowSegmentKeyKey] as? String == "E1:ext:A")
        #expect(prior["decision"] as? String == segmentTransitionDecisionConnect)
        #expect(prior["basis"] as? String == segmentTransitionMatchedSameKey)
    }

    @Test func storedConnectDifferentKeysIsRename() throws {
        let old = cellRow("A", kind: "segment", value: 10, key: "E1:ext:A")
        let new = cellRow("B", kind: "segment", value: 12, key: "E1:ext:B")
        let object = SegmentWaterfall.jsonObject(
            code: "2802",
            metric: segmentWaterfallMetricExternalSales,
            years: [
                (fyEnd: "2025-03-31", docID: "S2", payload: yearPayload([old])),
                (fyEnd: "2026-03-31", docID: "S3", payload: yearPayload([new])),
            ],
            transitions: [
                SegmentTransitionDraft(
                    oldKey: "E1:ext:A", newKey: "E1:ext:B", fyEnd: "2026-03-31",
                    decision: segmentTransitionDecisionConnect,
                    basis: segmentTransitionBasisDeterministic,
                    matched: segmentTransitionMatchedPluralOnly)
            ],
            key: "E1:ext:A")
        let years = try #require(object["years"] as? [[String: Any]])
        #expect(years.count == 2)
        #expect(years[0][segmentWaterfallLineCutKey] as? Bool == false)
        let segments = try #require(years[0][segmentWaterfallSegmentsKey] as? [[String: Any]])
        let prior = try #require(segments[0][segmentWaterfallPriorKey] as? [String: Any])
        #expect(prior[breakdownRowSegmentKeyKey] as? String == "E1:ext:A")
        #expect(prior["decision"] as? String == segmentWaterfallDecisionRename)
    }

    @Test func needsReviewIsReorgAndCutsTheLine() throws {
        let old = cellRow("A", kind: "segment", value: 10, key: "E1:ext:A")
        let new = cellRow("B", kind: "segment", value: 10, key: "E1:ext:B")
        let object = SegmentWaterfall.jsonObject(
            code: "2802",
            metric: segmentWaterfallMetricExternalSales,
            years: [
                (fyEnd: "2025-03-31", docID: "S2", payload: yearPayload([old])),
                (fyEnd: "2026-03-31", docID: "S3", payload: yearPayload([new])),
            ],
            transitions: [
                SegmentTransitionDraft(
                    oldKey: "E1:ext:A", newKey: "E1:ext:B", fyEnd: "2026-03-31",
                    decision: segmentTransitionDecisionNeedsReview,
                    basis: segmentTransitionBasisDeterministic,
                    matched: segmentTransitionMatchedUnmatched)
            ])
        let years = try #require(object["years"] as? [[String: Any]])
        #expect(years[0][segmentWaterfallLineCutKey] as? Bool == true)
        let segments = try #require(years[0][segmentWaterfallSegmentsKey] as? [[String: Any]])
        let prior = try #require(segments[0][segmentWaterfallPriorKey] as? [String: Any])
        #expect(prior["decision"] as? String == segmentWaterfallDecisionReorg)
    }

    @Test func yearsLimitDropsOlderIngestedYears() throws {
        let a = cellRow("A", kind: "segment", value: 1, key: "E1:ext:A")
        let years = (2021...2026).map { year in
            (fyEnd: "\(year)-03-31", docID: "S\(year)", payload: yearPayload([a]))
        }
        let object = SegmentWaterfall.jsonObject(
            code: "2802",
            metric: segmentWaterfallMetricExternalSales,
            years: years,
            limit: 5)
        let returned = try #require(object["years"] as? [[String: Any]])
        #expect(returned.count == 5)
        #expect(returned.first?["fy_end"] as? String == "2026-03-31")
        #expect(returned.last?["fy_end"] as? String == "2022-03-31")
    }
}

@Suite struct SegmentWaterfallReorgTests {
    private func row(_ local: String, _ label: String, _ value: Double) -> BreakdownRowPayload {
        var row = BreakdownRowPayload(
            labelRaw: local, label: label, amount: value, profit: nil, rowKind: "segment")
        row.segmentKey = "E1:ext:\(local)"
        row.externalSales = BreakdownMetricCellPayload(
            value: value, basis: breakdownSourceXbrlFacts, source: local, decimals: -6)
        return row
    }

    private func payload(_ rows: [BreakdownRowPayload]) -> BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 1, denominatorTag: "Sales",
            rows: rows, sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    private func object(old: [BreakdownRowPayload], new: [BreakdownRowPayload]) throws
        -> [String: Any]
    {
        let json = SegmentWaterfall.jsonObject(
            code: "2871", metric: segmentWaterfallMetricExternalSales,
            years: [
                (fyEnd: "2025-03-31", docID: "S1", payload: payload(old)),
                (fyEnd: "2026-03-31", docID: "S2", payload: payload(new)),
            ],
            transitions: SegmentTransitionMatcher.match(
                oldRows: old, newRows: new, fyEnd: "2026-03-31"))
        let years = try #require(json["years"] as? [[String: Any]])
        return years[0]
    }

    @Test func threeIntoOneIsMergeWithFromKeys() throws {
        let year = try object(
            old: [
                row("Processed", "加工食品", 100), row("Marine", "水産", 30),
                row("Livestock", "畜産", 20), row("Logistics", "物流", 50),
            ],
            new: [row("Food", "食品", 160), row("Logistics", "物流", 55)])
        let reorgs = try #require(year[segmentWaterfallReorgsKey] as? [[String: Any]])
        #expect(reorgs.count == 1)
        #expect(reorgs[0]["kind"] as? String == segmentWaterfallReorgKindMerge)
        let from = try #require(reorgs[0]["from"] as? [[String: Any]])
        #expect(from.map { $0["label"] as? String } == ["加工食品", "水産", "畜産"])
        #expect(reorgs[0]["from_total"] as? Int == 150)
        #expect(reorgs[0]["to_total"] as? Int == 160)
        let segments = try #require(year[segmentWaterfallSegmentsKey] as? [[String: Any]])
        let food = try #require(segments.first { $0["label"] as? String == "食品" })
        let prior = try #require(food[segmentWaterfallPriorKey] as? [String: Any])
        #expect(prior["decision"] as? String == segmentWaterfallDecisionReorg)
        #expect(
            prior[segmentWaterfallPriorFromKey] as? [String]
                == ["E1:ext:Processed", "E1:ext:Marine", "E1:ext:Livestock"])
        // 同じキーで続く行には from を付けない。
        let logistics = try #require(segments.first { $0["label"] as? String == "物流" })
        let logisticsPrior = try #require(logistics[segmentWaterfallPriorKey] as? [String: Any])
        #expect(logisticsPrior[segmentWaterfallPriorFromKey] == nil)
        #expect(year[segmentWaterfallLineCutKey] as? Bool == true)
    }

    @Test func oneIntoTwoIsSplitAndTwoByTwoIsRegroup() throws {
        let split = try object(
            old: [row("A", "A", 100)], new: [row("B", "B", 60), row("C", "C", 40)])
        let splitReorgs = try #require(split[segmentWaterfallReorgsKey] as? [[String: Any]])
        #expect(splitReorgs[0]["kind"] as? String == segmentWaterfallReorgKindSplit)

        let regroup = try object(
            old: [row("A", "A", 100), row("B", "B", 50)],
            new: [row("C", "C", 90), row("D", "D", 60)])
        let regroupReorgs = try #require(regroup[segmentWaterfallReorgsKey] as? [[String: Any]])
        #expect(regroupReorgs[0]["kind"] as? String == segmentWaterfallReorgKindRegroup)
        #expect((regroupReorgs[0]["from"] as? [[String: Any]])?.count == 2)
        #expect((regroupReorgs[0]["to"] as? [[String: Any]])?.count == 2)
    }

    @Test func regroupSplitsIntoSplitAndReplaceByNearbyTotals() throws {
        // 日本郵船型: 不定期専用船 → 自動車・ドライバルク・エネルギー（split）、その他の事業 → その他（replace）
        let result = try object(
            old: [
                row("Bulk", "Bulk", 1_230_737), row("Others", "Others", 116_050),
            ],
            new: [
                row("Auto", "Auto", 531_867), row("Dry", "Dry", 601_322),
                row("Energy", "Energy", 178_225), row("Other", "Other", 114_650),
            ])
        let reorgs = try #require(result[segmentWaterfallReorgsKey] as? [[String: Any]])
        let kinds = Set(reorgs.compactMap { $0["kind"] as? String })
        #expect(reorgs.count == 2)
        #expect(kinds == [segmentWaterfallReorgKindSplit, segmentWaterfallReorgKindReplace])
        let segments = try #require(result[segmentWaterfallSegmentsKey] as? [[String: Any]])
        let other = try #require(segments.first { $0["label"] as? String == "Other" })
        let prior = try #require(other[segmentWaterfallPriorKey] as? [String: Any])
        #expect((prior[segmentWaterfallPriorFromKey] as? [String]) == ["E1:ext:Others"])
    }

    @Test func regroupUsesRestatedPriorValuesWhenNearbyTotalsAreAmbiguous() {
        // 旧: 不定期 1230、その他 113、不動産 3。新の前期値: 自動車 500・ドライバルク 600・エネルギー 130、その他 116。
        let parts = SegmentWaterfall.splitRegroup(
            gone: [("Bulk", 1230), ("Others", 113), ("RealEstate", 3)],
            added: [("Auto", 500), ("Dry", 600), ("Energy", 130), ("Other", 116)],
            tolerance: SegmentWaterfall.regroupExactTolerance)
        #expect(parts?.count == 2)
        #expect(parts?.contains { $0.from == ["Bulk"] && $0.to == ["Auto", "Dry", "Energy"] } == true)
        #expect(parts?.contains { $0.from == ["Others", "RealEstate"] && $0.to == ["Other"] } == true)
    }

    @Test func endedOrNewSegmentsAloneAreNotReorgs() throws {
        let ended = try object(
            old: [row("A", "A", 100), row("B", "B", 50)], new: [row("A", "A", 110)])
        #expect(ended[segmentWaterfallReorgsKey] == nil)
        let added = try object(
            old: [row("A", "A", 100)], new: [row("A", "A", 110), row("N", "N", 5)])
        #expect(added[segmentWaterfallReorgsKey] == nil)
    }

    @Test func sameKeysHaveNoReorgs() throws {
        let year = try object(old: [row("A", "A", 1)], new: [row("A", "A", 2)])
        #expect(year[segmentWaterfallReorgsKey] == nil)
    }
}

@Suite struct GeographyWaterfallTests {
    private func region(_ label: String, _ value: Double) -> BreakdownRowPayload {
        BreakdownRowPayload(
            labelRaw: label, label: label, amount: value, profit: nil, rowKind: "segment")
    }

    private func payload(_ rows: [BreakdownRowPayload]) -> BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisGeography, denominator: 1, denominatorTag: "Sales",
            rows: rows, sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    @Test func labelsNormalize() {
        #expect(GeographyRegion.normalize(label: "日本").region == "japan")
        #expect(GeographyRegion.normalize(label: "北米（注）2").region == "north_america")
        #expect(GeographyRegion.normalize(label: "米国").region == "united_states")
        #expect(GeographyRegion.normalize(label: "中南米").region == "latin_america")
        #expect(GeographyRegion.normalize(label: "米州").region == "americas")
        #expect(GeographyRegion.normalize(label: "その他の地域").region == "other")
        #expect(GeographyRegion.normalize(label: "欧州他").region == "europe+other")
        #expect(GeographyRegion.normalize(label: "アジア・オセアニア").region == "asia+oceania")
        #expect(GeographyRegion.normalize(label: "アジア（中国を除く）").region == "asia")
        #expect(GeographyRegion.normalize(label: "インド").region == nil)
        #expect(GeographyRegion.normalize(label: "ブラジル・アジア").region == nil)
    }

    private func years(_ list: [(String, [BreakdownRowPayload])]) throws -> [[String: Any]] {
        let object = GeographyWaterfall.jsonObject(
            code: "7203",
            years: list.enumerated().map { index, entry in
                (fyEnd: entry.0, docID: "S\(index)", payload: payload(entry.1))
            })
        return try #require(object["years"] as? [[String: Any]])
    }

    @Test func sameShapeIsOneComparableGroupWithoutLineCut() throws {
        let result = try years([
            ("2025-03-31", [region("日本", 10), region("北米", 20), region("その他", 5)]),
            ("2026-03-31", [region("日本", 11), region("北米（注）1", 22), region("その他", 6)]),
        ])
        #expect(result.map { $0["fy_end"] as? String } == ["2026-03-31", "2025-03-31"])
        #expect(result.allSatisfy { $0["comparable_group"] as? Int == 0 })
        #expect(result.allSatisfy { $0[segmentWaterfallLineCutKey] as? Bool == false })
        let blocks = try #require(result[0]["comparable_regions"] as? [[String: Any]])
        #expect(blocks.map { $0["region"] as? String } == ["japan", "north_america", "other"])
    }

    @Test func finerRegionsAreLiftedWhenTheOtherYearIsCoarser() throws {
        let result = try years([
            ("2025-03-31", [region("日本", 10), region("北米", 20), region("欧州", 5)]),
            ("2026-03-31", [region("日本", 11), region("米国", 12), region("カナダ・北米", 3), region("欧州", 6)]),
        ])
        // 米国は北米へ 1 段持ち上げて、旧年の北米と同じ区分にする。
        #expect(result.allSatisfy { $0["comparable_group"] as? Int == 0 })
        #expect(result[0]["comparable_level"] as? Int == 1)
        let blocks = try #require(result[0]["comparable_regions"] as? [[String: Any]])
        let north = try #require(blocks.first { $0["region"] as? String == "north_america" })
        #expect(north["value"] as? Int == 15)
        // 元の地域はそのまま返す。
        let raw = try #require(result[0]["regions"] as? [[String: Any]])
        #expect(raw.map { $0["region"] as? String }.contains("united_states"))
    }

    @Test func otherPlusARegionNameIsThatRegion() {
        #expect(GeographyRegion.normalize(label: "その他の米州").region == "americas")
        #expect(GeographyRegion.normalize(label: "その他アジア").region == "asia")
        #expect(GeographyRegion.normalize(label: "その他の欧州").region == "europe")
        #expect(GeographyRegion.normalize(label: "その他の地域").region == "other")
        #expect(GeographyRegion.normalize(label: "その他海外").region == "other")
        #expect(GeographyRegion.normalize(label: "その他").region == "other")
    }

    @Test func fineAmericasAndACoarseAmericasYearShareAGroup() throws {
        let fine: [(String, Double)] = [("日本", 10), ("米国", 5), ("その他の米州", 2), ("欧州", 3)]
        let result = try years([
            ("2024-03-31", fine.map { region($0.0, $0.1) }),
            ("2025-03-31", [region("日本", 10), region("米州", 7), region("欧州", 3)]),
            ("2026-03-31", fine.map { region($0.0, $0.1) }),
        ])
        #expect(Set(result.compactMap { $0["comparable_group"] as? Int }).count == 1)
        #expect(result.allSatisfy { $0["comparable_level"] as? Int == 2 })
    }

    @Test func mergedRegionsUniteIntoOneBlockAcrossYears() throws {
        let result = try years([
            ("2025-03-31", [region("日本", 10), region("アジア", 20), region("その他", 5)]),
            ("2026-03-31", [region("日本", 11), region("アジア・その他", 27)]),
        ])
        #expect(result.allSatisfy { $0["comparable_group"] as? Int == 0 })
        for year in result {
            let blocks = try #require(year["comparable_regions"] as? [[String: Any]])
            #expect(blocks.map { $0["region"] as? String } == ["japan", "asia+other"])
        }
        let old = try #require(result[1]["comparable_regions"] as? [[String: Any]])
        #expect(old[1]["value"] as? Int == 25)
    }

    @Test func differentUniversesCutTheLine() throws {
        let result = try years([
            ("2025-03-31", [region("日本", 10), region("北米", 20), region("欧州", 5)]),
            ("2026-03-31", [region("日本", 11), region("欧州", 6), region("アジア", 9)]),
        ])
        #expect(result[0]["comparable_group"] as? Int == 0)
        #expect(result[1]["comparable_group"] as? Int == 1)
        // 線を切るのは、前年と別の塊になる年（新しい方の塊の最古年）。
        #expect(result[0][segmentWaterfallLineCutKey] as? Bool == true)
        #expect(result[1][segmentWaterfallLineCutKey] as? Bool == false)
    }

    @Test func missingYearCutsTheLineAndSubtotalsAreIgnored() throws {
        var subtotal = region("うち中国", 3)
        subtotal.rowKind = "subtotal"
        let result = try years([
            ("2024-03-31", [region("日本", 10), region("欧州", 5)]),
            ("2026-03-31", [region("日本", 11), region("欧州", 6), subtotal]),
        ])
        #expect(result[0]["comparable_group"] as? Int == 0)
        #expect(result[1]["comparable_group"] as? Int == 1)
        #expect((result[0]["regions"] as? [[String: Any]])?.count == 2)
    }

    @Test func fiscalYearAndLimit() throws {
        let rows = [region("日本", 1), region("欧州", 1)]
        let all = (2021...2026).map { (fyEnd: "\($0)-03-31", docID: "S\($0)", payload: payload(rows)) }
        let limited = GeographyWaterfall.jsonObject(code: "7203", years: all, limit: 3)
        #expect((limited["years"] as? [[String: Any]])?.count == 3)
        let one = GeographyWaterfall.jsonObject(code: "7203", years: all, fiscalYear: "2024")
        #expect((one["years"] as? [[String: Any]])?.count == 1)
    }
}
