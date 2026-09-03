// 富士フイルム型の「積み上げセグメント損益表」を決定論で正規化する。
//
// 同一の事業ラベルが指標ブロックごとに繰り返し、ブロック末尾の「XXX計」だけが指標名を持つ表
// （売上高 → 研究開発費 → その他費用 → 営業利益）では、LLM が研究開発費ブロックを profit に
// 誤寄せすることがある（実測: S100YIBH / S100W3XJ）。比較に必須な揃えは構造側で行う。
// docs/breakdown.md / .agents/skills/xbrl-development/SKILL.md 再発防止（Breakdown）参照。

import Foundation

enum StackedSegmentPnLNormalizer {

    /// LLM と同じ分母整合の許容幅。
    private static let denominatorTolerance = 0.90...1.10

    private struct MetricBlock {
        var segmentValues: [(label: String, value: Double)]
        var totalLabel: String
        var totalValue: Double?
    }

    /// `html_table` の積み上げセグメント損益表から business 軸スナップショットを組み立てる。
    /// パターン非該当・分母不整合・売上/営業利益ブロック欠落時は nil（呼び出し側が LLM へフォールバック）。
    static func normalize(
        _ result: ExtractedBreakdown, consolidatedSales: Double?
    ) -> BreakdownSnapshot? {
        guard !result.tables.isEmpty else { return nil }

        var best: BreakdownSnapshot?
        var bestScore = -1.0
        for table in result.tables {
            guard let candidate = normalizeMarkdown(
                table.markdown, consolidatedSales: consolidatedSales)
            else { continue }
            let score = candidate.rows.filter { $0.rowKind == "segment" }.count
            let denScore = consolidatedSales.map { sales in
                sales == 0 ? 0 : abs(candidate.denominator / sales - 1)
            } ?? 0
            // セグメント行数を優先し、分母乖離が小さい方を採用する。
            let rank = Double(score) * 10 - denScore
            if rank > bestScore {
                bestScore = rank
                best = candidate
            }
        }
        return best
    }

    /// 単一 Markdown 表を正規化する（単体テスト用に internal）。
    static func normalizeMarkdown(
        _ markdown: String, consolidatedSales: Double?
    ) -> BreakdownSnapshot? {
        let grid = parseMarkdownGrid(markdown)
        guard grid.count >= 4 else { return nil }

        let header = grid[0]
        let unitMultiplier = unitMultiplier(fromHeader: header.joined(separator: " "))
        guard let valueCol = currentPeriodColumnIndex(header: header, sampleRows: grid.dropFirst())
        else { return nil }

        let blocks = metricBlocks(from: Array(grid.dropFirst()), valueCol: valueCol)
        // 同一事業ラベルが2ブロック以上繰り返される積み上げ表だけを対象にする。
        guard blocks.count >= 2 else { return nil }
        let labelSets = blocks.map { Set($0.segmentValues.map(\.label)) }
        guard let firstLabels = labelSets.first, firstLabels.count >= 2 else { return nil }
        let repeated = labelSets.filter { $0 == firstLabels }.count
        guard repeated >= 2 else { return nil }

        guard let salesBlock = blocks.first(where: { isSalesTotalLabel($0.totalLabel) }),
              let profitBlock = blocks.first(where: { isOperatingProfitTotalLabel($0.totalLabel) })
        else { return nil }

        // 研究開発費・その他費用を営業利益と誤認していないこと（防御）。
        guard !isResearchAndDevelopmentTotalLabel(profitBlock.totalLabel) else { return nil }

        let salesByLabel = Dictionary(
            uniqueKeysWithValues: salesBlock.segmentValues.map { ($0.label, $0.value) })
        let profitByLabel = Dictionary(
            uniqueKeysWithValues: profitBlock.segmentValues.map { ($0.label, $0.value) })
        // 売上ブロックの並びを正とし、利益ブロックに同じラベルが揃っていること。
        let orderedLabels = salesBlock.segmentValues.map(\.label)
        guard orderedLabels.count >= 2,
              orderedLabels.allSatisfy({ profitByLabel[$0] != nil })
        else { return nil }

        var rows: [BreakdownRow] = orderedLabels.map { label in
            BreakdownRow(
                labelRaw: label,
                label: label,
                amount: salesByLabel[label]! * unitMultiplier,
                share: nil,
                profit: profitByLabel[label]! * unitMultiplier,
                rowKind: "segment")
        }

        let salesSum = rows.reduce(0.0) { $0 + $1.amount }
        let salesTotal = (salesBlock.totalValue ?? salesBlock.segmentValues.reduce(0) { $0 + $1.value })
            * unitMultiplier
        let profitTotal = (profitBlock.totalValue
            ?? profitBlock.segmentValues.reduce(0) { $0 + $1.value }) * unitMultiplier

        // 売上計行を subtotal として残す（公開キー sales/profit。profit は営業利益計）。
        rows.append(
            BreakdownRow(
                labelRaw: salesBlock.totalLabel,
                label: salesBlock.totalLabel,
                amount: salesTotal,
                share: nil,
                profit: profitTotal,
                rowKind: "subtotal"))

        let denominator: Double
        let denominatorTag: String
        if let consolidatedSales, consolidatedSales != 0 {
            let share = salesSum / consolidatedSales
            guard denominatorTolerance.contains(share) else { return nil }
            denominator = consolidatedSales
            denominatorTag = "income_statement.sales"
        } else {
            denominator = salesTotal
            denominatorTag = "stacked_table_sales_total"
        }

        let rowsWithShare = rows.map { row -> BreakdownRow in
            var r = row
            r.share = denominator == 0 ? nil : r.amount / denominator
            return r
        }

        return BreakdownSnapshot(
            axis: "business",
            denominator: denominator,
            denominatorTag: denominatorTag,
            rows: rowsWithShare,
            sourceKind: "stacked_segment_pnl",
            needsReview: false,
            warnings: [])
    }

