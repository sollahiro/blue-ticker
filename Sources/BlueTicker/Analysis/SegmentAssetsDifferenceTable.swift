import Foundation
import SwiftSoup

/// 報告セグメント合計と連結計上額の差額表（`DescriptionOfNatureAndAmountsOfDifferences…` TextBlock）
/// から、セグメント資産とフロー（増加額）の非分類行と計上額を読む。別軸ではない。
enum SegmentAssetsDifferenceTable {
    static let textBlockTag =
        "DescriptionOfNatureAndAmountsOfDifferencesBetweenReportableSegmentsTotalAndFinancialStatementsTextBlock"

    struct Parsed: Sendable {
        var assetReconciling: [(label: String, amountYen: Double)] = []
        var flowReconciling: [(label: String, amountYen: Double)] = []
        var assetEntityTotal: Double? = nil
        var flowEntityTotal: Double? = nil
    }

    private static let reportableTotalLabelKeywords = [
        "報告セグメント合計", "報告セグメント計",
    ]
    private static let consolidatedTotalLabelKeywords = [
        "連結財務諸表", "連結貸借対照表", "計上額",
    ]

    /// 当期列の資産差額内訳（label → 円）。既存の呼び出し向け。
    static func parseReconcilingAmountsYen(in xbrlDir: URL) -> [(label: String, amountYen: Double)] {
        parse(in: xbrlDir).assetReconciling
    }

    /// 資産・増加額の調整行と連結計上額。単位は表キャプション（百万円・千円）。
    static func parse(in xbrlDir: URL) -> Parsed {
        guard let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: textBlockTag),
              let soup = try? SwiftSoup.parse(html)
        else { return Parsed() }

