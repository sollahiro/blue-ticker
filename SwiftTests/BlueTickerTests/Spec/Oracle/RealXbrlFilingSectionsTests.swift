// 有報セクション切り出しの実データ回帰（SPEC_ORACLE の L1 実行器）。
// 節ごとの XBRL TextBlock を正本にする。見出し探索だけだと別の節が入る・途中で切れる。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlFilingSectionsTests {
    /// トヨタ。研究開発活動に MD&A が入り、事業等のリスクが導入2段落で切れていた。
    /// source: code=7203 fy_end=2026-03-31 doc_id=S100Y8NY page=6 field=research_and_development
    /// （page は第2【事業の状況】の項番。PDF 頁は未確認。business_risks は項番3、mda は項番4）
    @Test func toyotaSectionsFollowTheirOwnTextBlocks() async throws {
        await SmokeCacheSupport.ensureCached(["S100Y8NY"])
        let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("S100Y8NY_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let found = XBRLParser().extractSectionsPreferringTextBlocks(in: dir, sections: xbrlSections)

        let rd = try #require(found["research_and_development"])
        #expect(rd.hasPrefix("６ 【研究開発活動】"))
        #expect(rd.contains("クリーンで安全な商品の提供"))
        #expect(!rd.contains("経営成績の状況"))

        let risks = try #require(found["business_risks"])
        #expect(risks.hasPrefix("３ 【事業等のリスク】"))
        #expect(risks.count > 5_000)

        let mda = try #require(found["mda"])
        #expect(mda.hasPrefix("４ 【経営者による財政状態、経営成績及びキャッシュ・フローの状況の分析】"))
        #expect(mda.contains("\n"))
    }

    @Test func plainTextKeepsParagraphAndTableRowBreaks() {
        let html = "<p>第一段落</p><p>第二段落<br/>改行後</p><table><tr><td>売上</td><td>100</td></tr><tr><td>利益</td><td>5</td></tr></table>"
        let text = XBRLParser.plainTextKeepingBreaks(fromHTML: html)
        #expect(text == "第一段落\n第二段落\n改行後\n売上 100\n利益 5")
    }
}
