// 報告セグメント（xbrl_facts）と収益認識分解が同じ内訳のときの採否。
// 報告セグメントが地域名でも、収益認識が同じカテゴリ・同じ開示金額なら、
// 利益と計 / 調整 / 連結があるセグメント facts を product_service に載せる。
// 差額埋めはしない。Jev は使わない。

import Foundation

enum ReportableSegmentRevenueRecognition {
    /// 収益認識スナップショットのセグメント行が、報告セグメント facts と名前・金額とも一致し、
    /// facts 側に利益があるとき、axis を product_service にした facts を返す。
    static func preferFactsIfSameBreakdown(
        facts: BreakdownSnapshot?, rr: BreakdownSnapshot
    ) -> BreakdownSnapshot? {
        guard var facts, factsReconcile(facts, with: rr) else { return nil }
        facts.axis = breakdownAxisProductService
        return facts
    }

    /// LLM 無しのとき: 収益認識表の行ラベルと開示セルが facts と一致するか。
    static func tablesMatchFacts(
        _ tables: [BreakdownTable], facts: BreakdownSnapshot
    ) -> Bool {
        guard usableGeographyFacts(facts) else { return false }
        let factSeg = facts.rows.filter { $0.rowKind == "segment" }
        let factByKey = uniqueAmounts(factSeg)
        guard factByKey.count == factSeg.count, factByKey.count >= 2 else { return false }

        let parsed = RevenueRecognitionCandidates.parse(tables: tables)
        for table in parsed {
            guard table.tableIndex < tables.count else { continue }
            let source = tables[table.tableIndex]
            if source.period == "前期" { continue }
            guard let scale = yenScale(for: source, parsed: table) else { continue }
            let dataRows = Array(table.grid.dropFirst(table.headerRowCount))
            guard rowLabelsCover(factKeys: Set(factByKey.keys), rows: dataRows) else { continue }
            for (column, _) in table.columnHeaders {
                if columnMatches(factByKey, rows: dataRows, column: column, scale: scale) {
                    return true
                }
            }
        }
        return false
    }

    static func usableGeographyFacts(_ facts: BreakdownSnapshot) -> Bool {
        facts.axis == "geography"
            && !facts.needsReview
            && facts.rows.contains { $0.rowKind == "segment" && $0.profit != nil }
    }

    private static func factsReconcile(_ facts: BreakdownSnapshot, with rr: BreakdownSnapshot) -> Bool {
        guard usableGeographyFacts(facts) else { return false }
        let factSeg = facts.rows.filter { $0.rowKind == "segment" }
        let rrSeg = rr.rows.filter { $0.rowKind == "segment" }
        guard factSeg.count >= 2, rrSeg.count >= 2 else { return false }
        let factByKey = uniqueAmounts(factSeg)
        let rrByKey = uniqueAmounts(rrSeg)
        guard factByKey.count == factSeg.count, rrByKey.count == rrSeg.count else { return false }
        guard Set(factByKey.keys) == Set(rrByKey.keys) else { return false }
        return factByKey.allSatisfy { key, amount in rrByKey[key] == amount }
    }

    static func displayKey(_ row: BreakdownRow) -> String {
        normalized(row.label ?? row.labelRaw)
    }

    static func normalized(_ text: String) -> String {
        RevenueRecognitionCandidates.stripNoteMarker(
            RevenueRecognitionCandidates.compactCell(text))
    }

    private static func uniqueAmounts(_ rows: [BreakdownRow]) -> [String: Double] {
        var map: [String: Double] = [:]
        var duplicate = false
        for row in rows {
            let key = displayKey(row)
            if key.isEmpty { duplicate = true; break }
            if map[key] != nil { duplicate = true; break }
            map[key] = row.amount
        }
        return duplicate ? [:] : map
    }

    private static func yenScale(
        for source: BreakdownTable, parsed: RevenueRecognitionCandidates.ParsedTable
    ) -> Double? {
        let candidates = [
            source.unitCaption, parsed.unitCaption, parsed.precedingCaption,
            source.precedingCaption, source.markdown, source.heading,
        ]
        for raw in candidates {
            guard let text = raw, let token = BreakdownExtractor.parseUnitCaption(text),
                  let scale = BreakdownLLMAmountScale.yenScale(forHeaderToken: token)
            else { continue }
            return scale
        }
        return nil
    }

    private static func rowLabelsCover(factKeys: Set<String>, rows: [[String]]) -> Bool {
        let labels = Set(rows.map { normalized(RevenueRecognitionCandidates.rowLabel($0)) })
        return factKeys.isSubset(of: labels)
    }

    private static func columnMatches(
        _ factByKey: [String: Double], rows: [[String]], column: Int, scale: Double
    ) -> Bool {
        var matched = 0
        for (key, amount) in factByKey {
            guard let row = rows.first(where: {
                normalized(RevenueRecognitionCandidates.rowLabel($0)) == key
            }), column < row.count,
                let raw = RevenueRecognitionCandidates.parseAmount(row[column]),
                raw * scale == amount
            else { return false }
            matched += 1
        }
        return matched == factByKey.count
    }
}
