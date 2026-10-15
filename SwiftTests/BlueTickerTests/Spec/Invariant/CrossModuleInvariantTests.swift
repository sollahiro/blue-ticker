// モジュール横断 SPEC_INVARIANT（.agents/skills/xbrl-development/SKILL.md、2026-08-09）。
//
// IBDExtractor（有利子負債抽出器、Analysis/IBDExtractor.swift）の借入金等明細表フォールバックと
// BorrowingsSchedule.extract（明細表パーサ）は同じ `parseTable` 結果を経由するため、明細表が
// 解決した書類では常に合計が一致するはずである。IBDExtractor.extract は連結BSの
// XBRL タグ（field_parser）が解決できるときは明細表より優先するため、その最終結果
// （method="field_parser"）は明細表側の合計とは一致しない場合がある（実データで確認済み、
// SOMPO S100R1LR。field_parser 経由 total=609,051,000,000 に対し明細表側の合計は
// 662,453,000,000。この値は以前は使い捨てのダンプ用テストでしか確認していなかったため、
// 2026-08-09 の監査指摘を受けて下記 `borrowingsScheduleReconcilesWithParserTotalEvenWhenIbdPrefersFieldParser`
// にリポジトリ内の検証可能な値として固定した）。
//
// 公開 note_type `borrowings_schedule` は廃止した。本テストは IBDExtractor.extract を実際に呼び、
// method="borrowings_schedule" で解決した docID のみパーサ合計との一致を検証し、
// method="field_parser" の docID では「一致しないこと」自体を仕様として検証する。
//
// 対象docIDは `RealXbrlStatementNotesTests.swift` の BorrowingsSchedule golden ケースのうち、
// ローカルキャッシュで動作確認済みの3件（2026-08-09、実データ検証）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct CrossModuleInvariantTests {
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
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし")
            return false
        }
        return true
    }

    /// 明細表パーサの合計。公開 notes 経路は使わない。
    private func scheduleParserTotal(docID: String) throws -> (current: Double?, prior: Double?) {
        let dir = Self.xbrlDir(docID)
        let direct = try #require(BorrowingsSchedule.extract(xbrlDir: dir, accountingStandard: "unused"))
        return (direct.total, direct.priorTotal)
    }

    private func ibdResult(docID: String) -> IBDResult {
        let dir = Self.xbrlDir(docID)
        let (fs, std) = XBRLTestSupport.instantFieldSet(in: dir)
        return IBDExtractor.extract(fieldSet: fs, accountingStandard: std, xbrlDir: dir)
    }

    // MARK: - S100JRT9（リース負債のみの明細表。IBDExtractor も method="borrowings_schedule" で解決）

    @Test func borrowingsScheduleReconcilesWithParserTotalLeaseOnly() async throws {
        guard await Self.ensureAvailable("S100JRT9") else { return }
        let parserTotal = try scheduleParserTotal(docID: "S100JRT9")
        let ibd = ibdResult(docID: "S100JRT9")

        #expect(ibd.method == "borrowings_schedule")
        #expect(ibd.total == parserTotal.current)
        #expect(ibd.priorTotal == parserTotal.prior)
    }

    // MARK: - S100R1LR（SOMPO。連結BSタグが解決できるため IBDExtractor は method="field_parser" を
    // 優先する。IBD の最終値は明細表合計とは一致せず、これは仕様どおりの挙動である）

    @Test func borrowingsScheduleReconcilesWithParserTotalEvenWhenIbdPrefersFieldParser() async throws {
        guard await Self.ensureAvailable("S100R1LR") else { return }
        let parserTotal = try scheduleParserTotal(docID: "S100R1LR")
        #expect(parserTotal.current == 662_453_000_000)

        let ibd = ibdResult(docID: "S100R1LR")
        #expect(ibd.method.hasPrefix("field_parser"))
        #expect(ibd.method != "borrowings_schedule")
        // 実データ検証済み（2026-08-09）: 連結BSタグ側の合計は明細表合計と一致しない
        // （タグ側は明細表に含まれる一部の非借入項目・デリバティブ負債等を含まない）。
        // notes のリース帳簿を field_parser に足すと method は field_parser+lease_notes
        // （609,051 + 80,366 = 689,417）。どちらでも明細表 662,453 とは一致しない。
        if ibd.method == "field_parser+lease_notes" {
            #expect(ibd.total == 689_417_000_000)
        } else {
            #expect(ibd.total == 609_051_000_000)
        }
        #expect(ibd.total != parserTotal.current)
    }

    // MARK: - S100YHZG（三菱重工業。自社拡張タグ・非借入項目を含む全体構造化。IBDExtractor も
    // method="borrowings_schedule" で解決）

    @Test func borrowingsScheduleReconcilesWithParserTotalCompanySpecificTags() async throws {
        guard await Self.ensureAvailable("S100YHZG") else { return }
        let parserTotal = try scheduleParserTotal(docID: "S100YHZG")
        let ibd = ibdResult(docID: "S100YHZG")

        #expect(ibd.method == "borrowings_schedule")
        #expect(ibd.total == parserTotal.current)
        #expect(ibd.priorTotal == parserTotal.prior)
    }
}
