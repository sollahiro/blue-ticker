// 実 EDINET XBRL キャッシュでの segment_assets EntityTotal 比較（SPEC_ORACLE の L1）。
// 個別 NoncurrentAssets を EntityTotal にしないこと、連結 BS 合計の妥当な NR は残すこと。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlSegmentAssetsEntityTotalTests {

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

    private static func snapshot(_ docID: String) -> BreakdownSnapshot? {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let base = BreakdownNormalizer.normalizeSegmentAssets(
            facts: facts, labelsByTag: XBRLUtils.breakdownMemberLabels(in: dir))
        return BreakdownNormalizer.enrichSegmentAssetsWithDifferenceTable(snapshot: base, xbrlDir: dir)
    }

    /// 三菱 UFJ S100YJQO: 表合計 TotalMember ≈ 分母。個別 NoncurrentAssets は EntityTotal にしない。
    @Test func mufgLatestDoesNotFlagNonConsolidatedEntityTotal() async throws {
        guard await Self.ensureAvailable("S100YJQO") else { return }
        let snapshot = try #require(Self.snapshot("S100YJQO"))
        #expect(snapshot.denominatorTag == "NoncurrentAssets")
        let tableTotal = try #require(snapshot.rows.first { $0.labelRaw == "TotalMember" })
        #expect(abs(snapshot.denominator - tableTotal.amount) / snapshot.denominator <= 0.05)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("segment_assets_entity_total_differs_from_table_total"))
        if let entity = snapshot.rows.first(where: { $0.labelRaw == Xbrl.entityTotalMemberName }) {
            #expect(abs(entity.amount - snapshot.denominator) / snapshot.denominator <= 0.05)
        }
    }

    /// みずほ S100YF8Y: 同型。
    @Test func mizuhoLatestDoesNotFlagNonConsolidatedEntityTotal() async throws {
        guard await Self.ensureAvailable("S100YF8Y") else { return }
        let snapshot = try #require(Self.snapshot("S100YF8Y"))
        #expect(snapshot.denominatorTag == "NoncurrentAssets")
        let tableTotal = try #require(
            snapshot.rows.first { $0.labelRaw == "ReportableSegmentsMember" })
        #expect(abs(snapshot.denominator - tableTotal.amount) / snapshot.denominator <= 0.05)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("segment_assets_entity_total_differs_from_table_total"))
    }

    /// 三井住友トラスト S100YBGM: 同クラス。
    @Test func sumitomoTrustLatestDoesNotFlagNonConsolidatedEntityTotal() async throws {
        guard await Self.ensureAvailable("S100YBGM") else { return }
        let snapshot = try #require(Self.snapshot("S100YBGM"))
        #expect(snapshot.denominatorTag == "NoncurrentAssets")
        let tableTotal = try #require(
            snapshot.rows.first { $0.labelRaw == "TotalOfReportableSegmentsAndOthersMember" })
        #expect(abs(snapshot.denominator - tableTotal.amount) / snapshot.denominator <= 0.05)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("segment_assets_entity_total_differs_from_table_total"))
    }

    /// あおぞら S100YCRO: 差額表の非分類行を reconciling に足し分母=連結 BS。
    @Test func aozoraDifferenceTableReconcilingMatchesConsolidatedBs() async throws {
        guard await Self.ensureAvailable("S100YCRO") else { return }
        let snapshot = try #require(Self.snapshot("S100YCRO"))
        #expect(snapshot.denominatorTag == "Assets")
        let tableTotal = try #require(
            snapshot.rows.first { $0.labelRaw == "ReportableSegmentsMember" })
        #expect(tableTotal.rowKind == "subtotal")
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("segment_assets_entity_total_differs_from_table_total"))
        #expect(snapshot.rows.contains { $0.rowKind == "reconciling" && ($0.label ?? "").contains("貸倒引当金") })
        let entity = try #require(
            snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entity.amount == 8_601_673_000_000)
        #expect(abs(snapshot.denominator - entity.amount) / entity.amount <= 0.0001)
    }

    /// NTN S100Y8YZ: ReconcilingItems 消去後分母 = 連結 BS 資産合計。
    @Test func ntnReconcilingSignMatchesConsolidatedBsTotal() async throws {
        guard await Self.ensureAvailable("S100Y8YZ") else { return }
        let snapshot = try #require(Self.snapshot("S100Y8YZ"))
        #expect(snapshot.denominatorTag == "Assets")
        #expect(abs(snapshot.denominator - 878_676_000_000) <= 2_000_000)
        #expect(snapshot.needsReview == false)
        #expect(!snapshot.warnings.contains("segment_assets_entity_total_differs_from_table_total"))
        let reconciling = try #require(
            snapshot.rows.first { $0.labelRaw == "ReconcilingItemsMember" })
        #expect(reconciling.amount < 0)
        let entity = try #require(
            snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entity.amount == 878_676_000_000)
    }

    /// アコム S100YBXA / ミニストップ S100Y4UH: 差額表非分類を reconciling に載せ分母=連結 BS。
    @Test func acomAndMinistopDifferenceTableReconcilingMatchesBs() async throws {
        for docID in ["S100YBXA", "S100Y4UH"] {
            guard await Self.ensureAvailable(docID) else { continue }
            let snapshot = try #require(Self.snapshot(docID))
            let entity = try #require(
                snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
            #expect(snapshot.needsReview == false)
            #expect(!snapshot.warnings.contains("segment_assets_entity_total_differs_from_table_total"))
            #expect(!snapshot.warnings.contains("segment_assets_segment_sum_far_from_total"))
            #expect(abs(snapshot.denominator - entity.amount) / entity.amount <= 0.0001)
        }
    }

    /// アコム S100YBXA: 「その他」区分と同額の差額表 reconciling は落とし、分母=1,616,379 百万円相当。
    @Test func acomDropsDuplicateDifferenceTableReconciling() async throws {
        guard await Self.ensureAvailable("S100YBXA") else { return }
        let snapshot = try #require(Self.snapshot("S100YBXA"))
        let duplicateLabel = "その他の区分の資産"
        #expect(!snapshot.rows.contains {
            $0.rowKind == "reconciling"
                && ($0.label ?? "").replacingOccurrences(of: " ", with: "").contains(
                    duplicateLabel.replacingOccurrences(of: " ", with: ""))
        })
        let entity = try #require(
            snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entity.amount == 1_616_379_000_000)
        #expect(abs(snapshot.denominator - entity.amount) <= 2_000_000)
    }
}
