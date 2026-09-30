// セグメント注記（business / geography の省略）だけを Jev に判定させる。
// コードが候補の文と表を切り出す。Jev は Choice だけを返す。
// `OPENROUTER_DECISION_API_KEY` が無いときは呼ばない（今日の決定論のまま）。
// 研究開発費・設備投資・減損は対象外。公開 reason は既存の文字列だけを使う。

import Foundation

enum SegmentNoteAxis: Sendable {
    case business
    case geography

    var wire: String {
        switch self {
        case .business: return "business"
        case .geography: return "geography"
        }
    }
}

enum SegmentNoteAction: Equatable, Sendable {
    case unchanged
    case omitBusiness
    case omitGeography
    case keepTable(Int)
}

struct SegmentNoteTableCandidate: Equatable, Sendable {
    var index: Int
    var heading: String
    var period: String?
    var markdown: String
}

enum SegmentNoteTableSelection: Equatable, Sendable {
    case table(Int)
    case noneOfThese
    case unavailable

    var choiceKey: String? {
        switch self {
        case .table(let index): return "\(index)"
        case .noneOfThese: return OpenRouterSegmentNoteDecider.noneOfThese
        case .unavailable: return nil
        }
    }
}

/// Jev が返した Choice 一つ。`selected == nil` は応答が無い（今日の分類に戻す）。
struct SegmentNoteConsultedChoice: Equatable, Sendable {
    var question: String
    var selected: String?
    var probability: Double?
    var options: [String]
    var sentences: [String]
}

enum SegmentNoteOmission: Equatable, Sendable {
    case singleSegment
    case productOrServiceExternalSalesOver90
    case domesticExternalSalesOver90
    case none
    case unavailable

    var choiceKey: String? {
        switch self {
        case .singleSegment: return "single_segment"
        case .productOrServiceExternalSalesOver90: return "product_or_service_external_sales_over_90"
        case .domesticExternalSalesOver90: return "domestic_external_sales_over_90"
        case .none: return "none"
        case .unavailable: return nil
        }
    }

    static func fromChoiceKey(_ key: String) -> SegmentNoteOmission {
        switch key {
        case "single_segment": return .singleSegment
        case "product_or_service_external_sales_over_90": return .productOrServiceExternalSalesOver90
        case "domestic_external_sales_over_90": return .domesticExternalSalesOver90
        case "none": return .none
        default: return .unavailable
        }
    }
}

protocol SegmentNoteDeciding: Sendable {
    func selectBreakdownTable(
        tables: [SegmentNoteTableCandidate], sentences: [String]
    ) async -> SegmentNoteConsultedChoice

    func classifyOmission(sentence: String) async -> SegmentNoteConsultedChoice
}

struct SegmentNoteDecisionOutcome: Equatable, Sendable {
    var action: SegmentNoteAction
    /// 確率不足・欠測・解釈不能・文クラスの衝突、または省略理由の根拠が無い。決定論の結果は変えない。
    var needsReview: Bool
    var audit: SegmentNoteJevAuditPayload?
    /// business の省略を適用したときの公開 reason。`single_segment_disclosed` か `geography_only`。
    var omissionReason: String?
    var appliedOmission: SegmentNoteOmission?

    static let unchanged = SegmentNoteDecisionOutcome(
        action: .unchanged, needsReview: false, audit: nil, omissionReason: nil, appliedOmission: nil)
}

enum SegmentNoteDecision {
    /// 製品90％だが、単一セグメントの根拠も地域報告セグメントも無い。公開 reason にはしない。
    static let withheldProductOmissionReason =
        "product_or_service_over_90_without_single_segment_or_geography_evidence"

    /// 選ばれた選択肢の `probabilities[choice]` がこれ以上のときだけ表の採用か省略を適用する。
    /// `confidence` では代用しない。校正値は PR 本文。誤った省略より needs_review を残す。
    static let applyProbabilityThreshold: Double = 0.9

