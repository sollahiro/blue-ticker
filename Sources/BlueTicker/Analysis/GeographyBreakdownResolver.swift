// `geography` キーの地域別内訳（geography breakdown）を解決する。
// docs/breakdown.md 参照。内訳取り込み ingest と共有する振り分け:
//
// 1. method == not_found → snapshot nil（呼び出し側が not_applicable / not_found を永続化）
// 2. xbrl_facts → BreakdownNormalizer（axis=geography のみ採用）
// 3. html_table → GeographyBreakdownLLMNormalizer（決定論の表構造 + Jev 列選択）
// 4. それ以外・失敗 → snapshot nil（呼び出し側が not_applicable / unknown を永続化）

import Foundation

/// どの経路で geography breakdown を解決したか（監査・DB `source` 用）。
enum GeographyBreakdownSource: String {
    case xbrlFacts = "xbrl_facts"
    case geographyLLM = "geography_llm"
    case notFound = "not_found"
}

enum GeographyBreakdownResolver {

    /// geography（地域別情報）の ExtractedBreakdown から geography 軸の BreakdownSnapshot を解決する。
    /// Jev 列選択は html_table 経路でのみ発生し、xbrl_facts で解決できれば呼ばない。
    static func resolve(
        geography: ExtractedBreakdown,
        consolidatedSales: Double?,
        columnDecider: (any RevenueRecognitionColumnDeciding)?,
        labelsByTag: [String: String] = [:],
        fiscalYearEnd: String? = nil,
        docID: String = ""
    ) async -> (snapshot: BreakdownSnapshot?, source: GeographyBreakdownSource, audit: LLMBreakdownAudit?) {
        switch geography.method {
        case "not_found":
            return (nil, .notFound, nil)

        case "xbrl_facts":
            if let snapshot = BreakdownNormalizer.normalize(
                geography, consolidatedSales: consolidatedSales, labelsByTag: labelsByTag),
                snapshot.axis == "geography"
            {
                return (snapshot, .xbrlFacts, nil)
            }
            if !geography.tables.isEmpty, let columnDecider {
                let (snapshot, audit) = await GeographyBreakdownLLMNormalizer.normalize(
                    geography, consolidatedSales: consolidatedSales, decider: columnDecider,
                    fiscalYearEnd: fiscalYearEnd, docID: docID)
                if let snapshot { return (snapshot, .geographyLLM, audit) }
                return (nil, .notFound, audit)
            }
            return (nil, .notFound, nil)

        case "html_table":
            guard let columnDecider else { return (nil, .notFound, nil) }
            let (snapshot, audit) = await GeographyBreakdownLLMNormalizer.normalize(
                geography, consolidatedSales: consolidatedSales, decider: columnDecider,
                fiscalYearEnd: fiscalYearEnd, docID: docID)
            if let snapshot { return (snapshot, .geographyLLM, audit) }
            return (nil, .notFound, audit)

        default:
            return (nil, .notFound, nil)
        }
    }
}
