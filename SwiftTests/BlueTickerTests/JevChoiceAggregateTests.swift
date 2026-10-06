import Foundation
import Testing
@testable import BlueTickerCore

@Suite("JevChoiceAggregate")
struct JevChoiceAggregateTests {
    private func sample(_ selected: String?, _ probability: Double?) -> JevChoiceAggregate.Sample {
        JevChoiceAggregate.Sample(selected: selected, probability: probability)
    }

    @Test("同じ selected が揃えば agreed、中央値を返す")
    func unanimousUsesMedian() {
        let result = JevChoiceAggregate.combine([
            sample("t0_c2", 0.27),
            sample("t0_c2", 0.49),
            sample("t0_c2", 0.44),
        ])
        #expect(result.outcome == .agreed)
        #expect(result.isConfident)
        #expect(result.selected == "t0_c2")
        #expect(result.probability == 0.44)
        #expect(result.successfulCount == 3)
        #expect(result.unanimous)
    }

    @Test("selected が割れたら disagreement")
    func disagreementIsNotConfident() {
        let result = JevChoiceAggregate.combine([
            sample("t0_c1", 0.9),
            sample("t0_c2", 0.9),
            sample("t0_c1", 0.8),
        ])
        #expect(result.outcome == .disagreement)
        #expect(!result.isConfident)
        #expect(result.selected == "t0_c1")
        #expect(result.successfulCount == 3)
    }

    @Test("成功 1 件は insufficient")
    func oneSuccessIsInsufficient() {
        let result = JevChoiceAggregate.combine([
            sample(nil, nil),
            sample("t0_c2", 0.9),
            sample(nil, nil),
        ])
        #expect(result.outcome == .insufficient)
        #expect(!result.isConfident)
        #expect(result.selected == "t0_c2")
        #expect(result.successfulCount == 1)
    }

    @Test("全部欠測は allFailed")
    func allFailedHasNoSelected() {
        let result = JevChoiceAggregate.combine([
            sample(nil, nil),
            sample("", 0.9),
            sample("   ", 0.4),
        ])
        #expect(result.outcome == .allFailed)
        #expect(result.selected == nil)
        #expect(result.successfulCount == 0)
    }

    @Test("偶数列の中央値は中2件の平均")
    func evenMedianAveragesMiddle() {
        #expect(JevChoiceAggregate.median([0.2, 0.8, 0.4, 0.6]) == 0.5)
        #expect(JevChoiceAggregate.median([]) == nil)
        #expect(JevChoiceAggregate.median([0.7]) == 0.7)
    }
}
