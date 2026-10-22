// セグメント注記の開示パターン分類。
// 決定論の XBRL 信号を先に見る。曖昧なときだけ注記の散文を Jev に渡し、分類と根拠文だけを返す。
// 数値は返させない。低信頼・解釈不能は needs_review。

import Foundation

enum SegmentNotePatternClass: String, Equatable, Sendable {
    case multipleSegments = "multiple_segments"
    case singleSegment = "single_segment"
    case omittedDominant90pct = "omitted_dominant_90pct"
    case omittedSameAsSegment = "omitted_same_as_segment"
    case notDisclosed = "not_disclosed"
}

enum SegmentNotePatternAxis: Equatable, Sendable {
    case segment
    case productService
    case geography

    var wire: String {
        switch self {
        case .segment: return breakdownAxisSegment
        case .productService: return breakdownAxisProductService
        case .geography: return breakdownAxisGeography
        }
    }

    var optionKeys: [String] {
        switch self {
        case .segment:
            return [
                SegmentNotePatternClass.multipleSegments.rawValue,
                SegmentNotePatternClass.singleSegment.rawValue,
                SegmentNotePatternClass.omittedDominant90pct.rawValue,
                SegmentNotePatternClass.notDisclosed.rawValue,
            ]
        case .productService, .geography:
            return [
                SegmentNotePatternClass.omittedSameAsSegment.rawValue,
                SegmentNotePatternClass.notDisclosed.rawValue,
            ]
        }
    }
}

protocol SegmentNotePatternDeciding: Sendable {
    func classifyDisclosure(prose: String, axis: SegmentNotePatternAxis) async -> SegmentNoteConsultedChoice
}

struct SegmentNotePatternSignals: Equatable, Sendable {
    var reportableMemberCount: Int
    var hasDedicatedSingleSegmentTag: Bool
    var hasReportableSegmentTable: Bool
    var hasRelatedInfoTable: Bool
    /// 報告セグメント売上 member がすべて地域名（電通型 Japan/Americas/EMEA/APAC）。
    var reportableMembersAreGeographic: Bool = false
    var prose: [String]
}

struct SegmentNotePatternOutcome: Equatable, Sendable {
    var classification: SegmentNotePatternClass?
    var evidenceSentence: String?
    var needsReview: Bool
    var source: String
    var audit: SegmentNoteJevAuditPayload?

    static func deterministic(
        _ classification: SegmentNotePatternClass, evidence: String? = nil
    ) -> SegmentNotePatternOutcome {
        SegmentNotePatternOutcome(
            classification: classification, evidenceSentence: evidence, needsReview: false,
            source: SegmentNotePatternClassifier.deterministicSource, audit: nil)
    }

    static func review(audit: SegmentNoteJevAuditPayload?) -> SegmentNotePatternOutcome {
        SegmentNotePatternOutcome(
            classification: nil, evidenceSentence: nil, needsReview: true,
            source: SegmentNotePatternClassifier.jevSource, audit: audit)
    }
}

