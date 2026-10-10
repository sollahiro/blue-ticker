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
        #expect(
            InterestBearingDebtBreakdown.maturityClass(
                fromLabel: "リース債務(１年以内返済予定のものを除く。)") == "non_current")
        // 素の長期借入金・社債は1年内分を含み得る。裸の「除く」は非流動にしない。
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "長期借入金") == nil)
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "社債") == nil)
        #expect(
            InterestBearingDebtBreakdown.maturityClass(
                fromLabel: "長期借入金（ノンリコース債務を除く）") == nil)
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

    @Test func bankComponentsResolveWithoutReview() async throws {
        let inputs = IBDInputs(
            consolidated: true, isBank: true,
            bankComponents: [
                candidate(
                    "預金", tag: "DepositsLiabilitiesBNK", closing: 1_000_000_000_000,
                    source: ibdRowSourceFinancialsBankComponents,
                    preset: .interestBearingDebt),
                candidate(
                    "借用金", tag: "BorrowedMoneyBNK", closing: 200_000_000_000,
                    source: ibdRowSourceFinancialsBankComponents,
                    preset: .interestBearingDebt),
            ],
            balanceSheet: [], schedule: [], leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil)
        let (payload, audit) = try resolvedWithAudit(resolution)
        #expect(payload.needsReview == false)
        #expect(payload.denominatorTag == "bank_components")
        #expect(payload.rows.last?.closing == 1_200_000_000_000)
        #expect(payload.rows.dropLast().allSatisfy { $0.debtSource == ibdRowSourceFinancialsBankComponents })
        #expect(audit.sentences.contains("bank_components"))
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

    @Test func scheduleWithoutBondsTakesBalanceSheetBondRows() async throws {
        // J-GAAP の借入金等明細表は社債を含まない（AZplanning 型）。BS の社債単独行を足す。
        // 「社債及び借入金」のような合算行は借入金と二重になるので足さない。
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 1_000),
                bs("社債", tag: "BondsPayable", closing: 30, maturity: ibdMaturityNonCurrent),
            ],
            schedule: [schedule("短期借入金", closing: 1_000, rate: 1.5)],
            leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == false)
        let rows = payload.rows.dropLast()
        #expect(rows.map(\.label) == ["短期借入金", "社債"])
        #expect(rows.map(\.debtSource) == [ibdRowSourceBorrowingsSchedule, ibdRowSourceBalanceSheet])
        #expect(payload.rows.last?.closing == 1_030)

        let combined = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [bs("社債及び借入金", tag: "BondsAndBorrowingsCLIFRS", closing: 1_000)],
            schedule: [schedule("短期借入金", closing: 1_000)],
            leaseNote: nil)
        let combinedPayload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: combined, decider: nil))
        #expect(combinedPayload.rows.last?.closing == 1_000)
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
        #expect(payload.warnings == [breakdownWarningIBDLeaseDenominatorFromNotes])
        #expect(payload.rows.last?.closing == 6_279_000_000)
        #expect(payload.denominator == 6_279_000_000)
    }

    @Test func jevClassifiedBalanceSheetLineIsExcludedFromDenominator() async throws {
        // 会社タグを Jev が債務と答えても、分母はコード分類の BS 行だけ。
        // 行は残るので coverage は帯外になり needs_review。
        let decider = StubIBDDecider(
            rows: ["長期借入債務": IBDChoice(
                selected: IBDRowClass.interestBearingDebt.rawValue, probability: 0.95)],
            nearDuplicate: IBDChoice(selected: nil, probability: nil))
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 100),
                candidate(
                    "長期借入債務", tag: "LongTermDebt2NCLIFRS", closing: 900,
                    source: ibdRowSourceBalanceSheet, preset: nil),
            ],
            schedule: [
                schedule("短期借入金", closing: 100),
                schedule("長期借入債務", closing: 900),
            ],
            leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: decider))
        #expect(payload.rows.contains { $0.label == "長期借入債務" && $0.rowKind == "segment" })
        #expect(payload.denominator == 100)
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDCoverageOutOfBand))
    }

    @Test func leaseSourcesDifferBeyondToleranceNeedsReview() async throws {
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 1_000),
                candidate(
                    "リース負債", tag: "LeaseLiabilitiesCLIFRS", closing: 100,
                    source: ibdRowSourceBalanceSheet, preset: .leaseLiability),
            ],
            schedule: [
                schedule("短期借入金", closing: 1_000),
                candidate(
                    "リース負債", closing: 80,
                    source: ibdRowSourceBorrowingsSchedule, preset: .leaseLiability),
            ],
            leaseNote: IBDLeaseNote(
                rows: [
                    candidate(
                        "リース負債", closing: 100,
                        source: ibdRowSourceLeaseNote, preset: .leaseLiability),
                ],
                total: 100, priorTotal: nil))
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDLeaseSourcesDiffer))
        #expect(payload.rows.contains {
            $0.label == "リース負債" && $0.debtSource == ibdRowSourceBorrowingsSchedule
                && $0.closing == 80
        })
    }

    @Test func totalOpeningIsNilWhenAnyRowLacksOpening() async throws {
        let inputs = IBDInputs(
            consolidated: true, financialInstitution: false,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 40),
                bs("長期借入金", tag: "LongTermLoansPayable", closing: 60),
            ],
            schedule: [
                candidate(
                    "短期借入金", closing: 40, source: ibdRowSourceBorrowingsSchedule,
                    preset: .interestBearingDebt, maturity: ibdMaturityCurrent, opening: 10),
                candidate(
                    "長期借入金", closing: 60, source: ibdRowSourceBorrowingsSchedule,
                    preset: .interestBearingDebt, opening: nil),
            ],
            leaseNote: nil)
        let missing = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(missing.rows.last?.opening == nil)
        #expect(missing.rows.last?.closing == 100)

        var complete = inputs
        complete.schedule[1].opening = 20
        let summed = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: complete, decider: nil))
        #expect(summed.rows.last?.opening == 30)
        #expect(summed.rows.last?.closing == 100)
    }

    @Test func jevRetryableBreakdownIsOnlyUnclassifiedOrNearDuplicate() {
        #expect(
            isJevRetryableBreakdown(
                axis: breakdownAxisInterestBearingDebt, needsReview: true,
                warnings: [breakdownWarningIBDRowUnclassified]))
        #expect(
            isJevRetryableBreakdown(
                axis: breakdownAxisInterestBearingDebt, needsReview: true,
                warnings: [breakdownWarningIBDNearDuplicateUnresolved]))
        #expect(
            !isJevRetryableBreakdown(
                axis: breakdownAxisInterestBearingDebt, needsReview: true,
                warnings: [breakdownWarningIBDCoverageOutOfBand]))
        #expect(
            !isJevRetryableBreakdown(
                axis: breakdownAxisInterestBearingDebt, needsReview: false,
                warnings: [breakdownWarningIBDRowUnclassified]))
        #expect(
            !isJevRetryableBreakdown(
                axis: breakdownAxisGeography, needsReview: true,
                warnings: [breakdownWarningIBDRowUnclassified]))
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

    @Test func financialsCanonicalInterestBearingDebtMapping() {
        let cleanPayload = canonicalPayload(total: 123, prior: 45, needsReview: false)
        let clean = BreakdownFinancialsResolver.canonicalInterestBearingDebt(
            resolution: .resolved(payload: cleanPayload, audit: canonicalAudit(needsReview: false)),
            inputs: IBDInputs(consolidated: true, balanceSheet: [], schedule: [], leaseNote: nil),
            accountingStandard: "J-GAAP",
            legacy: { IBDResult(total: 9, priorTotal: 8, components: [], method: "old", accountingStandard: "J-GAAP") })
        #expect(clean.total == 123)
        #expect(clean.priorTotal == 45)
        #expect(clean.method == "breakdown.interest_bearing_debt")

        let review = BreakdownFinancialsResolver.canonicalInterestBearingDebt(
            resolution: .resolved(
                payload: canonicalPayload(
                    total: 123, prior: nil, needsReview: true,
                    warnings: [breakdownWarningIBDRowUnclassified]),
                audit: canonicalAudit(needsReview: true)),
            inputs: IBDInputs(consolidated: true, balanceSheet: [], schedule: [], leaseNote: nil),
            accountingStandard: "IFRS",
            legacy: { IBDResult(total: 99, priorTotal: 88, components: [], method: "field_parser", accountingStandard: "IFRS") })
        #expect(review.total == 99)
        #expect(review.priorTotal == 88)
        #expect(review.method == "legacy_ibd_extractor_fallback")
        #expect(review.warnings.contains("legacy_ibd_extractor_fallback"))
        #expect(review.warnings.contains { $0.contains("unclassified") })

        let zeroDebt = BreakdownFinancialsResolver.canonicalInterestBearingDebt(
            resolution: .notApplicable(reason: breakdownNotApplicableNotFound),
            inputs: IBDInputs(
                consolidated: true, balanceSheet: [], schedule: [], leaseNote: nil,
                largeInstance: true),
            accountingStandard: "J-GAAP",
            legacy: { IBDResult(total: 99, priorTotal: 88, components: [], method: "old", accountingStandard: "J-GAAP") })
        #expect(zeroDebt.total == 0)
        #expect(zeroDebt.priorTotal == 0)
        #expect(zeroDebt.method == "zero_debt")
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
        preset: IBDRowClass?, rate: Double? = nil, maturity: String? = nil,
        opening: Double? = nil
    ) -> IBDCandidate {
        IBDCandidate(
            labelRaw: label, label: label, tag: tag, opening: opening, closing: closing,
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

    private func canonicalPayload(
        total: Double, prior: Double?, needsReview: Bool, warnings: [String] = []
    ) -> BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisInterestBearingDebt,
            denominator: total,
            denominatorTag: "balance_sheet.interest_bearing_debt",
            rows: [
                BreakdownRowPayload(
                    labelRaw: "合計", label: "合計", amount: total, profit: nil,
                    rowKind: "subtotal", opening: prior, closing: total),
            ],
            sourceKind: breakdownSourceXbrlFacts,
            needsReview: needsReview,
            warnings: warnings)
    }

    private func canonicalAudit(needsReview: Bool) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: "", docID: "", axis: breakdownAxisInterestBearingDebt,
            model: Api.openrouterDecisionsModel,
            threshold: SegmentNoteDecision.applyProbabilityThreshold,
            applied: false,
            needsReview: needsReview,
            sentences: needsReview ? ["unclassified balance_sheet: 長期借入債務 closing=824393000000"] : [],
            calls: [],
            decisionSource: "test")
    }

    private enum ResolutionError: Error { case notResolved }
}
