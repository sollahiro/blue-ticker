// Fail-closed publish guards for `segment_info_llm` / `revenue_recognition_llm`.
// After merge, every new filing uses this path. A clean row with the wrong
// labels is a regression; `needs_review` hides the row (`isPubliclyServableBreakdown`).
// No company-code branches. docs/breakdown.md

import Foundation

enum SegmentInfoPublishGuards {
    static let warningGeographyWhileProductExists =
        "segment_info_geography_chosen_while_product_exists"
    static let warningNumericOrCodeLabels = "segment_info_numeric_or_code_labels"
    static let warningMetricRowLabels = "segment_info_metric_row_labels"
    static let warningDuplicateSegmentLabels = "segment_info_duplicate_segment_labels"
    static let warningPriorPeriodColumn = "segment_info_prior_period_column"
    static let warningRevenueTypeCategories = "segment_info_revenue_type_categories"

    private static let extraMetricMarkers = [
        "セグメント収益", "セグメント利益", "セグメント損失", "セグメント資産", "バーゲン",
        "支払利息", "信用損失", "持分法", "保険契約債務", "長期性資産",
        "外部顧客に対するもの", "資産合計", "資本的支出", "減価償却",
        "構造改革", "有形固定資産", "無形固定資産",
    ]
    private static let revenueTypeMarkers = [
        "医薬品の販売", "製商品の販売", "物品の販売", "プロフィットシェア",
        "知的財産権収入", "知的財産収益", "ライセンス収入",
        "医薬品販売による収益", "ライセンス供与による収益",
        "その他の源泉から認識した収益",
    ]

    static func apply(
        rows: [BreakdownRow],
        allTables: [RevenueRecognitionCandidates.ParsedTable],
        selectedTable: RevenueRecognitionCandidates.ParsedTable?,
        selectedColumn: RevenueRecognitionCandidates.AmountColumn?,
        fiscalYearEnd: String?,
        needsReview: inout Bool,
        warnings: inout [String]
    ) {
        let segments = rows.filter { $0.rowKind == "segment" }
        guard !segments.isEmpty else { return }

        if hasNumericOrCodeLabels(segments) {
            flag(&needsReview, &warnings, warningNumericOrCodeLabels)
        }
        if hasDuplicateSegmentLabels(segments) {
            flag(&needsReview, &warnings, warningDuplicateSegmentLabels)
        }
        if hasMetricRowLabels(segments) {
            flag(&needsReview, &warnings, warningMetricRowLabels)
        }
        if looksLikeRevenueTypeCategories(segments) {
            flag(&needsReview, &warnings, warningRevenueTypeCategories)
        }
        if looksLikeGeographyLabels(segments.map(\.labelRaw))
            && hasProductOrBusinessTable(allTables, besides: selectedTable)
        {
            flag(&needsReview, &warnings, warningGeographyWhileProductExists)
        }
        if looksLikeGeographyGroupPrefix(segments) {
            flag(&needsReview, &warnings, warningGeographyWhileProductExists)
        }
        if isPriorPeriodSelection(
            selectedColumn: selectedColumn, selectedTable: selectedTable,
            allTables: allTables, fiscalYearEnd: fiscalYearEnd)
        {
            flag(&needsReview, &warnings, warningPriorPeriodColumn)
        }
    }

    static func isNumericOrCodeLabel(_ label: String) -> Bool {
        let compact = RevenueRecognitionCandidates.compactCell(label)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        guard !compact.isEmpty else { return false }
        if RevenueRecognitionCandidates.isAmountCell(label) { return true }
        return compact.allSatisfy { ch in
            ch.isNumber || ch == "." || ch == "-" || ch == "△" || ch == "▲"
        }
    }

    private static func flag(
        _ needsReview: inout Bool, _ warnings: inout [String], _ warning: String
    ) {
        needsReview = true
        if !warnings.contains(warning) {
            warnings.append(warning)
        }
    }

    private static func hasNumericOrCodeLabels(_ segments: [BreakdownRow]) -> Bool {
        segments.contains { isNumericOrCodeLabel($0.labelRaw) }
    }

    private static func hasDuplicateSegmentLabels(_ segments: [BreakdownRow]) -> Bool {
        var groupsByLabel: [String: [String]] = [:]
        for row in segments {
            let label = RevenueRecognitionCandidates.compactCell(row.labelRaw)
            guard !label.isEmpty else { continue }
            let group = RevenueRecognitionCandidates.compactCell(row.categoryGroup ?? "")
            groupsByLabel[label, default: []].append(group)
        }
        for (label, groups) in groupsByLabel {
            guard groups.count >= 2 else { continue }
            let unique = Set(groups)
            if unique.count <= 1 { return true }
            if unique.contains(where: {
                $0.isEmpty || $0 == label || isMetricAsSegmentLabel($0)
            }) {
                return true
            }
        }
        return false
    }

