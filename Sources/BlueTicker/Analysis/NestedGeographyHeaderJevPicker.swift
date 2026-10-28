// 入れ子の地域列見出しで、最下段の既知地域名が spanning として落ちるが兄弟列では
// 確定できないときだけ、親を残すか 親 / 子 にするかを Jev の閉じた Choice に聞く。
// 同じ親の下に異なる子が並ぶ列は `RevenueRecognitionCandidates` が決定論で修復する。
// 値は発明しない。3 回一致・0.9。失敗は親だけの見出しのまま needs_review。
// OpenRouter のクライアントは既存の DecisionsCompleting（新しい HTTP クライアントは作らない）。

import Foundation

protocol NestedGeographyHeaderDeciding: Sendable {
    func classifyNestedGeographyHeader(
        table: RevenueRecognitionCandidates.ParsedTable,
        header: RevenueRecognitionCandidates.UnresolvedNestedGeographyHeader,
        docID: String
    ) async -> JevChoiceAggregate.Sample
}

enum NestedGeographyHeaderJevPicker {
    static let question = "nested_geography_header"
    static let keepParentAndChild = "keep_parent_and_child"
    static let dropChildAsSpanning = "drop_child_as_spanning"
    static let optionKeys = [keepParentAndChild, dropChildAsSpanning]
    static let jevPolicy = JevDecisionPolicy(
        kind: .classify, question: question, noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)
    static let warningUnresolved = "jev_nested_geography_header_unresolved"

    struct ResolveResult: Equatable, Sendable {
        var tables: [RevenueRecognitionCandidates.ParsedTable]
        var needsReview: Bool
        var notes: [String]
        var audit: SegmentNoteJevAuditPayload?
    }

    static func resolve(
        tables: [RevenueRecognitionCandidates.ParsedTable],
        decider: any NestedGeographyHeaderDeciding,
        docID: String
    ) async -> ResolveResult {
        var next = tables
        var needsReview = false
        var notes: [String] = []
        var calls: [SegmentNoteJevCallPayload] = []
        var model = ""
        var applied = false
        for index in next.indices {
            let unresolved = next[index].unresolvedNestedGeographyHeaders
            guard !unresolved.isEmpty else { continue }
            let table = next[index]
            var remaining: [RevenueRecognitionCandidates.UnresolvedNestedGeographyHeader] = []
            for header in unresolved {
                let result = await JevDecisionSampler.decide(
                    policy: jevPolicy, options: optionKeys
                ) {
                    await decider.classifyNestedGeographyHeader(
                        table: table, header: header, docID: docID)
                }
                calls += result.calls
                if model.isEmpty { model = result.aggregate.model }
                let median = result.aggregate.probability.map { String(format: "%.2f", $0) } ?? "nil"
                if result.selectedKey == keepParentAndChild {
                    next[index].columnHeaders[header.column] =
                        RevenueRecognitionCandidates.nestedParentChildLabel(
                            parent: header.parent, child: header.child)
                    applied = true
                    notes.append(
                        "nested_header_jev=keep c\(header.column):\(header.parent)/\(header.child):\(median)")
                } else if result.selectedKey == dropChildAsSpanning {
                    notes.append(
                        "nested_header_jev=drop c\(header.column):\(header.parent)/\(header.child):\(median)")
                } else {
                    needsReview = true
                    remaining.append(header)
                    notes.append(
                        "nested_header_jev=fail_closed c\(header.column):\(header.parent)/\(header.child):\(median)")
                }
            }
            next[index].unresolvedNestedGeographyHeaders = remaining
        }
        let audit: SegmentNoteJevAuditPayload? = calls.isEmpty
            ? nil
            : SegmentNoteJevAuditPayload(
                code: "", docID: docID, axis: breakdownAxisGeography,
                model: model.isEmpty ? Api.openrouterDecisionsModel : model,
                threshold: jevPolicy.auditThreshold, applied: applied, needsReview: needsReview,
                sentences: notes, calls: calls,
                withheldReason: needsReview ? warningUnresolved : nil,
                decisionSource: applied ? "jev_nested_geography_header" : nil)
        return ResolveResult(
            tables: next, needsReview: needsReview, notes: notes, audit: audit)
    }
}

struct OpenRouterNestedGeographyHeaderDecider: NestedGeographyHeaderDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func classifyNestedGeographyHeader(
        table: RevenueRecognitionCandidates.ParsedTable,
        header: RevenueRecognitionCandidates.UnresolvedNestedGeographyHeader,
        docID: String
    ) async -> JevChoiceAggregate.Sample {
        let options = NestedGeographyHeaderJevPicker.optionKeys
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(
            model: model, table: table, header: header, docID: docID)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: NestedGeographyHeaderJevPicker.jevPolicy.transportRetries,
            onFailure: "NestedGeographyHeaderJevPicker: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[
            NestedGeographyHeaderJevPicker.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: options, model: model)
    }

    static func requestJSON(
        model: String,
        table: RevenueRecognitionCandidates.ParsedTable,
        header: RevenueRecognitionCandidates.UnresolvedNestedGeographyHeader,
        docID: String
    ) -> Data? {
        let candidates = [
            JevPresentedCandidate(
                key: NestedGeographyHeaderJevPicker.keepParentAndChild,
                criterion: """
                    The bottom header cell is a child region (or country) under the parent \
                    heading in the row above. Keep both as parent / child (e.g. 欧米 / 米国).
                    """),
            JevPresentedCandidate(
                key: NestedGeographyHeaderJevPicker.dropChildAsSpanning,
                criterion: """
                    The bottom header cell is a spanning geography header copied into this \
                    column (rowspan / colspan), not a child of the parent. Keep only the parent \
                    (or other non-spanning) label.
                    """),
        ]
        let siblingHeaders = table.columnHeaders.sorted(by: { $0.key < $1.key }).map {
            ["column": $0.key, "header": $0.value]
        }
        let state: [String: Any] = [
            "doc_id": docID,
            "target_column": header.column,
            "parent_label": header.parent,
            "child_label": header.child,
            "header_parts": header.parts,
            "sibling_headers": siblingHeaders,
            "table_markdown": BreakdownExtractor.gridToMarkdown(table.grid),
        ]
        let instructions = """
            The state is a geography (地域ごとの情報) sales table from a Japanese annual \
            securities report (有価証券報告書, doc \(docID)). joinHeaderParts dropped the \
            bottom-row geography label as if it were a spanning header, leaving only the \
            parent. Classify whether that bottom cell is a nested child under the parent \
            heading or a spanning header. Do not invent amounts or labels.
            """
        return JevDecisionRequest.json(
            model: model, question: NestedGeographyHeaderJevPicker.question,
            instructions: instructions, candidates: candidates, state: state)
    }
}
