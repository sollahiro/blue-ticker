// Summary `sga` の fail-closed Jev フォールバック。
// タグ一覧（標準 → 保険 → 業種合計 → IFRS 合算 → 1行）が nil のときだけ、連結 PL の
// 売上総利益と営業利益のあいだにある既存1行を選ばせる。値は発明しない。合算もしない。
// 採否は GP − OP ±1百万円、またはその他の収益・その他の費用で説明できるギャップ。
// 銀行・保険には使わない。失敗・不一致・低合意は sga = null のまま監査だけ残す。

import Foundation

enum SgaTagPolicy: Sendable {
    /// 標準 → 保険 → 業種合計 → IFRS 合算 → 1行。
    case all
    /// 業種合計と1行フォールバックを使わない。Jev 経路の golden 用。
    case omitIndustryAndSingleLine
}

struct SgaLineCandidate: Equatable, Sendable {
    var key: String
    var tag: String
    var label: String
    var value: Double
    var order: Int
}

struct SgaLineChoice: Equatable, Sendable {
    var selected: String?
    var probability: Double?
    var probabilities: [String: Double] = [:]
    var options: [String] = []
    var model: String = ""
}

protocol SgaLineDeciding: Sendable {
    func chooseSgaLine(
        rows: [SgaLineCandidate],
        grossProfit: SgaSpanAnchor,
        operatingProfit: SgaSpanAnchor,
        docID: String
    ) async -> SgaLineChoice
}

struct SgaSpanAnchor: Equatable, Sendable {
    var tag: String
    var label: String
    var value: Double
    var order: Int
}

enum SgaLineJevPicker {
    static let noneOfThese = "none_of_these"
    static let question = "sga_line"
    static let axis = "sga"
    static let residualToleranceYen = Financial.millionYen
    static let defaultSgaLabel = "販売費及び一般管理費"
    /// Consensus only; residual ±1百万円 is the deterministic gate. 0.9 is audit.
    static let jevPolicy = JevDecisionPolicy(
        question: question,
        noneOfTheseKey: noneOfThese,
        confidenceThreshold: nil,
        auditThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    struct Span: Sendable {
        var grossProfit: SgaSpanAnchor
        var operatingProfit: SgaSpanAnchor
        var between: [OrderedPLRow]
    }

    struct OrderedPLRow: Sendable {
        var item: StatementLineItem
        var order: Int
        var index: Int
    }

    struct PickResult: Sendable {
        var accepted: StatementLineItem?
        var audit: SegmentNoteJevAuditPayload
    }

    static func orderedRows(_ items: [StatementLineItem]) -> [OrderedPLRow] {
        items.enumerated().map { index, item in
            OrderedPLRow(item: item, order: item.order ?? index, index: index)
        }
        .sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.index < rhs.index
        }
    }

    /// GP と OP（無ければ経常利益）に挟まれた行。挟めなければ nil。
    static func span(pl: [StatementLineItem]) -> Span? {
        let rows = orderedRows(pl)
        guard let gp = rows.last(where: { isGrossProfit($0.item) }) else { return nil }
        let afterGP = rows.filter { $0.order > gp.order || ($0.order == gp.order && $0.index > gp.index) }
        let opRow = afterGP.first(where: { isOperatingProfit($0.item) })
            ?? afterGP.first(where: { isOrdinaryIncome($0.item) })
        guard let op = opRow else { return nil }
        let between = rows.filter { row in
            let afterGP = row.order > gp.order || (row.order == gp.order && row.index > gp.index)
            let beforeOP = row.order < op.order || (row.order == op.order && row.index < op.index)
            return afterGP && beforeOP
        }
        return Span(
            grossProfit: anchor(gp),
            operatingProfit: anchor(op),
            between: between)
    }

    static func candidates(in span: Span) -> [SgaLineCandidate] {
        span.between.enumerated().compactMap { index, row in
            guard otherIncomeOrExpenseKind(row.item) == nil else { return nil }
            return SgaLineCandidate(
                key: "r\(index)",
                tag: row.item.tag,
                label: disclosedLabel(for: row.item),
                value: row.item.value,
                order: row.order)
        }
    }