    /// 表が分析すべき当期の内訳か。違い、かつ省略の種類が軸に合い、確率が閾値以上で、
    /// 文の種類が食い違わないときだけ今日の経路を変える。
    /// 決定論で既に business / geography が確定しているときは呼ばない前提で、
    /// `hasCleanDeterministicSnapshot` が true ならネットワークに行かない。
    static func decide(
        axis: SegmentNoteAxis,
        code: String = "",
        docID: String = "",
        tables: [BreakdownTable],
        sentences: [String],
        hasCleanDeterministicSnapshot: Bool,
        decider: any SegmentNoteDeciding
    ) async -> SegmentNoteDecisionOutcome {
        guard !hasCleanDeterministicSnapshot, !tables.isEmpty, !sentences.isEmpty else {
            return .unchanged
        }
        let candidates = tables.enumerated().map { index, table in
            SegmentNoteTableCandidate(
                index: index, heading: table.heading, period: table.period, markdown: table.markdown)
        }
        let tableChoice = await decider.selectBreakdownTable(tables: candidates, sentences: sentences)
        guard tableChoice.selected != nil else { return .unchanged }

        if tableChoice.selected == OpenRouterSegmentNoteDecider.noneOfThese {
            guard meetsThreshold(tableChoice.probability) else {
                return finish(
                    axis: axis, code: code, docID: docID, sentences: sentences,
                    action: .unchanged, needsReview: true,
                    calls: [call(tableChoice, sentences: sentences, applied: false)])
            }
            return await classifySentences(
                axis: axis, code: code, docID: docID, sentences: sentences,
                tableChoice: tableChoice, decider: decider)
        }
        if let selected = tableChoice.selected, let index = Int(selected), tables.indices.contains(index) {
            let apply = meetsThreshold(tableChoice.probability)
            return finish(
                axis: axis, code: code, docID: docID, sentences: sentences,
                action: apply ? .keepTable(index) : .unchanged, needsReview: !apply,
                calls: [call(tableChoice, sentences: sentences, applied: apply)])
        }
        return finish(
            axis: axis, code: code, docID: docID, sentences: sentences,
            action: .unchanged, needsReview: true,
            calls: [call(tableChoice, sentences: sentences, applied: false)])
    }

    private static func classifySentences(
        axis: SegmentNoteAxis, code: String, docID: String, sentences: [String],
        tableChoice: SegmentNoteConsultedChoice, decider: any SegmentNoteDeciding
    ) async -> SegmentNoteDecisionOutcome {
        struct Record {
            var choice: SegmentNoteConsultedChoice
            var omission: SegmentNoteOmission?
            var unparsable: Bool
            var sentence: String
        }
        var records: [Record] = []
        for sentence in sentences {
            let choice = await decider.classifyOmission(sentence: sentence)
            if choice.selected == nil {
                records.append(Record(choice: choice, omission: nil, unparsable: false, sentence: sentence))
                continue
            }
            let parsed = SegmentNoteOmission.fromChoiceKey(choice.selected ?? "")
            if parsed == .unavailable {
                records.append(Record(choice: choice, omission: nil, unparsable: true, sentence: sentence))
            } else {
                records.append(Record(choice: choice, omission: parsed, unparsable: false, sentence: sentence))
            }
        }

        let parsed = records.compactMap(\.omission)
        let classes = Set(parsed.compactMap(positiveClass))
        let conflict = classes.count > 1
        let weak = records.contains { record in
            record.omission != nil && !meetsThreshold(record.choice.probability)
        }
        let sawUnparsable = records.contains { $0.unparsable }
        let sawTransportGap = records.contains { $0.choice.selected == nil }
        let needsReview = parsed.isEmpty
            ? sawUnparsable
            : (weak || conflict || sawUnparsable || sawTransportGap)
        let agreed = classes.count == 1 ? classes.first : nil
        let canOmit = !needsReview && agreed.map { omissionMatches(axis: axis, $0) } == true
        var calls = [call(tableChoice, sentences: sentences, applied: canOmit)]
        for record in records {
            let applied = canOmit && record.omission.map { omissionMatches(axis: axis, $0) } == true
            calls.append(call(record.choice, sentences: [record.sentence], applied: applied))
        }
        let action: SegmentNoteAction
        if canOmit {
            switch axis {
            case .business: action = .omitBusiness
            case .geography: action = .omitGeography
            }
        } else {
            action = .unchanged
        }
        return finish(
            axis: axis, code: code, docID: docID, sentences: sentences,
            action: action, needsReview: needsReview, calls: calls,
            appliedOmission: canOmit ? agreed : nil)
    }

