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
