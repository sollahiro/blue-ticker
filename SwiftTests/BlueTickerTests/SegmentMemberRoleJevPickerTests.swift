// 会社拡張の調整・消去・全社 member の Jev 判定: 候補の作り方と、コード側の採否（外部売上）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct SegmentMemberRoleJevPickerTests {
    private func fact(_ member: String, _ value: Double, tag: String = "RevenueFromExternalCustomersIFRS") -> BreakdownFact {
        BreakdownFact(
            tag: tag, contextRef: "CurrentYearDuration_\(member)",
            dimensions: ["OperatingSegmentsAxis": member], value: value)
    }

    @Test func noCandidatesWhenStandardReconcilingMemberExists() {
        let facts = [fact("AReportableSegmentMember", 100), fact("BReportableSegmentMember", 50),
                     fact("ReconcilingItemsMember", 0)]
        #expect(SegmentMemberRoleJevPicker.candidates(facts: facts, labelsByTag: [:]).isEmpty)
    }

    @Test func extensionMembersAreCandidatesWithoutStandardReconcilingMember() {
        let facts = [fact("AReportableSegmentMember", 100), fact("BReportableSegmentMember", 50),
                     fact("CorporateAndEliminationMember", 0)]
        let members = SegmentMemberRoleJevPicker.candidates(facts: facts, labelsByTag: [:]).map(\.member)
        #expect(members == ["AReportableSegmentMember", "BReportableSegmentMember", "CorporateAndEliminationMember"])
    }

    @Test func gateRejectsMembersWithoutRevenueEvidence() {
        let withRevenue = [
            SegmentMemberRoleCandidate(key: "m0", member: "A", label: "A", externalRevenueMillionYen: 100),
            SegmentMemberRoleCandidate(key: "m1", member: "E", label: "消去", externalRevenueMillionYen: 0),
        ]
        #expect(SegmentMemberRoleJevPicker.externalRevenueIsNegligible(withRevenue[1], among: withRevenue))
        #expect(!SegmentMemberRoleJevPicker.externalRevenueIsNegligible(withRevenue[0], among: withRevenue))
        let noRevenue = [
            SegmentMemberRoleCandidate(key: "m0", member: "A", label: "A", externalRevenueMillionYen: nil),
            SegmentMemberRoleCandidate(key: "m1", member: "E", label: "消去", externalRevenueMillionYen: nil),
        ]
        #expect(!SegmentMemberRoleJevPicker.externalRevenueIsNegligible(noRevenue[1], among: noRevenue))
    }

    private struct UnavailableDecider: SegmentMemberRoleDeciding {
        func chooseReconcilingMember(
            candidates: [SegmentMemberRoleCandidate], docID: String
        ) async -> JevChoiceAggregate.Sample {
            JevChoiceAggregate.Sample(
                selected: nil, probability: nil,
                options: candidates.map(\.key) + [JevDecision.noneOfThese], model: "m")
        }
    }

    @Test func allSamplesFailedIsUnavailableNotFailClosed() async {
        let candidates = [
            SegmentMemberRoleCandidate(key: "m0", member: "A", label: "A", externalRevenueMillionYen: 100),
            SegmentMemberRoleCandidate(key: "m1", member: "E", label: "消去", externalRevenueMillionYen: 0),
        ]
        let result = await SegmentMemberRoleJevPicker.pick(
            candidates: candidates, decider: UnavailableDecider(), docID: "S1")
        #expect(result.unavailable)
        #expect(result.members.isEmpty)
        #expect(result.sentences == ["member_role_jev=unavailable"])
    }
}
