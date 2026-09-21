import Foundation
import SwiftSoup

/// 報告セグメント合計と連結計上額の差額表（`DescriptionOfNatureAndAmountsOfDifferences…` TextBlock）
/// から、セグメント資産の非分類行（`row_kind=reconciling`）を読む。別軸ではない。
enum SegmentAssetsDifferenceTable {
    static let textBlockTag =
        "DescriptionOfNatureAndAmountsOfDifferencesBetweenReportableSegmentsTotalAndFinancialStatementsTextBlock"

    private static let reportableTotalLabelKeywords = [
        "報告セグメント合計", "報告セグメント計",
    ]
    private static let consolidatedTotalLabelKeywords = [
        "連結財務諸表", "連結貸借対照表",
    ]

    /// 当期列の差額内訳（label → 円）。単位は表キャプションから決め、百万円以外は採用しない。
    static func parseReconcilingAmountsYen(in xbrlDir: URL) -> [(label: String, amountYen: Double)] {
        guard let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: textBlockTag),
              let soup = try? SwiftSoup.parse(html)
        else { return [] }

        guard let tables = try? soup.select("table") else { return [] }
        var candidates: [(rows: [(String, Double)], prefersCurrent: Bool)] = []
        for table in tables {
            guard let rows = try? table.select("tr"), !rows.isEmpty else { continue }
            guard tableLooksLikeSegmentAssets(rows: rows) else { continue }
            guard let unitScale = tableUnitScaleYen(table: table, rows: rows),
                  unitScale == Financial.millionYen
            else { continue }
            guard let parsed = parseAssetsTableRows(rows: rows, unitScale: unitScale) else { continue }
            guard !parsed.isEmpty else { continue }
            let prefersCurrent = tableHeaderPrefersCurrentPeriod(rows: rows)
            candidates.append((parsed, prefersCurrent))
        }
        guard !candidates.isEmpty else { return [] }
        if let current = candidates.last(where: { $0.prefersCurrent }) {
            return current.rows
        }
        return candidates.last!.rows
    }

    /// TextBlock 生 HTML（`breakdownContentHash` 用）。
    static func differenceTextBlockHtml(in xbrlDir: URL) -> String? {
        XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: textBlockTag)
    }

    private static func tableLooksLikeSegmentAssets(rows: Elements) -> Bool {
        for row in rows {
            guard let cells = try? row.select("td, th"), !cells.isEmpty(),
                  let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true)
            else { continue }
            if isAssetsMetricHeader(normalizeLabel(label)) { return true }
        }
        return false
    }

    private static func tableHeaderPrefersCurrentPeriod(rows: Elements) -> Bool {
        for row in rows {
            guard let cells = try? row.select("td, th"), cells.count >= 2 else { continue }
            let texts = cells.array().compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }
            let joined = texts.joined()
            if joined.contains("当連結") || joined.contains("当連結会計年度") { return true }
        }
        return false
    }

    private static func tableUnitScaleYen(table: Element, rows: Elements) -> Double? {
        var texts: [String] = []
        var ancestor: Element? = table
        for _ in 0..<5 {
            guard let el = ancestor else { break }
            var sibling = try? el.previousElementSibling()
            while let sib = sibling {
                if let t = try? sib.text(trimAndNormaliseWhitespace: true) { texts.append(t) }
                sibling = try? sib.previousElementSibling()
            }
            ancestor = el.parent()
        }
        if let parentText = try? table.parent()?.text(trimAndNormaliseWhitespace: true) {
            texts.append(parentText)
        }
        for row in rows {
            guard let cells = try? row.select("td, th") else { continue }
            for cell in cells.array() {
                if let t = try? cell.text(trimAndNormaliseWhitespace: true) { texts.append(t) }
            }
        }
        let joined = texts.joined()
        if joined.contains("千円") && !joined.contains("百万円") { return nil }
        if joined.contains("億円") && !joined.contains("百万円") { return nil }
        if joined.contains("百万円") { return Financial.millionYen }
        return nil
    }

    private static func isAssetsMetricHeader(_ normalized: String) -> Bool {
        normalized == "資産"
    }

    private static func parseAssetsTableRows(
        rows: Elements, unitScale: Double
    ) -> [(label: String, amountYen: Double)]? {
        var result: [(String, Double)] = []
        var pastHeader = false
        var currentValueColumnOffset: Int?
        for row in rows {
            guard let cells = try? row.select("td"), cells.count >= 2 else { continue }
            guard let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true) else { continue }
            let normalized = normalizeLabel(label)
            let dataCells = Array(cells.dropFirst())
            if !pastHeader {
                if isAssetsMetricHeader(normalized) {
                    pastHeader = true
                    currentValueColumnOffset = resolveCurrentValueColumnOffset(in: dataCells)
                }
                continue
            }
            if reportableTotalLabelKeywords.contains(where: { normalized.contains($0) }) { continue }
            if consolidatedTotalLabelKeywords.contains(where: { normalized.contains($0) }) { continue }
            let valueIndex = currentValueColumnOffset ?? (dataCells.count - 1)
            guard valueIndex >= 0, valueIndex < dataCells.count else { continue }
            guard let currentText = try? dataCells[valueIndex].text(trimAndNormaliseWhitespace: true),
                  let raw = XBRLUtils.parseTextblockCellValue(currentText)
            else { continue }
            result.append((label, raw * unitScale))
        }
        return result.isEmpty ? nil : result
    }

    /// `dataCells` はラベル列を除いた期間列。
    private static func resolveCurrentValueColumnOffset(in dataCells: [Element]) -> Int {
        let headers = dataCells.enumerated().map { index, cell -> (Int, String) in
            let text = (try? cell.text(trimAndNormaliseWhitespace: true)) ?? ""
            return (index, text)
        }
        if let match = headers.first(where: { _, text in
            text.contains("当連結") || text.contains("当連結会計年度")
                || (text.contains("当") && text.contains("年度") && !text.contains("前"))
        }) {
            return match.0
        }
        return dataCells.count - 1
    }

    private static func normalizeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
    }
}

