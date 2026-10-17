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

    private static func snapshot(
        _ docID: String, overviewFacts: BreakdownSnapshot? = nil
    ) -> BreakdownSnapshotPayload? {
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
            flowCompanyTotal: flowTotal, prebuiltAssets: assets,
            prebuiltOverviewFacts: overviewFacts)
    }

    /// facts 経路の Overview スナップショットに未タグ行の補完をかける（本番の resolveCapexBreakdown と同じ順）。
    private static func filledOverview(
        _ docID: String, decider: (any CapexOverviewRowDeciding)?
    ) async -> CapexOverviewUntaggedRowFill.FillResult? {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        guard let base = BreakdownNormalizer.normalizeCapitalExpendituresOverview(
            facts: facts, labelsByTag: XBRLUtils.breakdownMemberLabels(in: dir),
            memberParents: XBRLUtils.operatingSegmentMemberParents(in: dir))
        else { return nil }
        return await CapexOverviewUntaggedRowFill.fill(
            snapshot: base, facts: facts, xbrlDir: dir, decider: decider, docID: docID)
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

    /// トヨタ: 会社拡張の「消去又は全社」（設備投資 29,452 / 資産 14,532,118 百万円）。標準の調整
    /// member が無いので Jev（ここではスタブ）が会社拡張 member から選び、reconciling になる。
    /// Jev 無しは従来どおり segment。事業（自動車）を選んでも外部売上があるので採らない。
    // source: code=7203 fy_end=2026-03-31 doc_id=S100Y8NY page=146 row=消去又は全社
    @Test func toyotaCorporateExpensesAndEliminationIsReconciling() async throws {
        guard await Self.ensureAvailable("S100Y8NY") else { return }
        let dir = Self.xbrlDir("S100Y8NY")
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let candidates = SegmentMemberRoleJevPicker.candidates(
            facts: facts, labelsByTag: XBRLUtils.breakdownMemberLabels(in: dir))
        let members: [String] = candidates.map(\.member)
        #expect(members.contains("CorporateExpensesAndEliminationMember"))

        let elimination = await SegmentMemberRoleJevPicker.pick(
            candidates: candidates,
            decider: StubSegmentMemberRoleDecider(member: "CorporateExpensesAndEliminationMember"),
            docID: "S100Y8NY")
        #expect(elimination.members == ["CorporateExpensesAndEliminationMember"])
        let automotive = await SegmentMemberRoleJevPicker.pick(
            candidates: candidates,
            decider: StubSegmentMemberRoleDecider(member: "AutomotiveReportableSegmentMember"),
            docID: "S100Y8NY")
        #expect(automotive.members.isEmpty)

        let withRoles = try #require(
            BreakdownMemberRoles.$extraReconciling.withValue(elimination.members) { Self.snapshot("S100Y8NY") })
        let row = try #require(withRoles.rows.first { $0.labelRaw == "CorporateExpensesAndEliminationMember" })
        #expect(row.rowKind == "reconciling")
        #expect(row.flow == 29_452_000_000)
        #expect(row.segmentAssets == 14_532_118_000_000)
        let without = try #require(Self.snapshot("S100Y8NY"))
        #expect(without.rows.first { $0.labelRaw == "CorporateExpensesAndEliminationMember" }?.rowKind == "segment")
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
            if let tag = snapshot.flow?.denominatorTag {
                #expect(tag == "AdditionsOfFixedAssets" || tag.contains("Addition"))
            }
        }
        #expect(snapshot.segmentAssets != nil || snapshot.flow != nil
            || snapshot.capitalExpendituresOverview != nil)
    }

    /// パナソニックHD: 設備投資等の概要（億円）で「その他・全社」だけ ix:nonFraction が無い。報告セグメント・
    /// 報告セグメント計・合計にはタグがある。未タグ行の和（表示値 × タグ付きセルの倍率 1億円）が
    /// 「合計 − タグ付きセグメント」に一致し、Jev（ここではスタブ）が reconciling と分類したときだけ足す。
    /// Jev 無し・合計と分類したときは従来どおり行を足さない（S100W0F3 / S100TQZC は乖離 NR のまま）。
    // source: code=6752 fy_end=2026-03-31 doc_id=S100YETA page=45 field=capital_expenditures_overview row=その他・全社 276
    // source: code=6752 fy_end=2025-03-31 doc_id=S100W0F3 field=capital_expenditures_overview row=その他・全社 540
    // source: code=6752 fy_end=2024-03-31 doc_id=S100TQZC field=capital_expenditures_overview row=その他・全社 521
    @Test(arguments: [
        ("S100YETA", 629_100_000_000.0, 27_600_000_000.0),
        ("S100W0F3", 768_900_000_000.0, 54_000_000_000.0),
        ("S100TQZC", 568_000_000_000.0, 52_100_000_000.0),
    ])
    func panasonicUntaggedOtherAndCorporateOverviewRowIsReconciling(
        docID: String, total: Double, otherAndCorporate: Double
    ) async throws {
        guard await Self.ensureAvailable(docID) else { return }
        let filled = try #require(await Self.filledOverview(
            docID, decider: StubCapexOverviewRowDecider(answer: CapexOverviewUntaggedRowFill.reconcilingKey)))
        #expect(filled.audit?.applied == true)
        let snapshot = try #require(Self.snapshot(docID, overviewFacts: filled.snapshot))
        #expect(snapshot.capitalExpendituresOverview?.denominator == total)
        let row = try #require(snapshot.rows.first { $0.labelRaw == "その他・全社" })
        #expect(row.rowKind == "reconciling")
        #expect(row.capitalExpendituresOverview == otherAndCorporate)
        let additive = snapshot.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .compactMap(\.capitalExpendituresOverview).reduce(0, +)
        #expect(additive == total)
        #expect(!snapshot.warnings.contains("capital_expenditures_overview_segment_sum_far_from_total"))
        #expect(snapshot.needsReview == false)

        for decider: (any CapexOverviewRowDeciding)? in [
            nil, StubCapexOverviewRowDecider(answer: CapexOverviewUntaggedRowFill.totalKey),
        ] {
            let kept = try #require(await Self.filledOverview(docID, decider: decider))
            #expect(!kept.snapshot.rows.contains { $0.labelRaw == "その他・全社" })
        }
    }

    /// 味の素: Overview 総額タグ 96,439百万円が分母。segment+reconciling 96,437 は分母にしない。
    @Test func ajinomotoOverviewDenominatorIsEntityTotalNotSegmentSum() async throws {
        guard await Self.ensureAvailable("S100VXJA") else { return }
        let snapshot = try #require(Self.snapshot("S100VXJA"))
        #expect(snapshot.capitalExpendituresOverview?.denominator == 96_439_000_000)
        let additive = snapshot.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .compactMap(\.capitalExpendituresOverview).reduce(0, +)
        #expect(additive == 96_437_000_000)
        #expect(snapshot.needsReview == false)
        let entity = snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName }
        if let entity {
            #expect(entity.rowKind == breakdownRowKindEntityTotal)
            #expect(entity.capitalExpendituresOverview == 96_439_000_000)
        }
    }
}

/// 未タグ行の種別に固定の答えを返すスタブ（3 サンプルとも同じ答え）。
struct StubCapexOverviewRowDecider: CapexOverviewRowDeciding {
    var answer: String
    func classifyOverviewRow(
        table: CapexOverviewUntaggedRowFill.Table, row: CapexOverviewUntaggedRowFill.Row, docID: String
    ) async -> JevChoiceAggregate.Sample {
        JevChoiceAggregate.Sample(
            selected: answer, probability: 0.97,
            options: CapexOverviewUntaggedRowFill.optionKeys, model: "stub")
    }
}

/// 指定 member の候補キーを返すスタブ（3 サンプルとも同じ答え）。
struct StubSegmentMemberRoleDecider: SegmentMemberRoleDeciding {
    var member: String
    func chooseReconcilingMember(
        candidates: [SegmentMemberRoleCandidate], docID: String
    ) async -> JevChoiceAggregate.Sample {
        let key = candidates.first { $0.member == member }?.key ?? JevDecision.noneOfThese
        return JevChoiceAggregate.Sample(
            selected: key, probability: 0.97,
            options: candidates.map(\.key) + [JevDecision.noneOfThese], model: "stub")
    }
}
