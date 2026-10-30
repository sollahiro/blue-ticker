import Foundation
import Testing

@testable import BlueTickerCore

/// 提出パッケージの _lab.xml は会社拡張のラベルだけを持ち、標準科目（受取利息 等）の
/// ラベルは標準タクソノミ側にある。presentation arc に preferredLabel が無い行でも
/// 標準ラベルで名前を付ける（label null の行を出さない）。
@Suite struct StatementStandardLabelFallbackTests {
    private func xbrlDir(_ docID: String) async -> URL? {
        let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        await SmokeCacheSupport.ensureCached([docID])
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// SPEC_ORACLE: 単体のみの提出（S100ZA4E 損益計算書 p.81）。受取利息 42,618千円・補助金収入 72,167千円。
    @Test func standardTagsWithoutPreferredLabelGetTaxonomyLabels() async throws {
        let docID = "S100ZA4E"
        guard let dir = await xbrlDir(docID) else { return }
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: dir, docID: docID,
            statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity])
        else {
            Issue.record("\(docID): statement not resolved")
            return
        }
        let pl = year.incomeStatement
        #expect(pl.first { $0.tag == "InterestIncomeNOI" }?.label == "受取利息")
        #expect(pl.first { $0.tag == "SubsidyIncomeNOI" }?.label == "補助金収入")
        for (name, items) in [("PL", pl), ("BS", year.balanceSheet), ("CF", year.cashFlow),
                              ("SS", year.changesInEquity)] {
            let missing = items.filter { $0.label == nil }.map(\.tag)
            #expect(missing.isEmpty, "\(name) label nil: \(missing)")
        }
    }

    /// SPEC_ORACLE: 2025年版タクソノミ（2024-11-01）で書かれた 4813 S100Y070。
    /// 現行版で廃止された jppfs_cor:AccumulatedDepreciationRightOfUseAssets 等も名前が付く。
    @Test func conceptsRemovedFromCurrentTaxonomyGetPreviousVersionLabels() async throws {
        let docID = "S100Y070"
        guard let dir = await xbrlDir(docID) else { return }
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: dir, docID: docID,
            statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity])
        else {
            Issue.record("\(docID): statement not resolved")
            return
        }
        let bs = year.balanceSheet
        #expect(bs.contains { $0.tag == "AccumulatedDepreciationRightOfUseAssets" })
        for (name, items) in [("PL", year.incomeStatement), ("BS", bs), ("CF", year.cashFlow),
                              ("SS", year.changesInEquity)] {
            let missing = items.filter { $0.label == nil }.map(\.tag)
            #expect(missing.isEmpty, "\(name) label nil: \(missing)")
        }
    }
}
