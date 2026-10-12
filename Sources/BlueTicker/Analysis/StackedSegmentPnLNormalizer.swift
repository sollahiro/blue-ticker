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

    /// `html_table` の積み上げセグメント損益表から product_service 軸スナップショットを組み立てる。
    /// パターン非該当・分母不整合・売上/営業利益ブロック欠落時は nil（呼び出し側が LLM へフォールバック）。
    static func normalize(
        _ result: ExtractedBreakdown, consolidatedSales: Double?,
        salesDenominatorTag: String? = nil
    ) -> BreakdownSnapshot? {
        guard !result.tables.isEmpty else { return nil }

        var best: BreakdownSnapshot?
        var bestScore = -1.0
        for table in result.tables {
            guard let candidate = normalizeMarkdown(
                table.markdown, consolidatedSales: consolidatedSales,
                salesDenominatorTag: salesDenominatorTag)
                ?? normalizePeriodStackedColumns(
                    table.markdown, consolidatedSales: consolidatedSales,
                    salesDenominatorTag: salesDenominatorTag)
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
        _ markdown: String, consolidatedSales: Double?,
        salesDenominatorTag: String? = nil
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
            denominatorTag = salesDenominatorTag ?? "income_statement.sales"
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
            axis: breakdownAxisProductService,
            denominator: denominator,
            denominatorTag: denominatorTag,
            rows: rowsWithShare,
            sourceKind: "stacked_segment_pnl",
            needsReview: false,
            warnings: [])
    }

    // MARK: - 期間積み上げ・事業列型（野村 US-GAAP 注記23 型、BLT-143）

    /// 列＝事業（末尾「計」）、行＝指標、前期ブロック→当期ブロックが「2026年３月期」等の期間行で
    /// 縦に積まれた表（野村 S100YC5C［事業別セグメント］）。当期（最新年度）ブロックの売上相当行と
    /// 利益行を事業ごとに取る。パターン非該当・分母不整合は nil（LLM 経路へフォールバック）。
    ///
    /// 分母: 損益計算書売上と整合すればそれ。証券業の「収益合計（金融費用控除後）」（純収益）表は
    /// 損益計算書の「収益合計」（総額、金融費用控除前）と基準が違うため整合しない。そのときだけ、
    /// 事業列の和が表の「計」列と一致することを確かめて「計」を分母にする（fail closed）。
    static func normalizePeriodStackedColumns(
        _ markdown: String, consolidatedSales: Double?,
        salesDenominatorTag: String? = nil
    ) -> BreakdownSnapshot? {
        let grid = parseMarkdownGrid(markdown)
        guard grid.count >= 5 else { return nil }
        let unitMultiplier = unitMultiplier(fromHeader: markdown)

        // 事業見出し行: 数値セルが無く、非空セルが3つ以上で末尾が「計」「合計」。
        guard let headerIndex = grid.firstIndex(where: isSegmentColumnHeaderRow) else { return nil }
        let header = grid[headerIndex]
        var segmentColumns: [(col: Int, label: String)] = []
        var totalColumn: Int?
        for (col, cell) in header.enumerated() where col > 0 && !cell.isEmpty {
            if isTotalColumnLabel(cell) {
                totalColumn = col
            } else {
                segmentColumns.append((col, cell))
            }
        }
        guard segmentColumns.count >= 2, let totalCol = totalColumn,
              segmentColumns.allSatisfy({ $0.col < totalCol })
        else { return nil }

        // 期間行で区切った指標ブロック。
        var blocks: [(year: Int, rows: [[String]])] = []
        for row in grid[(headerIndex + 1)...] {
            if let year = periodMarkerYear(row) {
                blocks.append((year, []))
                continue
            }
            guard !blocks.isEmpty else { continue }
            blocks[blocks.count - 1].rows.append(row)
        }
        guard blocks.count >= 2 else { return nil }
        let metricLabelSets = blocks.map { Set($0.rows.compactMap { rowLabel($0) }) }
        guard let firstSet = metricLabelSets.first, !firstSet.isEmpty,
              metricLabelSets.allSatisfy({ $0 == firstSet })
        else { return nil }
        guard let current = blocks.max(by: { $0.year < $1.year }),
              blocks.filter({ $0.year == current.year }).count == 1
        else { return nil }

        guard let salesRow = current.rows.first(where: { isStackedColumnSalesLabel(rowLabel($0)) })
                ?? current.rows.first(where: { isLooseStackedColumnSalesLabel(rowLabel($0)) }),
              let profitRow = current.rows.first(where: { isStackedColumnProfitLabel(rowLabel($0)) }),
              let salesLabel = rowLabel(salesRow)
        else { return nil }

        func value(_ row: [String], _ col: Int) -> Double? {
            col < row.count ? XBRLUtils.parseHtmlNumber(row[col]) : nil
        }
        var rows: [BreakdownRow] = []
        for (col, label) in segmentColumns {
            guard let sales = value(salesRow, col), let profit = value(profitRow, col) else {
                return nil
            }
            rows.append(BreakdownRow(
                labelRaw: label, label: label, amount: sales * unitMultiplier, share: nil,
                profit: profit * unitMultiplier, rowKind: "segment"))
        }
        guard let salesTotalRaw = value(salesRow, totalCol) else { return nil }
        let salesTotal = salesTotalRaw * unitMultiplier
        let profitTotal = value(profitRow, totalCol).map { $0 * unitMultiplier }
        rows.append(BreakdownRow(
            labelRaw: header[totalCol], label: header[totalCol], amount: salesTotal, share: nil,
            profit: profitTotal, rowKind: "subtotal"))

        let segmentSum = rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        // 事業列の和が「計」列と一致しない表（列の取り違え・内数列）は採用しない。
        guard salesTotal != 0, abs(segmentSum - salesTotal) / abs(salesTotal) <= 0.005 else {
            return nil
        }

        let denominator: Double
        let denominatorTag: String
        if let consolidatedSales, consolidatedSales != 0,
           denominatorTolerance.contains(segmentSum / consolidatedSales)
        {
            denominator = consolidatedSales
            denominatorTag = salesDenominatorTag ?? "income_statement.sales"
        } else if consolidatedSales == nil || isNetRevenueLabel(salesLabel) {
            denominator = salesTotal
            denominatorTag = "stacked_table_sales_total"
        } else {
            return nil
        }

        return BreakdownSnapshot(
            axis: breakdownAxisProductService,
            denominator: denominator,
            denominatorTag: denominatorTag,
            rows: rows.map { row in
                var r = row
                r.share = r.amount / denominator
                return r
            },
            sourceKind: "stacked_segment_pnl",
            needsReview: false,
            warnings: [])
    }

    private static func compactLabel(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }.map(Character.init))
    }

    private static func isSegmentColumnHeaderRow(_ row: [String]) -> Bool {
        let nonEmpty = row.filter { !$0.isEmpty }
        guard nonEmpty.count >= 3,
              !row.contains(where: { XBRLUtils.parseHtmlNumber($0) != nil }),
              let last = nonEmpty.last
        else { return false }
        return isTotalColumnLabel(last)
    }

    private static func isTotalColumnLabel(_ text: String) -> Bool {
        let c = compactLabel(text)
        return c == "計" || c == "合計" || c == "連結" || c == "総計"
    }

    /// 「2026年３月期」「2025年3月期」等、先頭セルだけに期間があり他セルが空の行の年。
    private static func periodMarkerYear(_ row: [String]) -> Int? {
        guard let first = row.first(where: { !$0.isEmpty }),
              row.filter({ !$0.isEmpty }).count == 1
        else { return nil }
        let c = halfwidthDigits(compactLabel(first))
        guard c.hasSuffix("月期"), let r = c.range(of: "年") else { return nil }
        let yearText = c[c.startIndex..<r.lowerBound]
        guard yearText.count == 4, let year = Int(yearText) else { return nil }
        return year
    }

    private static func halfwidthDigits(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            if (0xFF10...0xFF19).contains(scalar.value),
               let half = Unicode.Scalar(scalar.value - 0xFF10 + 0x30)
            {
                return Character(half)
            }
            return Character(scalar)
        })
    }

    /// 売上相当行（合計系を優先）。「金融収益以外の収益」「純金融収益」等の内訳は除く。
    private static func isStackedColumnSalesLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        let c = compactLabel(label)
        if c.contains("以外") { return false }
        return c.hasPrefix("収益合計") || c.hasPrefix("売上高合計") || c.hasPrefix("営業収益合計")
            || c.hasPrefix("純収益合計")
    }

    private static func isLooseStackedColumnSalesLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        let c = compactLabel(label)
        if c.contains("以外") || c.contains("費用") || c.contains("原価") { return false }
        return c.hasPrefix("売上高") || c.hasPrefix("売上収益") || c.hasPrefix("営業収益")
    }

    private static func isStackedColumnProfitLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        let c = compactLabel(label)
        if c.contains("連結") || c.contains("研究開発") { return false }
        return c.hasPrefix("営業利益") || c.hasPrefix("セグメント利益") || c.hasPrefix("セグメント損益")
            || c.hasPrefix("事業利益") || c.hasPrefix("税引前当期純利益") || c.hasPrefix("税引前利益")
            || c.hasPrefix("税金等調整前当期純利益")
    }

    /// 証券業の純収益（金融費用控除後）。損益計算書「収益合計」（総額）とは基準が違う。
    private static func isNetRevenueLabel(_ label: String) -> Bool {
        let c = compactLabel(label)
        return c.contains("金融費用控除後") || c.hasPrefix("純収益") || c.hasPrefix("純営業収益")
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
