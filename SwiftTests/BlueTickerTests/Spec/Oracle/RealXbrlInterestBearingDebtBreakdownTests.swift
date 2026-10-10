// 実 EDINET XBRL キャッシュでの有利子負債内訳の回帰（SPEC_ORACLE の L1）。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ。

import Testing
import Foundation
@testable import BlueTickerCore

/// ゴールデン用の決定論デサイダ。デリバティブ・和解・その他は非有利子、それ以外は有利子。
private struct GoldenIBDDecider: InterestBearingDebtDeciding {
    func classifyRow(
        label: String, source: String, tag: String?, closingYen: Double?,
        siblingLabels: [String]
    ) async -> IBDChoice {
        if label.contains("デリバティブ") || label.contains("和解") || label.contains("その他") {
            return IBDChoice(selected: IBDRowClass.notInterestBearing.rawValue, probability: 0.95)
        }
        if label.contains("長期借入債務") {
            return IBDChoice(selected: IBDRowClass.interestBearingDebt.rawValue, probability: 0.97)
        }
        return IBDChoice(selected: IBDRowClass.interestBearingDebt.rawValue, probability: 0.95)
    }

    func classifyNearDuplicate(
        scheduleLabel: String, scheduleYen: Double, leaseNoteLabel: String, leaseNoteYen: Double
    ) async -> IBDChoice {
        IBDChoice(selected: IBDDuplicateRole.sameLiability, probability: 0.95)
    }
}

@Suite struct RealXbrlInterestBearingDebtBreakdownTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard FileManager.default.fileExists(atPath: xbrlDir(docID).path) else {
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    /// ソフトバンク: 明細表は売却及びリースバック表で帯外。BS 科目を使う。
    @Test func softBankUsesBalanceSheetWhenScheduleOutsideBand() async throws {
        guard await Self.ensureAvailable("S100YGH5") else { return }
        let (payload, audit) = try await resolve("S100YGH5", decider: GoldenIBDDecider())
        #expect(payload.needsReview == false)
        #expect(payload.warnings == ["borrowings_schedule_outside_coverage_band"])
        expectRows(payload, [
            ("有利子負債", ibdRowSourceBalanceSheet, 7_251_630_000_000, ibdMaturityCurrent),
            ("有利子負債", ibdRowSourceBalanceSheet, 17_433_486_000_000, ibdMaturityNonCurrent),
            ("リース負債", ibdRowSourceBalanceSheet, 184_666_000_000, ibdMaturityCurrent),
            ("リース負債", ibdRowSourceBalanceSheet, 793_784_000_000, ibdMaturityNonCurrent),
        ])
        #expect(payload.rows.last?.closing == 25_663_566_000_000)
        #expect(!payload.rows.contains { $0.debtSource == ibdRowSourceBorrowingsSchedule })
        #expect(audit.sentences.contains { $0.contains("schedule_rejected") })
    }

    /// ソフトバンクは全行コード分類なのでデサイダ無しでも同じ。
    @Test func softBankWithoutDeciderMatches() async throws {
        guard await Self.ensureAvailable("S100YGH5") else { return }
        let (payload, _) = try await resolve("S100YGH5", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.warnings == ["borrowings_schedule_outside_coverage_band"])
        expectRows(payload, [
            ("有利子負債", ibdRowSourceBalanceSheet, 7_251_630_000_000, ibdMaturityCurrent),
            ("有利子負債", ibdRowSourceBalanceSheet, 17_433_486_000_000, ibdMaturityNonCurrent),
            ("リース負債", ibdRowSourceBalanceSheet, 184_666_000_000, ibdMaturityCurrent),
            ("リース負債", ibdRowSourceBalanceSheet, 793_784_000_000, ibdMaturityNonCurrent),
        ])
        #expect(payload.rows.last?.closing == 25_663_566_000_000)
    }

