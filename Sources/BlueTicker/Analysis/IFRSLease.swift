// IFRS リース負債・財政状態計算書 TextBlock 抽出
// Python の blue_ticker/analysis/interest_bearing_debt.py の IFRS TextBlock/HTML 部分相当
//
// IFRS 企業ではリース負債（IFRS 16）の連結値が XBRL 数値タグに存在せず、
// リース注記 TextBlock または財務諸表本文 HTML のテーブルにのみ埋め込まれている場合がある。

import Foundation
import SwiftSoup

/// IBD コンポーネント（ラベル・当期値・前期値）
typealias IBDComponentEntry = (label: String, current: Double?, prior: Double?)

enum IFRSLease {

    /// resolve 済みタグにこれらが含まれる場合はノート抽出をスキップする
    static let leaseXbrlTags: Set<String> = ["LeaseLiabilitiesCLIFRS", "LeaseLiabilitiesNCLIFRS"]

    private static let bsTextblockTag = "ConsolidatedStatementOfFinancialPositionIFRSTextBlock"
    private static let leaseTextblockTag = "NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock"

    // IFRS連結財政状態計算書 TextBlock から集計する有利子負債コンポーネント定義
    // (HTMLラベル, 表示ラベル)。HTMLの表示順（流動→非流動）で定義する。
    private static let textblockIBDLabels: [(html: String, display: String)] = [
        ("短期借入金",                 "短期借入金"),
        ("コマーシャル・ペーパー",     "コマーシャル・ペーパー"),
        ("１年内償還予定の社債",       "1年内償還予定の社債"),
        ("１年内返済予定の長期借入金", "1年内返済予定の長期借入金"),
        ("社債",                       "社債"),
        ("長期借入金",                 "長期借入金"),
    ]

    // MARK: - 財政状態計算書 TextBlock からの IBD 積み上げ

    /// IFRS連結財政状態計算書TextBlockから有利子負債を積み上げ抽出する。
    /// IFRS Summary型XBRL（連結借入金タグが存在しない）向け。
    static func extractIBDFromTextblock(xbrlDir: URL) -> IBDResult? {
        let table = XBRLUtils.extractIfrsTextblockTable(in: xbrlDir, textblockTag: bsTextblockTag)
        guard !table.isEmpty else { return nil }

        var components: [IBDComponentEntry] = []
        var currentTotal = 0.0
        var priorTotal = 0.0
        var hasCurrent = false
        var hasPrior = false

        for (htmlLabel, displayLabel) in textblockIBDLabels {
            guard let vals = table[htmlLabel] else { continue }
            if let c = vals.current { currentTotal += c; hasCurrent = true }
            if let p = vals.prior { priorTotal += p; hasPrior = true }
            components.append((
                label: displayLabel,
                current: vals.current.map { $0 * Financial.millionYen },
                prior: vals.prior.map { $0 * Financial.millionYen }
            ))
        }

        guard hasCurrent || hasPrior else { return nil }

        return IBDResult(
            total: hasCurrent ? currentTotal * Financial.millionYen : nil,
            priorTotal: hasPrior ? priorTotal * Financial.millionYen : nil,
            components: components,
            method: "ifrs_textblock",
            accountingStandard: "IFRS"
        )
    }

    // MARK: - リース負債残高

