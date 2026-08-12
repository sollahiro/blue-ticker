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
    /// パターンB（TextBlock 支払期日が1年以内 / 1年超）: 流動・非流動の**帳簿価額**。
    /// パターンC（TextBlock 帳簿価額 / リース負債の現在価値）: 合計＋同表の満期バケット
    ///   （割引前契約CF。「１年以内」等。貸手表とラベルが衝突するため**表単位**で判定）。
    ///
    /// `components` は帳簿価額（IBD加算用）。`maturityBuckets` は割引前満期内訳（notes用。
    /// IBD には載せない）。
    static func extractLeaseLiabilities(
        fieldSet: FieldSet,
        xbrlDir: URL?
    ) -> (
        current: Double?, prior: Double?, components: [IBDComponentEntry],
        maturityBuckets: [IBDComponentEntry]
    ) {
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
            return (totalC, totalP, components, [])
        }

        guard let dir = xbrlDir else { return (nil, nil, [], []) }
        guard let html = XBRLUtils.extractTextblockHtml(in: dir, textblockTag: leaseTextblockTag)
        else {
            // 半期報告書ではリース注記テキストブロックが XBRL に含まれない場合がある
            let htmlFallback = extractLeaseFromHtml(xbrlDir: dir)
            return (htmlFallback.current, htmlFallback.prior, htmlFallback.components, [])
        }

        let tables = parseLeaseTextblockTables(html)

        // パターンB: 「支払期日が1年以内」「支払期日が1年超」（帳簿価額の流動/非流動）
        for rows in tables {
            let clVals = rows.first(where: { $0.label == "支払期日が1年以内" })
            let nclVals = rows.first(where: { $0.label == "支払期日が1年超" })
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
                    components,
                    []
                )
            }
        }

        // パターンC: 借手リース負債表（帳簿価額 / 現在価値）＋同表の満期バケット
        for rows in tables {
            guard isLesseeLeaseLiabilityMaturityTable(rows.map(\.label)) else { continue }
            var totalRow: (label: String, current: Double?, prior: Double?)?
            for key in ["リース負債の現在価値", "帳簿価額"] {
                if let row = rows.first(where: { $0.label == key }) {
                    totalRow = row
                    break
                }
            }
            guard let total = totalRow, total.current != nil || total.prior != nil else { continue }
            let c = total.current.map { $0 * Financial.millionYen }
            let p = total.prior.map { $0 * Financial.millionYen }
            let components: [IBDComponentEntry] = [(label: "リース負債", current: c, prior: p)]
            let buckets: [IBDComponentEntry] = rows.compactMap { row in
                guard isMaturityBucketLabel(row.label) else { return nil }
                guard row.current != nil || row.prior != nil else { return nil }
                return (
                    label: row.label,
                    current: row.current.map { $0 * Financial.millionYen },
                    prior: row.prior.map { $0 * Financial.millionYen }
                )
            }
            return (c, p, components, buckets)
        }

        // フラット辞書フォールバック（表境界が取れない TextBlock 等）
        let flat = XBRLUtils.extractIfrsTextblockTable(in: dir, textblockTag: leaseTextblockTag)
        let flatCL = flat["支払期日が1年以内"]
        let flatNCL = flat["支払期日が1年超"]
        if flatCL != nil || flatNCL != nil {
            var components: [IBDComponentEntry] = []
            var cTotal = 0.0
            var pTotal = 0.0
            var hasC = false
            var hasP = false
            for (vals, label) in [(flatCL, "リース負債（流動）"), (flatNCL, "リース負債（非流動）")] {
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
                components,
                []
            )
        }
        for key in ["帳簿価額", "リース負債の現在価値"] {
            if let vals = flat[key] {
                let c = vals.current.map { $0 * Financial.millionYen }
                let p = vals.prior.map { $0 * Financial.millionYen }
                return (c, p, [(label: "リース負債", current: c, prior: p)], [])
            }
        }

        return (nil, nil, [], [])
    }

    /// 借手のリース負債満期分析表か（貸手の正味投資未回収表と「１年以内」が衝突するため表単位判定）。
    /// 実データ: スズキ S100W4MT（帳簿価額＋契約上CF）、クボタ S100XR0M（現在価値＋割引前総額）。
    private static func isLesseeLeaseLiabilityMaturityTable(_ labels: [String]) -> Bool {
        let joined = labels.joined(separator: "\n")
        if joined.contains("正味リース投資") || joined.contains("未稼得金融収益")
            || joined.contains("無保証残存")
        {
            return false
        }
        if labels.contains(where: { $0.contains("リース負債の現在価値") }) { return true }
        if labels.contains(where: { $0.contains("割引前のリース負債") }) { return true }
        let hasBook = labels.contains(where: { $0 == "帳簿価額" })
        let hasContractual = labels.contains(where: { $0.contains("契約上のキャッシュ") })
        return hasBook && hasContractual
    }

    /// 満期バケット行（割引前CF）。「支払期日が1年以内」等の帳簿価額区分は除外。
    private static func isMaturityBucketLabel(_ label: String) -> Bool {
        if label.contains("支払期日") { return false }
        if label.contains("契約上") || label.contains("割引前") || label.contains("控除") {
            return false
        }
        if label == "帳簿価額" || label.contains("現在価値") || label.contains("合計") {
            return false
        }
        return label.contains("年以内") || label.contains("年超")
    }

    /// TextBlock HTML を表ごとに行パースする（百万円単位の生値）。
    private static func parseLeaseTextblockTables(
        _ html: String
    ) -> [[(label: String, current: Double?, prior: Double?)]] {
        guard let soup = try? SwiftSoup.parse(html),
            let tables = try? soup.select("table")
        else { return [] }
        var result: [[(label: String, current: Double?, prior: Double?)]] = []
        for table in tables {
            guard let rows = try? table.select("tr") else { continue }
            var parsed: [(label: String, current: Double?, prior: Double?)] = []
            for row in rows {
                guard let cells = try? row.select("td"), cells.count >= 3 else { continue }
                guard let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true),
                    !label.isEmpty
                else { continue }
                let dataCells = Array(cells.dropFirst())
                guard dataCells.count >= 2 else { continue }
                let currentV = XBRLUtils.parseTextblockCellValue(try? dataCells.last?.text())
                let priorV = XBRLUtils.parseTextblockCellValue(
                    try? dataCells[dataCells.count - 2].text())
                if currentV != nil || priorV != nil {
                    parsed.append((label: label, current: currentV, prior: priorV))
                }
            }
            if !parsed.isEmpty { result.append(parsed) }
        }
        return result
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
