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
    var profit: Double?  // 対応する利益タグが無ければ nil（任意フィールド）
    var rowKind: String  // "segment" | "subtotal" | "reconciling"
}

struct BreakdownSnapshot: Equatable {
    var axis: String  // "business" | "geography"
    var denominator: Double
    // 採用した分母の出所（監査・再現用）。xbrl_facts 経路は実際に使った XBRL タグ名
    // （例: "SalesToExternalCustomersIFRS"）、html_table 経路は XBRL タグが存在しないため
    // sentinel 文字列 "income_statement.sales" を使う（意図的な語彙の使い分け）。
    var denominatorTag: String
    var rows: [BreakdownRow]
    var sourceKind: String  // "xbrl_facts"（本ファイル） | "html_table"（SegmentBreakdownLLMNormalizer） | "revenue_recognition"（RevenueRecognitionLLMNormalizer） | "segment_info"（SegmentInfoLLMNormalizer）
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

        let perMember = resolvePerMember(facts: result.facts, tag: denominatorTag)
        guard !perMember.isEmpty else { return nil }

        // 利益は任意フィールド（対応する利益タグが無い/取れない member は profit=nil のまま）。
        let profitTag = Xbrl.segmentProfitTags.first(where: { tag in
            result.facts.contains(where: { $0.tag == tag })
        })
        let profitByMember = profitTag.map { resolvePerMember(facts: result.facts, tag: $0) } ?? [:]

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
                profit: profitByMember[member]?.value,
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

    /// 指定タグの当期 fact を member ごとに解決する。連結を優先し、連結コンテキストが
    /// 1件もなければ非連結（子会社を持たない小規模企業）にフォールバックする
    /// （resolveItemPreferCurrent と同じ「優先→フォールバック」の非対称ルール）。
    /// facts は tag+contextRef でソート済みのため、member 内の採用順は決定的。
    private static func resolvePerMember(facts: [SegmentFact], tag: String) -> [String: SegmentFact] {
        let candidateFacts = facts.filter { $0.tag == tag && isCurrentPeriod($0.contextRef) }
        let consolidatedFacts = candidateFacts.filter(isConsolidated)
        let source = consolidatedFacts.isEmpty ? candidateFacts : consolidatedFacts

        var perMember: [String: SegmentFact] = [:]
        for fact in source {
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
    /// 一致なしなら business、一部一致（混在）は business + needs_review（ただし下記の例外あり）。
    /// `segmentOtherBusinessMemberNames`（rowKind は segment だが事業/地域いずれの軸にも
    /// 断定できない「その他」）は候補から除外する。`SegmentExtractor.isGeographyAxis` と同じ理由
    /// （軸判定への影響を避ける）。除外しないと、地域別報告企業にこの member が同居する場合に
    /// 全一致判定が崩れ、本来 geography のスナップショットが business + needs_review へ誤分類される。
    ///
    /// 一部一致の needs_review 判定は `segmentGeographyMemberKeywords` 全体ではなく
    /// `segmentSpecificGeographyMemberKeywords`（Domestic/Overseas を除いた特定地域名）で行う
    /// （学び11、実データ検証: 1802大林組・1812鹿島建設・1808長谷工・2413エムスリー）。
    /// 「国内◯◯事業」「海外◯◯事業」という事業区分名や「海外事業」という単独カテゴリは
    /// Domestic/Overseas のみで一致するが、これらは事業軸の一部であって地域軸との真の混在ではない
    /// （sum(segment) ≈ denominator で axis=business の正しさを別途確認済み）。
    /// 既知のトレードオフ: 「DomesticMember」「OverseasMember」のように member ラベルが
    /// Domestic/Overseas 単体（他の事業語を伴わない）で、かつ他の segment が事業名という
    /// 真に軸混在のケースも、本ルールでは needs_review を立てず見逃す。実データでは
    /// 常に事業区分語との複合ラベルだったため、複合か単体かは判定に使っていない。
    private static func classifyAxis(rows: [BreakdownRow]) -> (axis: String, needsReview: Bool) {
        let segmentMembers = rows
            .filter { $0.rowKind == "segment" && !Xbrl.segmentOtherBusinessMemberNames.contains($0.labelRaw) }
            .map(\.labelRaw)
        guard !segmentMembers.isEmpty else { return ("business", false) }

        let geoMatches = segmentMembers.filter { member in
            Xbrl.segmentGeographyMemberKeywords.contains(where: member.contains)
        }
        if geoMatches.count == segmentMembers.count { return ("geography", false) }
        if geoMatches.isEmpty { return ("business", false) }

        let specificGeoMatches = segmentMembers.filter { member in
            Xbrl.segmentSpecificGeographyMemberKeywords.contains(where: member.contains)
        }
        return ("business", !specificGeoMatches.isEmpty)
    }
}