    /// ソニー: 明細表が帯内。リースは BS。
    @Test func sonyUsesBorrowingsSchedule() async throws {
        guard await Self.ensureAvailable("S100YE2C") else { return }
        let (payload, _) = try await resolve("S100YE2C", decider: GoldenIBDDecider())
        #expect(payload.needsReview == false)
        #expect(payload.warnings.isEmpty)
        expectRows(payload, [
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 51_183_000_000, ibdMaturityCurrent),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 516_460_000_000, nil),
            ("無担保社債", ibdRowSourceBorrowingsSchedule, 474_343_000_000, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 94_160_000_000, ibdMaturityCurrent),
            ("リース負債", ibdRowSourceBalanceSheet, 533_523_000_000, ibdMaturityNonCurrent),
        ])
        #expect(payload.rows.last?.closing == 1_669_669_000_000)
    }

    /// ソニーは「長期借入債務」が Jev 待ち。デサイダ無しは未分類。
    @Test func sonyWithoutDeciderNeedsReview() async throws {
        guard await Self.ensureAvailable("S100YE2C") else { return }
        let (payload, _) = try await resolve("S100YE2C", decider: nil)
        #expect(payload.needsReview == true)
    }

    /// JT: 明細表リースと注記合計が近似重複。same_liability で明細表側だけ残す。
    @Test func jtCollapsesLeaseNearDuplicate() async throws {
        guard await Self.ensureAvailable("S100XSSA") else { return }
        let (payload, audit) = try await resolve("S100XSSA", decider: GoldenIBDDecider())
        #expect(payload.needsReview == false)
        #expect(payload.warnings.isEmpty)
        expectRows(payload, [
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 79_444_000_000, ibdMaturityCurrent),
            ("１年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 184_000_000, ibdMaturityCurrent),
            ("１年内償還予定の社債(注２)", ibdRowSourceBorrowingsSchedule, nil, ibdMaturityCurrent),
            ("長期借入金(注１)", ibdRowSourceBorrowingsSchedule, 120_699_000_000, nil),
            ("社債(注２)", ibdRowSourceBorrowingsSchedule, 1_478_362_000_000, nil),
            ("リース負債（非流動）", ibdRowSourceBorrowingsSchedule, 74_540_000_000, nil),
        ])
        #expect(payload.rows.last?.closing == 1_753_229_000_000)
        let excluded = ["デリバティブ負債", "カナダ訴訟の和解金に係る負債", "その他"]
        #expect(!payload.rows.contains { excluded.contains($0.label) })
        let joined = audit.sentences.joined(separator: " ")
        #expect(joined.contains("lease_near_duplicate"))
        #expect(joined.contains("74540000000"))
        #expect(joined.contains("74151000000"))
    }

    /// JT は近似重複を解けないのでデサイダ無しは needs_review。
    @Test func jtWithoutDeciderNeedsReview() async throws {
        guard await Self.ensureAvailable("S100XSSA") else { return }
        let (payload, _) = try await resolve("S100XSSA", decider: nil)
        #expect(payload.needsReview == true)
    }

    /// スズキ: 1年内返済予定の長期借入金が独立行。リースは注記。
    @Test func suzukiKeepsCurrentPortionAsOwnRow() async throws {
        guard await Self.ensureAvailable("S100W4MT") else { return }
        let (payload, _) = try await resolve("S100W4MT", decider: GoldenIBDDecider())
        #expect(payload.needsReview == false)
        expectRows(payload, [
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 122_095_000_000, ibdMaturityCurrent),
            ("１年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 175_738_000_000, ibdMaturityCurrent),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 427_465_000_000, nil),
            ("リース負債", ibdRowSourceLeaseNote, 32_539_000_000, nil),
        ])
        #expect(payload.rows.last?.closing == 757_837_000_000)
    }

    /// クボタ: 社債及び長期借入金は合算行。合計行の期首も検算する。
    @Test func kubotaScheduleAndLeaseNote() async throws {
        guard await Self.ensureAvailable("S100XR0M") else { return }
        let (payload, _) = try await resolve("S100XR0M", decider: GoldenIBDDecider())
        #expect(payload.needsReview == false)
        expectRows(payload, [
            ("短期借入金(注１)", ibdRowSourceBorrowingsSchedule, 342_787_000_000, ibdMaturityCurrent),
            ("社債及び長期借入金(注２)", ibdRowSourceBorrowingsSchedule, 1_899_292_000_000, nil),
            ("リース負債", ibdRowSourceLeaseNote, 83_336_000_000, nil),
        ])
        let total = try #require(payload.rows.last)
        #expect(total.closing == 2_325_415_000_000)
        #expect(total.opening == 2_342_802_000_000)
    }

    /// 東邦レマック: 連結が無く単体だけ。平均利率は明細行だけ。
    @Test func tohoLemacStandaloneCarriesAverageRates() async throws {
        guard await Self.ensureAvailable("S100XRD8") else { return }
        let inputs = InterestBearingDebtBreakdown.inputs(xbrlDir: Self.xbrlDir("S100XRD8"))
        #expect(inputs.consolidated == false)
        let (payload, _) = try await resolve("S100XRD8", decider: GoldenIBDDecider(), inputs: inputs)
        #expect(payload.needsReview == false)
        expectRows(payload, [
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 1_095_000_000, ibdMaturityCurrent),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 6_430_000, ibdMaturityCurrent),
            (
                "長期借入金（１年以内に返済予定のものを除く。）",
                ibdRowSourceBorrowingsSchedule, 428_569_000, ibdMaturityNonCurrent
            ),
        ])
        let segments = payload.rows.filter { $0.rowKind == "segment" }
        #expect(segments.map(\.averageRate) == [0.9, 2.98, 2.75])
        let total = try #require(payload.rows.last)
        #expect(total.closing == 1_529_999_000)
        #expect(total.averageRate == nil)
        let totalJSON = try #require(
            (payload.jsonObject()["rows"] as? [[String: Any]])?.last)
        #expect(totalJSON["average_rate"] is NSNull)
    }

    /// 三菱UFJ: 銀行は financial_institution で内訳を出さない。
    @Test func mufgIsFinancialInstitution() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let inputs = InterestBearingDebtBreakdown.inputs(xbrlDir: Self.xbrlDir("S100W4FB"))
        let resolution = await InterestBearingDebtBreakdown.resolve(
            inputs: inputs, decider: GoldenIBDDecider(), docID: "S100W4FB")
        guard case .notApplicable(let reason) = resolution else {
            Issue.record("expected notApplicable, got \(resolution)")
            return
        }
        #expect(reason == "financial_institution")
    }

    // MARK: - helpers

    private func resolve(
        _ docID: String, decider: (any InterestBearingDebtDeciding)?,
        inputs: IBDInputs? = nil
    ) async throws -> (BreakdownSnapshotPayload, SegmentNoteJevAuditPayload) {
        let built = inputs ?? InterestBearingDebtBreakdown.inputs(xbrlDir: Self.xbrlDir(docID))
        let resolution = await InterestBearingDebtBreakdown.resolve(
            inputs: built, decider: decider, docID: docID)
        guard case .resolved(let payload, let audit) = resolution else {
            Issue.record("\(docID): expected resolved, got \(resolution)")
            throw ResolveError.notResolved
        }
        return (payload, audit)
    }

    private func expectRows(
        _ payload: BreakdownSnapshotPayload,
        _ expected: [(String, String, Double?, String?)]
    ) {
        let actual = payload.rows.filter { $0.rowKind == "segment" }.map {
            ($0.label, $0.debtSource, $0.closing, $0.maturityClass)
        }
        #expect(actual.count == expected.count)
        for (got, want) in zip(actual, expected) {
            #expect(got.0 == want.0)
            #expect(got.1 == want.1)
            #expect(got.2 == want.2)
            #expect(got.3 == want.3)
        }
    }

    private enum ResolveError: Error { case notResolved }
}