enum SegmentNotePatternClassifier {
    static let question = "segment_note_disclosure_pattern"
    static let deterministicSource = "deterministic_xbrl"
    static let jevSource = "jev_disclosure_pattern"
    static let jevPolicy = JevDecisionPolicy(
        kind: .classify,
        question: question,
        noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    /// 決定論の XBRL 信号で確定できれば Jev に行かない。
    static func classifyDeterministic(
        axis: SegmentNotePatternAxis, signals: SegmentNotePatternSignals
    ) -> SegmentNotePatternOutcome? {
        switch axis {
        case .productService:
            if signals.hasRelatedInfoTable { return nil }
            return nil
        case .geography:
            if signals.hasRelatedInfoTable { return nil }
            // 関連情報に売上の地域表が無く、報告セグメント自体が地域軸なら
            // 公開 geography は値のコピーではなく same_as: segment（電通 4324）。
            if signals.reportableMembersAreGeographic, signals.reportableMemberCount >= 2 {
                return .deterministic(.omittedSameAsSegment)
            }
            return nil
        case .segment:
            if signals.reportableMemberCount >= 2 {
                return .deterministic(.multipleSegments)
            }
            // 専用タグは「同じ注記に収益の分解表がある」より強い。Takeda 4502 は
            // 報告セグメント表が無く、製品表がセグメント注記に同居する。
            if signals.hasDedicatedSingleSegmentTag, signals.reportableMemberCount <= 1 {
                return .deterministic(
                    .singleSegment, evidence: signals.prose.first)
            }
            if signals.reportableMemberCount == 1, signals.prose.isEmpty {
                return .deterministic(.singleSegment)
            }
            if signals.hasReportableSegmentTable, signals.reportableMemberCount != 1 {
                return .deterministic(.multipleSegments)
            }
            return nil
        }
    }

    static func classify(
        axis: SegmentNotePatternAxis,
        signals: SegmentNotePatternSignals,
        docID: String = "",
        decider: (any SegmentNotePatternDeciding)?
    ) async -> SegmentNotePatternOutcome {
        if let determined = classifyDeterministic(axis: axis, signals: signals) {
            return determined
        }
        let sentences = signals.prose.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let decider, !sentences.isEmpty else {
            if axis == .segment, signals.reportableMemberCount == 1 {
                return .deterministic(.singleSegment)
            }
            return SegmentNotePatternOutcome(
                classification: nil, evidenceSentence: nil, needsReview: true,
                source: jevSource, audit: nil)
        }
        return await classifyWithJev(
            axis: axis, sentences: sentences, docID: docID, decider: decider)
    }

    static func classifyWithJev(
        axis: SegmentNotePatternAxis,
        sentences: [String],
        docID: String,
        decider: any SegmentNotePatternDeciding
    ) async -> SegmentNotePatternOutcome {
        var records: [(sentence: String, result: JevDecisionResult, selected: String?)] = []
        for sentence in sentences {
            let result = await JevDecisionSampler.decide(
                policy: jevPolicy, options: axis.optionKeys, sentences: [sentence]
            ) {
                let choice = await decider.classifyDisclosure(prose: sentence, axis: axis)
                return JevChoiceAggregate.fromReview(choice)
            }
            records.append((sentence, result, result.selectedKey))
        }
        let accepted = records.compactMap { record -> (SegmentNotePatternClass, String)? in
            guard case .accepted(let key) = record.result.status,
                  let parsed = SegmentNotePatternClass(rawValue: key)
            else { return nil }
            return (parsed, record.sentence)
        }
        let classes = Set(accepted.map(\.0))
        let calls = records.flatMap(\.result.calls)
        let audit = SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: axis.wire, model: Api.openrouterDecisionsModel,
            threshold: jevPolicy.auditThreshold, applied: classes.count == 1,
            needsReview: classes.count != 1, sentences: accepted.map(\.1), calls: calls,
            decisionSource: jevSource)
        guard classes.count == 1, let only = classes.first,
              let evidence = accepted.first(where: { $0.0 == only })?.1
        else {
            return .review(audit: audit)
        }
        var applied = audit
        applied.applied = true
        applied.needsReview = false
        applied.sentences = [evidence]
        return SegmentNotePatternOutcome(
            classification: only, evidenceSentence: evidence, needsReview: false,
            source: jevSource, audit: applied)
    }

