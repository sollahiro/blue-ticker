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
        let rows = try #require(year["rows"] as? [[String: Any]])
        #expect(rows.contains { $0["row_kind"] as? String == breakdownRowKindDifference } == false)
        let gaps = try #require(year[segmentRoundingGapsKey] as? [String: Any])
        #expect((gaps[segmentCellExternalSales] as? NSNumber)?.int64Value == 2_000_000)
        let first = try #require(rows[0]["value"] as? NSNumber)
        #expect(first.int64Value == 936_926_000_000)
        #expect(rows[0]["decimals"] as? Int == -6)
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
