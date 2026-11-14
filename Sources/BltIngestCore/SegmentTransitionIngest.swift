// 格納済み segment-v3 スナップショットから隣接年のつなぎを書く。
// 同じキーは行にしない。残りは決定論、決められないものは needs_review。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation
import Logging

/// 全上場会社のつなぎを会社ごとに書く。DB 操作の再試行とタイムアウトは会社 1 社ごとに掛ける。
/// 全社のループ全体を 1 つの `withDbRetry`（1 試行 60 秒）で包むと、会社数が多いときに必ず
/// タイムアウトし、再試行も先頭からやり直しになって取り込みが毎回異常終了する。
/// 1 社の処理は、既存行との差分があるときだけ書き直すので、再試行しても結果は同じ。
func runSegmentTransitionIngest(
    db: Database, listedCodes: Set<String>, logger: Logger? = nil
) async throws {
    for code in listedCodes.sorted() {
        try await withDbRetry(logger: logger, context: "company_segment_transitions code=\(code)") {
            try await writeSegmentTransitions(code: code, db: db, logger: logger)
        }
    }
}

private func writeSegmentTransitions(
    code: String, db: Database, logger: Logger?
) async throws {
    // 年次応答（`loadStoredSegmentWaterfall`）と同じ年の並びでつなぐ。決算期ごとに 1 書類、
    // 公開面に出ない行は飛ばす。書類の提出順で隣を取ると、同じ期の書類が 2 つあるときに
    // 前年とのつなぎが消える。
    let years = Array(try await loadServableSegmentYears(code: code, db: db).reversed())
    guard years.count >= 2 else { return }
    var written = 0
    for index in years.indices.dropFirst() {
        let previous = years[index - 1]
        let current = years[index]
        let drafts = SegmentTransitionMatcher.match(
            oldRows: previous.payload.rows, newRows: current.payload.rows,
            fyEnd: current.fyEnd)
        let existing = try await CompanySegmentTransition.query(on: db)
            .filter(\.$code == code)
            .filter(\.$fyEnd == current.fyEnd)
            .all()
        if sameTransitions(existing, drafts) { continue }
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
        written += 1
    }
    logger?.info(
        "segment transitions",
        metadata: [
            "code": .string(code), "pairs": .stringConvertible(years.count - 1),
            "rewritten": .stringConvertible(written),
        ])
}

/// 格納済みの行と今回の判定が同じか。同じなら書き直さない（毎回の delete / insert を避ける）。
private func sameTransitions(
    _ existing: [CompanySegmentTransition], _ drafts: [SegmentTransitionDraft]
) -> Bool {
    guard existing.count == drafts.count else { return false }
    func signature(
        _ oldKey: String?, _ newKey: String?, _ decision: String, _ basis: String, _ matched: String
    ) -> String {
        [oldKey ?? "", newKey ?? "", decision, basis, matched].joined(separator: "\u{1F}")
    }
    let stored = existing.map {
        signature($0.oldKey, $0.newKey, $0.decision, $0.basis, $0.matched)
    }
    let fresh = drafts.map { signature($0.oldKey, $0.newKey, $0.decision, $0.basis, $0.matched) }
    return stored.sorted() == fresh.sorted()
}
