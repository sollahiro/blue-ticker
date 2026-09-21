import Foundation
import SwiftSoup

/// 報告セグメント合計と連結計上額の差額表（`DescriptionOfNatureAndAmountsOfDifferences…` TextBlock）
/// から、セグメント資産の非分類行（`row_kind=reconciling`）を読む。別軸ではない。
enum SegmentAssetsDifferenceTable {
    private static let textBlockTag =
        "DescriptionOfNatureAndAmountsOfDifferencesBetweenReportableSegmentsTotalAndFinancialStatementsTextBlock"

    private static let reportableTotalLabelKeywords = [
        "報告セグメント合計", "報告セグメント計",
    ]
    private static let consolidatedTotalLabelKeywords = [
        "連結財務諸表", "連結貸借対照表",
    ]

    /// 当期列の差額内訳（label → 円）。百万円表の生値に `Financial.millionYen` を掛けた値。
    static func parseReconcilingAmountsYen(in xbrlDir: URL) -> [(label: String, amountYen: Double)] {
        guard let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: textBlockTag),
              let soup = try? SwiftSoup.parse(html)
        else { return [] }

        guard let tables = try? soup.select("table") else { return [] }
        for table in tables {
            guard let rows = try? table.select("tr"), !rows.isEmpty else { continue }
            guard tableLooksLikeSegmentAssets(rows: rows) else { continue }
            return parseAssetsTableRows(rows: rows)
        }
        return []
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

    private static func isAssetsMetricHeader(_ normalized: String) -> Bool {
        normalized == "資産"
    }

    private static func parseAssetsTableRows(rows: Elements) -> [(label: String, amountYen: Double)] {
        var result: [(String, Double)] = []
        var pastHeader = false
        for row in rows {
            guard let cells = try? row.select("td"), cells.count >= 2 else { continue }
            guard let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true) else { continue }
            let normalized = normalizeLabel(label)
            if !pastHeader {
                if isAssetsMetricHeader(normalized) { pastHeader = true }
                continue
            }
            if reportableTotalLabelKeywords.contains(where: { normalized.contains($0) }) { continue }
            if consolidatedTotalLabelKeywords.contains(where: { normalized.contains($0) }) { continue }
            let dataCells = Array(cells.dropFirst())
            guard let lastCell = dataCells.last,
                  let currentText = try? lastCell.text(trimAndNormaliseWhitespace: true),
                  let millions = XBRLUtils.parseTextblockCellValue(currentText)
            else { continue }
            result.append((label, millions * Financial.millionYen))
        }
        return result
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
        let parsed = SegmentAssetsDifferenceTable.parseReconcilingAmountsYen(in: xbrlDir)
        guard !parsed.isEmpty else { return snapshot }

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

        let reconciledKinds: Set<String> = ["segment", "reconciling"]
        let denominator = rows.filter { reconciledKinds.contains($0.rowKind) }
            .map(\.amount).reduce(0, +)
        guard denominator > 0 else { return snapshot }

        var warnings = snapshot.warnings.filter { $0 != "segment_assets_entity_total_differs_from_table_total" }
        if let entity = rows.first(where: { $0.labelRaw == Xbrl.entityTotalMemberName }) {
            let scale = max(1.0, abs(entity.amount), abs(denominator))
            if abs(entity.amount - denominator) / scale > 0.05 {
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
