// 収益分解表の金額なし行が「次の品目群の見出し」か「直前の品目の説明」かを Jev に判定させる。
// 対象は構造で決まらない行だけ（`RevenueRecognitionTableStructure.ambiguousHeadingRows`）。
// 括弧の種類や語では決めない。説明と判定した行は見出しにしない（値・ラベルは変えない）。
// キーが無い・合意できないときは従来どおり見出し。

import Foundation

protocol RevenueRecognitionRowRoleDeciding: Sendable {
    func classifyRow(
        grid: [[String]], row: Int, docID: String
    ) async -> JevChoiceAggregate.Sample
}

enum RevenueRecognitionRowRoleJev {
    static let question = "row_role"
    static let headingKey = "heading"
    static let descriptionKey = "description"
    /// 3 回一致に加えて中央値 0.75。実測（7416 4 書類・7532 S100Z42G）で説明は 0.78–0.99、
    /// 見出しは 0.92–1.0 と分かれる。説明にしても値・ラベルは変わらず group だけが変わる。
    static let confidenceThreshold = 0.75
    static let jevPolicy = JevDecisionPolicy(
        kind: .classify, question: question, noneOfTheseKey: nil,
        confidenceThreshold: confidenceThreshold,
        auditThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    /// Jev が説明と判定した行と、行ごとの判定の監査メモ（`r3:description:0.94` 等）。
    static func descriptionRows(
        grid: [[String]], decider: any RevenueRecognitionRowRoleDeciding, docID: String
    ) async -> (rows: Set<Int>, notes: [String]) {
        var out: Set<Int> = []
        var notes: [String] = []
        for row in RevenueRecognitionTableStructure.ambiguousHeadingRows(grid: grid) {
            let result = await JevDecisionSampler.decide(
                policy: jevPolicy, options: [headingKey, descriptionKey]
            ) {
                await decider.classifyRow(grid: grid, row: row, docID: docID)
            }
            if result.selectedKey == descriptionKey { out.insert(row) }
            let median = result.aggregate.probability.map { String(format: "%.2f", $0) } ?? "nil"
            notes.append("r\(row):\(result.selectedKey ?? "fail_closed"):\(median)")
        }
        return (out, notes)
    }
}

struct OpenRouterRevenueRecognitionRowRoleDecider: RevenueRecognitionRowRoleDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func classifyRow(grid: [[String]], row: Int, docID: String) async -> JevChoiceAggregate.Sample {
        let options = [RevenueRecognitionRowRoleJev.headingKey, RevenueRecognitionRowRoleJev.descriptionKey]
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(model: model, grid: grid, row: row, docID: docID)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: RevenueRecognitionRowRoleJev.jevPolicy.transportRetries,
            onFailure: "RevenueRecognitionRowRoleJev: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[
            RevenueRecognitionRowRoleJev.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: options, model: model)
    }

    static func requestJSON(model: String, grid: [[String]], row: Int, docID: String) -> Data? {
        let lines = grid.enumerated().map { index, cells in
            "r\(index): " + cells.map { $0.isEmpty ? "-" : $0 }.joined(separator: " | ")
        }
        let target = grid.indices.contains(row)
            ? grid[row].filter { !$0.isEmpty }.joined(separator: " ") : ""
        let candidates = [
            JevPresentedCandidate(
                key: RevenueRecognitionRowRoleJev.headingKey,
                criterion: "The row is a heading (group name) for the item rows that follow it."),
            JevPresentedCandidate(
                key: RevenueRecognitionRowRoleJev.descriptionKey,
                criterion: """
                    The row explains the item row directly above it (what that item includes); it is \
                    not a group of the rows below.
                    """),
        ]
        let state: [String: Any] = [
            "doc_id": docID,
            "table_rows": lines,
            "target_row": "r\(row)",
            "target_text": target,
        ]
        let instructions = """
            The state is a revenue-disaggregation table (収益の分解情報) from a Japanese annual \
            securities report (有価証券報告書, doc \(docID)), one line per table row (cells separated \
            by |, empty cells as -). The target row has no amount and sits between an item row with \
            an amount and another item row with an amount. Classify the target row.
            """
        return JevDecisionRequest.json(
            model: model, question: RevenueRecognitionRowRoleJev.question,
            instructions: instructions, candidates: candidates, state: state)
    }
}
