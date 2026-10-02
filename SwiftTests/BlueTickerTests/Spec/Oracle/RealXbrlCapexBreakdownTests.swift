// 実 EDINET XBRL キャッシュでの capex マトリクス回帰（SPEC_ORACLE の L1）。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlCapexBreakdownTests {
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

    private static func snapshot(_ docID: String) -> BreakdownSnapshotPayload? {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labels = XBRLUtils.breakdownMemberLabels(in: dir)
        let members = XBRLUtils.operatingSegmentMemberParents(in: dir)
        var assets = BreakdownNormalizer.normalizeSegmentAssets(
            facts: facts, labelsByTag: labels, memberParents: members)
        assets = BreakdownNormalizer.enrichSegmentAssetsWithDifferenceTable(
            snapshot: assets, xbrlDir: dir)
        var overviewHTML: BreakdownSnapshot?
        if case .resolved(let note, _, _) =
            StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: dir),
            let segments = note.capexSegments
        {
            overviewHTML = BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                segments: segments)
        }
        let overviewTotal = BreakdownFinancialsResolver.breakdownCanonicalCapexOverviewItem(
            xbrlDir: dir)
        let allTags = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
        let durationFS = fieldSetFromDuration(allTags)
        let cePresent = CapexNormalizer.filingHasCurrentTags(
            in: dir, tags: Xbrl.segmentCapitalExpenditureTags)
        let naaPresent = CapexNormalizer.filingHasCurrentTags(
            in: dir, tags: Xbrl.segmentNoncurrentAssetAdditionTags)
        let flowTags = cePresent
            ? Xbrl.segmentCapitalExpenditureTags : Xbrl.segmentNoncurrentAssetAdditionTags
        let flowItem = resolveItem(durationFS, tags: flowTags)
        let flowTotal: (value: Double, tag: String)? =
            flowItem.current.flatMap { value in
                guard let tag = flowItem.tag, value > 0 else { return nil }
                return (value, tag)
            }
        return CapexNormalizer.normalize(
            facts: facts, labelsByTag: labels, memberParents: members,
            capitalExpendituresPresent: cePresent, noncurrentAssetAdditionsPresent: naaPresent,
            overviewHTML: overviewHTML,
            overviewCompanyTotal: overviewTotal.value.flatMap { value in
                guard let tag = overviewTotal.tag, value > 0 else { return nil }
                return (value, tag)
            },
            flowCompanyTotal: flowTotal, prebuiltAssets: assets)
    }

    /// 富士フイルム: Overview タグにセグメント dimension。資産・フローがあれば同じ member に載る。
    @Test func fujifilmJoinsOverviewFactsByMember() async throws {
        guard await Self.ensureAvailable("S100W3XJ") else { return }
        let snapshot = try #require(Self.snapshot("S100W3XJ"))
        #expect(snapshot.axis == breakdownAxisCapex)
        #expect(snapshot.capitalExpendituresOverview?.denominator == 532_138_000_000)
        let healthcare = try #require(
            snapshot.rows.first { $0.labelRaw == "HealthcareReportableSegmentsMember" })
        #expect(healthcare.rowKind == "segment")
        #expect(healthcare.capitalExpendituresOverview == 448_362_000_000)
        let entity = snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName }
        if let entity {
            #expect(entity.rowKind == breakdownRowKindEntityTotal)
        }
        let json = snapshot.jsonObject()
        #expect(json["amount"] == nil)
        #expect((json["rows"] as? [[String: Any]])?.first?["amount"] == nil)
    }

    /// スズキ: 資本的支出タグがあり、同居する NAA があってもフローは CE。
    @Test func suzukiUsesCapitalExpendituresFlowWhenPresentOnFiling() async throws {
        guard await Self.ensureAvailable("S100W4MT") else { return }
        let snapshot = try #require(Self.snapshot("S100W4MT"))
        #expect(snapshot.flowMetric == capexFlowMetricCapitalExpenditures)
        #expect(snapshot.flow?.denominatorTag == "CapitalExpendituresIFRS")
        let subtotal = snapshot.rows.first { $0.labelRaw == "ReportableSegmentsMember" }
        if let subtotal {
            #expect(subtotal.flow == 419_699_000_000)
        }
    }

    /// 三菱UFJ: 銀行は固定資産増加額。資本的支出が無ければ NAA。
    @Test func mufgUsesNoncurrentAdditionsWhenCapitalExpendituresAbsent() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let snapshot = try #require(Self.snapshot("S100W4FB"))
        if snapshot.flowMetric != nil {
            #expect(snapshot.flowMetric != capexFlowMetricCapitalExpenditures
                || CapexNormalizer.filingHasCurrentTags(
                    in: Self.xbrlDir("S100W4FB"), tags: Xbrl.segmentCapitalExpenditureTags))
        }
        if snapshot.flowMetric == capexFlowMetricNoncurrentAssetAdditions {
            #expect(snapshot.flow?.denominatorTag == "AdditionsOfFixedAssets"
                || snapshot.flow?.denominatorTag.contains("Addition") == true)
        }
        #expect(snapshot.segmentAssets != nil || snapshot.flow != nil
            || snapshot.capitalExpendituresOverview != nil)
    }
}
