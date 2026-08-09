// モジュール横断 SPEC_INVARIANT（docs/test-spec-assets.md の D、2026-08-09）。
//
// IBDExtractor（有利子負債抽出器、Analysis/Extractors.swift）の借入金等明細表フォールバックと
// StatementNotesResolver.resolveBorrowingsSchedule（財務諸表注記取り込み borrowings_schedule note_type）は
// どちらも BorrowingsSchedule.extract 系（BorrowingsSchedule.swift）が同じ `parseTable` 結果を経由する
// ため、明細表が解決した書類では常に合計が一致するはずである。IBDExtractor.extract は連結BSの
// XBRL タグ（field_parser）が解決できるときは明細表より優先するため、IBDExtractor.extract の
// 最終結果（method="field_parser"）とは一致しない場合がある（実データで確認済み、SOMPO S100R1LR。
// field_parser 経由 total=609,051,000,000 に対し明細表側の合計は 662,453,000,000）。したがって
// 比較対象は IBDExtractor 経由ではなく、両モジュールが直接呼ぶ `BorrowingsSchedule.extract` と
// `resolveBorrowingsSchedule` の2エントリポイントとする。
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

    private func assertReconciles(docID: String) throws {
        let dir = Self.xbrlDir(docID)
        guard case .resolved(let payload, _, _) = StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: dir) else {
            Issue.record("docID=\(docID): resolveBorrowingsSchedule did not resolve")
            return
        }
        let noteTotal = try #require(payload.borrowingsComponents?.first { $0.isTotal })
        let direct = try #require(BorrowingsSchedule.extract(xbrlDir: dir, accountingStandard: "unused"))

        #expect(direct.total == noteTotal.currentBalance)
        #expect(direct.priorTotal == noteTotal.priorBalance)
    }

    // MARK: - S100JRT9（リース負債のみの明細表。IBDExtractor も method="borrowings_schedule" で解決）

    @Test(.enabled(if: cacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func borrowingsScheduleReconcilesWithNoteTotalLeaseOnly() throws {
        try assertReconciles(docID: "S100JRT9")
    }

    // MARK: - S100R1LR（SOMPO。IBDExtractor は method="field_parser" を優先し明細表合計とは一致しない
    // が、BorrowingsSchedule.extract を直接呼んだ場合はここでも一致する）

    @Test(.enabled(if: cacheAvailable("S100R1LR"), "XBRL cache S100R1LR not available"))
    func borrowingsScheduleReconcilesWithNoteTotalEvenWhenIbdPrefersFieldParser() throws {
        try assertReconciles(docID: "S100R1LR")
    }

    // MARK: - S100YHZG（三菱重工業。自社拡張タグ・非借入項目を含む全体構造化）

    @Test(.enabled(if: cacheAvailable("S100YHZG"), "XBRL cache S100YHZG not available"))
    func borrowingsScheduleReconcilesWithNoteTotalCompanySpecificTags() throws {
        try assertReconciles(docID: "S100YHZG")
    }
}
