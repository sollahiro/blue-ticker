// 研究開発費の数値タグが無いとき、研究開発活動の本文から当期の会社全体の総額だけを補う。
// コードが百万円・千円・億円を円へ換算する。Jev は文の分類だけを返す。
// 1文に金額が2つある文、0円、割合だけは候補にしない。
// 確率 0.9 以上の当期総額がちょうど1文のときだけ採用する。
// セグメントへ配分できない開示は warnings に載せ、404 にはしない。
// OPENROUTER_DECISION_API_KEY が無いときは呼ばない。cache_version は上げない。
// Summary の rd は数値タグのまま（この経路は breakdown の分母だけ）。

import Foundation
import SwiftSoup

enum ResearchAndDevelopmentProseRole {
    static let currentCompanyTotal = "current_company_total"
    static let priorPeriod = "prior_period"
    static let partialAmount = "partial_amount"
    static let unrelated = "unrelated"
    static let optionKeys = [currentCompanyTotal, priorPeriod, partialAmount, unrelated]
}

struct ResearchAndDevelopmentProseCandidate: Equatable, Sendable {
    var sentence: String
    var yen: Double
}

struct ResearchAndDevelopmentProseChoice: Equatable, Sendable {
    var sentence: String
    var selected: String?
    var probability: Double?
}

protocol ResearchAndDevelopmentProseDeciding: Sendable {
    func classify(sentence: String) async -> ResearchAndDevelopmentProseChoice
    /// 差額と一致する文が、セグメントに載っていない当期の残りか。
    func classifyRemainder(sentence: String) async -> ResearchAndDevelopmentProseChoice
}

enum ResearchAndDevelopmentRemainderRole {
    static let unallocatedRemainder = "unallocated_remainder"
    static let segmentAmount = "segment_amount"
    static let priorPeriod = "prior_period"
    static let unrelated = "unrelated"
    static let optionKeys = [unallocatedRemainder, segmentAmount, priorPeriod, unrelated]
}

struct ResearchAndDevelopmentProseTotal: Equatable, Sendable {
    var yen: Double
    var warnings: [String]
    var audit: SegmentNoteJevAuditPayload
}

enum ResearchAndDevelopmentProseDecision: Equatable, Sendable {
    case applied(ResearchAndDevelopmentProseTotal)
    case notApplied
    /// 応答が無い。行は作らず、次回の欠測 ingest で再試行する。
    case unavailable
}

enum ResearchAndDevelopmentProseTotalDecision {
    static let question = "research_and_development_total"
    static let maxCandidates = 12
    static let maxSentenceLength = 4_000

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