    // MARK: - グリッド / ブロック

    private static func parseMarkdownGrid(_ markdown: String) -> [[String]] {
        var grid: [[String]] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }
            // 区切り行 |---|---| をスキップ
            let body = trimmed.dropFirst().dropLast()
            let cells = body.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) }) {
                continue
            }
            grid.append(cells)
        }
        return grid
    }

    private static func unitMultiplier(fromHeader header: String) -> Double {
        if header.contains("百万円") { return Financial.millionYen }
        if header.contains("千円") { return 1_000 }
        return Financial.millionYen
    }

    /// 当期列を選ぶ。見出しに「当」があればその列、無ければ右端の数値列。
    private static func currentPeriodColumnIndex(
        header: [String], sampleRows: ArraySlice<[String]>
    ) -> Int? {
        if let idx = header.indices.reversed().first(where: {
            header[$0].contains("当") && !header[$0].contains("前")
        }) {
            return idx
        }
        // 見出しが空でもデータ行に数値が入る列（富士フイルム型の空セル挟み）を右から探す。
        let width = max(header.count, sampleRows.map(\.count).max() ?? 0)
        for col in stride(from: width - 1, through: 0, by: -1) {
            let hasNumber = sampleRows.contains { row in
                col < row.count && XBRLUtils.parseHtmlNumber(row[col]) != nil
            }
            if hasNumber { return col }
        }
        return nil
    }

    private static func metricBlocks(from rows: [[String]], valueCol: Int) -> [MetricBlock] {
        var blocks: [MetricBlock] = []
        var current: [(label: String, value: Double)] = []

        for row in rows {
            guard let label = rowLabel(row), valueCol < row.count,
                  let value = XBRLUtils.parseHtmlNumber(row[valueCol])
            else {
                // 数値の無い見出し行等はブロック境界にしない（現在の積み上げを維持）。
                continue
            }
            if isMetricTotalLabel(label) {
                blocks.append(
                    MetricBlock(segmentValues: current, totalLabel: label, totalValue: value))
                current = []
            } else {
                current.append((label, value))
            }
        }
        return blocks
    }

    private static func rowLabel(_ row: [String]) -> String? {
        row.first(where: { !$0.isEmpty && XBRLUtils.parseHtmlNumber($0) == nil })
    }

    /// 「売上高 計」「研究開発費 計」「営業利益 計」等の指標合計行。
    private static func isMetricTotalLabel(_ label: String) -> Bool {
        let compact = label.replacingOccurrences(of: " ", with: "")
        guard compact.contains("計") || compact.contains("合計") else { return false }
        // 事業名そのものに「計」が含まれる稀例より、指標名＋計を優先する。
        return isSalesTotalLabel(label)
            || isOperatingProfitTotalLabel(label)
            || isResearchAndDevelopmentTotalLabel(label)
            || compact.contains("費用")
            || compact.contains("利益")
            || compact.contains("売上")
            || compact.contains("収益")
            || compact.contains("償却")
            || compact.contains("資産")
    }

    private static func isSalesTotalLabel(_ label: String) -> Bool {
        let compact = label.replacingOccurrences(of: " ", with: "")
        guard compact.contains("計") || compact.contains("合計") else { return false }
        if isOperatingProfitTotalLabel(label) { return false }
        if isResearchAndDevelopmentTotalLabel(label) { return false }
        if compact.contains("費用") { return false }
        return compact.contains("売上高")
            || compact.contains("売上収益")
            || compact.contains("営業収益")
            || compact == "売上計"
            || compact.hasPrefix("売上計")
    }

    private static func isOperatingProfitTotalLabel(_ label: String) -> Bool {
        let compact = label.replacingOccurrences(of: " ", with: "")
        guard compact.contains("計") || compact.contains("合計") else { return false }
        if isResearchAndDevelopmentTotalLabel(label) { return false }
        if compact.contains("費用") { return false }
        // 「連結営業利益」は全社行でありブロック末尾のセグメント営業利益計ではない。
        if compact.contains("連結") { return false }
        return compact.contains("営業利益")
            || compact.contains("セグメント利益")
            || compact.contains("セグメント損益")
            || compact.contains("事業利益")
    }

    private static func isResearchAndDevelopmentTotalLabel(_ label: String) -> Bool {
        let compact = label.replacingOccurrences(of: " ", with: "")
        return compact.contains("研究開発")
    }
}
