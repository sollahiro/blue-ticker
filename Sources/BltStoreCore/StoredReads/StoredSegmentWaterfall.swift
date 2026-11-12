import BlueTickerCore
import FluentKit
import Foundation
import Logging

package func loadStoredSegmentWaterfall(
    code: String, metric: String, key: String?, years: Int, fiscalYear: String?, db: Database
) async throws -> BreakdownLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    guard segmentWaterfallMetrics.contains(metric) else { return .absent }
    if fiscalYear == nil, years <= 0 { return .absent }
    let snapshots = try await loadServableSegmentYears(code: code4, db: db)
    guard !snapshots.isEmpty else { return .absent }
    let transitions = try await loadSegmentTransitionDrafts(code: code4, db: db)
    let object = SegmentWaterfall.jsonObject(
        code: code4, metric: metric, years: snapshots, transitions: transitions,
        key: key, fiscalYear: fiscalYear, limit: max(1, years))
    let returned = object["years"] as? [[String: Any]] ?? []
    guard !returned.isEmpty else { return .absent }
    return .found(object)
}

private func loadSegmentTransitionDrafts(
    code: String, db: Database
) async throws -> [SegmentTransitionDraft] {
    let rows = try await CompanySegmentTransition.query(on: db)
        .filter(\.$code == code)
        .sort(\.$fyEnd, .ascending)
        .all()
    return rows.map {
        SegmentTransitionDraft(
            oldKey: $0.oldKey, newKey: $0.newKey, fyEnd: $0.fyEnd,
            decision: $0.decision, basis: $0.basis, matched: $0.matched)
    }
}

/// 年次応答に載る segment-v3 スナップショット（新しい順）。同じ決算期の書類が複数あれば提出の新しい方。
/// つなぎの ingest も同じ並びを使う（読む側と書く側で「前年」がずれないように）。
package func loadServableSegmentYears(
    code: String, db: Database
) async throws -> [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)] {
    let candidates = try await CompanyBreakdown.query(on: db)
        .filter(\.$code == code)
        .filter(\.$axis == breakdownAxisSegment)
        .sort(\.$submitDateTime, .ascending)
        .all()
    let companyDocIDs = try await companyDisclosureDocIDs(
        among: candidates.map(\.docID), db: db)
    let servable = candidates.filter {
        isServableBreakdown(
            source: $0.source, cacheVersion: $0.cacheVersion, axis: breakdownAxisSegment)
            && companyDocIDs.contains($0.docID)
            && $0.notApplicableReason == nil
            && isPubliclyServableBreakdown(
                source: $0.source, needsReview: $0.needsReview || $0.payload.needsReview,
                warnings: $0.payload.warnings, rows: $0.payload.rows, axis: breakdownAxisSegment)
    }
    let documents = try await EdinetDocument.query(on: db)
        .filter(\.$id ~~ servable.map(\.docID))
        .all()
    let fyEndByDoc = Dictionary(
        uniqueKeysWithValues: documents.compactMap { doc -> (String, String)? in
            guard let id = doc.id, let fy = doc.periodEnd, !fy.isEmpty else { return nil }
            return (id, fy)
        })
    var unique: [String: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload, submit: String)] = [:]
    for row in servable {
        let fyEnd = fyEndByDoc[row.docID] ?? row.submitDateTime
        if let existing = unique[fyEnd], existing.submit > row.submitDateTime { continue }
        unique[fyEnd] = (fyEnd: fyEnd, docID: row.docID, payload: row.payload, submit: row.submitDateTime)
    }
    return unique.values
        .sorted { $0.fyEnd > $1.fyEnd }
        .map { (fyEnd: $0.fyEnd, docID: $0.docID, payload: $0.payload) }
}
