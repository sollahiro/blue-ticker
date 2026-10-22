// product_service 軸。報告セグメント facts / 報告セグメント表は使わない（BLT-187）。
// 製品・サービス別表と収益分解表だけを `ProductServiceBreakdownResolver` へ渡す。

import Foundation

/// どの経路で business breakdown を解決したか（監査・目視検証用）。
enum BusinessBreakdownSource: String {
    case xbrlFacts = "xbrl_facts"
    /// 積み上げセグメント損益表（売上→研究開発費→営業利益等）の決定論寄せ。
    case stackedSegmentPnL = "stacked_segment_pnl"
    case revenueRecognitionLLM = "revenue_recognition_llm"
    case segmentInfoLLM = "segment_info_llm"
    case notFound = "not_found"
}

enum BusinessBreakdownResolver {

    /// product_service 軸。報告セグメント facts / 積み上げ PnL / 報告セグメント表は使わない。
    /// 製品・サービス別表または収益分解表だけを正規化する（BLT-187）。
    static func resolve(
        segments: ExtractedBreakdown, consolidatedSales: Double?,
        labelsByTag: [String: String] = [:],
        denominatorTag: String? = nil,
        columnDecider: (any RevenueRecognitionColumnDeciding)? = nil,
        segmentInfoDecider: (any SegmentInfoDeciding)? = nil,
        segmentProfitDecider: (any SegmentProfitDeciding)? = nil,
        rowRoleDecider: (any RevenueRecognitionRowRoleDeciding)? = nil,
        fiscalYearEnd: String? = nil,
        docID: String = ""
    ) async -> (snapshot: BreakdownSnapshot?, source: BusinessBreakdownSource, audit: LLMBreakdownAudit?) {
        _ = segmentProfitDecider
        let tables = segments.tables.filter(BreakdownExtractor.isProductServiceTable)
        let product = ExtractedBreakdown(
            method: tables.isEmpty ? "not_found" : "html_table",
            tables: tables, facts: [])
        return await ProductServiceBreakdownResolver.resolve(
            product: product, consolidatedSales: consolidatedSales, labelsByTag: labelsByTag,
            denominatorTag: denominatorTag, columnDecider: columnDecider,
            segmentInfoDecider: segmentInfoDecider, rowRoleDecider: rowRoleDecider,
            fiscalYearEnd: fiscalYearEnd, docID: docID)
    }

    /// 空行の LLM スナップショットは `xbrl_facts` を隠すので採用しない（7273 S100YLTN）。
    static func hasUsableSegmentRows(_ snapshot: BreakdownSnapshot) -> Bool {
        snapshot.rows.contains { $0.rowKind == "segment" }
    }

    /// 専用タグがあり、選んだ収益分解表にカテゴリ行が無い（合計行だけ）ときは
    /// main と同じ `single_segment_disclosed`。製品行がある表は残す（8771 S100YKOI）。
    /// 並行次元やフィルタで行を落としたあとの空表には使わない（2467 / 5936）。
    /// 当期の報告セグメント売上 member が 2 以上あるときはタグを信じない（7063 / 1711 / 2321）。
    static func dedicatedSingleSegmentFallback(
        snapshot: BreakdownSnapshot?, dedicatedTagText: String?,
        currentYearReportableSalesMemberCount: Int = 0
    ) -> Bool {
        if currentYearReportableSalesMemberCount >= 2 { return false }
        let tag = dedicatedTagText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !tag.isEmpty else { return false }
        if let warnings = snapshot?.warnings,
           warnings.contains(RevenueRecognitionColumnNormalizer.warningCategoryRowsDropped)
            || warnings.contains(RevenueRecognitionColumnNormalizer.warningParallelDimensions)
        {
            return false
        }
        return snapshot?.rows.contains { $0.rowKind == "segment" } != true
    }
}