    private static func hasMetricRowLabels(_ segments: [BreakdownRow]) -> Bool {
        let hits = segments.filter { isMetricAsSegmentLabel($0.labelRaw) }.count
        return hits >= 2 || (hits >= 1 && hits == segments.count)
    }

    static func isMetricAsSegmentLabel(_ label: String) -> Bool {
        let compact = RevenueRecognitionCandidates.compactCell(label)
        if SegmentInfoLLMNormalizer.isMetricRowLabel(compact) { return true }
        return extraMetricMarkers.contains { compact.contains($0) }
    }

    private static func looksLikeRevenueTypeCategories(_ segments: [BreakdownRow]) -> Bool {
        let core = segments.map(\.labelRaw).filter {
            let token = RevenueRecognitionCandidates.compactCell($0)
            return !token.isEmpty && !token.contains("その他")
                && !RevenueRecognitionCandidates.isTotalLabel(token)
        }
        guard !core.isEmpty else { return false }
        return core.allSatisfy { label in
            revenueTypeMarkers.contains { label.contains($0) }
        }
    }

    static func looksLikeGeographyLabels(_ labels: [String]) -> Bool {
        let core = labels.filter {
            let token = RevenueRecognitionCandidates.compactCell($0)
            return !token.contains("その他") && !RevenueRecognitionCandidates.isTotalLabel(token)
        }
        guard !core.isEmpty else { return false }
        let geo = core.filter(isGeographyLikeLabel)
        return geo.count * 2 >= core.count
    }

    static func isGeographyLikeLabel(_ label: String) -> Bool {
        let token = RevenueRecognitionCandidates.compactCell(label)
        if RevenueRecognitionTableStructure.isBareGeographyLabel(token) { return true }
        if RevenueRecognitionTableStructure.isGeographyHeading(token) { return true }
        let parts = token.components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.contains { RevenueRecognitionTableStructure.isBareGeographyLabel($0) }
    }

    private static func looksLikeGeographyGroupPrefix(_ segments: [BreakdownRow]) -> Bool {
        segments.contains { row in
            let raw = row.labelRaw
            guard raw.contains(" / ") else { return false }
            let parent = raw.components(separatedBy: " / ").first ?? raw
            let leaf = raw.components(separatedBy: " / ").last ?? raw
            guard isGeographyLikeLabel(parent) else { return false }
            return !isGeographyLikeLabel(leaf)
        }
    }

    static func hasProductOrBusinessTable(
        _ tables: [RevenueRecognitionCandidates.ParsedTable],
        besides selected: RevenueRecognitionCandidates.ParsedTable?
    ) -> Bool {
        tables.contains { table in
            if table.tableIndex == selected?.tableIndex { return false }
            // 前期の日本/アジア報告セグメント表は製品表ではない（3600 S100YHMW）。
            if RevenueRecognitionTableStructure.tableAxis(of: table) == .geography {
                return false
            }
            return hasProductOrBusinessLabels(table)
        }
    }

    static func hasProductOrBusinessLabels(
        _ table: RevenueRecognitionCandidates.ParsedTable
    ) -> Bool {
        let labels = businessLikeLabels(in: table)
        if labels.count >= 2 { return true }
        return table.heading == BreakdownExtractor.productOrServiceHeading && !labels.isEmpty
    }

    private static func businessLikeLabels(
        in table: RevenueRecognitionCandidates.ParsedTable
    ) -> [String] {
        var labels: [String] = []
        for item in table.items {
            let token = RevenueRecognitionCandidates.compactCell(item.label)
            guard !token.isEmpty else { continue }
            if RevenueRecognitionCandidates.isTotalLabel(token) { continue }
            if token.contains("その他") { continue }
            if isGeographyLikeLabel(token) { continue }
            if isMetricAsSegmentLabel(token) { continue }
            if isNumericOrCodeLabel(token) { continue }
            if RevenueRecognitionCandidates.isStubAxisHeader(token) { continue }
            if RevenueRecognitionTableStructure.isDisclosureOmissionProse(token) { continue }
            labels.append(token)
        }
        if !labels.isEmpty { return labels }
        for header in table.columnHeaders.values {
            let token = RevenueRecognitionCandidates.compactCell(header)
            let leaf = token.components(separatedBy: " / ").last ?? token
            guard !leaf.isEmpty else { continue }
            if RevenueRecognitionCandidates.isTotalLabel(leaf) { continue }
            if SegmentInfoLLMNormalizer.isSkippedTotalColumn(token) { continue }
            if isGeographyLikeLabel(leaf) { continue }
            if isMetricAsSegmentLabel(leaf) { continue }
            if isNumericOrCodeLabel(leaf) { continue }
            if RevenueRecognitionCandidates.isPeriodHeadingLabel(leaf) { continue }
            if RevenueRecognitionCandidates.isStubAxisHeader(leaf) { continue }
            if RevenueRecognitionTableStructure.isDisclosureOmissionProse(leaf) { continue }
            labels.append(leaf)
        }
        return labels
    }

