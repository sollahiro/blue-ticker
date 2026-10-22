// セグメント注記の開示パターン分類。Jev はスタブ（ライブ呼び出しなし）。
// 90%省略の本文は synthetic fixture と明示する。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct SegmentNotePatternClassifierTests {
    /// Takeda 4502 型: 単一セグメントと書くが「記載を省略」は無い。
    private let takedaWording =
        "当社グループは、医薬品の研究開発、製造、販売およびライセンス供与に従事しており、単一の事業セグメントから構成されております。"
    /// 定型の単一セグメント省略。
    private let classicOmission = "単一セグメントであるため、セグメント情報の記載を省略しております。"
    /// 90%省略。synthetic fixture。単一セグメントではない。
    private let synthetic90pct =
        "【synthetic】食品事業の売上高、セグメント利益及びセグメント資産の金額がいずれも全セグメントの90%を超えるため、記載を省略しております。"
    private let sameAsSegment =
        "セグメント情報に同様の情報を開示しているため、記載を省略しています。"

    @Test func twoReportableMembersAreMultipleSegmentsWithoutJev() async {
        let decider = FakeSegmentNotePatternDecider(selected: "single_segment")
        let outcome = await SegmentNotePatternClassifier.classify(
            axis: .segment,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: 2, hasDedicatedSingleSegmentTag: false,
                hasReportableSegmentTable: true, hasRelatedInfoTable: false,
                prose: [classicOmission]),
            decider: decider)
        #expect(outcome.classification == .multipleSegments)
        #expect(outcome.source == SegmentNotePatternClassifier.deterministicSource)
        #expect(decider.callCount() == 0)
    }

    @Test func dedicatedSingleSegmentTagIsDeterministic() async {
        let decider = FakeSegmentNotePatternDecider(selected: "omitted_dominant_90pct")
        let outcome = await SegmentNotePatternClassifier.classify(
            axis: .segment,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: 1, hasDedicatedSingleSegmentTag: true,
                hasReportableSegmentTable: false, hasRelatedInfoTable: false,
                prose: [takedaWording]),
            decider: decider)
        #expect(outcome.classification == .singleSegment)
        #expect(outcome.evidenceSentence == takedaWording)
        #expect(outcome.source == SegmentNotePatternClassifier.deterministicSource)
        #expect(decider.callCount() == 0)
    }

    @Test func stubbedJevClassifiesTakedaWordingAsSingleSegment() async {
        let decider = FakeSegmentNotePatternDecider(selected: "single_segment")
        let outcome = await SegmentNotePatternClassifier.classify(
            axis: .segment,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: 1, hasDedicatedSingleSegmentTag: false,
                hasReportableSegmentTable: false, hasRelatedInfoTable: false,
                prose: [takedaWording]),
            docID: "synthetic-takeda",
            decider: decider)
        #expect(outcome.classification == .singleSegment)
        #expect(outcome.evidenceSentence == takedaWording)
        #expect(outcome.source == SegmentNotePatternClassifier.jevSource)
        #expect(decider.callCount() >= 1)
    }

    @Test func stubbedJevClassifiesClassicOmissionAsSingleSegment() async {
        let decider = FakeSegmentNotePatternDecider(selected: "single_segment")
        let outcome = await SegmentNotePatternClassifier.classify(
            axis: .segment,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: 1, hasDedicatedSingleSegmentTag: false,
                hasReportableSegmentTable: false, hasRelatedInfoTable: false,
                prose: [classicOmission]),
            docID: "synthetic-classic",
            decider: decider)
        #expect(outcome.classification == .singleSegment)
        #expect(outcome.evidenceSentence == classicOmission)
        #expect(outcome.classification != .omittedDominant90pct)
    }

    @Test func syntheticDominant90pctProseIsNotSingleSegment() async {
        let decider = FakeSegmentNotePatternDecider(selected: "omitted_dominant_90pct")
        let outcome = await SegmentNotePatternClassifier.classify(
            axis: .segment,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: 1, hasDedicatedSingleSegmentTag: false,
                hasReportableSegmentTable: false, hasRelatedInfoTable: false,
                prose: [synthetic90pct]),
            docID: "synthetic-90pct",
            decider: decider)
        #expect(outcome.classification == .omittedDominant90pct)
        #expect(outcome.classification != .singleSegment)
        #expect(outcome.evidenceSentence == synthetic90pct)
        #expect(SegmentNotePatternClassifier.dominantBusinessName(fromEvidence: synthetic90pct)
            == "食品事業")
    }

    @Test func relatedInfoSameAsSegmentUsesJevOnGeographyAxis() async {
        let decider = FakeSegmentNotePatternDecider(selected: "omitted_same_as_segment")
        let outcome = await SegmentNotePatternClassifier.classify(
            axis: .geography,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: 3, hasDedicatedSingleSegmentTag: false,
                hasReportableSegmentTable: true, hasRelatedInfoTable: false,
                prose: [sameAsSegment]),
            docID: "synthetic-same-as",
            decider: decider)
        #expect(outcome.classification == .omittedSameAsSegment)
        #expect(outcome.evidenceSentence == sameAsSegment)
    }

    @Test func dedicatedTagWinsOverStrayRelatedInfoTables() async {
        let outcome = await SegmentNotePatternClassifier.classify(
            axis: .segment,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: 0, hasDedicatedSingleSegmentTag: true,
                hasReportableSegmentTable: true, hasRelatedInfoTable: true,
                prose: [takedaWording]),
            decider: FakeSegmentNotePatternDecider(selected: "multiple_segments"))
        #expect(outcome.classification == .singleSegment)
        #expect(outcome.source == SegmentNotePatternClassifier.deterministicSource)
    }

    @Test func lastBusinessNameDoesNotSwallowTheWholeSentence() {
        #expect(
            SegmentNotePatternClassifier.lastBusinessName(
                in: "当社グループは医薬品事業の単一の事業セグメントから構成されております。")
                == "医薬品事業")
        #expect(
            SegmentNotePatternClassifier.lastBusinessName(in: takedaWording) == nil)
    }

    @Test func employeesJoinUnavailableWhenDepartmentsDoNotMatchSingleSegment() {
        #expect(
            SegmentNotePatternClassifier.employeesJoinUnavailable(
                segmentLabels: ["食品事業"],
                employeeLabels: ["研究開発", "製造", "販売"]))
        #expect(
            !SegmentNotePatternClassifier.employeesJoinUnavailable(
                segmentLabels: ["医薬品事業"],
                employeeLabels: ["医薬品事業"]))
        #expect(
            !SegmentNotePatternClassifier.employeesJoinUnavailable(
                segmentLabels: ["G&NS", "音楽"],
                employeeLabels: ["G&NS", "音楽"]))
    }
}

final class FakeSegmentNotePatternDecider: SegmentNotePatternDeciding, @unchecked Sendable {
    let selected: String
    let probability: Double
    private let lock = NSLock()
    private var calls = 0

    init(selected: String, probability: Double = 0.95) {
        self.selected = selected
        self.probability = probability
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    private func bump() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    func classifyDisclosure(
        prose: String, axis: SegmentNotePatternAxis
    ) async -> SegmentNoteConsultedChoice {
        bump()
        return SegmentNoteConsultedChoice(
            question: SegmentNotePatternClassifier.question,
            selected: selected, probability: probability,
            options: axis.optionKeys, sentences: [prose])
    }
}
