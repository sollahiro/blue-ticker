// 連結附属明細表「借入金等明細表」からの有利子負債抽出
//
// 連結BSに有利子負債の数値タグが存在しない企業（リース債務が明細表のみに記載される等）向けの
// フォールバック。明細表は「区分 | 当期首残高 | 当期末残高 | 平均利率 | 返済期限」の固定列で、
// 当期首残高=前期末、当期末残高=当期末。最終行の「合計」で有利子負債総額を確定する。

import Foundation
import SwiftSoup

enum BorrowingsSchedule {

    /// リース債務行は「リース負債（流動/非流動）」へ正規化し、コードベース全体の表示ラベルに揃える。
    /// それ以外の区分（短期借入金・社債・長期借入金等）は明細表の表記をそのまま使う。
    private static func displayLabel(for normalizedLabel: String) -> String {
        guard normalizedLabel.contains("リース") else { return normalizedLabel }
        // 「1年以内に返済予定のものを除く」は非流動。"1年以内" を含むため除外判定を先に行う。
        if normalizedLabel.contains("除く") { return "リース負債（非流動）" }
        let currentMarkers = ["1年以内", "1年内", "１年以内", "１年内", "流動"]
        let isCurrent = currentMarkers.contains { normalizedLabel.contains($0) }
        return isCurrent ? "リース負債（流動）" : "リース負債（非流動）"
    }

    /// 借入金等明細表から有利子負債を積み上げ抽出する。
    /// IBD を XBRL タグで解決できない場合のフォールバック（会計基準は問わない）。
    static func extract(xbrlDir: URL, accountingStandard: String) -> IBDResult? {
        guard let html = XBRLUtils.extractTextblockHtml(
                in: xbrlDir, textblockTag: Xbrl.borrowingsScheduleTextblockTag),
              let soup = try? SwiftSoup.parse(html),
              let tables = (try? soup.select("table"))?.array() else { return nil }

        // 「合計」を含む表が本体明細表。後続の返済予定額の別表を除外するために選別する。
        let table = tables.first { ((try? $0.text()) ?? "").contains("合計") } ?? tables.first
        guard let table, let rows = (try? table.select("tr"))?.array() else { return nil }

        var components: [IBDComponentEntry] = []
        var totalCurrent: Double?
        var totalPrior: Double?

        for row in rows {
            guard let cells = (try? row.select("td, th"))?.array(), cells.count >= 3 else { continue }
            let label = ((try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
            guard !label.isEmpty else { continue }

            let prior = XBRLUtils.parseTextblockCellValue(try? cells[1].text())
            let current = XBRLUtils.parseTextblockCellValue(try? cells[2].text())
            // 区分ヘッダ・「該当事項はありません」等の非数値行を除外する。
            guard current != nil || prior != nil else { continue }

            if label == "合計" || label == "計" {
                totalCurrent = current.map { $0 * Financial.millionYen }
                totalPrior = prior.map { $0 * Financial.millionYen }
                break   // 合計以降は返済予定額の別表
            }
            components.append((
                label: displayLabel(for: label),
                current: current.map { $0 * Financial.millionYen },
                prior: prior.map { $0 * Financial.millionYen }
            ))
        }

        // 合計行が無い様式ではコンポーネントを合算する。
        if totalCurrent == nil && totalPrior == nil {
            let cs = components.compactMap { $0.current }
            let ps = components.compactMap { $0.prior }
            totalCurrent = cs.isEmpty ? nil : cs.reduce(0, +)
            totalPrior = ps.isEmpty ? nil : ps.reduce(0, +)
        }

        guard totalCurrent != nil || totalPrior != nil else { return nil }

        return IBDResult(
            total: totalCurrent,
            priorTotal: totalPrior,
            components: components,
            method: "borrowings_schedule",
            accountingStandard: accountingStandard
        )
    }
}
