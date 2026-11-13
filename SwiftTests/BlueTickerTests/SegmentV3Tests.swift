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

@Suite struct SegmentEmployeesMergeTests {
    private func employees(_ rows: [(String, String, Double)], total: Double) -> BreakdownSnapshot {
        BreakdownSnapshot(
            axis: breakdownAxisSegment, denominator: total, denominatorTag: "NumberOfEmployees",
            rows: rows.map {
                BreakdownRow(
                    labelRaw: $0.0, label: $0.1, amount: $0.2, share: nil, profit: nil,
                    rowKind: "segment")
            },
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    private func segmentPayload(_ rows: [(String, String, String)]) -> BreakdownSnapshotPayload {
        // 売上はセグメント行の和 = 連結にして、差額行が出ないようにする。
        let total = Double(rows.filter { $0.2 == "segment" }.count)
        return BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: total, denominatorTag: "income_statement.sales",
            rows: rows.map {
                BreakdownRowPayload(
                    labelRaw: $0.0, label: $0.1, amount: $0.2 == "segment" ? 1 : total, profit: nil,
                    rowKind: $0.2)
            },
            sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    private func assemble(
        _ segment: BreakdownSnapshotPayload, _ employees: BreakdownSnapshot, allowRows: Bool = false
    ) -> BreakdownSnapshotPayload {
        SegmentV3.assemble(
            segment: segment, assets: nil, capitalExpenditures: nil,
            noncurrentAssetAdditions: nil, overview: nil, overviewTotal: nil, equityMethod: nil,
            external: nil, employees: employees, allowEmployeeOnlyRows: allowRows,
            edinetCode: "E1", memberPrefixes: [:], labelsByTag: [:])
    }

    /// member 名が違っても表示名が同じなら同じ行（7203 の「その他」）。合わない行は未割当のカテゴリ。
    @Test func employeesJoinByMemberThenLabel() {
        let assembled = assemble(
            segmentPayload([
                ("AutoMember", "自動車", "segment"), ("OtherReportableSegmentsMember", "その他", "segment"),
                (Xbrl.entityTotalMemberName, "連結", breakdownRowKindEntityTotal),
            ]),
            employees(
                [
                    ("AutoMember", "自動車", 300), ("AllOtherReportableSegmentMember", "その他", 20),
                    ("CorporateSharedMember", "全社（共通）", 5),
                ], total: 325))
        #expect(assembled.rows.map { $0.employeesCell?.value } == [300, 20, 325])
        #expect(assembled.rows.count == 3)
        let categories = assembled.employeesBlock?.categories ?? []
        #expect(categories.map(\.unassigned) == [false, false, true])
        #expect(assembled.employeesBlock?.total?.value == 325)
        let json = assembled.jsonObject()
        let block = json[segmentCellEmployees] as? [String: Any]
        #expect(((block?["total"] as? [String: Any])?["value"] as? NSNumber)?.intValue == 325)
        let rows = json["rows"] as? [[String: Any]]
        #expect(((rows?[0][segmentCellEmployees] as? [String: Any])?["value"] as? NSNumber)?.intValue == 300)
    }

    /// 報告セグメントが 1 行で従業員の状況が事業部門に分かれているときは、部門をその行に載せない（7953 / 2303）。
    @Test func departmentsAreNotPutOnTheSingleSegmentRow() {
        let assembled = assemble(
            segmentPayload([("製品販売・工事", "製品販売・工事", "segment")]),
            employees([("製品販売・工事", "製品販売・工事", 279), ("住宅事業本部", "住宅事業本部", 106)], total: 426))
        #expect(assembled.rows.count == 1)
        #expect(assembled.rows[0].employeesCell == nil)
        #expect(assembled.employeesBlock?.categories.allSatisfy(\.unassigned) == true)
    }

    /// セグメント注記から行を作れないときは、従業員の状況の行で報告セグメントの行を作る（324A）。
    @Test func employeeRowsBecomeSegmentRowsWhenAllowed() {
        let assembled = assemble(
            segmentPayload([(Xbrl.entityTotalMemberName, "連結", breakdownRowKindEntityTotal)]),
            employees(
                [("集客支援事業", "集客支援事業", 26), ("直営宿泊事業", "直営宿泊事業", 16),
                 ("CorporateSharedMember", "全社（共通）", 6)], total: 48),
            allowRows: true)
        #expect(assembled.rows.filter { $0.rowKind == "segment" }.map(\.label) == ["集客支援事業", "直営宿泊事業"])
        #expect(assembled.rows.filter { $0.rowKind == "reconciling" }.map { $0.employeesCell?.value } == [6])
        #expect(assembled.employeesBlock?.categories.contains { $0.unassigned } == false)
    }

    @Test func employeesAxisIsRetiredAndWaterfallHasTheMetric() {
        #expect(retiredBreakdownAxes.contains(breakdownAxisEmployees))
        #expect(segmentWaterfallMetrics.contains(segmentWaterfallMetricEmployees))
        #expect(
            BreakdownExtractor.singleSegmentStatement(in: [
                "当社は、従来、集客事業の単一セグメントとして事業を営んでおりましたが、当事業年度より施設再生・リセール事業を開始しております。"
            ]) == nil)
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
