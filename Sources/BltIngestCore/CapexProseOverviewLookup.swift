// financials ingest 用: 格納済みの capex 軸から、本文由来（capex_prose）の概要総額を書類ごとに読む。
// financials の `capex` は breakdown capex 軸を正本にする。Jev は呼ばない（読むだけ）。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation

/// docID → 本文由来の設備投資総額（円）。現行版として servable な行だけ。
func loadCapexProseOverviewYenByDocID(
    db: Database, code: String, docIDs: [String]
) async throws -> [String: Double] {
    let ids = Array(Set(docIDs.filter { !$0.isEmpty }))
    guard !ids.isEmpty else { return [:] }
    let rows = try await CompanyBreakdown.query(on: db)
        .filter(\.$code == code)
        .filter(\.$axis ~~ [breakdownAxisSegment, breakdownAxisCapex])
        .filter(\.$docID ~~ ids)
        .all()
    var out: [String: Double] = [:]
    for row in rows {
        guard isServableBreakdown(
            source: row.source, cacheVersion: row.cacheVersion, axis: row.axis),
            row.notApplicableReason == nil,
            let yen = capexProseOverviewYen(in: row.payload)
        else { continue }
        if row.axis == breakdownAxisSegment || out[row.docID] == nil {
            out[row.docID] = yen
        }
    }
    return out
}

/// computeFinancials の結果へ、格納済み capex 軸の本文由来総額を載せる。
func applyingStoredCapexProseOverview(
    to result: FinancialsComputeResult, code: String, db: Database
) async -> FinancialsComputeResult {
    let docIDs = financialsDocIDs(in: result)
    guard !docIDs.isEmpty else { return result }
    guard let overview = try? await loadCapexProseOverviewYenByDocID(
        db: db, code: code, docIDs: docIDs)
    else { return result }
    return applyingBreakdownCapexProseOverview(to: result, overviewYenByDocID: overview)
}