    /// business の省略を公開 reason に写す。単一セグメントの根拠が先。
    /// 製品90％で報告セグメントが地域だけのときは `geography_only`。
    /// どちらも無ければ省略しない。
    static func resolveBusinessOmissionReason(
        _ outcome: SegmentNoteDecisionOutcome,
        hasDedicatedSingleSegmentTag: Bool,
        reportedSegmentsAreGeographic: Bool
    ) -> SegmentNoteDecisionOutcome {
        guard outcome.action == .omitBusiness else { return outcome }
        let singleSegmentEvidence = outcome.appliedOmission == .singleSegment || hasDedicatedSingleSegmentTag
        if singleSegmentEvidence {
            var copy = outcome
            copy.omissionReason = breakdownNotApplicableSingleSegmentDisclosed
            return copy
        }
        if outcome.appliedOmission == .productOrServiceExternalSalesOver90, reportedSegmentsAreGeographic {
            var copy = outcome
            copy.omissionReason = breakdownNotApplicableGeographyOnly
            return copy
        }
        var copy = outcome
        copy.action = .unchanged
        copy.needsReview = true
        copy.omissionReason = nil
        if var audit = copy.audit {
            audit.applied = false
            audit.needsReview = true
            audit.withheldReason = withheldProductOmissionReason
            audit.calls = audit.calls.map { call in
                var call = call
                call.applied = false
                return call
            }
            copy.audit = audit
        }
        return copy
    }

    private static func positiveClass(_ omission: SegmentNoteOmission) -> SegmentNoteOmission? {
        switch omission {
        case .singleSegment, .productOrServiceExternalSalesOver90, .domesticExternalSalesOver90:
            return omission
        case .none, .unavailable:
            return nil
        }
    }

    private static func omissionMatches(axis: SegmentNoteAxis, _ omission: SegmentNoteOmission) -> Bool {
        switch axis {
        case .business:
            return omission == .singleSegment || omission == .productOrServiceExternalSalesOver90
        case .geography:
            return omission == .domesticExternalSalesOver90
        }
    }

    /// 選ばれたキーの確率だけを見る。欠ける、有限でない、0...1 の外は適用しない。
    static func meetsThreshold(_ probability: Double?) -> Bool {
        guard let probability, probability.isFinite, (0.0...1.0).contains(probability) else { return false }
        return probability >= applyProbabilityThreshold
    }

    private static func call(
        _ choice: SegmentNoteConsultedChoice, sentences: [String], applied: Bool
    ) -> SegmentNoteJevCallPayload {
        SegmentNoteJevCallPayload(
            question: choice.question, options: choice.options, selected: choice.selected,
            probability: choice.probability, sentences: sentences, applied: applied)
    }

    private static func finish(
        axis: SegmentNoteAxis, code: String, docID: String, sentences: [String],
        action: SegmentNoteAction, needsReview: Bool, calls: [SegmentNoteJevCallPayload],
        appliedOmission: SegmentNoteOmission? = nil
    ) -> SegmentNoteDecisionOutcome {
        let audit = SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: axis.wire, model: Api.openrouterDecisionsModel,
            threshold: applyProbabilityThreshold, applied: action != .unchanged,
            needsReview: needsReview, sentences: sentences, calls: calls)
        return SegmentNoteDecisionOutcome(
            action: action, needsReview: needsReview, audit: audit, omissionReason: nil,
            appliedOmission: appliedOmission)
    }
}

