// 設備投資マトリクスの欠損埋め。Jev は文の Role だけを返す。円はコードが換算する。
// SegmentNoteDecision の表 Choice / 省略 Choice には載せない。
// 埋めるのは会社全体の総額（Overview セル）と、タグ付きセグメント行があるときの
// reconciling だけ。セグメント別セルは埋めない。
// 文の切り出し・円換算・残り行の照合は BreakdownProseToolkit に置く。

import Foundation

typealias CapexProseRole = BreakdownProseRole
typealias CapexRemainderRole = BreakdownProseRemainderRole
typealias CapexExclusionRole = BreakdownProseExclusionRole
typealias CapexProseCandidate = BreakdownProseCandidate
typealias CapexProseChoice = BreakdownProseChoice
typealias CapexProseDeciding = BreakdownProseDeciding
typealias CapexProseTotal = BreakdownProseTotal
typealias CapexProseDecision = BreakdownProseDecision

enum CapexProseCell: Equatable, Sendable {
    case segmentAssets
    case flow
    case overview

    var farWarning: String {
        switch self {
        case .segmentAssets: return "segment_assets_segment_sum_far_from_total"
        case .flow: return "capital_expenditures_segment_sum_far_from_total"
        case .overview: return "capital_expenditures_overview_segment_sum_far_from_total"
        }
    }

    func farWarnings(flowMetric: String? = nil) -> [String] {
        switch self {
        case .segmentAssets:
            return [farWarning]
        case .flow:
            var names = [
                farWarning, "capex_flow_segment_sum_far_from_total",
                "noncurrent_asset_additions_segment_sum_far_from_total",
            ]
            if flowMetric == capexFlowMetricNoncurrentAssetAdditions {
                names.insert("noncurrent_asset_additions_segment_sum_far_from_total", at: 0)
            }
            return names
        case .overview:
            return [
                farWarning,
                "capital_expenditures_overview_subtotal_differs_from_segment_sum",
            ]
        }
    }
}

enum CapexProseTotalDecision {
    static let question = "capex_total"
    static let maxCandidates = BreakdownProseToolkit.maxCandidates
    static let maxSentenceLength = BreakdownProseToolkit.maxSentenceLength
    static let classifyPolicy = BreakdownProseToolkit.classifyPolicy(question: question)
    static let remainderPolicy = BreakdownProseToolkit.classifyPolicy(
        question: OpenRouterCapexProseDecider.remainderQuestion)
    static let exclusionPolicy = BreakdownProseToolkit.classifyPolicy(
        question: OpenRouterCapexProseDecider.exclusionQuestion)

    private static let overviewTextBlockTags = [
        "OverviewOfCapitalExpendituresEtcOwnUsedAssetsLEATextBlock",
        "OverviewOfCapitalExpendituresEtcTextBlock",
    ]

    private static let preferredPhrases = ["設備投資", "資本的支出", "固定資産"]