    /// 本表ラベルを優先し、空なら既知の業種別 sga_label、その次に標準タクソノミ。
    static func disclosedLabel(for item: StatementLineItem) -> String {
        let raw = (item.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, raw.contains(where: { !$0.isASCII }) { return raw }
        if let known = knownSgaLabels[item.tag] { return known }
        if let standard = XBRLUtils.loadStandardTaxonomyLabels()[item.tag], !standard.isEmpty {
            return standard
        }
        return raw.isEmpty ? item.tag : raw
    }

    /// 選んだ行を採るか。値は既存行そのもので、GP − OP ±1百万円、または
    /// その他の収益・その他の費用のネットでギャップが埋まるときだけ。
    static func accepts(value yen: Double, span: Span) -> Bool {
        let residual = span.grossProfit.value - span.operatingProfit.value
        if abs(yen - residual) <= residualToleranceYen { return true }
        let otherNet = span.between.reduce(0.0) { sum, row in
            switch otherIncomeOrExpenseKind(row.item) {
            case .income: return sum - row.item.value
            case .expense: return sum + row.item.value
            case nil: return sum
            }
        }
        return abs(yen + otherNet - residual) <= residualToleranceYen
    }

    static func publishedSgaLabel(_ disclosed: String?) -> String? {
        var text = disclosed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasSuffix("合計") {
            text = String(text.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty || text == defaultSgaLabel { return nil }
        return text
    }

    static func applyIfNeeded(
        to values: inout StatementFinancialsValues,
        incomeStatement: [StatementLineItem],
        skip: Bool,
        decider: (any SgaLineDeciding)?,
        docID: String
    ) async {
        guard !skip, values.sga == nil, let decider else { return }
        let result = await pick(
            pl: incomeStatement,
            decider: decider,
            docID: docID)
        values.sgaJevAudit = result.audit
        if let accepted = result.accepted {
            values.sga = accepted.value
            values.sgaLabel = publishedSgaLabel(accepted.label)
        }
    }

    static func pick(
        pl: [StatementLineItem],
        decider: any SgaLineDeciding,
        docID: String
    ) async -> PickResult {
        guard let span = span(pl: pl) else {
            return PickResult(
                accepted: nil,
                audit: audit(
                    docID: docID, model: "", applied: false,
                    sentences: ["sga_jev=no_gp_op_span"],
                    calls: []))
        }
        let rows = candidates(in: span)
        let options = rows.map(\.key) + [noneOfThese]
        guard !rows.isEmpty else {
            return PickResult(
                accepted: nil,
                audit: audit(
                    docID: docID, model: "", applied: false,
                    sentences: ["sga_jev=no_candidate_rows"],
                    calls: []))
        }

        let samples = await JevDecisionSampler.collect(count: jevPolicy.sampling.sampleCount) {
            await decider.chooseSgaLine(
                rows: rows, grossProfit: span.grossProfit,
                operatingProfit: span.operatingProfit, docID: docID)
        }
        let aggregate = JevChoiceAggregate.combine(samples.map {
            JevChoiceAggregate.Sample(
                selected: $0.selected, probability: $0.probability,
                probabilities: $0.probabilities, options: $0.options, model: $0.model)
        })
        let calls = JevDecision.auditCalls(
            question: question, samples: samples.map {
                JevChoiceAggregate.Sample(
                    selected: $0.selected, probability: $0.probability,
                    probabilities: $0.probabilities, options: $0.options, model: $0.model)
            }, options: options)

        var sentences = [
            "sga_jev_samples=\(samples.count) \(aggregate.outcome.rawValue) successful=\(aggregate.successfulCount)",
        ]
        guard aggregate.isConfident, let selected = aggregate.selected, selected != noneOfThese else {
            sentences.append("sga_jev=fail_closed")
            return PickResult(
                accepted: nil,
                audit: audit(
                    docID: docID, model: aggregate.model, applied: false,
                    sentences: sentences, calls: calls))
        }
        guard let candidate = rows.first(where: { $0.key == selected }) else {
            sentences.append("sga_jev=selected_not_in_candidates")
            return PickResult(
                accepted: nil,
                audit: audit(
                    docID: docID, model: aggregate.model, applied: false,
                    sentences: sentences, calls: calls))
        }
        guard accepts(value: candidate.value, span: span) else {
            sentences.append("sga_jev=residual_mismatch")
            return PickResult(
                accepted: nil,
                audit: audit(
                    docID: docID, model: aggregate.model, applied: false,
                    sentences: sentences, calls: calls))
        }
        sentences.append("sga_jev=accepted tag=\(candidate.tag)")
        let accepted = StatementLineItem(
            tag: candidate.tag, label: candidate.label, value: candidate.value,
            unit: nil, order: candidate.order)
        var payload = audit(
            docID: docID, model: aggregate.model, applied: true,
            sentences: sentences, calls: calls)
        for index in payload.calls.indices {
            payload.calls[index].applied = payload.calls[index].selected == selected
        }
        return PickResult(accepted: accepted, audit: payload)
    }

    private static func audit(
        docID: String, model: String, applied: Bool, sentences: [String],
        calls: [SegmentNoteJevCallPayload]
    ) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: axis,
            model: model.isEmpty ? Api.openrouterDecisionsModel : model,
            threshold: jevPolicy.auditThreshold,
            applied: applied, needsReview: !applied, sentences: sentences,
            calls: calls, withheldReason: applied ? nil : (sentences.last ?? "sga_jev=fail_closed"),
            decisionSource: applied ? "jev_sga_line" : nil)
    }

    private static func anchor(_ row: OrderedPLRow) -> SgaSpanAnchor {
        SgaSpanAnchor(
            tag: row.item.tag,
            label: row.item.label ?? row.item.tag,
            value: row.item.value,
            order: row.order)
    }

    private static func isGrossProfit(_ item: StatementLineItem) -> Bool {
        if gpTags.contains(item.tag) { return true }
        let label = item.label ?? ""
        return label.contains("売上総利益") || label.contains("営業総利益")
            || label.contains("業務粗利益")
    }

    private static func isOperatingProfit(_ item: StatementLineItem) -> Bool {
        if opTags.contains(item.tag) { return true }
        let label = item.label ?? ""
        return label.contains("営業利益") && !label.contains("調整") && !label.contains("前")
    }

    private static func isOrdinaryIncome(_ item: StatementLineItem) -> Bool {
        if Xbrl.ordinaryIncomeTags.contains(item.tag) { return true }
        let label = item.label ?? ""
        return label.contains("経常利益")
    }

    private enum OtherKind {
        case income
        case expense
    }

    private static func otherIncomeOrExpenseKind(_ item: StatementLineItem) -> OtherKind? {
        let label = item.label ?? ""
        if label.contains("包括利益") { return nil }
        if label.contains("その他の収益") || label.contains("その他収益") {
            return .income
        }
        if label.contains("その他の費用") || label.contains("その他費用") {
            return .expense
        }
        let tag = item.tag
        if tag.contains("OtherOperatingIncome") || tag.hasSuffix("OtherIncomeIFRS")
            || tag == "OtherIncomeIFRS"
        {
            return .income
        }
        if tag.contains("OtherOperatingExpenses") || tag.hasSuffix("OtherExpensesIFRS")
            || tag == "OtherExpensesIFRS"
        {
            return .expense
        }
        return nil
    }

    private static let gpTags = Set(Xbrl.grossProfitDirectTags + Xbrl.operatingGrossProfitDirectTags)
    private static let opTags = Set(Xbrl.operatingProfitDirectTags)

    private static let knownSgaLabels: [String: String] = {
        var map: [String: String] = [:]
        for (tag, label) in Xbrl.sgaIndustryTotalTags {
            map[tag] = label ?? defaultSgaLabel
        }
        for (tag, label, _) in Xbrl.sgaSingleLineFallbackTags {
            map[tag] = label
        }
        return map
    }()
}

struct OpenRouterSgaLineDecider: SgaLineDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func chooseSgaLine(
        rows: [SgaLineCandidate],
        grossProfit: SgaSpanAnchor,
        operatingProfit: SgaSpanAnchor,
        docID: String
    ) async -> SgaLineChoice {
        let options = rows.map(\.key) + [SgaLineJevPicker.noneOfThese]
        let unavailable = SgaLineChoice(selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(
            model: model, rows: rows, grossProfit: grossProfit,
            operatingProfit: operatingProfit, docID: docID)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: SgaLineJevPicker.jevPolicy.transportRetries,
            onFailure: "SgaLineJevPicker: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[
            SgaLineJevPicker.question]?.choice
        else { return unavailable }
        return SgaLineChoice(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities,
            options: options,
            model: model)
    }