    /// IFRS リース負債残高を抽出する。XBRLタグ → TextBlock → HTML の優先順。
    ///
    /// パターンA（XBRLタグ直接）: LeaseLiabilitiesCLIFRS / LeaseLiabilitiesNCLIFRS
    /// パターンB（TextBlock 支払期日が1年以内 / 1年超）: 流動・非流動を個別取得して積み上げ。
    /// パターンC（TextBlock 帳簿価額 / リース負債の現在価値）: 合計のみ取得。
    static func extractLeaseLiabilities(
        fieldSet: FieldSet,
        xbrlDir: URL?
    ) -> (current: Double?, prior: Double?, components: [IBDComponentEntry]) {
        // パターンA: XBRL タグから直接解決（TextBlock/HTML より確実）
        let clFV = resolveItem(fieldSet, tags: ["LeaseLiabilitiesCLIFRS"])
        let nclFV = resolveItem(fieldSet, tags: ["LeaseLiabilitiesNCLIFRS"])
        if clFV.current != nil || nclFV.current != nil {
            var components: [IBDComponentEntry] = []
            let totalC = (clFV.current ?? 0) + (nclFV.current ?? 0)
            let hasP = clFV.prior != nil || nclFV.prior != nil
            let totalP: Double? = hasP ? (clFV.prior ?? 0) + (nclFV.prior ?? 0) : nil
            if clFV.current != nil {
                components.append((label: "リース負債（流動）", current: clFV.current, prior: clFV.prior))
            }
            if nclFV.current != nil {
                components.append((label: "リース負債（非流動）", current: nclFV.current, prior: nclFV.prior))
            }
            return (totalC, totalP, components)
        }

        guard let dir = xbrlDir else { return (nil, nil, []) }
        let table = XBRLUtils.extractIfrsTextblockTable(in: dir, textblockTag: leaseTextblockTag)
        if table.isEmpty {
            // 半期報告書ではリース注記テキストブロックが XBRL に含まれない場合がある
            return extractLeaseFromHtml(xbrlDir: dir)
        }

        // パターンB: 「支払期日が1年以内」「支払期日が1年超」
        let clVals = table["支払期日が1年以内"]
        let nclVals = table["支払期日が1年超"]
        if clVals != nil || nclVals != nil {
            var components: [IBDComponentEntry] = []
            var cTotal = 0.0
            var pTotal = 0.0
            var hasC = false
            var hasP = false
            for (vals, label) in [(clVals, "リース負債（流動）"), (nclVals, "リース負債（非流動）")] {
                guard let v = vals else { continue }
                if let c = v.current { cTotal += c; hasC = true }
                if let p = v.prior { pTotal += p; hasP = true }
                components.append((
                    label: label,
                    current: v.current.map { $0 * Financial.millionYen },
                    prior: v.prior.map { $0 * Financial.millionYen }
                ))
            }
            return (
                hasC ? cTotal * Financial.millionYen : nil,
                hasP ? pTotal * Financial.millionYen : nil,
                components
            )
        }

        // パターンC: 「帳簿価額」（スズキ型: 合計のみ）/「リース負債の現在価値」（クボタ型: 割引後現在価値合計）
        for key in ["帳簿価額", "リース負債の現在価値"] {
            if let vals = table[key] {
                let c = vals.current.map { $0 * Financial.millionYen }
                let p = vals.prior.map { $0 * Financial.millionYen }
                return (c, p, [(label: "リース負債", current: c, prior: p)])
            }
        }

        return (nil, nil, [])
    }

    /// IFRS リース負債を HTML（財務諸表本文）から抽出する。
    ///
    /// 半期報告書では XBRL にリース注記テキストブロックが含まれない場合があるため、
    /// BS の HTML 表から「リース負債」行を直接読む。「リース負債の返済」等の CF 行は除外する。
    private static func extractLeaseFromHtml(
        xbrlDir: URL
    ) -> (current: Double?, prior: Double?, components: [IBDComponentEntry]) {
        guard let file = XBRLUtils.findHtmlByPrefix(in: xbrlDir, prefix: "0105010")
                ?? XBRLUtils.findHtmlByPrefix(in: xbrlDir, prefix: "0104010"),
              let data = try? Data(contentsOf: file) else { return (nil, nil, []) }
        let content = String(decoding: data, as: UTF8.self)
        guard let soup = try? SwiftSoup.parse(content),
              let tables = try? soup.select("table") else { return (nil, nil, []) }

        for table in tables {
            guard let tableText = try? table.text(), tableText.contains("リース負債") else { continue }
            guard let rows = (try? table.select("tr"))?.array() else { continue }
            let (priorIdx, currentIdx) = HtmlFinancialTable.detectColumnIndexes(rows: rows)

            for row in rows {
                guard let cells = (try? row.select("td, th"))?.array(), !cells.isEmpty else { continue }
                let label = (try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? ""
                guard label.contains("リース負債") else { continue }
                guard !["返済", "支払", "残存", "増加", "減少"].contains(where: { label.contains($0) }) else { continue }

                let numerics = HtmlFinancialTable.numericCells(cells)
                guard !numerics.isEmpty else { continue }

                let priorM: Double?
                let currentM: Double?
                if let p = priorIdx, let c = currentIdx {
                    currentM = HtmlFinancialTable.nearestValue(to: c, in: numerics)
                    priorM = HtmlFinancialTable.nearestValue(to: p, in: numerics)
                } else {
                    priorM = numerics.count >= 2 ? numerics[0].value : nil
                    currentM = numerics.last!.value
                }
                guard let cM = currentM else { continue }

                let cYen = cM * Financial.millionYen
                let pYen = priorM.map { $0 * Financial.millionYen }
                return (cYen, pYen, [(label: "リース負債", current: cYen, prior: pYen)])
            }
        }
        return (nil, nil, [])
    }
}
