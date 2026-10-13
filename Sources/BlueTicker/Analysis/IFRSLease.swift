// IFRS リース負債・財政状態計算書 TextBlock 抽出
//
// IFRS 企業ではリース負債（IFRS 16）の連結値が XBRL 数値タグに存在せず、
// リース注記 TextBlock または財務諸表本文 HTML のテーブルにのみ埋め込まれている場合がある。

import Foundation
import SwiftSoup

/// IBD コンポーネント（ラベル・当期値・前期値）
typealias IBDComponentEntry = (label: String, current: Double?, prior: Double?)

enum IFRSLease {

    /// resolve 済みタグにこれらが含まれる場合はノート抽出をスキップする
    static let leaseXbrlTags: Set<String> = [
        "LeaseLiabilitiesCLIFRS", "LeaseLiabilitiesNCLIFRS", "LeaseLiabilitiesLiabilitiesIFRS",
    ]

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
    /// パターンC（TextBlock 帳簿価額 / リース負債の現在価値）: 合計＋同表の割引前合計行
    ///   （クボタ型「割引前のリース負債総額」/ スズキ型「契約上のキャッシュ・フロー」）＋満期バケット。
    ///
    /// `components` は帳簿価額（IBD加算用）。`maturityBuckets` は notes 用の内訳（割引前合計＋満期。
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
        // 流動性配列の BS（流動/非流動の区分なし。SBI アルヒ等）
        let liquidityFV = resolveItem(fieldSet, tags: ["LeaseLiabilitiesLiabilitiesIFRS"])
        if clFV.current != nil || nclFV.current != nil || liquidityFV.current != nil {
            var components: [IBDComponentEntry] = []
            let totalC = (clFV.current ?? 0) + (nclFV.current ?? 0) + (liquidityFV.current ?? 0)
            let hasP = clFV.prior != nil || nclFV.prior != nil || liquidityFV.prior != nil
            let totalP: Double? = hasP
                ? (clFV.prior ?? 0) + (nclFV.prior ?? 0) + (liquidityFV.prior ?? 0) : nil
            if liquidityFV.current != nil {
                components.append((label: "リース負債", current: liquidityFV.current, prior: liquidityFV.prior))
            }
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
            var details: [IBDComponentEntry] = []
            for row in rows {
                guard isSupplementaryLesseeRow(row.label) else { continue }
                guard row.current != nil || row.prior != nil else { continue }
                details.append((
                    label: row.label,
                    current: row.current.map { $0 * Financial.millionYen },
                    prior: row.prior.map { $0 * Financial.millionYen }
                ))
            }
            for row in rows {
                guard isInterestDeductionRow(row.label) else { continue }
                guard row.current != nil || row.prior != nil else { continue }
                details.append((
                    label: row.label,
                    current: row.current.map { $0 * Financial.millionYen },
                    prior: row.prior.map { $0 * Financial.millionYen }
                ))
            }
            for row in rows {
                guard isMaturityBucketLabel(row.label) else { continue }
                guard row.current != nil || row.prior != nil else { continue }
                details.append((
                    label: row.label,
                    current: row.current.map { $0 * Financial.millionYen },
                    prior: row.prior.map { $0 * Financial.millionYen }
                ))
            }
            return (c, p, components, details)
        }

        // パターンE: 借手の残高表に「リース負債（流動）」「リース負債（非流動）」の行がある。
        // 住友ファーマ S100YH3M・丸紅 S100YAY4 実データ検証（2026-10-11）: 「リース負債 残高」
        // 「割引前リース負債 残高」と並ぶ形で、B/C のどのラベルにも当たらずリースが落ちていた。
        for rows in tables {
            let labels = rows.map(\.label)
            let joined = labels.joined(separator: "\n")
            guard !joined.contains("正味リース投資"), !joined.contains("未稼得金融収益"),
                  !joined.contains("無保証残存") else { continue }
            func compact(_ label: String) -> String {
                label.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
                    .replacingOccurrences(of: "(", with: "（").replacingOccurrences(of: ")", with: "）")
            }
            let clVals = rows.first { compact($0.label) == "リース負債（流動）" }
            let nclVals = rows.first { compact($0.label) == "リース負債（非流動）" }
            guard clVals != nil || nclVals != nil else { continue }
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
            guard hasC || hasP else { continue }
            return (
                hasC ? cTotal * Financial.millionYen : nil,
                hasP ? pTotal * Financial.millionYen : nil,
                components,
                []
            )
        }

