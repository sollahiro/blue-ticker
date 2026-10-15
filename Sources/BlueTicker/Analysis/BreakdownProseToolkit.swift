// Capex と研究開発費の本文抽出が共有する文・円・残り行の道具。
// コードが億円・百万円・千円を円へ換算する。Jev は既存の文を分類するだけ。
// 開示総額から抽出済み合計を引いて値を埋める処理は持たない。残り行は、
// 本文の金額が不足額／超過額と一致する文を選んだときだけ足す（既存の意味を共有する）。

import Foundation
import SwiftSoup

enum BreakdownProseRole {
    static let currentCompanyTotal = "current_company_total"
    static let priorPeriod = "prior_period"
    static let partialAmount = "partial_amount"
    static let unrelated = "unrelated"
    static let optionKeys = [currentCompanyTotal, priorPeriod, partialAmount, unrelated]
}

enum BreakdownProseRemainderRole {
    static let unallocatedRemainder = "unallocated_remainder"
    static let segmentAmount = "segment_amount"
    static let priorPeriod = "prior_period"
    static let unrelated = "unrelated"
    static let optionKeys = [unallocatedRemainder, segmentAmount, priorPeriod, unrelated]
}

enum BreakdownProseExclusionRole {
    static let excludedFromTotal = "excluded_from_total"
    static let includedInTotal = "included_in_total"
    static let priorPeriod = "prior_period"
    static let unrelated = "unrelated"
    static let optionKeys = [excludedFromTotal, includedInTotal, priorPeriod, unrelated]
}

struct BreakdownProseCandidate: Equatable, Sendable {
    var sentence: String
    var yen: Double
}

struct BreakdownProseChoice: Equatable, Sendable {
    var sentence: String
    var selected: String?
    var probability: Double?
}

protocol BreakdownProseDeciding: Sendable {
    func classify(sentence: String) async -> BreakdownProseChoice
    func classifyRemainder(sentence: String) async -> BreakdownProseChoice
    func classifyExclusion(sentence: String) async -> BreakdownProseChoice
}

struct BreakdownProseTotal: Equatable, Sendable {
    var yen: Double
    var warnings: [String]
    var audit: SegmentNoteJevAuditPayload
}

enum BreakdownProseDecision: Equatable, Sendable {
    case applied(BreakdownProseTotal)
    case notApplied
    /// 応答が無い。行は作らず、次回の欠測 ingest で再試行する。
    case unavailable
}

enum BreakdownProseToolkit {
    static let maxCandidates = 12
    static let maxSentenceLength = 4_000
    static let coverageRatio = 0.05
    static let shortfallToleranceYen: Double = 5_000_000
    static let exclusionCues = ["このほか", "この他", "含まない", "含まれない", "除く"]

    private static let notAllocatablePhrases = [
        "配分することが困難",
        "配分できない",
        "関連付けることが困難",
        "関連付けられない",
        "関連づけることが困難",
        "関連づけられない",
        "セグメント別の記載は行っていません",
        "セグメント別の記載は行っておりません",
        "特定のセグメントに関連付けられない",
        "特定のセグメントに関連づけられない",
    ]

    static func classifyPolicy(question: String) -> JevDecisionPolicy {
        JevDecisionPolicy(
            kind: .classify,
            question: question,
            noneOfTheseKey: nil,
            confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)
    }

    static func plainText(from html: String) -> String {
        guard let document = try? SwiftSoup.parse(html),
            let text = try? document.text(trimAndNormaliseWhitespace: true)
        else { return "" }
        return text
    }

    static func sentences(in text: String) -> [String] {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return flattened.components(separatedBy: "。").compactMap { raw in
            let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty, sentence.count <= maxSentenceLength else { return nil }
            return sentence
        }
    }

