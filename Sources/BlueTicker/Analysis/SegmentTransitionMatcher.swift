// 隣接年の報告セグメント行を segment_key でつなぐ。同じキーは connect。
// 残件はラベル+値 / Segment(s) 複数形だけを決定論でつなぎ、値だけ一致は Jev。
// Jev 無し・低確信は needs_review。自動で connect しない。

import Foundation

public struct SegmentTransitionDraft: Equatable, Sendable {
    public var oldKey: String?
    public var newKey: String?
    public var fyEnd: String
    public var decision: String
    public var basis: String
    public var matched: String

    public init(
        oldKey: String?, newKey: String?, fyEnd: String, decision: String, basis: String,
        matched: String
    ) {
        self.oldKey = oldKey
        self.newKey = newKey
        self.fyEnd = fyEnd
        self.decision = decision
        self.basis = basis
        self.matched = matched
    }
}

public enum SegmentTransitionMatcher {
    public static func match(
        oldRows: [BreakdownRowPayload],
        newRows: [BreakdownRowPayload],
        fyEnd: String,
        priorYearAmountByNewKey: [String: Double] = [:]
    ) -> [SegmentTransitionDraft] {
        let oldKeys = Dictionary(
            uniqueKeysWithValues: oldRows.compactMap { row -> (String, BreakdownRowPayload)? in
                guard let key = row.segmentKey else { return nil }
                return (key, row)
            })
        let newKeys = Dictionary(
            uniqueKeysWithValues: newRows.compactMap { row -> (String, BreakdownRowPayload)? in
                guard let key = row.segmentKey else { return nil }
                return (key, row)
            })
        let shared = Set(oldKeys.keys).intersection(newKeys.keys)
        var leftoverOld = Set(oldKeys.keys).subtracting(shared)
        var leftoverNew = Set(newKeys.keys).subtracting(shared)
        var out: [SegmentTransitionDraft] = []

        for key in leftoverOld.sorted() {
            guard let old = oldKeys[key] else { continue }
            if let renamed = leftoverNew.sorted().first(where: { candidate in
                guard let new = newKeys[candidate] else { return false }
                return isPluralOnlyRename(oldKey: key, newKey: candidate)
                    || labelAndPriorValueMatch(
                        old: old, new: new, prior: priorYearAmountByNewKey[candidate])
            }) {
                let matched =
                    isPluralOnlyRename(oldKey: key, newKey: renamed)
                    ? segmentTransitionMatchedPluralOnly
                    : segmentTransitionMatchedLabelAndValue
                out.append(
                    SegmentTransitionDraft(
                        oldKey: key, newKey: renamed, fyEnd: fyEnd,
                        decision: segmentTransitionDecisionConnect,
                        basis: segmentTransitionBasisDeterministic, matched: matched))
                leftoverOld.remove(key)
                leftoverNew.remove(renamed)
            }
        }

        for key in leftoverOld.sorted() {
            guard let old = oldKeys[key] else { continue }
            let valueHits = leftoverNew.sorted().filter { candidate in
                valuesMatch(old.amount, priorYearAmountByNewKey[candidate] ?? newKeys[candidate]?.amount)
                    && !labelsMatch(old, newKeys[candidate])
            }
            if valueHits.count == 1, let hit = valueHits.first {
                out.append(
                    SegmentTransitionDraft(
                        oldKey: key, newKey: hit, fyEnd: fyEnd,
                        decision: segmentTransitionDecisionNeedsReview,
                        basis: segmentTransitionBasisDeterministic,
                        matched: segmentTransitionMatchedUnmatched))
                leftoverOld.remove(key)
                leftoverNew.remove(hit)
                continue
            }
            out.append(
                SegmentTransitionDraft(
                    oldKey: key, newKey: nil, fyEnd: fyEnd,
                    decision: leftoverNew.isEmpty
                        ? segmentTransitionDecisionBreak : segmentTransitionDecisionNeedsReview,
                    basis: segmentTransitionBasisDeterministic,
                    matched: segmentTransitionMatchedUnmatched))
        }
        for key in leftoverNew.sorted() {
            out.append(
                SegmentTransitionDraft(
                    oldKey: nil, newKey: key, fyEnd: fyEnd,
                    decision: leftoverOld.isEmpty
                        ? segmentTransitionDecisionBreak : segmentTransitionDecisionNeedsReview,
                    basis: segmentTransitionBasisDeterministic,
                    matched: segmentTransitionMatchedUnmatched))
        }
        return out
    }

    /// Jev の閉じた集合。connect は閾値を満たしたときだけ。それ以外は needs_review。
    static func applyJev(
        _ draft: SegmentTransitionDraft, decision: String, confident: Bool
    ) -> SegmentTransitionDraft {
        var out = draft
        out.basis = segmentTransitionBasisJev
        if confident, decision == segmentTransitionDecisionBreak {
            out.decision = segmentTransitionDecisionBreak
        } else if confident, decision == segmentTransitionDecisionConnect {
            out.decision = segmentTransitionDecisionConnect
        } else {
            out.decision = segmentTransitionDecisionNeedsReview
        }
        return out
    }

    static func isPluralOnlyRename(oldKey: String, newKey: String) -> Bool {
        guard let old = SegmentKey.parse(oldKey), let new = SegmentKey.parse(newKey) else {
            return false
        }
        guard old.edinetCode == new.edinetCode, old.kind == new.kind else { return false }
        return pluralFold(old.localName) == pluralFold(new.localName)
            && old.localName != new.localName
    }

    private static func pluralFold(_ local: String) -> String {
        local.replacingOccurrences(of: "SegmentsMember", with: "SegmentMember")
            .replacingOccurrences(of: "SegmentMember", with: "SegmentMember")
    }

    private static func labelAndPriorValueMatch(
        old: BreakdownRowPayload, new: BreakdownRowPayload, prior: Double?
    ) -> Bool {
        labelsMatch(old, new) && valuesMatch(old.amount, prior)
    }

    private static func labelsMatch(_ old: BreakdownRowPayload, _ new: BreakdownRowPayload?) -> Bool {
        guard let new else { return false }
        return SegmentLabelMatch.matches(old.label, segmentLabel: new.label)
    }

    private static func valuesMatch(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) <= max(1.0, abs(a) * 1e-9)
    }
}