        // パターンF: 「財政状態計算書で認識された金額」型の表。使用権資産の行と並んで
        // 「リース負債」（または「リース負債合計」）が1行だけある。楽天グループ S100XTNW
        // 実データ検証（2026-10-11）: 「リース負債(注)２ | 352,856 | 361,443」。注記で
        // その他の金融負債に含めると書かれ、BS にリース科目がないためリースが落ちていた。
        for rows in tables {
            let labels = rows.map(\.label)
            guard labels.contains(where: { $0.contains("使用権資産") }) else { continue }
            let joined = labels.joined(separator: "\n")
            guard !joined.contains("正味リース投資"), !joined.contains("未稼得金融収益"),
                  !joined.contains("無保証残存") else { continue }
            let leaseRows = rows.filter {
                let label = compactLeaseLabel($0.label)
                return label == "リース負債" || label == "リース負債合計"
            }
            guard leaseRows.count == 1, let row = leaseRows.first,
                  row.current != nil || row.prior != nil
            else { continue }
            // 負債を △ 付きで載せる会社がある（LIFULL S100X8TY 実データ検証 2026-10-12:
            // 「リース負債 | △1,713 | △829」）。残高なので符号は捨てる。
            let scale = textblockUnitScale(html)
            let c = row.current.map { abs($0) * scale }
            let p = row.prior.map { abs($0) * scale }
            return (c, p, [(label: "リース負債", current: c, prior: p)], [])
        }

        // パターンD: 列見出しが「帳簿価額｜将来リース料｜１年以内…」で、値が次の行に並ぶ表を
        // 前期・当期で2つ並べる様式。日機装 S100XU3R 実データ検証（2026-10-11）: 帳簿価額
        // 27,492 百万円 = BS リース負債 3,963 + 23,529。
        if let columnLayout = columnLayoutLeaseBookValues(html) {
            let c = columnLayout.current * Financial.millionYen
            let p = columnLayout.prior * Financial.millionYen
            return (c, p, [(label: "リース負債", current: c, prior: p)], [])
        }

        // パターンG: 満期分析表の列見出しに「帳簿価額」「帳簿残高」の列があり、行「リース負債」の
        // その列が帳簿価額。前期・当期は表を分けるか（Ｊトラスト S100XSDT 2026-10-11:
        // 前期 5,278 / 当期 4,653）、同じ表の期間行で区切る（日本取引所グループ S100YA84: 前期 584 / 当期 4,511）。
        if let split = splitMaturityLeaseBookValues(html) {
            let scale = textblockUnitScale(html)
            let c = split.current * scale
            let p = split.prior * scale
            return (c, p, [(label: "リース負債", current: c, prior: p)], [])
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
        // 日機装 S100XU3R: 「帳簿価額」は使用権資産の表（取得原価・減価償却累計額と並ぶ）にもある。
        // 資産の帳簿価額をリース負債として読まない。
        let hasRightOfUseAssetTable = tables.contains { rows in
            rows.contains { $0.label == "帳簿価額" }
                && rows.contains { $0.label.contains("取得原価") || $0.label.contains("減価償却累計額") }
        }
        for key in ["帳簿価額", "リース負債の現在価値"] {
            if key == "帳簿価額", hasRightOfUseAssetTable { continue }
            if let vals = flat[key] {
                let c = vals.current.map { $0 * Financial.millionYen }
                let p = vals.prior.map { $0 * Financial.millionYen }
                return (c, p, [(label: "リース負債", current: c, prior: p)], [])
            }
        }

        return (nil, nil, [], [])
    }

    /// 列見出し型の借手リース負債表（先頭行「帳簿価額｜将来リース料（契約上CF・割引前）｜…」、
    /// 次の行の先頭セルが帳簿価額）の帳簿価額。前期・当期の2表がこの順に並ぶときだけ返す（百万円）。
    private static func columnLayoutLeaseBookValues(_ html: String) -> (prior: Double, current: Double)? {
        guard let soup = try? SwiftSoup.parse(html), let tables = try? soup.select("table") else {
            return nil
        }
        var values: [Double] = []
        for table in tables {
            guard let rows = try? table.select("tr").array(), rows.count >= 2 else { continue }
            let header = (try? rows[0].select("td, th").array().map {
                (try? $0.text(trimAndNormaliseWhitespace: true)) ?? ""
            }) ?? []
            guard header.first?.replacingOccurrences(of: " ", with: "") == "帳簿価額" else { continue }
            let joined = header.joined()
            guard joined.contains("将来リース料") || joined.contains("契約上") || joined.contains("割引前")
            else { continue }
            guard let firstValue = try? rows[1].select("td, th").first()?.text(),
                  let value = XBRLUtils.parseTextblockCellValue(firstValue)
            else { continue }
            values.append(value)
        }
        guard values.count == 2 else { return nil }
        return (prior: values[0], current: values[1])
    }