    /// 1文にちょうど1つの正の金額がある文だけ。上限を超えるときは preferred を先に残す。
    /// `limit == nil` は上限なし（差額照合用）。
    static func candidates(
        in text: String, preferredPhrases: [String], limit: Int? = maxCandidates
    ) -> [BreakdownProseCandidate] {
        var found: [BreakdownProseCandidate] = []
        for sentence in sentences(in: text) {
            guard let yen = singlePositiveYen(in: sentence) else { continue }
            found.append(BreakdownProseCandidate(sentence: sentence, yen: yen))
        }
        guard let limit, found.count > limit else { return found }
        func isPreferred(_ candidate: BreakdownProseCandidate) -> Bool {
            preferredPhrases.contains { candidate.sentence.contains($0) }
        }
        let preferred = found.filter(isPreferred)
        let rest = found.filter { !isPreferred($0) }
        return Array((preferred + rest).prefix(limit))
    }

    static func mentionsNotAllocatableToSegments(_ text: String) -> Bool {
        notAllocatablePhrases.contains { text.contains($0) }
    }

    static func matchesShortfall(_ yen: Double, gap: Double) -> Bool {
        abs(yen - gap) <= shortfallToleranceYen
    }

    static func matchesTaggedAmount(_ yen: Double, amounts: [Double]) -> Bool {
        amounts.contains { abs($0 - yen) <= shortfallToleranceYen }
    }

    static func isAdditiveRowKind(_ kind: String) -> Bool {
        kind == "segment" || kind == "reconciling"
    }

    static func shortfall(denominator: Double, additive: Double) -> Double? {
        guard denominator > 0 else { return nil }
        let gap = denominator - additive
        guard additive > 0, gap > 0, gap / denominator > coverageRatio else { return nil }
        return gap
    }

    static func excess(denominator: Double, additive: Double) -> Double? {
        guard denominator > 0 else { return nil }
        let over = additive - denominator
        guard additive > 0, over > 0, over / denominator > coverageRatio else { return nil }
        return over
    }

    static func stillFarFromTotal(denominator: Double, additive: Double) -> Bool {
        denominator > 0 && additive > 0
            && abs(additive - denominator) / denominator > coverageRatio
    }

    /// 5百万円で一致する文がちょうど1つ。無ければ配分不能の1文だけ。2文以上は選ばない。
    /// 開示総額 − 抽出済み合計で金額を作らない。
    static func matchRemainderCandidate(
        pool: [BreakdownProseCandidate], gap: Double,
        matchesTaggedRow: (Double) -> Bool
    ) -> BreakdownProseCandidate? {
        let exact = pool.filter { matchesShortfall($0.yen, gap: gap) }
        if exact.count == 1 { return exact.first }
        if exact.isEmpty {
            let phrase = pool.filter {
                mentionsNotAllocatableToSegments($0.sentence) && !matchesTaggedRow($0.yen)
            }
            if phrase.count == 1 { return phrase.first }
        }
        return nil
    }

    static func remainderLabel(in sentence: String, notAllocatableOverrides: Bool = false)
        -> String
    {
        var label = sentence
        if let range = label.range(of: "は") {
            label = String(label[..<range.lowerBound])
        }
        for prefix in ["なお、", "また、", "ただし、"] where label.hasPrefix(prefix) {
            label.removeFirst(prefix.count)
        }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if notAllocatableOverrides, mentionsNotAllocatableToSegments(sentence) {
            return "配分不能"
        }
        if label.count > 80 { label = String(label.prefix(80)) }
        return label.isEmpty ? "配分不能" : label
    }