extension BreakdownNormalizer {
    /// XBRL セグメント資産に無い非分類行を差額表 HTML から足し、分母を segment+reconciling で再計算する。
    static func enrichSegmentAssetsWithDifferenceTable(
        snapshot: BreakdownSnapshot?, xbrlDir: URL
    ) -> BreakdownSnapshot? {
        guard let snapshot, snapshot.axis == breakdownAxisSegmentAssets else { return snapshot }

        let reconciledKinds: Set<String> = ["segment", "reconciling"]
        func reconciledSum(_ rows: [BreakdownRow]) -> Double {
            rows.filter { reconciledKinds.contains($0.rowKind) }.map(\.amount).reduce(0, +)
        }

        let entityAmount = snapshot.rows.first(where: { $0.labelRaw == Xbrl.entityTotalMemberName })?.amount
        let existingReconciling = snapshot.rows.filter { $0.rowKind == "reconciling" }
        if !existingReconciling.isEmpty {
            // XBRL 調整（例: ReconcilingItemsMember）があるとき HTML 内訳を足すと二重計上になる。
            return snapshot
        }

        let parsed = SegmentAssetsDifferenceTable.parseReconcilingAmountsYen(in: xbrlDir)
        guard !parsed.isEmpty else { return snapshot }

        let segmentOnlySum = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.amount).reduce(0, +)
        let parsedSum = parsed.map(\.amountYen).reduce(0, +)
        if let entity = entityAmount, entity > 0 {
            let gap = entity - segmentOnlySum
            let scale = max(1.0, abs(entity), abs(gap), abs(parsedSum))
            if abs(parsedSum - gap) / scale > 0.05 { return snapshot }
        }

        var rows = snapshot.rows
        let existingLabels = Set(rows.map { normalizeDifferenceLabel($0.label ?? $0.labelRaw) })
        for (label, amountYen) in parsed {
            let key = normalizeDifferenceLabel(label)
            if existingLabels.contains(key) { continue }
            let labelRaw = "segmentAssetsDifference:\(key)"
            rows.append(
                BreakdownRow(
                    labelRaw: labelRaw, label: label, amount: amountYen, share: nil, profit: nil,
                    rowKind: "reconciling", description: nil))
        }
        guard rows.count > snapshot.rows.count else { return snapshot }

        let denominator = reconciledSum(rows)
        guard denominator > 0 else { return snapshot }

        var warnings = snapshot.warnings.filter { $0 != "segment_assets_entity_total_differs_from_table_total" }
        if let entity = entityAmount {
            let scale = max(1.0, abs(entity), abs(denominator))
            if abs(entity - denominator) / scale > 0.05 {
                warnings.append("segment_assets_entity_total_differs_from_table_total")
            }
        }

        rows = rows.map { row in
            var copy = row
            if reconciledKinds.contains(row.rowKind) || row.labelRaw == Xbrl.entityTotalMemberName {
                copy.share = row.amount / denominator
            }
            return copy
        }

        return BreakdownSnapshot(
            axis: snapshot.axis, denominator: denominator, denominatorTag: snapshot.denominatorTag,
            rows: rows.sorted { $0.labelRaw < $1.labelRaw }, sourceKind: snapshot.sourceKind,
            needsReview: !warnings.isEmpty, warnings: warnings)
    }

    private static func normalizeDifferenceLabel(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "（注）", with: "")
            .replacingOccurrences(of: "(注)", with: "")
    }
}