    /// 「リース負債（注）２」「リース負債※１」等の注記マーカーを除いたラベル。
    static func cleanedLeaseLabel(_ label: String) -> String {
        var out = label
        let patterns = [
            #"[（(]\s*注\s*[0-9０-９]*(?:\s*[、,・]\s*[0-9０-９]+)*\s*[）)]\s*[0-9０-９]*(?:\s*[、,・]\s*[0-9０-９]+)*"#,
            #"注\s*[0-9０-９]+(?:\s*[、,・]\s*[0-9０-９]+)*$"#,
            #"[※＊*]\s*[0-9０-９]*(?:\s*[、,・]\s*[0-9０-９]+)*"#,
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? label : out
    }

    private static func compactLeaseLabel(_ label: String) -> String {
        cleanedLeaseLabel(label).replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "(", with: "（").replacingOccurrences(of: ")", with: "）")
    }

    /// TextBlock の金額単位。「千円」だけが書かれていれば千円、それ以外は百万円。
    static func textblockUnitScale(_ html: String) -> Double {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        if text.contains("千円"), !text.contains("百万円") { return 1_000 }
        return Financial.millionYen
    }

    /// パターンG の帳簿価額（生値）。期間ごとに1つずつ取れたときだけ返す。
    private static func splitMaturityLeaseBookValues(_ html: String) -> (prior: Double, current: Double)? {
        guard let soup = try? SwiftSoup.parse(html), let tables = try? soup.select("table") else {
            return nil
        }
        func cellTexts(_ row: Element) -> [String] {
            ((try? row.select("td, th").array()) ?? []).map {
                ((try? $0.text(trimAndNormaliseWhitespace: true)) ?? "")
                    .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
            }
        }
        var unlabelled: [Double] = []
        var prior: Double?
        var current: Double?
        for table in tables {
            guard let rows = try? table.select("tr").array(), rows.count >= 2 else { continue }
            let tableText = (try? table.text()) ?? ""
            if tableText.contains("正味リース投資") || tableText.contains("未稼得金融収益")
                || tableText.contains("無保証残存") || tableText.contains("使用権資産")
            {
                continue
            }
            guard let headerIndex = rows.firstIndex(where: { row in
                let cells = cellTexts(row)
                return cells.contains { $0 == "帳簿価額" || $0 == "帳簿残高" }
                    && cells.contains { $0.contains("年以内") }
            }) else { continue }
            let header = cellTexts(rows[headerIndex])
            guard header.first?.isEmpty ?? true,
                  let bookIndex = header.firstIndex(where: { $0 == "帳簿価額" || $0 == "帳簿残高" })
            else { continue }
            var period: String?
            var tableValues: [(period: String?, value: Double)] = []
            for row in rows[(headerIndex + 1)...] {
                let cells = cellTexts(row)
                guard let first = cells.first else { continue }
                if first.hasPrefix("前連結会計年度") || first.hasPrefix("前事業年度") { period = "prior"; continue }
                if first.hasPrefix("当連結会計年度") || first.hasPrefix("当事業年度") { period = "current"; continue }
                let label = compactLeaseLabel(first)
                guard label == "リース負債" || label == "リース負債合計" else { continue }
                guard cells.count == header.count,
                      let value = XBRLUtils.parseTextblockCellValue(cells[bookIndex])
                else { return nil }
                tableValues.append((period, value))
            }
            for entry in tableValues {
                switch entry.period {
                case "prior":
                    guard prior == nil else { return nil }
                    prior = entry.value
                case "current":
                    guard current == nil else { return nil }
                    current = entry.value
                default:
                    unlabelled.append(entry.value)
                }
            }
        }
        if let prior, let current, unlabelled.isEmpty { return (prior, current) }
        if prior == nil, current == nil, unlabelled.count == 2 {
            return (prior: unlabelled[0], current: unlabelled[1])
        }
        return nil
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

    /// 借手表の利息控除行（クボタ型「控除：利息相当額」。貸手の未稼得金融収益は対象外）。
    private static func isInterestDeductionRow(_ label: String) -> Bool {
        label.contains("控除") && label.contains("利息")
    }

    /// 借手表の割引前合計行（満期バケットの合計と一致する開示行）。
    private static func isSupplementaryLesseeRow(_ label: String) -> Bool {
        label.contains("割引前のリース負債") || label.contains("契約上のキャッシュ")
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
                guard let rawLabel = try? cells.first()?.text(trimAndNormaliseWhitespace: true),
                    !rawLabel.isEmpty
                else { continue }
                let label = cleanedLeaseLabel(rawLabel)
                // 値の後ろに空のスペーサー <td> を置く会社がある（サワイ S100YITS 実データ検証
                // 2026-10-11: 当期 3,967 を前期と読み当期 nil になっていた）。空セルを除いてから
                // 末尾2つを前期・当期とする。空でないセルが2つ未満なら従来どおり位置で読む。
                let allDataCells = Array(cells.dropFirst())
                let nonEmpty = allDataCells.filter {
                    !((try? $0.text(trimAndNormaliseWhitespace: true)) ?? "").isEmpty
                }
                let dataCells = nonEmpty.count >= 2 ? nonEmpty : allDataCells
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