    static func exclusionLabel(in sentence: String, fallback: String) -> String {
        let normalized = normalizeAmountText(sentence)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:億円|百万円|千円)の([^、。を\s]{1,20})"#)
        else { return fallback }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
            match.numberOfRanges >= 2,
            let nameRange = Range(match.range(at: 1), in: normalized)
        else { return fallback }
        let name = String(normalized[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    static func exclusionCandidates(
        in text: String, excess: Double,
        matchesTotal: (Double, String) -> Bool,
        acceptYen: (Double) -> Bool = { _ in true }
    ) -> [BreakdownProseCandidate] {
        sentences(in: text).compactMap { sentence in
            guard exclusionCues.contains(where: { sentence.contains($0) }) else { return nil }
            let amounts = positiveYenAmounts(in: sentence)
            let totals = amounts.filter { matchesTotal($0, sentence) }
            let overs = amounts.filter { matchesShortfall($0, gap: excess) }
            guard totals.count == 1, overs.count == 1, let yen = overs.first else { return nil }
            guard acceptYen(yen) else { return nil }
            return BreakdownProseCandidate(sentence: sentence, yen: yen)
        }
    }

    static func adjustedWarnings(
        existing: [String], farWarningNames: [String], primaryFarWarning: String,
        stillFar: Bool, extraWarning: String
    ) -> (warnings: [String], needsReview: Bool) {
        var warnings = existing.filter { !farWarningNames.contains($0) }
        if stillFar { warnings.append(primaryFarWarning) }
        if !warnings.contains(extraWarning) { warnings.append(extraWarning) }
        let needsReview = farWarningNames.contains { warnings.contains($0) }
        return (warnings, needsReview)
    }

    static func classifyCurrentCompanyTotal(
        candidates: [BreakdownProseCandidate], policy: JevDecisionPolicy,
        decider: any BreakdownProseDeciding
    ) async -> CompanyTotalOutcome {
        guard !candidates.isEmpty else { return .notApplied }
        var calls: [SegmentNoteJevCallPayload] = []
        var winners: [BreakdownProseCandidate] = []
        for candidate in candidates {
            let result = await JevDecisionSampler.decide(
                policy: policy,
                options: BreakdownProseRole.optionKeys,
                sentences: [candidate.sentence]
            ) {
                let choice = await decider.classify(sentence: candidate.sentence)
                return JevChoiceAggregate.Sample(
                    selected: choice.selected, probability: choice.probability)
            }
            if result.isEmpty { return .unavailable }
            var resultCalls = result.calls
            let applied = result.selectedKey == BreakdownProseRole.currentCompanyTotal
            if !applied {
                for index in resultCalls.indices { resultCalls[index].applied = false }
            }
            calls.append(contentsOf: resultCalls)
            if applied { winners.append(candidate) }
        }
        guard winners.count == 1, let winner = winners.first else { return .notApplied }
        return .applied(winner: winner, calls: calls)
    }

    /// 既存の1文を分類する。採用キーでなければ nil（スナップショットは変えない）。
    static func acceptedClassification(
        sentence: String, policy: JevDecisionPolicy, optionKeys: [String],
        appliedKey: String, classify: @Sendable @escaping () async -> BreakdownProseChoice
    ) async -> JevDecisionResult? {
        let result = await JevDecisionSampler.decide(
            policy: policy, options: optionKeys, sentences: [sentence]
        ) {
            let choice = await classify()
            return JevChoiceAggregate.Sample(
                selected: choice.selected, probability: choice.probability)
        }
        guard result.selectedKey == appliedKey else { return nil }
        return result
    }

    static func companyTotalAudit(
        code: String, docID: String, axis: String,
        sentences: [String], calls: [SegmentNoteJevCallPayload]
    ) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: axis,
            model: Api.openrouterDecisionsModel,
            threshold: SegmentNoteDecision.applyProbabilityThreshold,
            applied: true, needsReview: false,
            sentences: sentences, calls: calls)
    }

