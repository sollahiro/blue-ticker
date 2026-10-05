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
        "セグメント収益", "セグメント利益", "セグメント資産", "バーゲン",
        "支払利息", "信用損失", "持分法", "保険契約債務", "長期性資産",
        "外部顧客に対するもの",
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
            fiscalYearEnd: fiscalYearEnd)
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
        var seen: [String: Int] = [:]
        for row in segments {
            let label = RevenueRecognitionCandidates.compactCell(row.labelRaw)
            guard !label.isEmpty else { continue }
            let group = RevenueRecognitionCandidates.compactCell(row.categoryGroup ?? "")
            let key = group + "\u{1e}" + label
            seen[key, default: 0] += 1
            if seen[key]! >= 2 { return true }
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
            if table.heading == BreakdownExtractor.productOrServiceHeading { return true }
            if RevenueRecognitionTableStructure.tableAxis(of: table) == .productOrBusiness {
                return true
            }
            if table.tableIndex == selected?.tableIndex { return false }
            return businessLikeLabels(in: table).count >= 2
        }
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
            labels.append(leaf)
        }
        return labels
    }

    private static func isPriorPeriodSelection(
        selectedColumn: RevenueRecognitionCandidates.AmountColumn?,
        selectedTable: RevenueRecognitionCandidates.ParsedTable?,
        fiscalYearEnd: String?
    ) -> Bool {
        guard let selectedColumn, let selectedTable else { return false }
        if RevenueRecognitionColumnNormalizer.isPriorOnlyColumn(
            selectedColumn, table: selectedTable)
        {
            return true
        }
        guard let fyYear = fiscalYearEnd.flatMap({ Int($0.prefix(4)) }) else { return false }
        let years = years(in: selectedColumn.header + (selectedColumn.caption ?? ""))
        return !years.isEmpty && years.allSatisfy { $0 < fyYear }
    }

    private static func years(in text: String) -> [Int] {
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