/// Decisions API へセグメント注記の Choice を出す。失敗時は `.unavailable`（今日の分類に戻す）。
struct OpenRouterSegmentNoteDecider: SegmentNoteDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    static let breakdownTableQuestion = "breakdown_table"
    static let omissionQuestion = "omission"
    static let noneOfThese = "none_of_these"
    static let omissionOptionKeys = [
        "single_segment",
        "product_or_service_external_sales_over_90",
        "domestic_external_sales_over_90",
        "none",
    ]
    private static let markdownLimit = 4_000

    func selectBreakdownTable(
        tables: [SegmentNoteTableCandidate], sentences: [String]
    ) async -> SegmentNoteConsultedChoice {
        let options = tables.map { "\($0.index)" } + [Self.noneOfThese]
        let unavailable = SegmentNoteConsultedChoice(
            question: Self.breakdownTableQuestion, selected: nil, probability: nil,
            options: options, sentences: sentences)
        guard let body = Self.tableRequestJSON(model: model, tables: tables, sentences: sentences) else {
            return unavailable
        }
        do {
            let data = try await client.decide(requestJSON: body)
            return Self.consultedChoice(
                from: data, question: Self.breakdownTableQuestion, options: options, sentences: sentences)
        } catch {
            return unavailable
        }
    }

    func classifyOmission(sentence: String) async -> SegmentNoteConsultedChoice {
        let unavailable = SegmentNoteConsultedChoice(
            question: Self.omissionQuestion, selected: nil, probability: nil,
            options: Self.omissionOptionKeys, sentences: [sentence])
        guard let body = Self.omissionRequestJSON(model: model, sentence: sentence) else {
            return unavailable
        }
        do {
            let data = try await client.decide(requestJSON: body)
            return Self.consultedChoice(
                from: data, question: Self.omissionQuestion, options: Self.omissionOptionKeys,
                sentences: [sentence])
        } catch {
            return unavailable
        }
    }

    static func tableRequestJSON(
        model: String, tables: [SegmentNoteTableCandidate], sentences: [String]
    ) -> Data? {
        var criteria: [String: String] = [
            noneOfThese: """
                どれも分析すべき当期のセグメント内訳ではない。関連情報の表（主要な顧客など）は \
                セグメント内訳ではない。当期の注記が記載を省略していて、残っているのが前期の表だけのときも、 \
                その前期表は分析しない。
                """,
        ]
        var tableState: [[String: String]] = []
        for table in tables {
            let period = table.period ?? "不明"
            criteria["\(table.index)"] = """
                表\(table.index)（期間: \(period)、見出し: \(table.heading)）が、分析すべき当期の \
                セグメント内訳である。報告セグメント別、地域別の外部売上、または製品・サービス別の当期の表が \
                これにあたる。単一セグメントの省略文が別にあっても、当期の内訳表ならこの表を選ぶ。
                """
            tableState.append([
                "index": "\(table.index)",
                "period": period,
                "heading": table.heading,
                "markdown": String(table.markdown.prefix(markdownLimit)),
            ])
        }
        let questions: [String: Any] = [
            breakdownTableQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "抽出された表のうち、分析すべき当期のセグメント内訳はどれか。無ければ none_of_these。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model,
            state: ["sentences": sentences, "tables": tableState],
            questions: questions)
    }

    static func omissionRequestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            "single_segment": """
                単一セグメントであるため、セグメント情報の記載を省略している。 \
                例: 当社グループは、コミュニケーション・プラットフォーム関連事業の単一セグメントであるため、記載を省略しております。
                """,
            "product_or_service_external_sales_over_90": """
                単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略している。
                """,
            "domestic_external_sales_over_90": """
                本邦の外部顧客への売上高が、連結損益計算書または連結損益及び包括利益計算書の売上高の90％を超えるため、記載を省略している。
                """,
            "none": """
                上のどれでもない。報告セグメントと同一のため、または同様の情報を開示しているための記載省略を含む。
                """,
        ]
        let questions: [String: Any] = [
            omissionQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "この文は、セグメント注記のどの記載省略か。文の意味で一つ選ぶ。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model,
            state: ["sentence": sentence],
            questions: questions)
    }

    static func consultedChoice(
        from data: Data, question: String, options: [String], sentences: [String]
    ) -> SegmentNoteConsultedChoice {
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[question]?.choice else {
            return SegmentNoteConsultedChoice(
                question: question, selected: nil, probability: nil, options: options, sentences: sentences)
        }
        return SegmentNoteConsultedChoice(
            question: question, selected: choice.selected,
            probability: selectedProbability(selected: choice.selected, probabilities: choice.probabilities),
            options: options, sentences: sentences)
    }

    /// `probabilities` の選ばれたキーだけ。`confidence` が別にあっても使わない。
    static func selectedProbability(selected: String, probabilities: [String: Double]) -> Double? {
        guard let value = probabilities[selected], value.isFinite, (0.0...1.0).contains(value) else {
            return nil
        }
        return value
    }
}