    static func appliedSentenceAudit(
        code: String, docID: String, axis: String,
        result: JevDecisionResult, sentence: String, policy: JevDecisionPolicy
    ) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: axis,
            model: result.aggregate.model.isEmpty
                ? Api.openrouterDecisionsModel : result.aggregate.model,
            threshold: policy.auditThreshold,
            applied: true, needsReview: false,
            sentences: [sentence], calls: result.calls)
    }

    static func decideCompanyTotal(
        plainText: String, code: String, docID: String, axis: String,
        preferredPhrases: [String], policy: JevDecisionPolicy,
        decider: any BreakdownProseDeciding
    ) async -> BreakdownProseDecision {
        let found = candidates(in: plainText, preferredPhrases: preferredPhrases)
        switch await classifyCurrentCompanyTotal(
            candidates: found, policy: policy, decider: decider)
        {
        case .unavailable:
            return .unavailable
        case .notApplied:
            return .notApplied
        case .applied(let winner, let calls):
            var warnings: [String] = []
            if mentionsNotAllocatableToSegments(plainText) {
                warnings.append(breakdownWarningNotAllocatableToSegments)
            }
            return .applied(
                BreakdownProseTotal(
                    yen: winner.yen, warnings: warnings,
                    audit: companyTotalAudit(
                        code: code, docID: docID, axis: axis,
                        sentences: found.map(\.sentence), calls: calls)))
        }
    }

    enum CompanyTotalOutcome: Equatable, Sendable {
        case applied(winner: BreakdownProseCandidate, calls: [SegmentNoteJevCallPayload])
        case notApplied
        case unavailable
    }

    static func singlePositiveYen(in sentence: String) -> Double? {
        let amounts = positiveYenAmounts(in: sentence)
        guard amounts.count == 1 else { return nil }
        return amounts[0]
    }

    static func positiveYenAmounts(in sentence: String) -> [Double] {
        let normalized = normalizeAmountText(sentence)
        guard let regex = try? NSRegularExpression(
            pattern: #"([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.([0-9]+))?\s*(億円|百万円|千円)"#)
        else { return [] }
        let range = NSRange(normalized.startIndex..., in: normalized)
        return regex.matches(in: normalized, range: range).compactMap { match in
            guard match.numberOfRanges >= 4, !hasNegativePrefix(in: normalized, match: match.range)
            else { return nil }
            guard let wholeRange = Range(match.range(at: 1), in: normalized),
                let unitRange = Range(match.range(at: 3), in: normalized)
            else { return nil }
            var digits = String(normalized[wholeRange]).replacingOccurrences(of: ",", with: "")
            if match.range(at: 2).location != NSNotFound,
                let fractionRange = Range(match.range(at: 2), in: normalized)
            {
                digits += "." + String(normalized[fractionRange])
            }
            guard let magnitude = Double(digits) else { return nil }
            return yen(magnitude: magnitude, unit: String(normalized[unitRange]))
        }
    }

    /// 文中の単位語（億円 / 百万円 / 千円）だけ。表キャプションの contains 判定とは別。
    static func yenScale(forUnit unit: String) -> Double? {
        switch unit {
        case "億円": return 100_000_000
        case "百万円": return Financial.millionYen
        case "千円": return 1_000
        default: return nil
        }
    }

    static func yen(magnitude: Double, unit: String) -> Double? {
        guard let scale = yenScale(forUnit: unit) else { return nil }
        let value = magnitude * scale
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func hasNegativePrefix(in text: String, match: NSRange) -> Bool {
        guard let range = Range(match, in: text), range.lowerBound > text.startIndex else {
            return false
        }
        let previous = text[text.index(before: range.lowerBound)]
        return previous == "△" || previous == "▲" || previous == "-" || previous == "－"
            || previous == "−"
    }

    static func normalizeAmountText(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        let chars = Array(text.unicodeScalars)
        for (index, scalar) in chars.enumerated() {
            if (0xFF10...0xFF19).contains(scalar.value) {
                scalars.append(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
            } else if scalar.value == 0xFF0C {
                scalars.append(",")
            } else if scalar.value == 0x3001, index > 0, index + 1 < chars.count,
                isAmountDigit(chars[index - 1]), isAmountDigit(chars[index + 1])
            {
                scalars.append(",")
            } else {
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isAmountDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0xFF10...0xFF19).contains(scalar.value)
    }
}

enum BreakdownProseOpenRouter {
    static func choice(
        client: any DecisionsCompleting, question: String, body: Data?, sentence: String,
        retries: Int, onFailure: String
    ) async -> BreakdownProseChoice {
        let unavailable = BreakdownProseChoice(sentence: sentence, selected: nil, probability: nil)
        guard let body else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body, retries: retries, onFailure: onFailure)
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[question]?.choice else {
            return unavailable
        }
        return BreakdownProseChoice(
            sentence: sentence, selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities))
    }

    static func requestJSON(
        model: String, question: String, sentence: String, instructions: String,
        criteria: [String: String]
    ) -> Data? {
        OpenRouterDecisionsCodec.requestJSON(
            model: model, state: ["sentence": sentence],
            questions: [
                question: OpenRouterDecisionsCodec.choiceQuestion(
                    instructions: instructions, criteria: criteria)
            ])
    }
}