    static func requestJSON(
        model: String,
        rows: [SgaLineCandidate],
        grossProfit: SgaSpanAnchor,
        operatingProfit: SgaSpanAnchor,
        docID: String
    ) -> Data? {
        var candidates: [JevPresentedCandidate] = rows.map { row in
            let million = row.value / Financial.millionYen
            return JevPresentedCandidate(
                key: row.key,
                criterion: """
                    label=\(row.label); tag=\(row.tag); value_million_yen=\(million); order=\(row.order)
                    """)
        }
        candidates.append(JevPresentedCandidate(
            key: SgaLineJevPicker.noneOfThese,
            criterion: """
                No existing row in this span is the company's SG&A line. Use this when the span \
                has no 販売費及び一般管理費 alias (供給販売費及び一般管理費 / 一般管理費 / 営業費用 / 事業費用 etc.).
                """))
        let state: [String: Any] = [
            "doc_id": docID,
            "gross_profit": [
                "tag": grossProfit.tag,
                "label": grossProfit.label,
                "value_million_yen": grossProfit.value / Financial.millionYen,
                "order": grossProfit.order,
            ],
            "operating_profit": [
                "tag": operatingProfit.tag,
                "label": operatingProfit.label,
                "value_million_yen": operatingProfit.value / Financial.millionYen,
                "order": operatingProfit.order,
            ],
            "rows": rows.map { row -> [String: Any] in
                [
                    "key": row.key,
                    "tag": row.tag,
                    "label": row.label,
                    "value_million_yen": row.value / Financial.millionYen,
                    "order": row.order,
                ]
            },
        ]
        let instructions = """
            The state lists consolidated profit-and-loss rows that sit strictly between gross \
            profit (売上総利益 / 営業総利益 / 業務粗利益) and operating profit (営業利益; 経常利益 \
            only when no operating-profit row exists) of a Japanese annual securities report \
            (有価証券報告書, doc \(docID)). Pick the ONE existing row that is the company's SG&A \
            line — 販売費及び一般管理費 or the industry alias that plays that role \
            (供給販売費及び一般管理費, 一般管理費, 営業費用, 事業費用, and similar). \
            Do not add amounts. Do not invent a residual. Do not pick 売上原価, その他の収益, \
            その他の費用, or the profit rows themselves. If no such line exists, choose none_of_these.
            """
        return JevDecisionRequest.json(
            model: model, question: SgaLineJevPicker.question,
            instructions: instructions, candidates: candidates, state: state)
    }
}
