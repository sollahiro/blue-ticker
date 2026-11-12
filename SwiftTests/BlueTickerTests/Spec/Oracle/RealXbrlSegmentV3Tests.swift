// segment-v3 の実 XBRL 回帰。トヨタ S100Y8NY は設備投資セルと資産セルの生円。
// 丸め幅の差額は差額行に出さない。キャッシュが無いときは SKIP。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct RealXbrlSegmentV3Tests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard FileManager.default.fileExists(atPath: xbrlDir(docID).path) else {
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func payload(from snapshot: BreakdownSnapshot) -> BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: snapshot.axis, denominator: snapshot.denominator,
            denominatorTag: snapshot.denominatorTag,
            rows: snapshot.rows.map {
                var row = BreakdownRowPayload(
                    labelRaw: $0.labelRaw, label: $0.label ?? $0.labelRaw, amount: $0.amount,
                    profit: $0.profit, rowKind: $0.rowKind, segmentBasis: $0.segmentBasis,
                    disclosureBasis: $0.disclosureBasis)
                if let profit = $0.profit {
                    row.profitCell = BreakdownMetricCellPayload(
                        value: profit, basis: snapshot.sourceKind, source: "profit",
                        decimals: $0.decimals)
                }
                return row
            },
            sourceKind: snapshot.sourceKind, needsReview: snapshot.needsReview,
            warnings: snapshot.warnings)
    }

    private static func assemble(_ docID: String) -> BreakdownSnapshotPayload? {
        let dir = xbrlDir(docID)
        let reportable = BreakdownExtractor.extractReportableSegmentInfo(xbrlDir: dir)
        let labels = XBRLUtils.breakdownMemberLabels(in: dir)
        let memberParents = XBRLUtils.operatingSegmentMemberParents(in: dir)
        guard let normalized = BreakdownNormalizer.normalize(
            reportable, consolidatedSales: nil, labelsByTag: labels, reportableSegmentAxis: true)
        else { return nil }
        let segment = BreakdownNormalizer.publishingAsSegment(normalized)
        let facts = reportable.facts
        let assets = BreakdownNormalizer.normalizeSegmentAssets(
            facts: facts, labelsByTag: labels, memberParents: memberParents)
        let capitalExpenditures = BreakdownNormalizer.normalizeCapitalExpenditures(
            facts: facts, labelsByTag: labels, memberParents: memberParents)
        let noncurrent = BreakdownNormalizer.normalizeNoncurrentAssetAdditions(
            facts: facts, labelsByTag: labels, memberParents: memberParents)
        let overview = BreakdownNormalizer.normalizeCapitalExpendituresOverview(
            facts: facts, labelsByTag: labels, memberParents: memberParents)
        let equityMethod = BreakdownNormalizer.normalizeEquityMethodInvestments(
            facts: facts, labelsByTag: labels)
        let external = SegmentExternalSales.normalize(
            facts: facts, labelsByTag: labels, memberParents: memberParents)
        var memberPrefixes: [String: String] = [:]
        for fact in facts {
            guard let member = XBRLUtils.primaryBreakdownMember(fact.dimensions),
                let prefix = fact.memberPrefix
            else { continue }
            if memberPrefixes[member] == nil { memberPrefixes[member] = prefix }
        }
        let edinetCode = XBRLUtils.extractTextblockHtml(
            in: dir, textblockTag: Xbrl.edinetCodeDEITag)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SegmentV3.assemble(
            segment: payload(from: segment), assets: assets,
            capitalExpenditures: capitalExpenditures, noncurrentAssetAdditions: noncurrent,
            overview: overview, overviewTotal: nil, equityMethod: equityMethod,
            external: external, edinetCode: edinetCode, memberPrefixes: memberPrefixes,
            labelsByTag: labels)
    }

    /// トヨタ: 自動車の設備投資・資産は tagged 円。丸め幅の差額は差額行に出さない。
    // source: code=7203 fy_end=2026-03-31 doc_id=S100Y8NY page=146 field=segment.capital_expenditures
    @Test func toyotaKeepsRawYenAndOmitsRoundingDifference() async throws {
        guard await Self.ensureAvailable("S100Y8NY") else { return }
        let assembled = try #require(Self.assemble("S100Y8NY"))
        let automotive = try #require(
            assembled.rows.first { $0.labelRaw == "AutomotiveReportableSegmentMember" })
        #expect(automotive.capitalExpenditures?.value == 2_453_641_000_000)
        #expect(automotive.segmentAssetsCell?.value == 33_182_372_000_000)
        #expect(automotive.segmentKey?.contains(":ext:AutomotiveReportableSegmentMember") == true
            || automotive.segmentKey?.contains(":std:AutomotiveReportableSegmentMember") == true)
        #expect(automotive.externalSales?.decimals != nil || automotive.capitalExpenditures?.decimals != nil)
        #expect(assembled.salesBasis == segmentSalesBasisExternal)
        if let difference = assembled.rows.first(where: { $0.rowKind == breakdownRowKindDifference }) {
            for (key, cell) in [
                (segmentCellExternalSales, difference.externalSales),
                (segmentCellCapitalExpenditures, difference.capitalExpenditures),
                (capexCellSegmentAssets, difference.segmentAssetsCell),
            ] {
                guard let cell else { continue }
                let additive = assembled.rows
                    .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
                    .compactMap { row -> (Double, Int?)? in
                        switch key {
                        case segmentCellExternalSales:
                            return row.externalSales.map { ($0.value, $0.decimals) }
                        case segmentCellCapitalExpenditures:
                            return row.capitalExpenditures.map { ($0.value, $0.decimals) }
                        default:
                            return row.segmentAssetsCell.map { ($0.value, $0.decimals) }
                        }
                    }
                #expect(
                    isSegmentRoundingGap(
                        gap: cell.value, decimals: cell.decimals ?? additive.compactMap(\.1).min(),
                        summedRowCount: additive.count) == false)
                _ = key
            }
        }
        if let gaps = assembled.roundingGaps {
            for (key, gap) in gaps {
                let additive = assembled.rows
                    .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
                    .compactMap { row -> (Double, Int?)? in
                        switch key {
                        case segmentCellExternalSales:
                            return row.externalSales.map { ($0.value, $0.decimals) }
                        case segmentCellCapitalExpenditures:
                            return row.capitalExpenditures.map { ($0.value, $0.decimals) }
                        case capexCellSegmentAssets:
                            return row.segmentAssetsCell.map { ($0.value, $0.decimals) }
                        default:
                            return nil
                        }
                    }
                #expect(
                    isSegmentRoundingGap(
                        gap: gap, decimals: additive.compactMap(\.1).min(),
                        summedRowCount: max(additive.count, 1)))
            }
        }
        let json = assembled.jsonObject()
        #expect(json["amount"] == nil)
        let rows = try #require(json["rows"] as? [[String: Any]])
        #expect(rows.first?["amount"] == nil)
        let autoJSON = try #require(
            rows.first { $0["label_raw"] as? String == "AutomotiveReportableSegmentMember" })
        let ce = try #require(autoJSON[segmentCellCapitalExpenditures] as? [String: Any])
        #expect((ce["value"] as? NSNumber)?.int64Value == 2_453_641_000_000)
    }
}
