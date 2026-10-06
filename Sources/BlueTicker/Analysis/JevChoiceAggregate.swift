// Jev Decisions は temperature / seed を受けない。同一入力でも confidence が揺れる。
// geography は列 Choice と最終判定を N 回並列に取り、一致＋中央値で公開/NR を決める。
// 一致（成功 ≥ minSuccessfulSamples かつ全部同じ selected）は confident。不一致・不足は fail-closed。

import Foundation

enum JevChoiceAggregate {
    static let sampleCount = 3
    static let minSuccessfulSamples = 2

    enum Outcome: String, Equatable, Sendable {
        case agreed
        case disagreement
        case insufficient
        case allFailed
    }

    struct Sample: Equatable, Sendable {
        var selected: String?
        var probability: Double?
        var pNone: Double? = nil
        var probabilities: [String: Double] = [:]
        var options: [String] = []
        var sentences: [String] = []
        var model: String = ""
    }

    struct Result: Equatable, Sendable {
        var samples: [Sample]
        var selected: String?
        var probability: Double?
        var pNone: Double?
        var probabilities: [String: Double]
        var options: [String]
        var sentences: [String]
        var model: String
        var successfulCount: Int
        var unanimous: Bool
        var outcome: Outcome

        var isConfident: Bool { outcome == .agreed }
    }

    static func combine(_ samples: [Sample]) -> Result {
        let successful = samples.filter { sample in
            guard let selected = sample.selected?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return false }
            return !selected.isEmpty
        }
        let options = samples.first(where: { !$0.options.isEmpty })?.options ?? []
        let model = samples.first(where: { !$0.model.isEmpty })?.model ?? ""
        let sentences = samples.first(where: { !$0.sentences.isEmpty })?.sentences ?? []

        guard !successful.isEmpty else {
            return Result(
                samples: samples, selected: nil, probability: nil, pNone: nil,
                probabilities: [:], options: options, sentences: sentences, model: model,
                successfulCount: 0, unanimous: false, outcome: .allFailed)
        }

        var counts: [String: Int] = [:]
        for sample in successful {
            counts[sample.selected!, default: 0] += 1
        }
        let unanimous = counts.count == 1
        let modalCount = counts.values.max() ?? 0
        let tied = counts.filter { $0.value == modalCount }.count > 1
        let modal = tied ? successful[0].selected! : counts.first { $0.value == modalCount }!.key
        let agreeing = successful.filter { $0.selected == modal }
        let outcome: Outcome
        if successful.count < minSuccessfulSamples {
            outcome = .insufficient
        } else if !unanimous {
            outcome = .disagreement
        } else {
            outcome = .agreed
        }
        return Result(
            samples: samples,
            selected: modal,
            probability: median(agreeing.compactMap(\.probability)),
            pNone: median(agreeing.compactMap(\.pNone)),
            probabilities: agreeing.first?.probabilities ?? [:],
            options: options,
            sentences: sentences,
            model: model,
            successfulCount: successful.count,
            unanimous: unanimous,
            outcome: outcome)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func fromColumn(_ choice: RevenueRecognitionColumnChoice) -> Sample {
        Sample(
            selected: choice.selected, probability: choice.confidence, pNone: choice.pNone,
            probabilities: choice.probabilities, options: choice.options, model: choice.model)
    }

    static func fromReview(_ choice: SegmentNoteConsultedChoice) -> Sample {
        Sample(
            selected: choice.selected, probability: choice.probability,
            options: choice.options, sentences: choice.sentences)
    }

    static func columnChoice(from result: Result) -> RevenueRecognitionColumnChoice {
        RevenueRecognitionColumnChoice(
            selected: result.selected,
            confidence: result.probability,
            pNone: result.pNone,
            probabilities: result.probabilities,
            model: result.model,
            options: result.options)
    }
}
