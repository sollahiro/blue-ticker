// 外出し SPEC_ORACLE フォーマット（`StatementNotesOracleFormatTests.swift`=borrowings_schedule と同型）。
//
// - 試作2docID（レーザーテック J-GAAP / 日立 IFRS）: `RealXbrlStatementNotesTests` の既存golden
//   （ユーザー実データ確認済み）を転記。analysis_cache 経路。このマシンにキャッシュが無い場合は SKIP。
// - smoke 固定11社: 2026-08-11 にユーザーが数値確認済み（US-GAAP BPS 含む。diluted_eps 欠落は
//   希薄化証券なしとして正当）。`SmokeCacheSupport` / `tmp_cache/edinet` 経路。
//
// 既存ハードコードgoldenテストを置き換えるものではなく併存させる。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct PerShareInformationOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/statement_notes_per_share_information_expected.json")

    private func assertMatchesOracle(docID: String, xbrlDir: URL) throws {
        let result = StatementNotesResolver.resolvePerShareInformation(xbrlDir: xbrlDir)
        let items: [[String: Any]]?
        if case .resolved(let payload, _, _) = result {
            items = payload.items?.map { $0.jsonObject() }
        } else {
            items = nil
        }
        try StatementNotesOracleSupport.assertMatchesOracle(
            docID: docID, expectedFileURL: Self.expectedFileURL, result: result,
            itemsKey: "items", items: items)
    }

    private func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        try await StatementNotesOracleSupport.withSmokeCache(docID, body)
    }

    // MARK: - 試作（analysis_cache）

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100JRT9"), "XBRL cache S100JRT9 not available"))
    func perShareMatchesExternalizedOracleLaserTecJGAAP() throws {
        try assertMatchesOracle(docID: "S100JRT9", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100JRT9"))
    }

    @Test(.enabled(if: StatementNotesOracleSupport.analysisCacheAvailable("S100QZT0"), "XBRL cache S100QZT0 not available"))
    func perShareMatchesExternalizedOracleHitachiIFRS() throws {
        try assertMatchesOracle(docID: "S100QZT0", xbrlDir: StatementNotesOracleSupport.analysisXbrlDir("S100QZT0"))
    }

    // MARK: - smoke 床11社（tmp_cache / SmokeCacheSupport）

    @Test
    func smokePerShareAZplanningMatchesOracle() async throws {
        try await withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareAjinomotoMatchesOracle() async throws {
        try await withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareNichireiMatchesOracle() async throws {
        try await withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareOkumaMatchesOracle() async throws {
        try await withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareSMFGMatchesOracle() async throws {
        try await withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareFujifilmMatchesOracle() async throws {
        try await withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareMUFGMatchesOracle() async throws {
        try await withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareSuzukiMatchesOracle() async throws {
        try await withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareKubotaMatchesOracle() async throws {
        try await withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareTohoRemacMatchesOracle() async throws {
        try await withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", xbrlDir: $0)
        }
    }

    @Test
    func smokePerShareCanonMatchesOracle() async throws {
        try await withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", xbrlDir: $0)
        }
    }
}
