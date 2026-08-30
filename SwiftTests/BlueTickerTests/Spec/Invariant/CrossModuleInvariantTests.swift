// モジュール横断 SPEC_INVARIANT（.agents/skills/xbrl-development/SKILL.md、2026-08-09）。
//
// IBDExtractor（有利子負債抽出器、Analysis/Extractors.swift）の借入金等明細表フォールバックと
// StatementNotesResolver.resolveBorrowingsSchedule（財務諸表注記取り込み borrowings_schedule note_type）は
// どちらも BorrowingsSchedule.extract 系（BorrowingsSchedule.swift）が同じ `parseTable` 結果を経由する
// ため、明細表が解決した書類では常に合計が一致するはずである。IBDExtractor.extract は連結BSの
// XBRL タグ（field_parser）が解決できるときは明細表より優先するため、その最終結果
// （method="field_parser"）は明細表側の合計とは一致しない場合がある（実データで確認済み、
// SOMPO S100R1LR。field_parser 経由 total=609,051,000,000 に対し明細表側の合計は
// 662,453,000,000。この値は以前は使い捨てのダンプ用テストでしか確認していなかったため、
// 2026-08-09 の監査指摘を受けて下記 `borrowingsScheduleReconcilesWithNoteTotalEvenWhenIbdPrefersFieldParser`
// にリポジトリ内の検証可能な値として固定した）。
//
// したがって本テストは IBDExtractor.extract を実際に呼び、method="borrowings_schedule" で
// 解決した docID のみ明細表合計との一致を検証し、method="field_parser" の docID では
// 「一致しないこと」自体を仕様として検証する（IBDExtractorを経由しない
// `BorrowingsSchedule.extract` と `resolveBorrowingsSchedule` の一致だけでは、両者とも
// 同じ `parseTable` のラッパーに過ぎず IBDExtractor モジュールを一切通らないため、
// 「横断」INVARIANT として弱すぎるという指摘に対応）。
//
// 対象docIDは `RealXbrlStatementNotesTests.swift` の borrowings_schedule golden ケースのうち、
// ローカルキャッシュで動作確認済みの3件（2026-08-09、実データ検証）。他の golden docID にも
// 同じ関係が成り立つはずだが未確認のため含めない。

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

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    /// 明細表側（IBDExtractorを経由しない2エントリポイント）が常に一致することの確認。
    /// これ自体は `parseTable` の共有に由来する構造的な一致であり、IBDExtractor 側の
    /// 分岐選択が正しいかどうかまでは検証しない（それは呼び出し元の各 `@Test` が担う）。
    private func scheduleNoteTotal(docID: String) throws -> (current: Double?, prior: Double?) {
        let dir = Self.xbrlDir(docID)
        guard case .resolved(let payload, _, _) = StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: dir) else {
            Issue.record("docID=\(docID): resolveBorrowingsSchedule did not resolve")
            return (nil, nil)
        }
        let noteTotal = try #require(payload.borrowingsComponents?.first { $0.isTotal })
        let direct = try #require(BorrowingsSchedule.extract(xbrlDir: dir, accountingStandard: "unused"))

        #expect(direct.total == noteTotal.currentBalance)
        #expect(direct.priorTotal == noteTotal.priorBalance)
        return (noteTotal.currentBalance, noteTotal.priorBalance)
    }

    private func ibdResult(docID: String) -> IBDResult {
        let dir = Self.xbrlDir(docID)
        let (fs, std) = XBRLTestSupport.instantFieldSet(in: dir)
        return IBDExtractor.extract(fieldSet: fs, accountingStandard: std, xbrlDir: dir)
    }

    // MARK: - S100JRT9（リース負債のみの明細表。IBDExtractor も method="borrowings_schedule" で解決）

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func borrowingsScheduleReconcilesWithNoteTotalLeaseOnly() throws {
        let noteTotal = try scheduleNoteTotal(docID: "S100JRT9")
        let ibd = ibdResult(docID: "S100JRT9")

        #expect(ibd.method == "borrowings_schedule")
        #expect(ibd.total == noteTotal.current)
        #expect(ibd.priorTotal == noteTotal.prior)
    }

    // MARK: - S100R1LR（SOMPO。連結BSタグが解決できるため IBDExtractor は method="field_parser" を
    // 優先する。IBD の最終値は明細表合計とは一致せず、これは仕様どおりの挙動である）

    @Test(.enabled(if: cacheAvailable("S100R1LR"), "XBRL cache S100R1LR not available"))
    func borrowingsScheduleReconcilesWithNoteTotalEvenWhenIbdPrefersFieldParser() throws {
        let noteTotal = try scheduleNoteTotal(docID: "S100R1LR")
        #expect(noteTotal.current == 662_453_000_000)

        let ibd = ibdResult(docID: "S100R1LR")
        #expect(ibd.method == "field_parser")
        // 実データ検証済み（2026-08-09）: 連結BSタグ側の合計は明細表合計と一致しない
        // （タグ側は明細表に含まれる一部の非借入項目・デリバティブ負債等を含まない）。
        #expect(ibd.total == 609_051_000_000)
        #expect(ibd.total != noteTotal.current)
    }

    // MARK: - S100YHZG（三菱重工業。自社拡張タグ・非借入項目を含む全体構造化。IBDExtractor も
    // method="borrowings_schedule" で解決）

    @Test(.enabled(if: cacheAvailable("S100YHZG"), "XBRL cache S100YHZG not available"))
    func borrowingsScheduleReconcilesWithNoteTotalCompanySpecificTags() throws {
        let noteTotal = try scheduleNoteTotal(docID: "S100YHZG")
        let ibd = ibdResult(docID: "S100YHZG")

        #expect(ibd.method == "borrowings_schedule")
        #expect(ibd.total == noteTotal.current)
        #expect(ibd.priorTotal == noteTotal.prior)
    }
}
