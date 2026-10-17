// セグメント member の役割（事業か、調整・消去・全社か）。
// 標準の調整 member（`Xbrl.segmentReconcilingMemberNames`）を使わず、会社拡張の member で
// 「消去又は全社」などの列を立てる会社（7203 トヨタ `CorporateExpensesAndEliminationMember`）が
// ある。会社拡張の member 名を一覧に足していかず、書類ごとに Jev に既存の member から選ばせる。
// 採否はコード: 選んだ member の外部売上が売上合計の 1% を超えたら事業とみなして採らない。
// 結果は書類単位で `BreakdownMemberRoles.extraReconciling`（TaskLocal）に載せ、各軸の
// member 分類（`BreakdownMemberRoles.isReconciling`）が標準一覧と同じに扱う。

import Foundation

enum BreakdownMemberRoles {
    /// この書類で Jev が調整・消去・全社と判定した会社拡張 member。
    @TaskLocal static var extraReconciling: Set<String> = []

    static func isReconciling(_ member: String) -> Bool {
        Xbrl.segmentReconcilingMemberNames.contains(member) || extraReconciling.contains(member)
    }
}

struct SegmentMemberRoleCandidate: Equatable, Sendable {
    var key: String
    var member: String
    var label: String
    var externalRevenueMillionYen: Double?
}

protocol SegmentMemberRoleDeciding: Sendable {
    func chooseReconcilingMember(
        candidates: [SegmentMemberRoleCandidate], docID: String
    ) async -> JevChoiceAggregate.Sample
}

enum SegmentMemberRoleJevPicker {
    static let question = "reconciling_member"
    static let axis = "segment_member_role"
    /// 外部売上がこの割合を超える member は事業セグメント（Jev では覆さない）。
    static let maxExternalRevenueShare = 0.01
    static let jevPolicy = JevDecisionPolicy(
        question: question,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    /// 標準の調整 member が無い書類の、標準一覧に無い（会社拡張の）当期 member。
    /// 標準の調整 member があるときは空（聞かない）。
    static func candidates(facts: [BreakdownFact], labelsByTag: [String: String]) -> [SegmentMemberRoleCandidate] {
        let members = Set(facts.compactMap { XBRLUtils.primaryBreakdownMember($0.dimensions) })
        if members.contains(where: { Xbrl.segmentReconcilingMemberNames.contains($0) }) { return [] }
        let standard = Xbrl.segmentSubtotalMemberNames
            .union(Xbrl.segmentOtherBusinessMemberNames)
            .union([Xbrl.entityTotalMemberName])
        let external = externalRevenueByMember(facts: facts)
        return members.subtracting(standard).sorted().enumerated().map { index, member in
            SegmentMemberRoleCandidate(
                key: "m\(index)", member: member, label: labelsByTag[member] ?? member,
                externalRevenueMillionYen: external[member].map { $0 / Financial.millionYen })
        }
    }

    static func externalRevenueByMember(facts: [BreakdownFact]) -> [String: Double] {
        guard let tag = Xbrl.segmentExternalRevenueTags.first(where: { tag in
            facts.contains { $0.tag == tag }
        }) else { return [:] }
        var out: [String: Double] = [:]
        for fact in facts where fact.tag == tag && BreakdownNormalizer.isCurrentPeriodContext(fact.contextRef) {
            guard let member = XBRLUtils.primaryBreakdownMember(fact.dimensions), out[member] == nil
            else { continue }
            out[member] = fact.value
        }
        return out
    }

    /// 外部売上が売上合計（候補の絶対値の和）の 1% 以下か。売上が無ければ通す。
    static func externalRevenueIsNegligible(
        _ chosen: SegmentMemberRoleCandidate, among candidates: [SegmentMemberRoleCandidate]
    ) -> Bool {
        guard let own = chosen.externalRevenueMillionYen else { return true }
        let total = candidates.compactMap(\.externalRevenueMillionYen).map(abs).reduce(0, +)
        guard total > 0 else { return true }
        return abs(own) <= total * maxExternalRevenueShare
    }

    struct PickResult: Equatable, Sendable {
        var members: Set<String>
        var sentences: [String]
    }

    static func pick(
        candidates: [SegmentMemberRoleCandidate], decider: any SegmentMemberRoleDeciding, docID: String
    ) async -> PickResult {
        guard candidates.count >= 2 else {
            return PickResult(members: [], sentences: ["member_role_jev=skipped candidates=\(candidates.count)"])
        }
        let options = candidates.map(\.key) + [JevDecision.noneOfThese]
        let result = await JevDecisionSampler.decide(policy: jevPolicy, options: options) {
            await decider.chooseReconcilingMember(candidates: candidates, docID: docID)
        }
        guard let key = result.selectedKey,
              let chosen = candidates.first(where: { $0.key == key })
        else {
            return PickResult(members: [], sentences: [
                result.status == .noneOfThese ? "member_role_jev=none_of_these" : "member_role_jev=fail_closed",
            ])
        }
        guard externalRevenueIsNegligible(chosen, among: candidates) else {
            return PickResult(members: [], sentences: ["member_role_jev=has_external_revenue member=\(chosen.member)"])
        }
        return PickResult(members: [chosen.member], sentences: ["member_role_jev=accepted member=\(chosen.member)"])
    }
}

struct OpenRouterSegmentMemberRoleDecider: SegmentMemberRoleDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func chooseReconcilingMember(
        candidates: [SegmentMemberRoleCandidate], docID: String
    ) async -> JevChoiceAggregate.Sample {
        let options = candidates.map(\.key) + [JevDecision.noneOfThese]
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(model: model, candidates: candidates, docID: docID)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: SegmentMemberRoleJevPicker.jevPolicy.transportRetries,
            onFailure: "SegmentMemberRoleJevPicker: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[
            SegmentMemberRoleJevPicker.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: options, model: model)
    }

    static func requestJSON(
        model: String, candidates: [SegmentMemberRoleCandidate], docID: String
    ) -> Data? {
        var presented = candidates.map { candidate in
            JevPresentedCandidate(key: candidate.key, criterion: "column=\(candidate.label)")
        }
        presented.append(JevPresentedCandidate(
            key: JevDecision.noneOfThese,
            criterion: "Every column is a business (operating) segment."))
        let state: [String: Any] = [
            "doc_id": docID,
            "columns": candidates.map { candidate -> [String: Any] in
                var column: [String: Any] = [
                    "key": candidate.key, "label": candidate.label, "member": candidate.member,
                ]
                if let revenue = candidate.externalRevenueMillionYen {
                    column["external_revenue_million_yen"] = revenue
                }
                return column
            },
        ]
        let instructions = """
            The state lists the company-specific columns of the segment information table \
            (セグメント情報) in a Japanese annual securities report (有価証券報告書, doc \(docID)). \
            Pick the ONE column that is not a business segment but the adjustment / elimination / \
            corporate column (調整額, 消去, 全社, 消去又は全社, 本社費用, 全社費用 and similar) that \
            reconciles the segments to the consolidated amounts. If every column is a business \
            segment, choose none_of_these.
            """
        return JevDecisionRequest.json(
            model: model, question: SegmentMemberRoleJevPicker.question,
            instructions: instructions, candidates: presented, state: state)
    }
}
