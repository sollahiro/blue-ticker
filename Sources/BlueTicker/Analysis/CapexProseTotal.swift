// 設備投資マトリクスの欠損埋め。Jev は文の Role だけを返す。円はコードが換算する。
// SegmentNoteDecision の表 Choice / 省略 Choice には載せない。
// 埋めるのは会社全体の総額（Overview セル）と、タグ付きセグメント行があるときの
// reconciling だけ。セグメント別セルは埋めない。

import Foundation
import SwiftSoup

enum CapexProseRole {
    static let currentCompanyTotal = "current_company_total"
    static let priorPeriod = "prior_period"
    static let partialAmount = "partial_amount"
    static let unrelated = "unrelated"
    static let optionKeys = [currentCompanyTotal, priorPeriod, partialAmount, unrelated]
}

enum CapexRemainderRole {
    static let unallocatedRemainder = "unallocated_remainder"
    static let segmentAmount = "segment_amount"
    static let priorPeriod = "prior_period"
    static let unrelated = "unrelated"
    static let optionKeys = [unallocatedRemainder, segmentAmount, priorPeriod, unrelated]
}

enum CapexExclusionRole {
    static let excludedFromTotal = "excluded_from_total"
    static let includedInTotal = "included_in_total"
    static let priorPeriod = "prior_period"
    static let unrelated = "unrelated"
    static let optionKeys = [excludedFromTotal, includedInTotal, priorPeriod, unrelated]
}

struct CapexProseCandidate: Equatable, Sendable {
    var sentence: String
    var yen: Double
}

struct CapexProseChoice: Equatable, Sendable {
    var sentence: String
    var selected: String?
    var probability: Double?
}

protocol CapexProseDeciding: Sendable {
    func classify(sentence: String) async -> CapexProseChoice
    func classifyRemainder(sentence: String) async -> CapexProseChoice
    func classifyExclusion(sentence: String) async -> CapexProseChoice
}

struct CapexProseTotal: Equatable, Sendable {
    var yen: Double
    var warnings: [String]
    var audit: SegmentNoteJevAuditPayload
}

