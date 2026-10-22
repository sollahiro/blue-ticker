// 関係会社の状況: 区分の目印（表内の区分見出し・名称の頭の区分・表の外の見出し）が無い表だけ、
// 表の行の区分（親会社 / 連結子会社 / 持分法適用関連会社等 / その他の関係会社）を Jev の選択式で決める。
// 表ごとに 1 回（3 回一致・確率 0.9 以上）。採用した行は `decided_by = jev`。未採用は `needs_review` のまま
// （公開しない）。名前解決（銘柄コード）には使わない。

import Foundation

protocol RelationKindDeciding: Sendable {
    func classifyGroupTable(
        table: CompanyRelationsExtractor.PendingGroupTable, docID: String
    ) async -> JevChoiceAggregate.Sample
}

enum RelationKindJev {
    static let question = "affiliated_entities_table_kind"
    static let jevPolicy = JevDecisionPolicy(
        kind: .select, question: question,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    /// 区分の決まらない表を Jev に聞き、採用できた行だけ区分を付ける。キーが無いときは何もしない。
    static func apply(
        _ result: CompanyRelationsExtractor.Result, decider: (any RelationKindDeciding)?, docID: String
    ) async -> CompanyRelationsExtraction {
        var extraction = result.extraction
        guard let decider else { return extraction }
        for table in result.pendingGroupTables {
            let decision = await JevDecisionSampler.decide(
                policy: jevPolicy, options: relationGroupKinds
            ) {
                await decider.classifyGroupTable(table: table, docID: docID)
            }
            guard let kind = decision.selectedKey, relationGroupKinds.contains(kind) else {
                printError(
                    "RelationKindJev \(docID): 区分を採用しません（\(decision.warnings.joined(separator: ","))）\n")
                continue
            }
            for index in table.rowIndices where extraction.rows.indices.contains(index) {
                extraction.rows[index].kind = kind
                extraction.rows[index].decidedBy = relationDecidedByJev
                extraction.rows[index].needsReview = false
            }
        }
        return extraction
    }
}

struct OpenRouterRelationKindDecider: RelationKindDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func classifyGroupTable(
        table: CompanyRelationsExtractor.PendingGroupTable, docID: String
    ) async -> JevChoiceAggregate.Sample {
        let options = relationGroupKinds
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(model: model, table: table, docID: docID) else {
            return unavailable
        }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body, retries: RelationKindJev.jevPolicy.transportRetries,
            onFailure: "RelationKindJev: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[RelationKindJev.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: options, model: model)
    }

    /// 1 表あたりの行・本文の上限（入力を小さく保つ）。
    static let maxRows = 40
    static let maxTextChars = 1500

    static func requestJSON(
        model: String, table: CompanyRelationsExtractor.PendingGroupTable, docID: String
    ) -> Data? {
        let candidates = [
            JevPresentedCandidate(
                key: relationKindParent,
                criterion: "The rows are the filer's parent company (親会社): a company that controls the filer and holds its voting rights (議決権の被所有)."),
            JevPresentedCandidate(
                key: relationKindSubsidiary,
                criterion: "The rows are the filer's consolidated subsidiaries (連結子会社)."),
            JevPresentedCandidate(
                key: relationKindAffiliate,
                criterion: "The rows are equity-method affiliates or equity-method / unconsolidated subsidiaries (持分法適用関連会社・持分法適用非連結子会社・関連会社)."),
            JevPresentedCandidate(
                key: relationKindOtherRelated,
                criterion: "The rows are other related companies (その他の関係会社): companies that hold the filer's voting rights as a significant shareholder but are not its parent."),
        ]
        let rows = table.rows.prefix(maxRows).map { cells in
            Dictionary(uniqueKeysWithValues: zip(
                table.header.indices.map { index in
                    table.header[index].isEmpty ? "column_\(index)" : "\(index):\(table.header[index])"
                },
                cells))
        }
        let state: [String: Any] = [
            "doc_id": docID,
            "header": table.header,
            "rows": rows,
            "row_count": table.rows.count,
            "text_before_table": String(table.precedingText.suffix(maxTextChars)),
            "text_after_table": String(table.followingText.prefix(maxTextChars)),
        ]
        let instructions = """
            The state is one table from 関係会社の状況 (overview of affiliated entities) in a Japanese \
            annual securities report (有価証券報告書, doc \(docID)). The table has no category heading \
            such as (連結子会社) / (持分法適用関連会社) / (親会社) / (その他の関係会社). Decide which single \
            category all rows of this table belong to, using the column headers (議決権の所有割合 vs \
            被所有割合), the voting-right percentages, the relationship column, and the surrounding text \
            and notes. Choose none_of_these when the rows mix categories or the table is not a list of \
            affiliated companies.
            """
        return JevDecisionRequest.json(
            model: model, question: RelationKindJev.question, instructions: instructions,
            candidates: candidates, state: state)
    }
}