    /// 90%省略の根拠文から支配的事業名を取る。Jev は名前を作らない。
    static func dominantBusinessName(fromEvidence sentence: String) -> String? {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "の売上高")
            ?? trimmed.range(of: "のセグメント利益")
            ?? trimmed.range(of: "の金額がいずれも")
        {
            let prefix = String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name = lastBusinessName(in: prefix) { return name }
        }
        return lastBusinessName(in: trimmed)
    }

    static func lastBusinessName(in text: String) -> String? {
        let stripped = text.replacingOccurrences(
            of: #"【[^】]*】"#, with: "", options: .regularExpression)
        // 助詞・句読点で切る。貪欲に文頭から最後の「事業」まで取ると
        // 「当社グループは医薬品事業の単一の事業」になる。
        guard let regex = try? NSRegularExpression(
            pattern: #"([^\s。、のはがをにとで]{1,20}事業)"#)
        else {
            return nil
        }
        let ns = stripped as NSString
        let matches = regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length))
        let names = matches.map { ns.substring(with: $0.range) }.filter { name in
            !name.contains("全セグメント") && !name.contains("報告セグメント")
                && !name.contains("単一")
        }
        return names.last
    }

    /// 従業員行のラベルが segment 行と接合できないとき true。
    static func employeesJoinUnavailable(
        segmentLabels: Set<String>, employeeLabels: Set<String>
    ) -> Bool {
        let segment = normalizedJoinKeys(segmentLabels)
        let employees = normalizedJoinKeys(employeeLabels)
        guard !segment.isEmpty, !employees.isEmpty else { return false }
        if segment.count == 1, employees.count > 1, employees != segment {
            return true
        }
        return false
    }

    static func normalizedJoinKeys(_ labels: Set<String>) -> Set<String> {
        Set(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}

extension OpenRouterSegmentNoteDecider: SegmentNotePatternDeciding {
    static let patternQuestion = SegmentNotePatternClassifier.question

    func classifyDisclosure(
        prose: String, axis: SegmentNotePatternAxis
    ) async -> SegmentNoteConsultedChoice {
        let options = axis.optionKeys
        let unavailable = SegmentNoteConsultedChoice(
            question: Self.patternQuestion, selected: nil, probability: nil,
            options: options, sentences: [prose])
        guard let body = Self.patternRequestJSON(model: model, prose: prose, axis: axis) else {
            return unavailable
        }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: SegmentNotePatternClassifier.jevPolicy.transportRetries,
            onFailure: "SegmentNotePatternClassifier: Jev呼び出し失敗")
        else { return unavailable }
        return Self.consultedChoice(
            from: data, question: Self.patternQuestion, options: options, sentences: [prose])
    }

    static func patternRequestJSON(
        model: String, prose: String, axis: SegmentNotePatternAxis
    ) -> Data? {
        let criteria: [String: String]
        let instructions: String
        switch axis {
        case .segment:
            criteria = [
                SegmentNotePatternClass.multipleSegments.rawValue: """
                    複数の報告セグメントを開示している。表がある、または単一・90%省略・未開示ではない。
                    """,
                SegmentNotePatternClass.singleSegment.rawValue: """
                    単一の事業セグメントから構成されている、または単一セグメントであるため \
                    セグメント情報の記載を省略している。90%超のため省略、とは別。
                    """,
                SegmentNotePatternClass.omittedDominant90pct.rawValue: """
                    特定の事業の売上高・セグメント利益・セグメント資産がいずれも全セグメントの \
                    90%を超えるため、セグメント情報の記載を省略している。単一セグメントではない。
                    """,
                SegmentNotePatternClass.notDisclosed.rawValue: """
                    セグメント情報を開示しておらず、単一セグメントでも90%省略でもない。
                    """,
            ]
            instructions = """
                このセグメント情報の本文はどの開示パターンか。文の意味で一つ選ぶ。 \
                数値や行は作らない。
                """
        case .productService, .geography:
            let related = axis == .productService ? "製品及びサービスごとの情報" : "地域ごとの情報"
            criteria = [
                SegmentNotePatternClass.omittedSameAsSegment.rawValue: """
                    \(related)を、セグメント情報に同様の情報を開示しているため記載省略している。
                    """,
                SegmentNotePatternClass.notDisclosed.rawValue: """
                    \(related)を開示していないが、セグメント情報と同一だから省略した、とは書いていない。
                    """,
            ]
            instructions = """
                この関連情報の本文はどの開示パターンか。文の意味で一つ選ぶ。 \
                数値や行は作らない。
                """
        }
        let questions: [String: Any] = [
            patternQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: instructions, criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model, state: ["sentence": prose, "axis": axis.wire], questions: questions)
    }
}