    static func activityPlainText(in xbrlDir: URL) -> String? {
        guard let tag = xbrlSections["research_and_development"]?.xbrlElements.first,
            let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: tag)
        else { return nil }
        let text = plainText(from: html)
        return text.isEmpty ? nil : text
    }

    static func plainText(from html: String) -> String {
        guard let document = try? SwiftSoup.parse(html),
            let text = try? document.text(trimAndNormaliseWhitespace: true)
        else { return "" }
        return text
    }

    /// 1文にちょうど1つの正の金額がある文だけ。長い文と、上限を超えたあとの文は落とす。
    /// 上限を超えるときは「研究開発費」を含む文を先に残す。`limit == nil` は上限なし（差額照合用）。
    static func candidates(in text: String, limit: Int? = maxCandidates) -> [ResearchAndDevelopmentProseCandidate] {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var found: [ResearchAndDevelopmentProseCandidate] = []
        for raw in flattened.components(separatedBy: "。") {
            let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty, sentence.count <= maxSentenceLength else { continue }
            guard let yen = singlePositiveYen(in: sentence) else { continue }
            found.append(ResearchAndDevelopmentProseCandidate(sentence: sentence, yen: yen))
        }
        guard let limit, found.count > limit else { return found }
        let preferred = found.filter { $0.sentence.contains("研究開発費") }
        let rest = found.filter { !$0.sentence.contains("研究開発費") }
        return Array((preferred + rest).prefix(limit))
    }

    static let segmentSumFarWarning = "research_and_development_segment_sum_far_from_total"

    /// タグ付きの segment と reconciling が全社合計より 5% 以上少ないときの不足額。
    /// セグメント行が無い合計のみは nil（総額を残り行として二重に載せない）。
    static func shortfall(in snapshot: BreakdownSnapshot) -> Double? {
        guard snapshot.denominator > 0 else { return nil }
        let additive = snapshot.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount)
            .reduce(0, +)
        let gap = snapshot.denominator - additive
        guard additive > 0, gap > 0, gap / snapshot.denominator > 0.05 else { return nil }
        return gap
    }

    /// 百万円の丸め（日揮の 2百万円、日清製粉の 3百万円）を許容する。
    static func matchesShortfall(_ yen: Double, gap: Double) -> Bool {
        abs(yen - gap) <= max(5_000_000, gap * 0.005)
    }

    static func remainderLabel(in sentence: String) -> String {
        var label = sentence
        if let range = label.range(of: "は") {
            label = String(label[..<range.lowerBound])
        }
        for prefix in ["なお、", "また、", "ただし、"] where label.hasPrefix(prefix) {
            label.removeFirst(prefix.count)
        }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.count > 80 {
            label = String(label.prefix(80))
        }
        return label.isEmpty ? "配分不能" : label
    }

    /// 差額と一致する文がちょうど1つで、Jev が配分されていない残りと分類したときだけ行を足す。
    /// 応答が無い、分類が外れたときはスナップショットを変えない。
    static func fillShortfall(
        snapshot: BreakdownSnapshot, plainText: String, code: String = "", docID: String = "",
        decider: any ResearchAndDevelopmentProseDeciding
    ) async -> (snapshot: BreakdownSnapshot, audit: SegmentNoteJevAuditPayload?) {
        guard let gap = shortfall(in: snapshot) else { return (snapshot, nil) }
        let matches = candidates(in: plainText, limit: nil).filter { matchesShortfall($0.yen, gap: gap) }
        guard matches.count == 1, let match = matches.first else { return (snapshot, nil) }
        let choice = await decider.classifyRemainder(sentence: match.sentence)
        guard let selected = choice.selected else { return (snapshot, nil) }
        let applied = selected == ResearchAndDevelopmentRemainderRole.unallocatedRemainder
            && meetsThreshold(choice.probability)
        guard applied else { return (snapshot, nil) }
        let filled = snapshotByAddingRemainder(snapshot, sentence: match.sentence, yen: match.yen)
        guard !filled.warnings.contains(segmentSumFarWarning) else { return (snapshot, nil) }
        let call = SegmentNoteJevCallPayload(
            question: OpenRouterResearchAndDevelopmentProseDecider.remainderQuestion,
            options: ResearchAndDevelopmentRemainderRole.optionKeys,
            selected: selected, probability: choice.probability,
            sentences: [match.sentence], applied: true)
        let audit = SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: breakdownAxisResearchAndDevelopment,
            model: Api.openrouterDecisionsModel,
            threshold: SegmentNoteDecision.applyProbabilityThreshold,
            applied: true, needsReview: false,
            sentences: [match.sentence], calls: [call])
        return (filled, audit)
    }

    private static func snapshotByAddingRemainder(
        _ snapshot: BreakdownSnapshot, sentence: String, yen: Double
    ) -> BreakdownSnapshot {
        var filled = snapshot
        let label = remainderLabel(in: sentence)
        filled.rows.append(
            BreakdownRow(
                labelRaw: label, label: label, amount: yen,
                share: snapshot.denominator > 0 ? yen / snapshot.denominator : nil,
                profit: nil, rowKind: "reconciling"))
        var warnings = filled.warnings.filter { $0 != segmentSumFarWarning }
        let additive = filled.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount)
            .reduce(0, +)
        if filled.denominator > 0, additive > 0,
            abs(additive - filled.denominator) / filled.denominator > 0.05
        {
            warnings.append(segmentSumFarWarning)
        }
        if !warnings.contains(breakdownWarningResearchAndDevelopmentProseRemainder) {
            warnings.append(breakdownWarningResearchAndDevelopmentProseRemainder)
        }
        filled.warnings = warnings
        filled.needsReview = warnings.contains(segmentSumFarWarning)
        return filled
    }

    static func mentionsNotAllocatableToSegments(_ text: String) -> Bool {
        notAllocatablePhrases.contains { text.contains($0) }
    }

    static func decide(
        plainText: String, code: String = "", docID: String = "",
        decider: any ResearchAndDevelopmentProseDeciding
    ) async -> ResearchAndDevelopmentProseDecision {
        let found = candidates(in: plainText)
        guard !found.isEmpty else { return .notApplied }
        var calls: [SegmentNoteJevCallPayload] = []
        var winners: [ResearchAndDevelopmentProseCandidate] = []
        for candidate in found {
            let choice = await decider.classify(sentence: candidate.sentence)
            guard let selected = choice.selected else { return .unavailable }
            let applied = selected == ResearchAndDevelopmentProseRole.currentCompanyTotal
                && meetsThreshold(choice.probability)
            calls.append(
                SegmentNoteJevCallPayload(
                    question: question, options: ResearchAndDevelopmentProseRole.optionKeys,
                    selected: selected, probability: choice.probability,
                    sentences: [candidate.sentence], applied: applied))
            if applied { winners.append(candidate) }
        }
        guard winners.count == 1, let winner = winners.first else { return .notApplied }
        var warnings: [String] = []
        if mentionsNotAllocatableToSegments(plainText) {
            warnings.append(breakdownWarningNotAllocatableToSegments)
        }
        let audit = SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: breakdownAxisResearchAndDevelopment,
            model: Api.openrouterDecisionsModel,
            threshold: SegmentNoteDecision.applyProbabilityThreshold,
            applied: true, needsReview: false,
            sentences: found.map(\.sentence), calls: calls)
        return .applied(
            ResearchAndDevelopmentProseTotal(yen: winner.yen, warnings: warnings, audit: audit))
    }

    static func snapshot(axis: String, total: ResearchAndDevelopmentProseTotal) -> BreakdownSnapshot {
        BreakdownSnapshot(
            axis: axis, denominator: total.yen,
            denominatorTag: breakdownDenominatorTagResearchAndDevelopmentProse,
            rows: [], sourceKind: breakdownSourceResearchAndDevelopmentProse,
            needsReview: false, warnings: total.warnings)
    }

    private static func meetsThreshold(_ probability: Double?) -> Bool {
        guard let probability else { return false }
        return probability >= SegmentNoteDecision.applyProbabilityThreshold
    }

    /// 単位付き金額がちょうど1つで、円換算が正のときだけその金額。
    private static func singlePositiveYen(in sentence: String) -> Double? {
        let normalized = normalizeAmountText(sentence)
        guard let regex = try? NSRegularExpression(
            pattern: #"([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.([0-9]+))?\s*(億円|百万円|千円)"#)
        else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        let matches = regex.matches(in: normalized, range: range)
        guard matches.count == 1, let match = matches.first, match.numberOfRanges >= 4 else { return nil }
        guard !hasNegativePrefix(in: normalized, match: match.range) else { return nil }
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

    private static func yen(magnitude: Double, unit: String) -> Double? {
        let scale: Double
        switch unit {
        case "億円": scale = 100_000_000
        case "百万円": scale = Financial.millionYen
        case "千円": scale = 1_000
        default: return nil
        }
        let value = magnitude * scale
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func hasNegativePrefix(in text: String, match: NSRange) -> Bool {
        guard let range = Range(match, in: text), range.lowerBound > text.startIndex else { return false }
        let previous = text[text.index(before: range.lowerBound)]
        return previous == "△" || previous == "▲" || previous == "-" || previous == "－" || previous == "−"
    }

    private static func normalizeAmountText(_ text: String) -> String {
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

/// Decisions API へ研究開発費本文の Choice を出す。失敗時は selected = nil（行は作らない）。
struct OpenRouterResearchAndDevelopmentProseDecider: ResearchAndDevelopmentProseDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    static let remainderQuestion = "research_and_development_remainder"

    func classify(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        await choice(
            question: ResearchAndDevelopmentProseTotalDecision.question,
            body: Self.requestJSON(model: model, sentence: sentence),
            sentence: sentence)
    }

    func classifyRemainder(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        await choice(
            question: Self.remainderQuestion,
            body: Self.remainderRequestJSON(model: model, sentence: sentence),
            sentence: sentence)
    }

    private func choice(question: String, body: Data?, sentence: String) async -> ResearchAndDevelopmentProseChoice {
        let unavailable = ResearchAndDevelopmentProseChoice(
            sentence: sentence, selected: nil, probability: nil)
        guard let body else { return unavailable }
        do {
            let data = try await client.decide(requestJSON: body)
            guard let choice = OpenRouterDecisionsCodec.answers(from: data)[question]?.choice else {
                return unavailable
            }
            return ResearchAndDevelopmentProseChoice(
                sentence: sentence, selected: choice.selected,
                probability: OpenRouterSegmentNoteDecider.selectedProbability(
                    selected: choice.selected, probabilities: choice.probabilities))
        } catch {
            return unavailable
        }
    }

    static func requestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            ResearchAndDevelopmentProseRole.currentCompanyTotal: """
                当期（当連結会計年度、当事業年度、当期）の会社全体の研究開発費の総額を述べている。 \
                セグメントに配分できないので総額のみ、という説明が同じ文にあっても、総額ならこれ。
                """,
            ResearchAndDevelopmentProseRole.priorPeriod: """
                前期、前連結会計年度、前事業年度の金額である。
                """,
            ResearchAndDevelopmentProseRole.partialAmount: """
                一部のセグメント、疾患領域、地域、プロジェクトだけの金額である。会社全体の総額ではない。
                """,
            ResearchAndDevelopmentProseRole.unrelated: """
                研究開発費の総額ではない。従業員数、売上、設備投資、割合だけ、注記番号への参照を含む。
                """,
        ]
        let questions: [String: Any] = [
            ResearchAndDevelopmentProseTotalDecision.question: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "この文に出てくる金額は、当期の会社全体の研究開発費の総額か。文の意味で一つ選ぶ。金額の数値は選ばない。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model, state: ["sentence": sentence], questions: questions)
    }

    static func remainderRequestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            ResearchAndDevelopmentRemainderRole.unallocatedRemainder: """
                報告セグメントに配分されていない当期の研究開発費の残りを述べている。 \
                全社、共通、基礎研究、本社、各セグメントに帰属しない金額がこれにあたる。 \
                会社全体の研究開発費の総額そのものではない。
                """,
            ResearchAndDevelopmentRemainderRole.segmentAmount: """
                特定の報告セグメント、事業、地域、疾患領域だけの当期の金額である。
                """,
            ResearchAndDevelopmentRemainderRole.priorPeriod: """
                前期、前連結会計年度、前事業年度の金額である。
                """,
            ResearchAndDevelopmentRemainderRole.unrelated: """
                研究開発費の残りではない。売上、従業員数、設備投資、割合だけ、注記番号への参照を含む。
                """,
        ]
        let questions: [String: Any] = [
            remainderQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "この文の金額は、報告セグメントに配分されていない当期の研究開発費の残りか。文の意味で一つ選ぶ。金額の数値は選ばない。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model, state: ["sentence": sentence], questions: questions)
    }
}
