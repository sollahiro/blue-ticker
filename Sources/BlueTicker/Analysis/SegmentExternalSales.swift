// 報告セグメントの外部顧客売上。セグメント間含む計（RevenueIFRS 等）は external_sales にしない。

import Foundation

enum SegmentExternalSales {
    static func normalize(
        facts: [BreakdownFact], labelsByTag: [String: String] = [:],
        memberParents: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        BreakdownNormalizer.normalizeTrueExternalSales(
            facts: facts, labelsByTag: labelsByTag, memberParents: memberParents)
    }
}
