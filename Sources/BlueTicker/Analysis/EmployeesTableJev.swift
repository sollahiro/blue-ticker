// 従業員数の内訳: 合計だけタグの表（`EmployeesUntaggedRowFill.fromTotalOnlyTable`）の行が
// セグメント別か（部門別・製品区分別・会社別・地域別でないか）を Jev に判定させる。
// 見出しの語（「セグメント」等）では決めない。値と和の一致はコードが先に確かめている。

import Foundation

protocol EmployeesTableDeciding: Sendable {
    func classifyEmployeesTable(
        table: EmployeesUntaggedRowFill.TotalOnlyTable, segmentLabels: [String], docID: String
    ) async -> JevChoiceAggregate.Sample
}

enum EmployeesTableJev {
    static let question = "employees_table_breakdown"
    static let segmentsKey = "segments"
    static let otherKey = "other_breakdown"
    static let jevPolicy = JevDecisionPolicy(
        kind: .classify, question: question, noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    static func decide(
        table: EmployeesUntaggedRowFill.TotalOnlyTable, segmentLabels: [String],
        decider: any EmployeesTableDeciding, docID: String
    ) async -> JevDecisionResult {
        await JevDecisionSampler.decide(policy: jevPolicy, options: [segmentsKey, otherKey]) {
            await decider.classifyEmployeesTable(table: table, segmentLabels: segmentLabels, docID: docID)
        }
    }
}

struct OpenRouterEmployeesTableDecider: EmployeesTableDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func classifyEmployeesTable(
        table: EmployeesUntaggedRowFill.TotalOnlyTable, segmentLabels: [String], docID: String
    ) async -> JevChoiceAggregate.Sample {
        let options = [EmployeesTableJev.segmentsKey, EmployeesTableJev.otherKey]
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(
            model: model, table: table, segmentLabels: segmentLabels, docID: docID)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: EmployeesTableJev.jevPolicy.transportRetries,
            onFailure: "EmployeesTableJev: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[EmployeesTableJev.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: options, model: model)
    }

    static func requestJSON(
        model: String, table: EmployeesUntaggedRowFill.TotalOnlyTable,
        segmentLabels: [String], docID: String
    ) -> Data? {
        let candidates = [
            JevPresentedCandidate(
                key: EmployeesTableJev.segmentsKey,
                criterion: """
                    The rows are the company's business (operating / reportable) segments, possibly \
                    with a corporate / holding-company / shared-staff row (全社（共通）, 純粋持株会社等).
                    """),
            JevPresentedCandidate(
                key: EmployeesTableJev.otherKey,
                criterion: """
                    The rows are another breakdown: departments or functions (営業部門, 管理部門, 製造部門), \
                    product categories, group companies, or regions.
                    """),
        ]
        let state: [String: Any] = [
            "doc_id": docID,
            "label_column_header": table.header,
            "rows": table.rows.map { ["label": $0.label, "employees": $0.amount] },
            "segment_names_in_segment_note": segmentLabels,
        ]
        let instructions = """
            The state is the consolidated employee table (従業員の状況 / 連結会社の状況) of a Japanese \
            annual securities report (有価証券報告書, doc \(docID)). Only the total is XBRL-tagged; the \
            rows are untagged and already sum to the total. Classify what the rows break employees \
            down by. Segment names from the segment note, when present, are given for reference; a \
            single-segment company may still list 銀行業務 / その他事業 style segment rows.
            """
        return JevDecisionRequest.json(
            model: model, question: EmployeesTableJev.question,
            instructions: instructions, candidates: candidates, state: state)
    }
}
