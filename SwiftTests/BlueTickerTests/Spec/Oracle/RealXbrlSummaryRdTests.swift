// Summary rd の実データ回帰（SPEC_ORACLE の L1 実行器）。対象企業は各 @Test にハードコード。
// 期待値は有報原本（連結損益計算書の研究開発費注記、千円開示）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlSummaryRdTests {
    private static func dir(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID])
        let url = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// ユビテック。連結損益計算書 ※3 研究開発費 17,723千円（前期 6,482千円）。
    /// source: code=6662 fy_end=2026-06-30 doc_id=S100Z42X page=41 field=summary.rd
    @Test func ubiquitecRdIsThousandYenNoteNotProseRounded() async throws {
        guard let dir = await Self.dir("S100Z42X") else { return }
        let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
        #expect(rd.value == 17_723_000)
    }

    /// 環境管理センター。※3 研究開発費の総額 19,470千円（地の文は 19百万円の丸め）。
    /// source: code=4657 fy_end=2026-06-30 doc_id=S100Z45G page=54 field=summary.rd
    @Test func kankyoRdIsThousandYenNoteNotProseRounded() async throws {
        guard let dir = await Self.dir("S100Z45G") else { return }
        let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: dir)
        #expect(rd.value == 19_470_000)
    }
}
