// 有利子負債内訳の純関数テスト（XBRL ファイルは使わない）。

import Testing
import Foundation
@testable import BlueTickerCore

/// ラベル辞書で分類を返す決定論スタブ。Sendable のため辞書は `let`。
private struct StubIBDDecider: InterestBearingDebtDeciding {
    let rows: [String: IBDChoice]
    let nearDuplicate: IBDChoice

    func classifyRow(
        label: String, source: String, tag: String?, closingYen: Double?,
        siblingLabels: [String]
    ) async -> IBDChoice {
        rows[label] ?? IBDChoice(selected: nil, probability: nil)
    }

    func classifyNearDuplicate(
        scheduleLabel: String, scheduleYen: Double, leaseNoteLabel: String, leaseNoteYen: Double
    ) async -> IBDChoice {
        nearDuplicate
    }
}

@Suite struct InterestBearingDebtBreakdownTests {
    @Test func maturityClassFromLabel() {
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "１年内返済予定の長期借入金") == "current")
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "１年以内に返済予定の長期借入金") == "current")
        #expect(
            InterestBearingDebtBreakdown.maturityClass(
                fromLabel: "長期借入金（１年以内に返済予定のものを除く。）") == "non_current")
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "リース負債（非流動）") == "non_current")
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "短期借入金") == "current")
        // 素の長期借入金・社債は1年内分を含み得る
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "長期借入金") == nil)
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "社債") == nil)
    }

    @Test func maturityClassFromTag() {
        #expect(InterestBearingDebtBreakdown.maturityClass(fromTag: "ShortTermLoansPayable") == "current")
        #expect(
            InterestBearingDebtBreakdown.maturityClass(fromTag: "BondsAndBorrowingsCLIFRS") == "current")
        #expect(InterestBearingDebtBreakdown.maturityClass(fromTag: "LongTermLoansPayable") == "non_current")
        #expect(
            InterestBearingDebtBreakdown.maturityClass(fromTag: "BondsAndBorrowingsNCLIFRS")
                == "non_current")
        #expect(InterestBearingDebtBreakdown.maturityClass(fromTag: "InterestBearingDebt") == nil)
    }

    @Test func scheduleRowPreset() {
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("短期借入金") == .interestBearingDebt)
        // 非有利子の典型はコードで確定せず Jev に回す
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("デリバティブ負債") == nil)
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("カナダ訴訟の和解金に係る負債") == nil)
    }

    @Test func financialInstitutionIsNotApplicable() async {
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: true,
            balanceSheet: [], schedule: [], leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil)
        guard case .notApplicable(let reason) = resolution else {
            Issue.record("expected notApplicable, got \(resolution)")
            return
        }
        #expect(reason == breakdownNotApplicableFinancialInstitution)
    }

    @Test func scheduleWithinBandResolvesWithoutReview() async throws {
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 100_000_000_000),
                bs("長期借入金", tag: "LongTermLoansPayable", closing: 900_000_000_000),
            ],
            schedule: [
                schedule("短期借入金", closing: 100_000_000_000, rate: 0.5),
                schedule("長期借入金", closing: 900_000_000_000, rate: 1.2),
            ],
            leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil)
        let payload = try resolved(resolution)
        #expect(payload.needsReview == false)
        #expect(payload.warnings.isEmpty)
        let total = try #require(payload.rows.last)
        #expect(total.label == "合計")
        #expect(total.rowKind == "subtotal")
        #expect(total.closing == 1_000_000_000_000)
        #expect(total.averageRate == nil)
        let jsonRows = try #require(
            payload.jsonObject()["rows"] as? [[String: Any]])
        let totalJSON = try #require(jsonRows.last)
        #expect(totalJSON["average_rate"] is NSNull)
        let segment = try #require(jsonRows.first)
        #expect(segment["opening"] is NSNull || segment["opening"] is Double)
        #expect(segment.keys.contains("opening"))
        #expect(segment.keys.contains("closing"))
        #expect(segment.keys.contains("average_rate"))
        #expect(segment.keys.contains("source"))
        #expect(segment.keys.contains("maturity_class"))
        #expect(segment["source"] as? String == ibdRowSourceBorrowingsSchedule)
        #expect(segment["closing"] as? Double == 100_000_000_000)
        #expect(segment["average_rate"] as? Double == 0.5)
        #expect(segment["maturity_class"] as? String == ibdMaturityCurrent)
    }

    @Test func scheduleOutsideBandFallsBackToBalanceSheet() async throws {
        // 明細表は分母の帯外。BS はコード分類済みなので BS 主に差し替える。
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 200_000_000_000),
                bs("長期借入金", tag: "LongTermLoansPayable", closing: 800_000_000_000),
            ],
            schedule: [
                schedule("短期借入金", closing: 50_000_000_000),
            ],
            leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil)
        let (payload, audit) = try resolvedWithAudit(resolution)
        #expect(payload.needsReview == false)
        #expect(payload.warnings == [breakdownWarningIBDScheduleRejected])
        #expect(payload.rows.filter { $0.rowKind == "segment" }.allSatisfy {
            $0.debtSource == ibdRowSourceBalanceSheet
        })
        #expect(payload.rows.last?.closing == 1_000_000_000_000)
        #expect(audit.sentences.contains { $0.contains("schedule_rejected") })
    }

    @Test func coverageOutOfBandWithUnclassifiableBalanceSheetNeedsReview() async throws {
        // BS に未分類行があり差し替えできない。明細表のまま帯外で needs_review。
        // 分母を作るため、分類済みの BS 債務行も置く（未分類だけでは分母が nil）。
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 1_000_000_000_000),
                candidate(
                    "その他の借入関連負債", tag: "OtherBorrowings", closing: 50_000_000_000,
                    source: ibdRowSourceBalanceSheet, preset: nil),
            ],
            schedule: [
                schedule("短期借入金", closing: 100_000_000_000),
            ],
            leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil)
        let payload = try resolved(resolution)
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDCoverageOutOfBand))
        #expect(payload.warnings.contains(breakdownWarningIBDRowUnclassified))
    }

    @Test func nilDeciderLeavesAmbiguousRowUnclassified() async throws {
        // 未分類行を落としても残りの明細表は分母の帯内。BS へは落ちない。
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 80_000_000_000),
            ],
            schedule: [
                schedule("短期借入金", closing: 80_000_000_000),
                candidate(
                    "カナダ訴訟の和解金に係る負債", closing: 20_000_000_000,
                    source: ibdRowSourceBorrowingsSchedule, preset: nil),
            ],
            leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil)
        let payload = try resolved(resolution)
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDRowUnclassified))
        // 未解決行は金額を変えず、行にも載せない
        let segments = payload.rows.filter { $0.rowKind == "segment" }
        #expect(segments.count == 1)
        #expect(segments[0].label == "短期借入金")
        #expect(segments[0].closing == 80_000_000_000)
    }

    @Test func belowThresholdDeciderIsUnclassified() async throws {
        let decider = StubIBDDecider(
            rows: ["カナダ訴訟の和解金に係る負債": IBDChoice(
                selected: IBDRowClass.notInterestBearing.rawValue, probability: 0.6)],
            nearDuplicate: IBDChoice(selected: nil, probability: nil))
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 100_000_000_000),
            ],
            schedule: [
                schedule("短期借入金", closing: 100_000_000_000),
                candidate(
                    "カナダ訴訟の和解金に係る負債", closing: 5_000_000_000,
                    source: ibdRowSourceBorrowingsSchedule, preset: nil),
            ],
            leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(
            inputs: inputs, decider: decider)
        let payload = try resolved(resolution)
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDRowUnclassified))
        #expect(payload.rows.filter { $0.rowKind == "segment" }.map(\.label) == ["短期借入金"])
        #expect(payload.rows.last?.closing == 100_000_000_000)
    }

    @Test func nearDuplicateSameLiabilityKeepsOneLeaseRow() async throws {
        let decider = StubIBDDecider(
            rows: [:],
            nearDuplicate: IBDChoice(selected: IBDDuplicateRole.sameLiability, probability: 0.95))
        let resolution = await InterestBearingDebtBreakdown.resolve(
            inputs: nearDuplicateInputs(), decider: decider)
        let (payload, audit) = try resolvedWithAudit(resolution)
        #expect(payload.needsReview == false)
        let leaseRows = payload.rows.filter { $0.label.contains("リース") }
        #expect(leaseRows.count == 1)
        #expect(leaseRows[0].closing == 74_540_000_000)
        #expect(leaseRows[0].debtSource == ibdRowSourceBorrowingsSchedule)
        let joined = audit.sentences.joined(separator: " ")
        #expect(joined.contains("74540000000"))
        #expect(joined.contains("74151000000"))
    }

    @Test func nearDuplicateLowProbabilityNeedsReview() async throws {
        let decider = StubIBDDecider(
            rows: [:],
            nearDuplicate: IBDChoice(selected: IBDDuplicateRole.sameLiability, probability: 0.5))
        let resolution = await InterestBearingDebtBreakdown.resolve(
            inputs: nearDuplicateInputs(), decider: decider)
        let payload = try resolved(resolution)
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDNearDuplicateUnresolved))
    }

    @Test func maturitySplitIsCountedOnceInTotal() async throws {
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs(
                    "有利子負債", tag: "InterestBearingDebtCL", closing: 100,
                    maturity: ibdMaturityCurrent),
                bs(
                    "有利子負債", tag: "InterestBearingDebtNCL", closing: 200,
                    maturity: ibdMaturityNonCurrent),
            ],
            schedule: [], leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil)
        let payload = try resolved(resolution)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 300)
        #expect(payload.denominator == 300)
    }

    @Test func zeroDenominatorIsCoverageUnavailable() async throws {
        // BS の有利子負債が 0 だけのとき 0/0 を帯内にしない
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                candidate(
                    "リース債務", tag: "LeaseObligationsCL", closing: 0,
                    source: ibdRowSourceBalanceSheet, preset: .leaseLiability),
            ],
            schedule: [], leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDCoverageUnavailable))
        #expect(!payload.warnings.contains(breakdownWarningIBDCoverageOutOfBand))
    }

    @Test func balanceSheetWithoutLeaseLineUsesScheduleLeaseRows() async throws {
        // BS にリース科目が無く明細表にだけリース行がある。分母と同じ行を載せる。
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("社債", tag: "BondsPayable", closing: 5_000_000_000),
            ],
            schedule: [
                candidate(
                    "リース負債（流動）", closing: 550_000_000,
                    source: ibdRowSourceBorrowingsSchedule, preset: .leaseLiability),
                candidate(
                    "リース負債（非流動）", closing: 729_000_000,
                    source: ibdRowSourceBorrowingsSchedule, preset: .leaseLiability),
            ],
            leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 6_279_000_000)
        #expect(payload.denominator == 6_279_000_000)
    }

    @Test func unresolvedScheduleRowNeedsReviewEvenWhenBalanceSheetIsPrimary() async throws {
        // 明細表に債務行が無く BS 主でも、明細表の未分類行（割賦未払金等）は落とさず needs_review
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                candidate(
                    "リース債務", tag: "LeaseObligationsCL", closing: 64_000_000,
                    source: ibdRowSourceBalanceSheet, preset: .leaseLiability),
            ],
            schedule: [
                candidate(
                    "１年以内に返済予定の割賦未払金", closing: 307_000_000,
                    source: ibdRowSourceBorrowingsSchedule, preset: nil),
            ],
            leaseNote: nil)
        let (payload, audit) = try resolvedWithAudit(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDRowUnclassified))
        #expect(audit.sentences.contains { $0.contains("unclassified") && $0.contains("307000000") })
    }

    @Test func publicServabilityFailsClosedOnNeedsReview() {
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceXbrlFacts, needsReview: true, warnings: [],
                axis: breakdownAxisInterestBearingDebt) == false)
        #expect(
            isPubliclyServableBreakdown(
                source: breakdownSourceXbrlFacts, needsReview: false, warnings: [],
                axis: breakdownAxisInterestBearingDebt) == true)
    }

    @Test func axisIsSupportedAndCacheVersionIsV1() {
        #expect(isSupportedBreakdownAxis(breakdownAxisInterestBearingDebt))
        #expect(interestBearingDebtBreakdownCacheVersion == "breakdown-interest-bearing-debt-v1")
    }

    // MARK: - helpers

    private func bs(
        _ label: String, tag: String, closing: Double, maturity: String? = nil
    ) -> IBDCandidate {
        candidate(
            label, tag: tag, closing: closing, source: ibdRowSourceBalanceSheet,
            preset: .interestBearingDebt, maturity: maturity)
    }

    private func schedule(
        _ label: String, closing: Double, rate: Double? = nil
    ) -> IBDCandidate {
        candidate(
            label, closing: closing, source: ibdRowSourceBorrowingsSchedule,
            preset: .interestBearingDebt, rate: rate,
            maturity: InterestBearingDebtBreakdown.maturityClass(fromLabel: label))
    }

    private func candidate(
        _ label: String, tag: String? = nil, closing: Double, source: String,
        preset: IBDRowClass?, rate: Double? = nil, maturity: String? = nil
    ) -> IBDCandidate {
        IBDCandidate(
            labelRaw: label, label: label, tag: tag, opening: nil, closing: closing,
            averageRatePercent: rate, source: source, maturityClass: maturity, presetClass: preset)
    }

    /// 明細表リース 74,540 と注記合計 74,151（相対差 2% 以内）。
    private func nearDuplicateInputs() -> IBDInputs {
        IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 79_444_000_000),
                candidate(
                    "リース負債", tag: "LeaseLiabilitiesCLIFRS", closing: 74_151_000_000,
                    source: ibdRowSourceBalanceSheet, preset: .leaseLiability,
                    maturity: ibdMaturityCurrent),
            ],
            schedule: [
                schedule("短期借入金", closing: 79_444_000_000),
                candidate(
                    "リース負債", closing: 74_540_000_000,
                    source: ibdRowSourceBorrowingsSchedule, preset: .leaseLiability),
            ],
            leaseNote: IBDLeaseNote(
                rows: [
                    candidate(
                        "リース負債", closing: 74_151_000_000,
                        source: ibdRowSourceLeaseNote, preset: .leaseLiability),
                ],
                total: 74_151_000_000, priorTotal: nil))
    }

    private func resolved(_ resolution: IBDResolution) throws -> BreakdownSnapshotPayload {
        try resolvedWithAudit(resolution).payload
    }

    private func resolvedWithAudit(_ resolution: IBDResolution) throws -> (
        payload: BreakdownSnapshotPayload, audit: SegmentNoteJevAuditPayload
    ) {
        guard case .resolved(let payload, let audit) = resolution else {
            Issue.record("expected resolved, got \(String(describing: resolution))")
            throw ResolutionError.notResolved
        }
        return (payload, audit)
    }

    private enum ResolutionError: Error { case notResolved }
}