    static func overviewPlainText(in xbrlDir: URL) -> String? {
        for tag in overviewTextBlockTags {
            guard let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: tag) else {
                continue
            }
            let text = BreakdownProseToolkit.plainText(from: html)
            if !text.isEmpty { return text }
        }
        return nil
    }

    static func plainText(from html: String) -> String {
        BreakdownProseToolkit.plainText(from: html)
    }

    static func candidates(in text: String, limit: Int? = maxCandidates) -> [CapexProseCandidate] {
        BreakdownProseToolkit.candidates(
            in: text, preferredPhrases: preferredPhrases, limit: limit)
    }

    static func matchesShortfall(_ yen: Double, gap: Double) -> Bool {
        BreakdownProseToolkit.matchesShortfall(yen, gap: gap)
    }

    static func decide(
        plainText: String, code: String = "", docID: String = "",
        decider: any CapexProseDeciding
    ) async -> CapexProseDecision {
        await BreakdownProseToolkit.decideCompanyTotal(
            plainText: plainText, code: code, docID: docID, axis: breakdownAxisCapex,
            preferredPhrases: preferredPhrases, policy: classifyPolicy, decider: decider)
    }

    /// タグも表も無い Overview セルへ、当期総額 1 文を載せる。他セルは触らない。
    static func snapshotFromCompanyTotal(_ total: CapexProseTotal) -> BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisCapex, denominator: 0,
            denominatorTag: breakdownDenominatorTagCapexProse,
            rows: [], sourceKind: breakdownSourceCapexProse, needsReview: false,
            warnings: total.warnings, flowMetric: nil, segmentAssets: nil, flow: nil,
            capitalExpendituresOverview: CapexMetricTotalsPayload(
                denominator: total.yen, denominatorTag: breakdownDenominatorTagCapexProse))
    }

    static func applyCompanyTotal(
        to payload: BreakdownSnapshotPayload, total: CapexProseTotal
    ) -> BreakdownSnapshotPayload {
        guard payload.capitalExpendituresOverview == nil else { return payload }
        var filled = payload
        filled.capitalExpendituresOverview = CapexMetricTotalsPayload(
            denominator: total.yen, denominatorTag: breakdownDenominatorTagCapexProse)
        for warning in total.warnings where !filled.warnings.contains(warning) {
            filled.warnings.append(warning)
        }
        if filled.segmentAssets == nil, filled.flow == nil {
            filled.sourceKind = breakdownSourceCapexProse
            filled.denominatorTag = breakdownDenominatorTagCapexProse
        }
        return filled
    }

    static func shortfall(in payload: BreakdownSnapshotPayload, cell: CapexProseCell) -> Double? {
        guard let totals = totals(payload, cell: cell) else { return nil }
        return BreakdownProseToolkit.shortfall(
            denominator: totals.denominator, additive: additiveSum(payload, cell: cell))
    }

    static func excess(in payload: BreakdownSnapshotPayload, cell: CapexProseCell) -> Double? {
        guard let totals = totals(payload, cell: cell) else { return nil }
        return BreakdownProseToolkit.excess(
            denominator: totals.denominator, additive: additiveSum(payload, cell: cell))
    }

    static func fillShortfall(
        payload: BreakdownSnapshotPayload, cell: CapexProseCell, plainText: String,
        code: String = "", docID: String = "", decider: any CapexProseDeciding
    ) async -> (payload: BreakdownSnapshotPayload, audit: SegmentNoteJevAuditPayload?) {
        guard let gap = shortfall(in: payload, cell: cell) else { return (payload, nil) }
        let pool = candidates(in: plainText, limit: nil)
        guard let match = BreakdownProseToolkit.matchRemainderCandidate(
            pool: pool, gap: gap,
            matchesTaggedRow: { matchesTaggedRow($0, payload: payload, cell: cell) })
        else { return (payload, nil) }
        guard let result = await BreakdownProseToolkit.acceptedClassification(
            sentence: match.sentence, policy: remainderPolicy,
            optionKeys: CapexRemainderRole.optionKeys,
            appliedKey: CapexRemainderRole.unallocatedRemainder,
            classify: { await decider.classifyRemainder(sentence: match.sentence) })
        else { return (payload, nil) }
        let filled = payloadByAddingAdjustment(
            payload, cell: cell, yen: match.yen, label: remainderLabel(in: match.sentence),
            warning: breakdownWarningCapexProseRemainder)
        guard !cell.farWarnings(flowMetric: filled.flowMetric).contains(where: {
            filled.warnings.contains($0)
        }) else { return (payload, nil) }
        return (
            filled,
            BreakdownProseToolkit.appliedSentenceAudit(
                code: code, docID: docID, axis: breakdownAxisCapex,
                result: result, sentence: match.sentence, policy: remainderPolicy)
        )
    }

    static func fillExclusion(
        payload: BreakdownSnapshotPayload, cell: CapexProseCell, plainText: String,
        code: String = "", docID: String = "", decider: any CapexProseDeciding
    ) async -> (payload: BreakdownSnapshotPayload, audit: SegmentNoteJevAuditPayload?) {
        guard let over = excess(in: payload, cell: cell),
            let totals = totals(payload, cell: cell)
        else { return (payload, nil) }
        let matches = exclusionCandidates(
            in: plainText, total: totals.denominator, excess: over)
        guard matches.count == 1, let match = matches.first else { return (payload, nil) }
        guard let result = await BreakdownProseToolkit.acceptedClassification(
            sentence: match.sentence, policy: exclusionPolicy,
            optionKeys: CapexExclusionRole.optionKeys,
            appliedKey: CapexExclusionRole.excludedFromTotal,
            classify: { await decider.classifyExclusion(sentence: match.sentence) })
        else { return (payload, nil) }
        let filled = payloadByAddingAdjustment(
            payload, cell: cell, yen: -match.yen, label: exclusionLabel(in: match.sentence),
            warning: breakdownWarningCapexProseExclusion)
        guard !cell.farWarnings(flowMetric: filled.flowMetric).contains(where: {
            filled.warnings.contains($0)
        }) else { return (payload, nil) }
        return (
            filled,
            BreakdownProseToolkit.appliedSentenceAudit(
                code: code, docID: docID, axis: breakdownAxisCapex,
                result: result, sentence: match.sentence, policy: exclusionPolicy)
        )
    }

    static func mentionsNotAllocatableToSegments(_ text: String) -> Bool {
        BreakdownProseToolkit.mentionsNotAllocatableToSegments(text)
    }

    private static func exclusionCandidates(
        in text: String, total: Double, excess: Double
    ) -> [CapexProseCandidate] {
        BreakdownProseToolkit.exclusionCandidates(
            in: text, excess: excess,
            matchesTotal: { yen, _ in matchesShortfall(yen, gap: total) })
    }

    private static func remainderLabel(in sentence: String) -> String {
        BreakdownProseToolkit.remainderLabel(in: sentence, notAllocatableOverrides: true)
    }

    private static func exclusionLabel(in sentence: String) -> String {
        BreakdownProseToolkit.exclusionLabel(in: sentence, fallback: "総額に含まれない支出")
    }

    private static func payloadByAddingAdjustment(
        _ payload: BreakdownSnapshotPayload, cell: CapexProseCell, yen: Double, label: String,
        warning: String
    ) -> BreakdownSnapshotPayload {
        var filled = payload
        var row = BreakdownRowPayload(
            labelRaw: label, label: label, amount: 0, profit: nil, rowKind: "reconciling")
        switch cell {
        case .segmentAssets: row.segmentAssets = yen
        case .flow: row.flow = yen
        case .overview: row.capitalExpendituresOverview = yen
        }
        filled.rows.append(row)
        let denominator = totals(filled, cell: cell)?.denominator ?? 0
        let adjusted = BreakdownProseToolkit.adjustedWarnings(
            existing: filled.warnings,
            farWarningNames: cell.farWarnings(flowMetric: filled.flowMetric),
            primaryFarWarning: cell.farWarning,
            stillFar: BreakdownProseToolkit.stillFarFromTotal(
                denominator: denominator, additive: additiveSum(filled, cell: cell)),
            extraWarning: warning)
        filled.warnings = adjusted.warnings
        filled.needsReview = adjusted.needsReview
        return filled
    }

    private static func totals(
        _ payload: BreakdownSnapshotPayload, cell: CapexProseCell
    ) -> CapexMetricTotalsPayload? {
        switch cell {
        case .segmentAssets: return payload.segmentAssets
        case .flow: return payload.flow
        case .overview: return payload.capitalExpendituresOverview
        }
    }

    private static func cellAmount(_ row: BreakdownRowPayload, cell: CapexProseCell) -> Double? {
        switch cell {
        case .segmentAssets: return row.segmentAssets
        case .flow: return row.flow
        case .overview: return row.capitalExpendituresOverview
        }
    }

    private static func additiveSum(
        _ payload: BreakdownSnapshotPayload, cell: CapexProseCell
    ) -> Double {
        payload.rows
            .filter { BreakdownProseToolkit.isAdditiveRowKind($0.rowKind) }
            .compactMap { cellAmount($0, cell: cell) }
            .reduce(0, +)
    }

    private static func matchesTaggedRow(
        _ yen: Double, payload: BreakdownSnapshotPayload, cell: CapexProseCell
    ) -> Bool {
        BreakdownProseToolkit.matchesTaggedAmount(
            yen,
            amounts: payload.rows
                .filter { BreakdownProseToolkit.isAdditiveRowKind($0.rowKind) }
                .compactMap { cellAmount($0, cell: cell) })
    }
}

