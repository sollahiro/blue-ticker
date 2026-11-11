// 格納済み segment-v3 スナップショットから隣接年のつなぎを書く。
// 同じキーは行にしない。残りは決定論、決められないものは needs_review。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation
import Logging

func runSegmentTransitionIngest(
    db: Database, listedCodes: Set<String>, logger: Logger? = nil
) async throws {
    let codes = listedCodes.sorted()
    for code in codes {
        let rows = try await CompanyBreakdown.query(on: db)
            .filter(\.$code == code)
            .filter(\.$axis == breakdownAxisSegment)
            .sort(\.$submitDateTime, .ascending)
            .all()
        let servable = rows.filter {
            isServableBreakdown(
                source: $0.source, cacheVersion: $0.cacheVersion, axis: breakdownAxisSegment)
                && $0.notApplicableReason == nil
        }
        guard servable.count >= 2 else { continue }
        let docIDs = servable.map(\.docID)
        let documents = try await EdinetDocument.query(on: db)
            .filter(\.$id ~~ docIDs)
            .all()
        let fyEndByDoc = Dictionary(
            uniqueKeysWithValues: documents.compactMap { doc -> (String, String)? in
                guard let id = doc.id, let fy = doc.periodEnd, !fy.isEmpty else { return nil }
                return (id, fy)
            })
        var previous: CompanyBreakdown?
        for current in servable {
            defer { previous = current }
            guard let previous else { continue }
            let fyEnd = fyEndByDoc[current.docID] ?? current.submitDateTime
            let drafts = SegmentTransitionMatcher.match(
                oldRows: previous.payload.rows, newRows: current.payload.rows, fyEnd: fyEnd)
            let existing = try await CompanySegmentTransition.query(on: db)
                .filter(\.$code == code)
                .filter(\.$fyEnd == fyEnd)
                .all()
            for row in existing {
                try await row.delete(on: db)
            }
            for draft in drafts {
                let model = CompanySegmentTransition(
                    code: code, fyEnd: draft.fyEnd, oldKey: draft.oldKey, newKey: draft.newKey)
                model.decision = draft.decision
                model.basis = draft.basis
                model.matched = draft.matched
                model.needsReview = draft.decision == segmentTransitionDecisionNeedsReview
                try await model.create(on: db)
            }
        }
        logger?.info(
            "segment transitions",
            metadata: ["code": .string(code), "pairs": .stringConvertible(max(0, servable.count - 1))])
    }
}
