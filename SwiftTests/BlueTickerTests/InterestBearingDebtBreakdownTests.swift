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
            consolidated: true,
            balanceSheet: [
                // 合算科目は入れ子の親にしない（明細表の内訳をそのまま数える）
                bs("社債及び借入金", tag: "BondsAndBorrowingsCLIFRS", closing: 100_000_000_000),
                bs("社債及び借入金", tag: "BondsAndBorrowingsNCLIFRS", closing: 900_000_000_000),
            ],
            schedule: [
                schedule("短期借入金", closing: 100_000_000_000),
                schedule("長期借入金", closing: 900_000_000_000),
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
        #expect(total.inTotal == nil)
        let jsonRows = try #require(
            payload.jsonObject()["rows"] as? [[String: Any]])
        let totalJSON = try #require(jsonRows.last)
        #expect(!totalJSON.keys.contains("average_rate"))
        let segment = try #require(jsonRows.first)
        #expect(segment["opening"] is NSNull || segment["opening"] is Double)
        #expect(segment.keys.contains("opening"))
        #expect(segment.keys.contains("closing"))
        #expect(!segment.keys.contains("average_rate"))
        #expect(segment["in_total"] as? Bool == true)
        #expect(segment["excluded_reason"] is NSNull)
        #expect(segment["paired_row_index"] is NSNull)
        #expect(segment.keys.contains("source"))
        #expect(segment.keys.contains("maturity_class"))
        #expect(segment["source"] as? String == ibdRowSourceBorrowingsSchedule)
        #expect(segment["closing"] as? Double == 100_000_000_000)
        #expect(segment["maturity_class"] as? String == ibdMaturityCurrent)
    }

    @Test func scheduleWithoutBondsTakesBalanceSheetBondRows() async throws {
        // J-GAAP の借入金等明細表は社債を含まない（AZplanning 型）。BS の社債単独行を足す。
        // 「社債及び借入金」のような合算行は借入金と二重になるので足さない。
        let inputs = IBDInputs(
            consolidated: true,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 1_000),
                bs("社債", tag: "BondsPayable", closing: 30, maturity: ibdMaturityNonCurrent),
            ],
            schedule: [schedule("短期借入金", closing: 1_000)],
            leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == false)
        // BS 短期借入金が親として数え、明細表の短期借入金は同額の内訳
        let rows = payload.rows.dropLast().filter { $0.inTotal == true }
        #expect(rows.map(\.label) == ["短期借入金", "社債"])
        #expect(rows.map(\.debtSource) == [ibdRowSourceBalanceSheet, ibdRowSourceBalanceSheet])
        #expect(payload.rows.last?.closing == 1_030)
        expectInvariants(payload)

        let combined = IBDInputs(
            consolidated: true,
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
            consolidated: true,
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

    @Test func unclassifiableBalanceSheetRowNeedsReviewAfterBalanceSheetWins() async throws {
        // 同じ区分で明細表の和と BS が食い違うので BS の短期借入金を数える（明細表行は scope_differs）。
        // BS に未分類行が残るので needs_review。
        // 分母を作るため、分類済みの BS 債務行も置く（未分類だけでは分母が nil）。
        let inputs = IBDInputs(
            consolidated: true,
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
        #expect(payload.warnings.contains(breakdownWarningIBDRowUnclassified))
        let counted = payload.rows.filter { $0.inTotal == true }
        #expect(counted.map(\.debtSource) == [ibdRowSourceBalanceSheet])
        #expect(counted.map(\.closing) == [1_000_000_000_000])
        let excluded = try #require(payload.rows.first { $0.inTotal == false })
        #expect(excluded.debtSource == ibdRowSourceBorrowingsSchedule)
        #expect(excluded.excludedReason == ibdExcludedReasonScopeDiffers)
        #expect(excluded.pairedRowIndex == 0)
        expectInvariants(payload)
    }

    @Test func nilDeciderLeavesAmbiguousRowUnclassified() async throws {
        // 未分類行を落としても残りの明細表は分母の帯内。BS へは落ちない。
        let inputs = IBDInputs(
            consolidated: true,
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
        let segments = payload.rows.filter { $0.rowKind == "segment" && $0.inTotal == true }
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
            consolidated: true,
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
        #expect(payload.rows.filter { $0.rowKind == "segment" && $0.inTotal == true }.map(\.label) == ["短期借入金"])
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
        let leaseRows = payload.rows.filter { $0.label.contains("リース") && $0.inTotal == true }
        #expect(leaseRows.count == 1)
        #expect(leaseRows[0].closing == 74_540_000_000)
        #expect(leaseRows[0].debtSource == ibdRowSourceBorrowingsSchedule)
        // 注記側は別表の同じ負債として残し、合計に入れない
        let noteRow = try #require(payload.rows.first { $0.debtSource == ibdRowSourceLeaseNote })
        #expect(noteRow.inTotal == false)
        #expect(noteRow.excludedReason == ibdExcludedReasonOtherTable)
        #expect(payload.rows.last?.closing == 153_984_000_000)
        expectInvariants(payload)
        let joined = audit.sentences.joined(separator: " ")
        #expect(joined.contains("74540000000"))
        #expect(joined.contains("74151000000"))
    }

    /// 受入保証金・預り保証金はラベルで非有利子に確定（Jev に聞かない）。他の曖昧ラベルは nil（Jev）。
    @Test func depositLabelsAreDeterministicallyNonInterestBearing() {
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("長期受入保証金") == .notInterestBearing)
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("預り保証金（注３）") == .notInterestBearing)
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("預り金") == nil)
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("デリバティブ負債") == nil)
    }

    /// B6: 明細表に当期末値が無い CP・短期借入金は BS 行を足し、明細表行は duplicate_of_balance_sheet。
    @Test func balanceSheetCommercialPaperAndShortTermAreAddedBack() async throws {
        let balanceSheet = [
            bs("短期借入金", tag: "ShortTermLoansPayable", closing: 383_000_000),
            bs("コマーシャル・ペーパー", tag: "CommercialPapersLiabilities", closing: 5_932_000_000),
            bs("長期借入金", tag: "LongTermLoansPayable", closing: 160_000_000_000),
        ]
        let noClosing = IBDInputs(
            consolidated: true,
            balanceSheet: balanceSheet,
            schedule: [
                IBDCandidate(
                    labelRaw: "短期借入金", label: "短期借入金", tag: nil, opening: 542_000_000,
                    closing: nil, source: ibdRowSourceBorrowingsSchedule,
                    maturityClass: ibdMaturityCurrent, presetClass: .interestBearingDebt),
                schedule("長期借入金（１年以内に返済予定のものを除く。）", closing: 160_000_000_000),
            ],
            leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: noClosing, decider: nil))
        #expect(payload.rows.last?.closing == 166_315_000_000)
        let addedBack = payload.rows.filter { $0.debtSource == ibdRowSourceBalanceSheet && $0.inTotal == true }
        #expect(Set(addedBack.map(\.label)) == ["短期借入金", "コマーシャル・ペーパー", "長期借入金"])
        let dup = try #require(payload.rows.first {
            $0.debtSource == ibdRowSourceBorrowingsSchedule && $0.label == "短期借入金"
        })
        #expect(dup.inTotal == false)
        #expect(dup.excludedReason == ibdExcludedReasonDuplicateOfBalanceSheet)
        expectInvariants(payload)
    }

    /// BS のリース科目は明細表リースに勝つ。同額は duplicate_of_balance_sheet、違えば scope_differs。
    /// 区分の無い明細表リース行が BS リース科目1行と同額なら duplicate でその行を対応先にする。
    /// 残りは対応した BS 行を除いた和と比べ、対応先は付けない。
    @Test func unbucketedLeaseRowMatchingOneBalanceSheetRowIsDuplicate() {
        let bsCurrent = candidate(
            "リース債務", tag: "LeaseObligationsCL", closing: 756_000_000,
            source: ibdRowSourceBalanceSheet, preset: .leaseLiability, maturity: ibdMaturityCurrent)
        let bsNonCurrent = candidate(
            "リース債務", tag: "LeaseObligationsNCL", closing: 1_102_000_000,
            source: ibdRowSourceBalanceSheet, preset: .leaseLiability, maturity: ibdMaturityNonCurrent)
        let matching = candidate(
            "リース債務（一年以内）", closing: 756_000_000,
            source: ibdRowSourceBorrowingsSchedule, preset: .leaseLiability)
        let other = candidate(
            "リース債務（その他）", closing: 1_000_000_000,
            source: ibdRowSourceBorrowingsSchedule, preset: .leaseLiability)
        let result = InterestBearingDebtBreakdown.reconcileLease(
            balanceSheet: [bsCurrent, bsNonCurrent], schedule: [matching, other], note: [])
        #expect(result.included == [bsCurrent, bsNonCurrent])
        #expect(result.excluded == [
            .init(row: matching, reason: ibdExcludedReasonDuplicateOfBalanceSheet, pairedTo: bsCurrent),
            .init(row: other, reason: ibdExcludedReasonScopeDiffers, pairedTo: nil),
        ])
    }

    @Test func balanceSheetLeaseWinsOverScheduleLease() async throws {
        let inputs = IBDInputs(
            consolidated: true,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 1_000_000_000),
                candidate(
                    "リース債務", tag: "LeaseObligationsCL", closing: 756_000_000,
                    source: ibdRowSourceBalanceSheet, preset: .leaseLiability, maturity: ibdMaturityCurrent),
                candidate(
                    "リース債務", tag: "LeaseObligationsNCL", closing: 1_102_000_000,
                    source: ibdRowSourceBalanceSheet, preset: .leaseLiability,
                    maturity: ibdMaturityNonCurrent),
            ],
            schedule: [
                schedule("短期借入金", closing: 1_000_000_000),
                candidate(
                    "１年以内に返済予定のリース債務", closing: 756_000_000,
                    source: ibdRowSourceBorrowingsSchedule, preset: .leaseLiability,
                    maturity: ibdMaturityCurrent),
                candidate(
                    "リース債務（１年以内に返済予定のものを除く。）", closing: 507_000_000,
                    source: ibdRowSourceBorrowingsSchedule, preset: .leaseLiability,
                    maturity: ibdMaturityNonCurrent),
            ],
            leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.rows.last?.closing == 2_858_000_000)
        let excluded = payload.rows.filter { $0.inTotal == false && $0.label.contains("リース") }
        #expect(excluded.map(\.excludedReason) == [
            ibdExcludedReasonDuplicateOfBalanceSheet, ibdExcludedReasonScopeDiffers,
        ])
        for row in excluded {
            let paired = try #require(row.pairedRowIndex)
            #expect(payload.rows[paired].debtSource == ibdRowSourceBalanceSheet)
            #expect(payload.rows[paired].maturityClass == row.maturityClass)
        }
        expectInvariants(payload)
        // JSON でも合計行の 3 キーは null、除外行は理由と添字を持つ
        let json = try #require(payload.jsonObject()["rows"] as? [[String: Any]])
        let totalJSON = try #require(json.last)
        #expect(totalJSON["in_total"] is NSNull)
        #expect(totalJSON["excluded_reason"] is NSNull)
        let excludedJSON = json.filter { $0["in_total"] as? Bool == false }
        #expect(excludedJSON.count == 3)  // リース2行 + 明細表の短期借入金（BS 短期借入金の内訳）
        #expect(excludedJSON.allSatisfy { $0["excluded_reason"] is String && $0["paired_row_index"] is Int })
    }

    /// 入れ子: BS 短期借入金が明細表の短期借入金と1年内返済の長期借入金を含む。和が違っても
    /// BS 行を数え、内訳は scope_differs で親を指す。needs_review にせず差は監査だけ。
    @Test func nestedComponentsWithGapCountBalanceSheetLine() async throws {
        let inputs = IBDInputs(
            consolidated: true,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 128_000_000_000),
                bs("長期借入金", tag: "LongTermLoansPayable", closing: 900_000_000_000),
            ],
            schedule: [
                schedule("短期借入金", closing: 110_000_000_000),
                schedule("１年以内に返済予定の長期借入金", closing: 16_000_000_000),
                schedule("長期借入金（１年以内に返済予定のものを除く。）", closing: 900_000_000_000),
            ],
            leaseNote: nil)
        let (payload, audit) = try resolvedWithAudit(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == false)
        #expect(payload.warnings.isEmpty)
        #expect(payload.rows.last?.closing == 1_028_000_000_000)
        let parent = try #require(payload.rows.firstIndex { $0.debtSource == ibdRowSourceBalanceSheet && $0.label == "短期借入金" })
        #expect(payload.rows[parent].categoryGroup == "短期借入金")
        #expect(payload.rows[parent].category == nil)
        let components = payload.rows.filter { $0.pairedRowIndex == parent }
        #expect(components.map(\.label) == ["短期借入金", "１年以内に返済予定の長期借入金"])
        #expect(components.allSatisfy {
            $0.inTotal == false && $0.excludedReason == ibdExcludedReasonScopeDiffers
                && $0.categoryGroup == "短期借入金" && $0.category == $0.label
        })
        #expect(audit.sentences.contains {
            $0.contains("nesting_gap parent=短期借入金 balance_sheet=128000000000 components=126000000000 gap=2000000000")
        })
        let json = try #require(payload.jsonObject()["rows"] as? [[String: Any]])
        #expect(json[parent]["category_group"] as? String == "短期借入金")
        #expect(json[parent]["category"] is NSNull)
        expectInvariants(payload)
    }

    /// 親候補の BS 行が2行以上で決まらないときだけ needs_review。
    @Test func unresolvableNestingParentNeedsReview() async throws {
        let inputs = IBDInputs(
            consolidated: true,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 60),
                bs("短期借入金", tag: "ShortTermBorrowingsCLIFRS", closing: 40),
            ],
            schedule: [schedule("短期借入金", closing: 100)],
            leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains(breakdownWarningIBDNestingParentUnresolved))
    }

    /// 逆向き: 明細表「借入金」1行が BS の流動・非流動の2科目に跨る。BS を数え、明細行は親を
    /// 1行に決められないので対応先なし（category_group も付けない）。
    @Test func scheduleRowSpanningTwoBalanceSheetLines() async throws {
        let inputs = IBDInputs(
            consolidated: true,
            balanceSheet: [
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 996),
                bs("長期借入金", tag: "LongTermLoansPayable", closing: 12_447),
            ],
            schedule: [
                candidate("借入金", closing: 13_444, source: ibdRowSourceBorrowingsSchedule,
                    preset: .interestBearingDebt),
            ],
            leaseNote: nil)
        let payload = try resolved(
            await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil))
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 13_443)
        let row = try #require(payload.rows.first { $0.debtSource == ibdRowSourceBorrowingsSchedule })
        #expect(row.inTotal == false)
        #expect(row.excludedReason == ibdExcludedReasonDuplicateOfBalanceSheet)
        #expect(row.pairedRowIndex == nil)
        #expect(row.categoryGroup == nil)
        expectInvariants(payload)
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
            consolidated: true,
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
            consolidated: true,
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
            consolidated: true,
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
            consolidated: true,
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
            consolidated: true,
            balanceSheet: [
                // BS にリース科目が無いときだけ明細表と注記のリースを突き合わせる
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 1_000),
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
            consolidated: true,
            balanceSheet: [
                // 合算科目（入れ子の親にならない）なので明細表の期首で合計する
                bs("社債及び借入金", tag: "BondsAndBorrowingsCLIFRS", closing: 40),
                bs("社債及び借入金", tag: "BondsAndBorrowingsNCLIFRS", closing: 60),
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

    @Test func jevRetryStopsAtAttemptCap() {
        let warnings = [breakdownWarningIBDRowUnclassified]
        #expect(isJevRetryableBreakdown(
            axis: breakdownAxisInterestBearingDebt, needsReview: true, warnings: warnings,
            attempts: ibdJevRetryMaxAttempts - 1))
        #expect(!isJevRetryableBreakdown(
            axis: breakdownAxisInterestBearingDebt, needsReview: true, warnings: warnings,
            attempts: ibdJevRetryMaxAttempts))

        let jev = SegmentNoteJevAuditPayload(
            code: "", docID: "S100TEST", axis: breakdownAxisInterestBearingDebt, model: "m",
            threshold: 0.9, applied: false, needsReview: true, sentences: ["primary=balance_sheet"],
            calls: [])
        let base = LLMBreakdownAuditPayload.segmentNoteJev(jev)
        #expect(ibdJevRetryAttempts(base) == 0)
        #expect(ibdJevRetryAttempts(nil) == 0)
        #expect(stampingIBDJevRetryAttempt(base, attempt: 0) == base)
        let once = stampingIBDJevRetryAttempt(base, attempt: 1)
        #expect(ibdJevRetryAttempts(once) == 1)
        let twice = stampingIBDJevRetryAttempt(once, attempt: 2)
        #expect(ibdJevRetryAttempts(twice) == 2)
        #expect(twice?.jev?.sentences.filter { $0.hasPrefix(ibdJevRetryAttemptSentencePrefix) }.count == 1)
        #expect(twice?.jev?.sentences.first == "primary=balance_sheet")
    }

    @Test func unresolvedScheduleRowNeedsReviewEvenWhenBalanceSheetIsPrimary() async throws {
        // 明細表に債務行が無く BS 主でも、明細表の未分類行（割賦未払金等）は落とさず needs_review
        let inputs = IBDInputs(
            consolidated: true,
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

    @Test func axisIsSupportedAndCacheVersionIsV2() {
        #expect(isSupportedBreakdownAxis(breakdownAxisInterestBearingDebt))
        // v2: タクソノミ preset・リース込み有利子負債・除外リスト・source_tag（行の金額が変わる）
        #expect(interestBearingDebtBreakdownCacheVersion == "breakdown-interest-bearing-debt-v2")
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

        // 軸 not_found でも旧 Extractor が債務を拾えばその値（0 へ落とさない）。
        let notFound = BreakdownFinancialsResolver.canonicalInterestBearingDebt(
            resolution: .notApplicable(reason: breakdownNotApplicableNotFound),
            inputs: IBDInputs(consolidated: true, balanceSheet: [], schedule: [], leaseNote: nil),
            accountingStandard: "J-GAAP",
            legacy: { IBDResult(total: 99, priorTotal: 88, components: [], method: "field_parser", accountingStandard: "J-GAAP") })
        #expect(notFound.total == 99)
        #expect(notFound.priorTotal == 88)
        #expect(notFound.method == "legacy_ibd_extractor_fallback")
        #expect(notFound.warnings.contains("reason=\(breakdownNotApplicableNotFound)"))

        // 無借金は旧 Extractor の zero_debt をそのまま（印なし）。
        let zeroDebt = BreakdownFinancialsResolver.canonicalInterestBearingDebt(
            resolution: .notApplicable(reason: breakdownNotApplicableNotFound),
            inputs: IBDInputs(consolidated: true, balanceSheet: [], schedule: [], leaseNote: nil),
            accountingStandard: "J-GAAP",
            legacy: { IBDResult(total: 0, priorTotal: 0, components: [], method: "zero_debt", accountingStandard: "J-GAAP") })
        #expect(zeroDebt.total == 0)
        #expect(zeroDebt.priorTotal == 0)
        #expect(zeroDebt.method == "zero_debt")
        #expect(zeroDebt.warnings.isEmpty)
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
        _ label: String, closing: Double
    ) -> IBDCandidate {
        candidate(
            label, closing: closing, source: ibdRowSourceBorrowingsSchedule,
            preset: .interestBearingDebt,
            maturity: InterestBearingDebtBreakdown.maturityClass(fromLabel: label))
    }

    private func candidate(
        _ label: String, tag: String? = nil, closing: Double, source: String,
        preset: IBDRowClass?, maturity: String? = nil,
        opening: Double? = nil
    ) -> IBDCandidate {
        IBDCandidate(
            labelRaw: label, label: label, tag: tag, opening: opening, closing: closing,
            source: source, maturityClass: maturity, presetClass: preset)
    }

    /// 明細表リース 74,540 と注記合計 74,151（相対差 2% 以内）。
    private func nearDuplicateInputs() -> IBDInputs {
        IBDInputs(
            consolidated: true,
            balanceSheet: [
                // BS にリース科目が無い（あれば BS リースが勝ち近似重複は起きない。JT 型）
                bs("短期借入金", tag: "ShortTermLoansPayable", closing: 79_444_000_000),
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

    /// Maintainer の不変条件: 合計 == in_total 行の和（完全一致）、除外行は 4 値の理由を必ず持ち、
    /// 数える行は理由を持たない。対応先は数える行の添字。
    private func expectInvariants(_ payload: BreakdownSnapshotPayload) {
        let segments = payload.rows.filter { $0.rowKind == "segment" }
        let sum = segments.filter { $0.inTotal == true }.reduce(0.0) { $0 + ($1.closing ?? 0) }
        #expect(payload.rows.last?.closing == sum)
        for (index, row) in payload.rows.enumerated() where row.rowKind == "segment" {
            #expect(row.inTotal != nil)
            if row.inTotal == true {
                #expect(row.excludedReason == nil)
                #expect(row.pairedRowIndex == nil)
            } else {
                let reason = try? #require(row.excludedReason)
                #expect(reason.map { ibdExcludedReasons.contains($0) } == true)
                if let paired = row.pairedRowIndex {
                    #expect(paired != index)
                    #expect(payload.rows.indices.contains(paired))
                    #expect(payload.rows[paired].inTotal == true)
                }
            }
        }
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

// MARK: - タクソノミ preset・除外リスト・source_tag（2026-10-11）

@Suite struct InterestBearingDebtPresetAndSourceTagTests {
    @Test func scheduleRowPresetNewDebtWordsAndDeposits() {
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("長期借入債務") == .interestBearingDebt)
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("１年以内返済予定長期債務") == .interestBearingDebt)
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("短期債務") == .interestBearingDebt)
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("預り敷金") == .notInterestBearing)
        // 引当金・債務保証は債務の語を含んでも確定しない（Jev）
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("長期債務保証損失引当金") == nil)
    }

    @Test func balanceSheetExtensionPreset() {
        let securities = InterestBearingDebtBreakdown.balanceSheetExtensionPreset("信用取引借入金")
        #expect(securities.0 == .notInterestBearing)
        #expect(securities.1 == ibdExcludedReasonScopeDiffers)
        // リース込みの債務科目は債務（リース単独ではない）
        #expect(InterestBearingDebtBreakdown.balanceSheetExtensionPreset("社債、借入金及びリース負債").0
            == .interestBearingDebt)
        #expect(InterestBearingDebtBreakdown.balanceSheetExtensionPreset("リース負債").0 == .leaseLiability)
        #expect(InterestBearingDebtBreakdown.balanceSheetExtensionPreset("その他の金融負債").0 == nil)
    }

    @Test func maturityKanjiOneYear() {
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "一年以内に返済予定の長期借入金") == ibdMaturityCurrent)
        #expect(InterestBearingDebtBreakdown.maturityClass(fromLabel: "長期借入金(一年以内に返済予定のものを除く)")
            == ibdMaturityNonCurrent)
        #expect(InterestBearingDebtBreakdown.maturityClass(fromTag: "LongTermDebtToSubsidiariesAndAffiliatesNCLGAS")
            == ibdMaturityNonCurrent)
        #expect(InterestBearingDebtBreakdown.maturityClass(fromTag: "PayablesUnderFluidityLeaseReceivablesCLLEA")
            == ibdMaturityCurrent)
    }

    @Test func deadTagsRemovedAndNewPresetsPresent() {
        let all = Set((Xbrl.ibdCurrentComponents + Xbrl.ibdNonCurrentComponents
            + Xbrl.ibdLiquidityOrderComponents + [Xbrl.ibdIFRSCLTags, Xbrl.ibdIFRSNCLTags]).flatMap { $0 })
        for dead in ["InterestBearingDebt", "InterestBearingLiabilities", "RedeemableBondsWithinOneYear",
                     "CommercialPapersCLIFRS"] {
            #expect(!all.contains(dead), "\(dead)")
        }
        for tag in ["CurrentPortionOfConvertibleBonds", "ConvertibleBondTypeBondsWithSubscriptionRightsToShares",
                    "BorrowingsLiabilitiesINS", "PayablesUnderFluidityLeaseReceivablesCLLEA",
                    "LeaseObligationsLiabilities", "LongTermLoansPayableToSubsidiariesAndAffiliates"] {
            #expect(all.contains(tag), "\(tag)")
        }
        // 債権流動化は Lease を名前に含むが債務（リースタグではない）
        #expect(!Xbrl.leaseLiabilitiesBSTags.contains("PayablesUnderFluidityLeaseReceivablesCLLEA"))
        #expect(Xbrl.bankIBDComponents.contains { $0.tags.contains("DebenturesLiabilitiesBNK") })
        // 除外リストと債務 preset は重ならない
        #expect(Xbrl.ibdNonInterestBearingBSTags.isDisjoint(with: all))
        #expect(Xbrl.ibdSecuritiesBusinessBorrowingTags.isDisjoint(with: all))
    }

    private func candidate(
        _ label: String, tag: String?, closing: Double, source: String, maturity: String?,
        preset: IBDRowClass, sourceTag: String?
    ) -> IBDCandidate {
        IBDCandidate(
            labelRaw: label, label: label, tag: tag, opening: nil, closing: closing, source: source,
            maturityClass: maturity, presetClass: preset, sourceTag: sourceTag)
    }

    /// BS に別建てのリースが無い「有利子負債」集約はリース込み。明細表（借入金＋リース）を内訳に
    /// して BS を数え、注記のリースを足さない。source_tag は BS 要素・TextBlock、合計は null。
    @Test func leaseInclusiveAggregateNestsScheduleAndCarriesSourceTags() async throws {
        let schedTag = "NotesInterestBearingLiabilitiesConsolidatedFinancialStatementsIFRSTextBlock"
        let inputs = IBDInputs(
            consolidated: true,
            balanceSheet: [
                candidate("有利子負債", tag: "InterestBearingLiabilitiesCLIFRS", closing: 30_000_000_000,
                          source: ibdRowSourceBalanceSheet, maturity: ibdMaturityCurrent,
                          preset: .interestBearingDebt, sourceTag: "InterestBearingLiabilitiesCLIFRS"),
                candidate("有利子負債", tag: "InterestBearingLiabilitiesNCLIFRS", closing: 50_000_000_000,
                          source: ibdRowSourceBalanceSheet, maturity: ibdMaturityNonCurrent,
                          preset: .interestBearingDebt, sourceTag: "InterestBearingLiabilitiesNCLIFRS"),
            ],
            schedule: [
                candidate("短期借入金", tag: nil, closing: 25_000_000_000, source: ibdRowSourceBorrowingsSchedule,
                          maturity: ibdMaturityCurrent, preset: .interestBearingDebt, sourceTag: schedTag),
                candidate("１年内返済予定のリース負債", tag: nil, closing: 5_000_000_000,
                          source: ibdRowSourceBorrowingsSchedule, maturity: ibdMaturityCurrent,
                          preset: .leaseLiability, sourceTag: schedTag),
                candidate("長期借入金", tag: nil, closing: 42_000_000_000, source: ibdRowSourceBorrowingsSchedule,
                          maturity: nil, preset: .interestBearingDebt, sourceTag: schedTag),
                candidate("長期リース負債", tag: nil, closing: 8_000_000_000, source: ibdRowSourceBorrowingsSchedule,
                          maturity: nil, preset: .leaseLiability, sourceTag: schedTag),
            ],
            leaseNote: nil)
        let resolution = await InterestBearingDebtBreakdown.resolve(inputs: inputs, decider: nil)
        guard case .resolved(let payload, _) = resolution else {
            Issue.record("expected resolved")
            return
        }
        #expect(payload.needsReview == false)
        #expect(payload.denominator == 80_000_000_000)
        #expect(payload.rows.last?.closing == 80_000_000_000)
        #expect(payload.rows.last?.sourceTag == nil)
        let counted = payload.rows.filter { $0.inTotal == true }
        #expect(counted.map(\.sourceTag) == ["InterestBearingLiabilitiesCLIFRS", "InterestBearingLiabilitiesNCLIFRS"])
        let children = payload.rows.filter { $0.inTotal == false }
        #expect(children.count == 4)
        #expect(children.allSatisfy { $0.sourceTag == schedTag })
        #expect(children.allSatisfy { $0.excludedReason == ibdExcludedReasonDuplicateOfBalanceSheet })
        // JSON は source_tag キーを常に出す（合計行は null）
        let json = payload.rows.last!.interestBearingDebtJsonObject()
        #expect(json[ibdSourceTagKey] is NSNull)
        #expect(counted[0].interestBearingDebtJsonObject()[ibdSourceTagKey] as? String
            == "InterestBearingLiabilitiesCLIFRS")
    }

    @Test func sourceTagRoundTripsThroughPayloadCoding() throws {
        let row = BreakdownRowPayload(
            labelRaw: "短期借入金", label: "短期借入金", amount: 1, profit: nil, rowKind: "segment",
            debtSource: ibdRowSourceBalanceSheet, inTotal: true, sourceTag: "ShortTermLoansPayable")
        let data = try JSONEncoder().encode(row)
        #expect(String(decoding: data, as: UTF8.self).contains("\"source_tag\":\"ShortTermLoansPayable\""))
        let decoded = try JSONDecoder().decode(BreakdownRowPayload.self, from: data)
        #expect(decoded.sourceTag == "ShortTermLoansPayable")
    }
}
