import BlueTickerCore
import FluentKit
import Foundation
import Logging

package func loadStoredSegmentWaterfall(
    code: String, metric: String, key: String?, years: Int, db: Database
) async throws -> BreakdownLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    guard segmentWaterfallMetrics.contains(metric) else { return .absent }
    let snapshots = try await loadServableSegmentYears(code: code4, db: db)
    guard !snapshots.isEmpty else { return .absent }
    let limited = Array(snapshots.suffix(max(1, years)))
    return .found(
        SegmentWaterfall.jsonObject(code: code4, metric: metric, years: limited, key: key))
}

package func loadStoredSegmentTransitions(
    code: String, key: String?, db: Database
) async throws -> BreakdownLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    let rows = try await CompanySegmentTransition.query(on: db)
        .filter(\.$code == code4)
        .sort(\.$fyEnd, .ascending)
        .all()
    let filtered = rows.filter { row in
        guard let key else { return true }
        return row.oldKey == key || row.newKey == key
    }
    guard !filtered.isEmpty else { return .absent }
    return .found([
        "code": code4,
        "transitions": filtered.map { row -> [String: Any] in
            var object: [String: Any] = [
                "fy_end": row.fyEnd,
                "decision": row.decision,
                "basis": row.basis,
                "matched": row.matched,
            ]
            if let oldKey = row.oldKey { object["old_key"] = oldKey }
            if let newKey = row.newKey { object["new_key"] = newKey }
            return object
        },
    ])
}

private func loadServableSegmentYears(
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
    return servable.map {
        (fyEnd: fyEndByDoc[$0.docID] ?? $0.submitDateTime, docID: $0.docID, payload: $0.payload)
    }
}