enum CapexProseDecision: Equatable, Sendable {
    case applied(CapexProseTotal)
    case notApplied
    case unavailable
}

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
    static let maxCandidates = 12
    static let maxSentenceLength = 4_000

    private static let overviewTextBlockTags = [
        "OverviewOfCapitalExpendituresEtcOwnUsedAssetsLEATextBlock",
        "OverviewOfCapitalExpendituresEtcTextBlock",
    ]

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

    private static let preferredPhrases = ["設備投資", "資本的支出", "固定資産"]

    static func overviewPlainText(in xbrlDir: URL) -> String? {
        for tag in overviewTextBlockTags {
            guard let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: tag) else {
                continue
            }
            let text = plainText(from: html)
            if !text.isEmpty { return text }
        }
        return nil
    }

    static func plainText(from html: String) -> String {
        guard let document = try? SwiftSoup.parse(html),
            let text = try? document.text(trimAndNormaliseWhitespace: true)
        else { return "" }
        return text
    }

    static func candidates(in text: String, limit: Int? = maxCandidates) -> [CapexProseCandidate] {
        var found: [CapexProseCandidate] = []
        for sentence in sentences(in: text) {
            guard let yen = singlePositiveYen(in: sentence) else { continue }
            found.append(CapexProseCandidate(sentence: sentence, yen: yen))
        }
        guard let limit, found.count > limit else { return found }
        let preferred = found.filter { candidate in
            preferredPhrases.contains { candidate.sentence.contains($0) }
        }
        let rest = found.filter { candidate in
            !preferredPhrases.contains { candidate.sentence.contains($0) }
        }
        return Array((preferred + rest).prefix(limit))
    }

    static func matchesShortfall(_ yen: Double, gap: Double) -> Bool {
        abs(yen - gap) <= 5_000_000
    }

    static func decide(
        plainText: String, code: String = "", docID: String = "",
        decider: any CapexProseDeciding
    ) async -> CapexProseDecision {
        let found = candidates(in: plainText)
        guard !found.isEmpty else { return .notApplied }
        var calls: [SegmentNoteJevCallPayload] = []
        var winners: [CapexProseCandidate] = []
        for candidate in found {
            let choice = await decider.classify(sentence: candidate.sentence)
            guard let selected = choice.selected else { return .unavailable }
            let applied = selected == CapexProseRole.currentCompanyTotal
                && meetsThreshold(choice.probability)
            calls.append(
                SegmentNoteJevCallPayload(
                    question: question, options: CapexProseRole.optionKeys,
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
            code: code, docID: docID, axis: breakdownAxisCapex,
            model: Api.openrouterDecisionsModel,
            threshold: SegmentNoteDecision.applyProbabilityThreshold,
            applied: true, needsReview: false,
            sentences: found.map(\.sentence), calls: calls)
        return .applied(CapexProseTotal(yen: winner.yen, warnings: warnings, audit: audit))
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
        guard let totals = totals(payload, cell: cell), totals.denominator > 0 else { return nil }
        let additive = additiveSum(payload, cell: cell)
        let gap = totals.denominator - additive
        guard additive > 0, gap > 0, gap / totals.denominator > 0.05 else { return nil }
        return gap
    }

    static func excess(in payload: BreakdownSnapshotPayload, cell: CapexProseCell) -> Double? {
        guard let totals = totals(payload, cell: cell), totals.denominator > 0 else { return nil }
        let additive = additiveSum(payload, cell: cell)
        let over = additive - totals.denominator
        guard additive > 0, over > 0, over / totals.denominator > 0.05 else { return nil }
        return over
    }

    static func fillShortfall(
        payload: BreakdownSnapshotPayload, cell: CapexProseCell, plainText: String,
        code: String = "", docID: String = "", decider: any CapexProseDeciding
    ) async -> (payload: BreakdownSnapshotPayload, audit: SegmentNoteJevAuditPayload?) {
        guard let gap = shortfall(in: payload, cell: cell) else { return (payload, nil) }
        let pool = candidates(in: plainText, limit: nil)
        let exact = pool.filter { matchesShortfall($0.yen, gap: gap) }
        let match: CapexProseCandidate
        if exact.count == 1, let one = exact.first {
            match = one
        } else if exact.isEmpty {
            let phrase = pool.filter {
                mentionsNotAllocatableToSegments($0.sentence)
                    && !matchesTaggedRow($0.yen, payload: payload, cell: cell)
            }
            guard phrase.count == 1, let one = phrase.first else { return (payload, nil) }
            match = one
        } else {
            return (payload, nil)
        }
        let choice = await decider.classifyRemainder(sentence: match.sentence)
        guard let selected = choice.selected else { return (payload, nil) }
        let applied = selected == CapexRemainderRole.unallocatedRemainder
            && meetsThreshold(choice.probability)
        guard applied else { return (payload, nil) }
        let filled = payloadByAddingAdjustment(
            payload, cell: cell, yen: match.yen, label: remainderLabel(in: match.sentence),
            warning: breakdownWarningCapexProseRemainder)
        guard !cell.farWarnings(flowMetric: filled.flowMetric).contains(where: {
            filled.warnings.contains($0)
        }) else { return (payload, nil) }
        let call = SegmentNoteJevCallPayload(
            question: OpenRouterCapexProseDecider.remainderQuestion,
            options: CapexRemainderRole.optionKeys,
            selected: selected, probability: choice.probability,
            sentences: [match.sentence], applied: true)
        let audit = SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: breakdownAxisCapex,
            model: Api.openrouterDecisionsModel,
            threshold: SegmentNoteDecision.applyProbabilityThreshold,
            applied: true, needsReview: false,
            sentences: [match.sentence], calls: [call])
        return (filled, audit)
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
        let choice = await decider.classifyExclusion(sentence: match.sentence)
        guard let selected = choice.selected else { return (payload, nil) }
        let applied = selected == CapexExclusionRole.excludedFromTotal
            && meetsThreshold(choice.probability)
        guard applied else { return (payload, nil) }
        let filled = payloadByAddingAdjustment(
            payload, cell: cell, yen: -match.yen, label: exclusionLabel(in: match.sentence),
            warning: breakdownWarningCapexProseExclusion)
        guard !cell.farWarnings(flowMetric: filled.flowMetric).contains(where: {
            filled.warnings.contains($0)
        }) else { return (payload, nil) }
        let call = SegmentNoteJevCallPayload(
            question: OpenRouterCapexProseDecider.exclusionQuestion,
            options: CapexExclusionRole.optionKeys,
            selected: selected, probability: choice.probability,
            sentences: [match.sentence], applied: true)
        let audit = SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: breakdownAxisCapex,
            model: Api.openrouterDecisionsModel,
            threshold: SegmentNoteDecision.applyProbabilityThreshold,
            applied: true, needsReview: false,
            sentences: [match.sentence], calls: [call])
        return (filled, audit)
    }

    static func mentionsNotAllocatableToSegments(_ text: String) -> Bool {
        notAllocatablePhrases.contains { text.contains($0) }
    }

    private static let exclusionCues = ["このほか", "この他", "含まない", "含まれない", "除く"]

    private static func exclusionCandidates(
        in text: String, total: Double, excess: Double
    ) -> [CapexProseCandidate] {
        sentences(in: text).compactMap { sentence in
            guard exclusionCues.contains(where: { sentence.contains($0) }) else { return nil }
            let amounts = positiveYenAmounts(in: sentence)
            let totals = amounts.filter { matchesShortfall($0, gap: total) }
            let overs = amounts.filter { matchesShortfall($0, gap: excess) }
            guard totals.count == 1, overs.count == 1, let yen = overs.first else { return nil }
            return CapexProseCandidate(sentence: sentence, yen: yen)
        }
    }

    private static func remainderLabel(in sentence: String) -> String {
        var label = sentence
        if let range = label.range(of: "は") {
            label = String(label[..<range.lowerBound])
        }
        for prefix in ["なお、", "また、", "ただし、"] where label.hasPrefix(prefix) {
            label.removeFirst(prefix.count)
        }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if mentionsNotAllocatableToSegments(sentence) { return "配分不能" }
        if label.count > 80 { label = String(label.prefix(80)) }
        return label.isEmpty ? "配分不能" : label
    }

    private static func exclusionLabel(in sentence: String) -> String {
        let normalized = normalizeAmountText(sentence)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:億円|百万円|千円)の([^、。を\s]{1,20})"#)
        else { return "総額に含まれない支出" }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
            match.numberOfRanges >= 2,
            let nameRange = Range(match.range(at: 1), in: normalized)
        else { return "総額に含まれない支出" }
        let name = String(normalized[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "総額に含まれない支出" : name
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
        var warnings = filled.warnings.filter { warning in
            !cell.farWarnings(flowMetric: filled.flowMetric).contains(warning)
        }
        if let totals = totals(filled, cell: cell), totals.denominator > 0 {
            let additive = additiveSum(filled, cell: cell)
            if additive > 0, abs(additive - totals.denominator) / totals.denominator > 0.05 {
                warnings.append(cell.farWarning)
            }
        }
        if !warnings.contains(warning) { warnings.append(warning) }
        filled.warnings = warnings
        filled.needsReview = cell.farWarnings(flowMetric: filled.flowMetric).contains {
            warnings.contains($0)
        }
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
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .compactMap { cellAmount($0, cell: cell) }
            .reduce(0, +)
    }

    private static func matchesTaggedRow(
        _ yen: Double, payload: BreakdownSnapshotPayload, cell: CapexProseCell
    ) -> Bool {
        payload.rows
            .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .compactMap { cellAmount($0, cell: cell) }
            .contains { abs($0 - yen) <= 5_000_000 }
    }

    private static func meetsThreshold(_ probability: Double?) -> Bool {
        guard let probability else { return false }
        return probability >= SegmentNoteDecision.applyProbabilityThreshold
    }

    private static func sentences(in text: String) -> [String] {
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

    private static func singlePositiveYen(in sentence: String) -> Double? {
        let amounts = positiveYenAmounts(in: sentence)
        guard amounts.count == 1 else { return nil }
        return amounts[0]
    }

    private static func positiveYenAmounts(in sentence: String) -> [Double] {
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
        guard let range = Range(match, in: text), range.lowerBound > text.startIndex else {
            return false
        }
        let previous = text[text.index(before: range.lowerBound)]
        return previous == "△" || previous == "▲" || previous == "-" || previous == "－"
            || previous == "−"
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
        let unavailable = CapexProseChoice(sentence: sentence, selected: nil, probability: nil)
        guard let body else { return unavailable }
        do {
            let data = try await client.decide(requestJSON: body)
            guard let choice = OpenRouterDecisionsCodec.answers(from: data)[question]?.choice else {
                return unavailable
            }
            return CapexProseChoice(
                sentence: sentence, selected: choice.selected,
                probability: OpenRouterSegmentNoteDecider.selectedProbability(
                    selected: choice.selected, probabilities: choice.probabilities))
        } catch {
            return unavailable
        }
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
        let questions: [String: Any] = [
            CapexProseTotalDecision.question: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "この文に出てくる金額は、当期の会社全体の設備投資の総額か。文の意味で一つ選ぶ。金額の数値は選ばない。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model, state: ["sentence": sentence], questions: questions)
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
        let questions: [String: Any] = [
            remainderQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "この文の金額は、報告セグメントに配分されていない当期の設備投資の残りか。文の意味で一つ選ぶ。金額の数値は選ばない。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model, state: ["sentence": sentence], questions: questions)
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
        let questions: [String: Any] = [
            exclusionQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "設備投資の総額と一緒に出てくるもう一つの金額は、その総額の外の支出か。文の意味で一つ選ぶ。金額の数値は選ばない。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model, state: ["sentence": sentence], questions: questions)
    }
}