    static func isPriorEraTable(
        _ table: RevenueRecognitionCandidates.ParsedTable,
        among tables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?
    ) -> Bool {
        if tables.contains(where: { $0.period == "当期" }) && table.period == "前期" {
            return true
        }
        let selectedEra = eraNumber(in: table.precedingCaption ?? "")
            ?? eraNumber(in: table.columnHeaders.values.joined(separator: " "))
        let siblingEras = tables.compactMap { candidate -> Int? in
            eraNumber(in: candidate.precedingCaption ?? "")
                ?? eraNumber(in: candidate.columnHeaders.values.joined(separator: " "))
        }
        if let selectedEra, let maxEra = siblingEras.max(), selectedEra < maxEra {
            return true
        }
        guard let fyYear = fiscalYearEnd.flatMap({ Int($0.prefix(4)) }) else { return false }
        let captionYears = years(in: table.precedingCaption ?? "")
        if !captionYears.isEmpty && captionYears.allSatisfy({ $0 < fyYear }) {
            let siblingHasCurrent = tables.contains { candidate in
                let other = years(in: candidate.precedingCaption ?? "")
                return other.contains(fyYear)
            }
            return siblingHasCurrent
        }
        return false
    }

    static func eraNumber(in text: String) -> Int? {
        let compact = RevenueRecognitionCandidates.compactCell(text)
        guard !compact.isEmpty else { return nil }
        guard let eraRegex = try? NSRegularExpression(pattern: #"第([0-9]+)期"#) else {
            return nil
        }
        let ns = compact as NSString
        let range = NSRange(location: 0, length: ns.length)
        let eras = eraRegex.matches(in: compact, range: range).compactMap { match -> Int? in
            Int(ns.substring(with: match.range(at: 1)))
        }
        if eras.count == 1 { return eras[0] }
        if eras.count >= 2 { return nil }
        let foundYears = years(in: compact)
        if foundYears.count == 1,
           compact.contains("終了した") || compact.contains("年度") || compact.contains("事業年度")
        {
            return foundYears[0]
        }
        return nil
    }

    private static func isPriorPeriodSelection(
        selectedColumn: RevenueRecognitionCandidates.AmountColumn?,
        selectedTable: RevenueRecognitionCandidates.ParsedTable?,
        allTables: [RevenueRecognitionCandidates.ParsedTable],
        fiscalYearEnd: String?
    ) -> Bool {
        guard let selectedColumn, let selectedTable else { return false }
        if RevenueRecognitionColumnNormalizer.isPriorOnlyColumn(
            selectedColumn, table: selectedTable)
        {
            return true
        }
        if isPriorEraTable(selectedTable, among: allTables, fiscalYearEnd: fiscalYearEnd) {
            return true
        }
        let blob = selectedColumn.header + (selectedColumn.caption ?? "")
            + (selectedTable.precedingCaption ?? "")
        if let selectedEra = eraNumber(in: blob) {
            let siblingEras = allTables.flatMap { table -> [Int] in
                let captionEra = eraNumber(in: table.precedingCaption ?? "")
                let headerEras = table.columnHeaders.values.compactMap { eraNumber(in: $0) }
                return (captionEra.map { [$0] } ?? []) + headerEras
            }
            if let maxEra = siblingEras.max(), selectedEra < maxEra {
                return true
            }
        }
        guard let fyYear = fiscalYearEnd.flatMap({ Int($0.prefix(4)) }) else { return false }
        let foundYears = years(in: blob)
        return !foundYears.isEmpty && foundYears.allSatisfy { $0 < fyYear }
    }

    static func years(in text: String) -> [Int] {
        let compact = RevenueRecognitionCandidates.compactCell(text)
        guard let regex = try? NSRegularExpression(pattern: #"((?:19|20)\d{2})"#) else {
            return []
        }
        let ns = compact as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: compact, range: range).compactMap { match in
            Int(ns.substring(with: match.range(at: 1)))
        }
    }
}
