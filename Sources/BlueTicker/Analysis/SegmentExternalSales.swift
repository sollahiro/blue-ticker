// 報告セグメントの外部顧客売上。セグメント間含む計（RevenueIFRS 等）は external_sales にしない。
// ただし「外部顧客への売上高」と「その他の収益を含む計」を両方開示する書類（350A / 5842）は、
// 連結売上高に一致する計を採る。見分けは金額の近さではなく、計の連結値が連結売上高そのものか。

import Foundation

enum SegmentExternalSales {
    struct Resolution {
        var snapshot: BreakdownSnapshot
        /// `segmentSalesBasisExternal` または `segmentSalesBasisExternalIncludingOtherRevenue`。
        var salesBasis: String
    }

    static func normalize(
        facts: [BreakdownFact], labelsByTag: [String: String] = [:],
        memberParents: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        BreakdownNormalizer.normalizeTrueExternalSales(
            facts: facts, labelsByTag: labelsByTag, memberParents: memberParents)
    }

    /// 連結売上高（Summary sales）が分かるときの解決。外部顧客売上の連結値が連結売上高と合わず、
    /// セグメント member に付いた別の売上タグの連結値が連結売上高に一致するときだけ、その計を採る。
    /// セグメント間を含む計（6349: 計 152,869 ≠ 連結売上 118,611）は連結売上高に一致しないので採らない。
    static func resolve(
        facts: [BreakdownFact], consolidatedSales: Double?, labelsByTag: [String: String] = [:],
        memberParents: [String: String] = [:]
    ) -> Resolution? {
        let external = normalize(facts: facts, labelsByTag: labelsByTag, memberParents: memberParents)
        guard let external else { return nil }
        let plain = Resolution(snapshot: external, salesBasis: segmentSalesBasisExternal)
        // 外部顧客売上に連結値のタグが無い書類（3199）は比べられないので、外部顧客のまま。
        guard let consolidatedSales, consolidatedSales > 0, external.denominator > 0,
            !matches(external.denominator, consolidatedSales)
        else { return plain }
        let candidates = totalTagCandidates(
            facts: facts, excluding: external.denominatorTag
        ).compactMap { tag -> BreakdownSnapshot? in
            guard let snapshot = BreakdownNormalizer.normalizeSegmentSalesTotal(
                facts: facts, tag: tag, labelsByTag: labelsByTag, memberParents: memberParents),
                matches(snapshot.denominator, consolidatedSales),
                additiveRowsClose(snapshot)
            else { return nil }
            return snapshot
        }
        // 候補が 1 つに決まらないときは外部顧客売上のまま（どちらの計かをここでは決めない）。
        guard candidates.count == 1, let total = candidates.first else { return plain }
        return Resolution(
            snapshot: total, salesBasis: segmentSalesBasisExternalIncludingOtherRevenue)
    }

    /// 開示精度の丸めを見込んだ一致（0.1% または 1 円）。±5% のような近さの判定はしない。
    static func matches(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(1.0, abs(b) * 0.001)
    }

    /// セグメント + 調整の和が連結値に合うか。合わない計（セグメント間を消去していない等）は採らない。
    private static func additiveRowsClose(_ snapshot: BreakdownSnapshot) -> Bool {
        let additive = snapshot.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount)
        guard !additive.isEmpty else { return false }
        return matches(additive.reduce(0, +), snapshot.denominator)
    }

    /// セグメント member に付いた売上系タグ。外部顧客・セグメント間・その他の収益単独・
    /// 売上以外の概念（利益・資産など）は除く。
    static func totalTagCandidates(facts: [BreakdownFact], excluding: String) -> [String] {
        let excludedWords = ["External", "Intersegment", "InterSegment", "OtherRevenue", "OtherThan"]
        return Set(facts.map(\.tag)).sorted().filter { tag in
            guard tag != excluding,
                tag.contains("Sales") || tag.contains("Revenue"),
                !Xbrl.segmentTrueExternalRevenueTags.contains(tag),
                !excludedWords.contains(where: tag.contains),
                !Xbrl.segmentNonRevenueTagKeywords.contains(where: tag.contains)
            else { return false }
            return SegmentMetricDiscovery.hasSegmentMember(facts, tag: tag)
        }
    }
}