struct OpenRouterCapexProseDecider: CapexProseDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    static let remainderQuestion = "capex_remainder"
    static let exclusionQuestion = "capex_exclusion"

    func classify(sentence: String) async -> CapexProseChoice {
        await choice(
            question: CapexProseTotalDecision.question,
            body: Self.requestJSON(model: model, sentence: sentence), sentence: sentence)
    }

    func classifyRemainder(sentence: String) async -> CapexProseChoice {
        await choice(
            question: Self.remainderQuestion,
            body: Self.remainderRequestJSON(model: model, sentence: sentence), sentence: sentence)
    }

    func classifyExclusion(sentence: String) async -> CapexProseChoice {
        await choice(
            question: Self.exclusionQuestion,
            body: Self.exclusionRequestJSON(model: model, sentence: sentence), sentence: sentence)
    }

    private func choice(question: String, body: Data?, sentence: String) async -> CapexProseChoice {
        await BreakdownProseOpenRouter.choice(
            client: client, question: question, body: body, sentence: sentence,
            retries: CapexProseTotalDecision.classifyPolicy.transportRetries,
            onFailure: "CapexProseTotal: Jev呼び出し失敗")
    }

    static func requestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            CapexProseRole.currentCompanyTotal: """
                当期（当連結会計年度、当事業年度、当期）の会社全体の設備投資、資本的支出、 \
                または設備投資等の概要の総額を述べている。セグメントに配分できないので総額のみ、 \
                という説明が同じ文にあっても、総額ならこれ。
                """,
            CapexProseRole.priorPeriod: """
                前期、前連結会計年度、前事業年度の金額である。
                """,
            CapexProseRole.partialAmount: """
                一部のセグメント、事業所、地域、案件だけの金額である。会社全体の総額ではない。
                """,
            CapexProseRole.unrelated: """
                設備投資の総額ではない。従業員数、売上、研究開発費、割合だけ、注記番号への参照を含む。
                """,
        ]
        return BreakdownProseOpenRouter.requestJSON(
            model: model, question: CapexProseTotalDecision.question, sentence: sentence,
            instructions: "この文に出てくる金額は、当期の会社全体の設備投資の総額か。文の意味で一つ選ぶ。金額の数値は選ばない。",
            criteria: criteria)
    }

    static func remainderRequestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            CapexRemainderRole.unallocatedRemainder: """
                報告セグメントに配分されていない当期の設備投資、資本的支出、または資産の残りを述べている。 \
                全社、共通、本社、各セグメントに帰属しない金額がこれにあたる。会社全体の総額そのものではない。
                """,
            CapexRemainderRole.segmentAmount: """
                特定の報告セグメント、事業、地域だけの当期の金額である。
                """,
            CapexRemainderRole.priorPeriod: """
                前期、前連結会計年度、前事業年度の金額である。
                """,
            CapexRemainderRole.unrelated: """
                設備投資の残りではない。売上、従業員数、研究開発費、割合だけ、注記番号への参照を含む。
                """,
        ]
        return BreakdownProseOpenRouter.requestJSON(
            model: model, question: remainderQuestion, sentence: sentence,
            instructions: "この文の金額は、報告セグメントに配分されていない当期の設備投資の残りか。文の意味で一つ選ぶ。金額の数値は選ばない。",
            criteria: criteria)
    }

    static func exclusionRequestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            CapexExclusionRole.excludedFromTotal: """
                文が述べる設備投資の総額には含まれない、別の支出である。 \
                「このほか」と続く金額のように、総額の外で支出した金額がこれにあたる。
                """,
            CapexExclusionRole.includedInTotal: """
                その金額は、同じ文が述べる設備投資の総額に含まれる。
                """,
            CapexExclusionRole.priorPeriod: """
                前期、前連結会計年度、前事業年度の金額である。
                """,
            CapexExclusionRole.unrelated: """
                設備投資の総額の外の支出ではない。売上、従業員数、研究開発費、割合だけを含む。
                """,
        ]
        return BreakdownProseOpenRouter.requestJSON(
            model: model, question: exclusionQuestion, sentence: sentence,
            instructions: "設備投資の総額と一緒に出てくるもう一つの金額は、その総額の外の支出か。文の意味で一つ選ぶ。金額の数値は選ばない。",
            criteria: criteria)
    }
}
