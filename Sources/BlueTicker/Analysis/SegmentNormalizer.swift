// 事業別・地域別売上の比較用コモンモデル（Stage 6, docs/segment-normalization-concept.md）
// SegmentExtractor の xbrl_facts 結果を BreakdownSnapshot（比較可能な正規化スナップショット）へ写す。
//
// html_table 由来（method == "html_table"）は行パース未実装のため対象外（nil を返す）。
// 銀行等の金融機関は segmentExternalRevenueTags に一致するタグを持たないため、
// 自然に nil（対象外）になる。

import Foundation

struct BreakdownRow: Equatable {
    var labelRaw: String
    var amount: Double
    var share: Double?
    var rowKind: String  // "segment" | "subtotal" | "reconciling"
}

struct BreakdownSnapshot: Equatable {
    var axis: String  // "business" | "geography"
    var denominator: Double
    var denominatorTag: String
    var rows: [BreakdownRow]
    var sourceKind: String  // 現状 "xbrl_facts" のみ
    var needsReview: Bool
    var warnings: [String]
}

enum SegmentNormalizer {

    /// SegmentResult（xbrl_facts）と連結外部売上から BreakdownSnapshot を組み立てる。
    /// 適用不可（html_table / not_found / 該当タグなし＝銀行等）の場合は nil。
    static func normalize(_ result: SegmentResult, consolidatedSales: Double?) -> BreakdownSnapshot? {
        guard result.method == "xbrl_facts", !result.facts.isEmpty,
              let consolidatedSales, consolidatedSales != 0 else { return nil }

        guard let denominatorTag = Xbrl.segmentExternalRevenueTags.first(where: { tag in
            result.facts.contains(where: { $0.tag == tag })
        }) else { return nil }

        // 連結を優先し、連結コンテキストが1件もなければ非連結（子会社を持たない小規模企業）にフォールバックする。
        // resolveItemPreferCurrent と同じ「優先→フォールバック」の非対称ルール。
        let candidateFacts = result.facts.filter { $0.tag == denominatorTag && isCurrentPeriod($0.contextRef) }
        let consolidatedFacts = candidateFacts.filter(isConsolidated)
        let perMember = buildPerMember(from: consolidatedFacts.isEmpty ? candidateFacts : consolidatedFacts)
        guard !perMember.isEmpty else { return nil }

        // 1次判定: タクソノミ標準の小計・調整 member を名称で分類する。
        var kinds: [String: String] = [:]
        for member in perMember.keys {
            if Xbrl.segmentReconcilingMemberNames.contains(member) {
                kinds[member] = "reconciling"
            } else if Xbrl.segmentSubtotalMemberNames.contains(member) {
                kinds[member] = "subtotal"
            } else {
                kinds[member] = "segment"
            }
        }
        // 2次判定（数値の安全網）: 名称未収載の合計行を分母一致で補足する。
        // ただし segment 候補が1件しかない場合は適用しない
        // （単一セグメント企業では amount ≈ denominator が正しい姿であり、小計ではない）。
        let segmentCandidates = perMember.keys.filter { kinds[$0] == "segment" }
        if segmentCandidates.count > 1 {
            for member in segmentCandidates {
                let amount = perMember[member]!.value
                if abs(amount - consolidatedSales) / abs(consolidatedSales) < 0.01 {
                    kinds[member] = "subtotal"
                }
            }
        }

        let rows = perMember.keys.sorted().map { member -> BreakdownRow in
            let fact = perMember[member]!
            return BreakdownRow(
                labelRaw: member,
                amount: fact.value,
                share: fact.value / consolidatedSales,
                rowKind: kinds[member]!
            )
        }

        let (axis, axisNeedsReview) = classifyAxis(rows: rows)
        var warnings: [String] = []
        if axisNeedsReview { warnings.append("axis_ambiguous") }

        return BreakdownSnapshot(
            axis: axis,
            denominator: consolidatedSales,
            denominatorTag: denominatorTag,
            rows: rows,
            sourceKind: "xbrl_facts",
            needsReview: axisNeedsReview,
            warnings: warnings
        )
    }

    // MARK: - 内部ロジック

    /// ConsolidatedOrNonConsolidatedAxis が明示的に非連結を指していないこと。
    private static func isConsolidated(_ fact: SegmentFact) -> Bool {
        fact.dimensions["ConsolidatedOrNonConsolidatedAxis"] != "NonConsolidatedMember"
    }

    /// member ごとに最初に見つかった fact を採用する（facts は tag+contextRef でソート済みのため決定的）。
    private static func buildPerMember(from facts: [SegmentFact]) -> [String: SegmentFact] {
        var perMember: [String: SegmentFact] = [:]
        for fact in facts {
            guard let member = primaryMember(fact.dimensions), perMember[member] == nil else { continue }
            perMember[member] = fact
        }
        return perMember
    }

    /// 当期コンテキストかどうか（セグメント軸は Member 修飾があるため ContextHelpers は使わず判定する）。
    private static func isCurrentPeriod(_ contextRef: String) -> Bool {
        Xbrl.durationContextPatterns.contains(where: contextRef.contains)
            || Xbrl.instantContextPatterns.contains(where: contextRef.contains)
    }

    /// dimensions のうち ConsolidatedOrNonConsolidatedAxis 以外の member を行ラベルとする。
    /// 複数該当する場合は dimension キー名の辞書順で先頭を採用し、Dictionary の走査順不定に依存しない
    /// （smoke 実データでは OperatingSegmentsAxis 系1本のみだが、将来複数軸が絡む書類のための決定的化）。
    private static func primaryMember(_ dimensions: [String: String]) -> String? {
        dimensions
            .filter { $0.key != "ConsolidatedOrNonConsolidatedAxis" }
            .sorted { $0.key < $1.key }
            .first?.value
    }

    /// segment 行の member ラベルが地域名キーワードと全一致すれば geography、
    /// 一致なしなら business、一部一致（混在）は business + needs_review。
    private static func classifyAxis(rows: [BreakdownRow]) -> (axis: String, needsReview: Bool) {
        let segmentMembers = rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        guard !segmentMembers.isEmpty else { return ("business", false) }

        let geoMatches = segmentMembers.filter { member in
            Xbrl.segmentGeographyMemberKeywords.contains(where: member.contains)
        }
        if geoMatches.count == segmentMembers.count { return ("geography", false) }
        if geoMatches.isEmpty { return ("business", false) }
        return ("business", true)
    }
}