        guard let tables = try? soup.select("table") else { return Parsed() }
        var merged = Parsed()
        for table in tables {
            guard let rows = try? table.select("tr"), !rows.isEmpty else { continue }
            guard let unitScale = tableUnitScaleYen(table: table, rows: rows) else { continue }
            let prefersCurrent = tableHeaderPrefersCurrentPeriod(rows: rows)
            if tableLooksLikeSegmentMetrics(rows: rows) {
                let parsed = parseMetricSections(rows: rows, unitScale: unitScale)
                merge(&merged, parsed, prefer: prefersCurrent)
            }
            if let wide = parseWideIncreaseRow(rows: rows, unitScale: unitScale) {
                if prefersCurrent || merged.flowEntityTotal == nil {
                    merged.flowReconciling.append(("調整額", wide.adjustmentYen))
                    merged.flowEntityTotal = wide.entityTotalYen
                }
            }
        }
        return merged
    }

    private static func merge(_ dest: inout Parsed, _ src: Parsed, prefer: Bool) {
        if !src.assetReconciling.isEmpty, prefer || dest.assetReconciling.isEmpty {
            dest.assetReconciling = src.assetReconciling
            dest.assetEntityTotal = src.assetEntityTotal ?? dest.assetEntityTotal
        } else if dest.assetEntityTotal == nil {
            dest.assetEntityTotal = src.assetEntityTotal
        }
        if !src.flowReconciling.isEmpty, prefer || dest.flowReconciling.isEmpty {
            dest.flowReconciling = src.flowReconciling
            dest.flowEntityTotal = src.flowEntityTotal ?? dest.flowEntityTotal
        } else if dest.flowEntityTotal == nil {
            dest.flowEntityTotal = src.flowEntityTotal
        }
    }

    /// TextBlock 生 HTML（`breakdownContentHash` 用）。
    static func differenceTextBlockHtml(in xbrlDir: URL) -> String? {
        XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: textBlockTag)
    }

    private static func tableLooksLikeSegmentMetrics(rows: Elements) -> Bool {
        for row in rows {
            guard let cells = try? row.select("td, th"), !cells.isEmpty(),
                  let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true)
            else { continue }
            if metricSection(normalizeLabel(label)) != nil { return true }
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
        return AmountUnit.yenScale(containedIn: joined)?.multiplier
    }

    private enum Section {
        case assets, flow, skip
    }

    /// 表の見出し行がどの指標か。売上・利益・減価償却は読まない。
    private static func metricSection(_ normalized: String) -> Section? {
        if normalized == "資産" { return .assets }
        if normalized.contains("増加額") || normalized.contains("資本的支出") { return .flow }
        if normalized.contains("減価償却") || normalized.contains("売上") || normalized.contains("利益") {
            return .skip
        }
        return nil
    }

    private static func parseMetricSections(
        rows: Elements, unitScale: Double
    ) -> Parsed {
        var parsed = Parsed()
        var section: Section?
        var currentValueColumnOffset: Int?
        for row in rows {
            guard let cells = try? row.select("td"), cells.count >= 2 else { continue }
            guard let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true) else { continue }
            let normalized = normalizeLabel(label)
            let dataCells = Array(cells.dropFirst())
            let hasNumeric = dataCells.contains {
                XBRLUtils.parseTextblockCellValue((try? $0.text(trimAndNormaliseWhitespace: true)) ?? "") != nil
            }
            if !hasNumeric, let next = metricSection(normalized) {
                section = next
                currentValueColumnOffset = resolveCurrentValueColumnOffset(in: dataCells)
                continue
            }
            guard let section, section != .skip else { continue }
            if reportableTotalLabelKeywords.contains(where: { normalized.contains($0) }) { continue }
            let valueIndex = currentValueColumnOffset ?? (dataCells.count - 1)
            guard valueIndex >= 0, valueIndex < dataCells.count else { continue }
            guard let currentText = try? dataCells[valueIndex].text(trimAndNormaliseWhitespace: true)
            else { continue }
            let raw: Double?
            if let parsedValue = XBRLUtils.parseTextblockCellValue(currentText) {
                raw = parsedValue
            } else if section == .flow, isDash(currentText) {
                raw = 0
            } else {
                raw = nil
            }
            guard let raw else { continue }
            let yen = raw * unitScale
            if consolidatedTotalLabelKeywords.contains(where: { normalized.contains($0) }) {
                switch section {
                case .assets: parsed.assetEntityTotal = yen
                case .flow: parsed.flowEntityTotal = yen
                case .skip: break
                }
                continue
            }
            switch section {
            case .assets: parsed.assetReconciling.append((label, yen))
            case .flow: parsed.flowReconciling.append((label, yen))
            case .skip: break
            }
        }
        return parsed
    }

    private static func isDash(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "　", with: "")
        return ["－", "-", "—", "―"].contains(s)
    }

    /// 3300 型: 列が 報告セグメント計 / その他 / 調整額 / 計上額、行が増加額。
    /// 調整額の当期と連結財務諸表計上額の当期を読む。積み上げ差額表（行が調整額）は対象外。
    private static func parseWideIncreaseRow(
        rows: Elements, unitScale: Double
    ) -> (adjustmentYen: Double, entityTotalYen: Double)? {
        var isWide = false
        for row in rows.prefix(3) {
            guard let cells = try? row.select("td, th") else { continue }
            let joined = cells.array()
                .compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }
                .joined()
            if joined.contains("調整額"), joined.contains("連結財務諸表計上額") {
                isWide = true
                break
            }
        }
        guard isWide else { return nil }
        for row in rows {
            guard let cells = try? row.select("td"), cells.count >= 5,
                  let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true)
            else { continue }
            let normalized = normalizeLabel(label)
            guard normalized.contains("増加額") else { continue }
            let data = Array(cells.dropFirst())
            let values = data.compactMap {
                XBRLUtils.parseTextblockCellValue(try? $0.text(trimAndNormaliseWhitespace: true))
            }
            // 末尾2列が計上額 前/当、その手前2列が調整額 前/当。
            guard values.count >= 4 else { continue }
            let entity = values[values.count - 1]
            let adjustment = values[values.count - 3]
            return (adjustment * unitScale, entity * unitScale)
        }
        return nil
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
    /// XBRL セグメント資産に無い非分類行を差額表 HTML から足し、`finalizeSegmentAssetsSnapshot` で分母・dedupe を揃える。
    static func enrichSegmentAssetsWithDifferenceTable(
        snapshot: BreakdownSnapshot?, xbrlDir: URL
    ) -> BreakdownSnapshot? {
        guard let snapshot, snapshot.axis == breakdownAxisSegmentAssets else { return snapshot }

        let entityAmount = snapshot.rows.first(where: { $0.labelRaw == Xbrl.entityTotalMemberName })?.amount
        let existingReconciling = snapshot.rows.filter { $0.rowKind == "reconciling" }
        if !existingReconciling.isEmpty {
            // XBRL 調整（例: ReconcilingItemsMember）があるとき HTML 内訳を足すと二重計上になる。
            return snapshot
        }

        let diff = SegmentAssetsDifferenceTable.parse(in: xbrlDir)
        let parsed = diff.assetReconciling
        guard !parsed.isEmpty || diff.assetEntityTotal != nil else { return snapshot }

        let segmentOnlySum = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.amount).reduce(0, +)
        let segmentAmounts = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.amount)
        let parsedNoSegmentDupes = parsed.filter { item in
            !segmentAmounts.contains(where: { BreakdownNormalizer.segmentAssetsAmountsEqual($0, item.amountYen) })
        }
        let parsedSum = parsedNoSegmentDupes.map(\.amountYen).reduce(0, +)
        if let entity = entityAmount ?? diff.assetEntityTotal, entity > 0, !parsedNoSegmentDupes.isEmpty {
            let gap = entity - segmentOnlySum
            let scale = max(1.0, abs(entity), abs(gap), abs(parsedSum))
            if abs(parsedSum - gap) / scale > 0.05 { return snapshot }
        }

        var rows = snapshot.rows
        let existingLabels = Set(rows.map { normalizeDifferenceLabel($0.label ?? $0.labelRaw) })
        for (label, amountYen) in parsedNoSegmentDupes {
            let key = normalizeDifferenceLabel(label)
            if existingLabels.contains(key) { continue }
            let labelRaw = "segmentAssetsDifference:\(key)"
            rows.append(
                BreakdownRow(
                    labelRaw: labelRaw, label: label, amount: amountYen, share: nil, profit: nil,
                    rowKind: "reconciling", description: nil))
        }
        if rows.first(where: { $0.labelRaw == Xbrl.entityTotalMemberName }) == nil,
            let entity = diff.assetEntityTotal, entity > 0
        {
            rows.append(
                BreakdownRow(
                    labelRaw: Xbrl.entityTotalMemberName,
                    label: Xbrl.codeSideStandardMemberLabels[Xbrl.entityTotalMemberName]
                        ?? "連結合計又は会社合計",
                    amount: entity, share: nil, profit: nil,
                    rowKind: breakdownRowKindEntityTotal, description: nil))
        }
        guard rows.count > snapshot.rows.count else { return snapshot }

        let merged = BreakdownSnapshot(
            axis: snapshot.axis, denominator: snapshot.denominator,
            denominatorTag: snapshot.denominatorTag,
            rows: rows.sorted { $0.labelRaw < $1.labelRaw }, sourceKind: snapshot.sourceKind,
            needsReview: snapshot.needsReview, warnings: snapshot.warnings)
        return BreakdownNormalizer.finalizeSegmentAssetsSnapshot(merged)
    }

    /// 差額表の増加額セクションを flow スナップショットへ足す。XBRL 調整があるときは足さない。
    static func enrichFlowWithDifferenceTable(
        snapshot: BreakdownSnapshot?, xbrlDir: URL
    ) -> BreakdownSnapshot? {
        let diff = SegmentAssetsDifferenceTable.parse(in: xbrlDir)
        if snapshot == nil {
            guard let entity = diff.flowEntityTotal, entity > 0 else { return nil }
            var rows: [BreakdownRow] = []
            for (label, amountYen) in diff.flowReconciling {
                rows.append(
                    BreakdownRow(
                        labelRaw: "flowDifference:\(normalizeDifferenceLabel(label))",
                        label: label, amount: amountYen, share: amountYen / entity, profit: nil,
                        rowKind: "reconciling"))
            }
            rows.append(
                BreakdownRow(
                    labelRaw: Xbrl.entityTotalMemberName,
                    label: Xbrl.codeSideStandardMemberLabels[Xbrl.entityTotalMemberName]
                        ?? "連結合計又は会社合計",
                    amount: entity, share: 1, profit: nil,
                    rowKind: breakdownRowKindEntityTotal))
            return BreakdownSnapshot(
                axis: breakdownAxisCapitalExpenditures, denominator: entity,
                denominatorTag: SegmentAssetsDifferenceTable.textBlockTag,
                rows: rows, sourceKind: "html_table", needsReview: false, warnings: [])
        }
        guard var snapshot else { return nil }
        let existingReconciling = snapshot.rows.filter { $0.rowKind == "reconciling" }
        if existingReconciling.isEmpty {
            let segmentAmounts = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.amount)
            let extras = diff.flowReconciling.filter { item in
                !segmentAmounts.contains {
                    BreakdownNormalizer.segmentAssetsAmountsEqual($0, item.amountYen)
                }
            }
            let existingLabels = Set(snapshot.rows.map { normalizeDifferenceLabel($0.label ?? $0.labelRaw) })
            for (label, amountYen) in extras {
                let key = normalizeDifferenceLabel(label)
                if existingLabels.contains(key) { continue }
                snapshot.rows.append(
                    BreakdownRow(
                        labelRaw: "flowDifference:\(key)", label: label, amount: amountYen,
                        share: nil, profit: nil, rowKind: "reconciling"))
            }
        }
        if snapshot.denominator <= 0, let entity = diff.flowEntityTotal, entity > 0 {
            snapshot.denominator = entity
            snapshot.denominatorTag = SegmentAssetsDifferenceTable.textBlockTag
            snapshot.rows = snapshot.rows.map { row in
                var copy = row
                copy.share = row.amount / entity
                return copy
            }
        }
        if snapshot.rows.first(where: { $0.labelRaw == Xbrl.entityTotalMemberName }) == nil,
            let entity = diff.flowEntityTotal, entity > 0
        {
            snapshot.rows.append(
                BreakdownRow(
                    labelRaw: Xbrl.entityTotalMemberName,
                    label: Xbrl.codeSideStandardMemberLabels[Xbrl.entityTotalMemberName]
                        ?? "連結合計又は会社合計",
                    amount: entity, share: 1, profit: nil,
                    rowKind: breakdownRowKindEntityTotal))
        }
        let additive = snapshot.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        if snapshot.denominator > 0, additive > 0,
            abs(additive - snapshot.denominator) / snapshot.denominator <= 0.05
        {
            snapshot.warnings.removeAll { $0.hasSuffix("_segment_sum_far_from_total") }
            snapshot.needsReview = !snapshot.warnings.isEmpty
        }
        return snapshot
    }

    private static func normalizeDifferenceLabel(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "（注）", with: "")
            .replacingOccurrences(of: "(注)", with: "")
    }
}
