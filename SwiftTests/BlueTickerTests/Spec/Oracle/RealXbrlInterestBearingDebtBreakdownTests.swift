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
        print("IBD-GOLDEN RUN \(docID)")
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
        // Jev が債務と答えた LongTermDebt2NCLIFRS は行に残るが分母から外す。coverage は帯外。
        #expect(payload.needsReview == true)
        #expect(payload.warnings.contains("interest_bearing_debt_coverage_out_of_band"))
        expectRows(payload, [
            // BS 短期借入金（BorrowingsCLIFRS）が親で数え、明細表の短期借入金は同額の内訳
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 516_460_000_000, nil),
            ("無担保社債", ibdRowSourceBorrowingsSchedule, 474_343_000_000, nil),
            ("短期借入金", ibdRowSourceBalanceSheet, 51_183_000_000, ibdMaturityCurrent),
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
        #expect(payload.warnings == ["interest_bearing_debt_lease_denominator_from_notes"])
        expectRows(payload, [
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 79_444_000_000, ibdMaturityCurrent),
            ("１年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 184_000_000, ibdMaturityCurrent),
            ("１年内償還予定の社債(注２)", ibdRowSourceBorrowingsSchedule, nil, ibdMaturityCurrent),
            ("長期借入金(注１)", ibdRowSourceBorrowingsSchedule, 120_699_000_000, nil),
            ("社債(注２)", ibdRowSourceBorrowingsSchedule, 1_478_362_000_000, nil),
            ("リース負債（非流動）", ibdRowSourceBorrowingsSchedule, 74_540_000_000, nil),
        ])
        #expect(payload.rows.last?.closing == 1_753_229_000_000)
        // 非有利子の明細表行は合計に入れず non_interest_bearing で残す
        let excluded = ["デリバティブ負債", "カナダ訴訟の和解金に係る負債", "その他"]
        for row in payload.rows where excluded.contains(row.label) {
            #expect(row.inTotal == false)
            #expect(row.excludedReason == ibdExcludedReasonNonInterestBearing)
        }
        // 注記のリース 74,151 は明細表リースと同じ負債（別表）
        let note = try #require(payload.rows.first { $0.debtSource == ibdRowSourceLeaseNote })
        #expect(note.closing == 74_151_000_000)
        #expect(note.excludedReason == ibdExcludedReasonOtherTable)
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

    /// 東邦レマック: 連結が無く単体だけ。BS 3科目が親で数え、明細表3行は同額の内訳。
    /// 平均利率は契約に持たない（average_rate 廃止）。
    @Test func tohoLemacStandaloneUsesScheduleRows() async throws {
        guard await Self.ensureAvailable("S100XRD8") else { return }
        let inputs = InterestBearingDebtBreakdown.inputs(xbrlDir: Self.xbrlDir("S100XRD8"))
        #expect(inputs.consolidated == false)
        let (payload, _) = try await resolve("S100XRD8", decider: GoldenIBDDecider(), inputs: inputs)
        #expect(payload.needsReview == false)
        expectRows(payload, [
            ("短期借入金", ibdRowSourceBalanceSheet, 1_095_000_000, ibdMaturityCurrent),
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 6_430_000, ibdMaturityCurrent),
            ("長期借入金", ibdRowSourceBalanceSheet, 428_569_000, ibdMaturityNonCurrent),
        ])
        let components = payload.rows.filter { $0.inTotal == false }
        #expect(components.map(\.excludedReason) == Array(repeating: ibdExcludedReasonDuplicateOfBalanceSheet, count: 3))
        #expect(components.map(\.pairedRowIndex) == [0, 1, 2])
        let total = try #require(payload.rows.last)
        #expect(total.closing == 1_529_999_000)
        // 期首は数える BS 行の前期末（800 + 0 + 0 百万円）
        #expect(total.opening == 800_000_000)
        let totalJSON = try #require(
            (payload.jsonObject()["rows"] as? [[String: Any]])?.last)
        #expect(!totalJSON.keys.contains("average_rate"))
    }

    /// 第一生命: 保険会社は除外せず通常パイプラインで解く。
    @Test func insurerUsesNormalPipeline() async throws {
        guard await Self.ensureAvailable("S100YC7A") else { return }
        let inputs = InterestBearingDebtBreakdown.inputs(xbrlDir: Self.xbrlDir("S100YC7A"))
        #expect(inputs.isBank == false)
        let (payload, _) = try await resolve("S100YC7A", decider: GoldenIBDDecider(), inputs: inputs)
        #expect(payload.needsReview == false)
        #expect(payload.warnings == [
            breakdownWarningIBDLeaseDenominatorFromNotes,
            breakdownWarningIBDScheduleRejected,
        ])
        expectRows(payload, [
            ("短期社債", ibdRowSourceBalanceSheet, 7_822_000_000, ibdMaturityCurrent),
            ("社債", ibdRowSourceBalanceSheet, 1_337_337_000_000, ibdMaturityNonCurrent),
            ("リース負債（流動）", ibdRowSourceBorrowingsSchedule, 1_913_000_000, ibdMaturityCurrent),
            ("リース負債（非流動）", ibdRowSourceBorrowingsSchedule, 16_486_000_000, ibdMaturityNonCurrent),
        ])
        #expect(payload.rows.last?.closing == 1_363_558_000_000)
    }

    @Test func financialsCanonicalInterestBearingDebtGoldens() async throws {
        let cases: [(String, Double, String)] = [
            ("S100YGH5", 25_663_566_000_000, "breakdown.interest_bearing_debt"),
            ("S100XRD8", 1_529_999_000, "breakdown.interest_bearing_debt"),
            ("S100YE2C", 845_276_000_000, "legacy_ibd_extractor_fallback"),
        ]
        for (docID, expected, method) in cases {
            guard await Self.ensureAvailable(docID) else { continue }
            let canonical = await BreakdownFinancialsResolver.financialsCanonicalInterestBearingDebt(
                xbrlDir: Self.xbrlDir(docID))
            #expect(canonical.total == expected)
            #expect(canonical.method == method)
            if docID == "S100YE2C" {
                #expect(canonical.warnings.contains { $0.contains("長期借入債務") })
            }
        }
    }

    /// 三菱UFJ: 銀行は bank components を行にする。
    @Test func mufgUsesBankComponents() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let (payload, audit) = try await resolve("S100W4FB", decider: GoldenIBDDecider())
        #expect(payload.needsReview == false)
        #expect(payload.denominatorTag == "bank_components")
        expectRows(payload, [
            ("預金", ibdRowSourceFinancialsBankComponents, 228_512_749_000_000, nil),
            ("譲渡性預金", ibdRowSourceFinancialsBankComponents, 17_374_010_000_000, nil),
            ("コマーシャル・ペーパー", ibdRowSourceFinancialsBankComponents, 3_475_042_000_000, nil),
            ("借用金", ibdRowSourceFinancialsBankComponents, 22_101_954_000_000, nil),
            ("短期社債", ibdRowSourceFinancialsBankComponents, 1_373_236_000_000, ibdMaturityCurrent),
            ("社債", ibdRowSourceFinancialsBankComponents, 14_018_955_000_000, nil),
            ("リース負債（非流動）", ibdRowSourceBorrowingsSchedule, 90_694_000_000, nil),
        ])
        #expect(payload.rows.last?.closing == 286_946_640_000_000)
        #expect(audit.sentences.contains("bank_components"))
    }

    /// 単体だけの会社（DEI 連結無し）は単体明細表を読む。コンテキスト共存では誤って連結扱いになり
    /// 唯一の明細表を落としていた（ニッカトー S100Y9NY、サイバーソリューションズ S100YRSR）。
    @Test func standaloneFilersKeepStandaloneSchedule() async throws {
        let cases: [(String, Double)] = [
            ("S100Y9NY", 509_178_000),
            ("S100YRSR", 10_036_000),
        ]
        for (docID, total) in cases {
            guard await Self.ensureAvailable(docID) else { continue }
            let dir = Self.xbrlDir(docID)
            #expect(BorrowingsSchedule.filerHasConsolidatedStatements(xbrlDir: dir) == false)
            guard case .resolved(let payload, _, _) = StatementNotesResolver.resolveBorrowingsSchedule(
                xbrlDir: dir)
            else {
                Issue.record("\(docID): borrowings_schedule should stay resolved")
                continue
            }
            let totalRow = payload.borrowingsComponents?.first { $0.isTotal }
            #expect(totalRow?.currentBalance == total)
            #expect(InterestBearingDebtBreakdown.inputs(xbrlDir: dir).consolidated == false)
        }
    }

    /// 連結を作る会社（DEI 連結有り）は単体明細表へフォールバックしない（ＡＩフュージョン S100W4HU）。
    @Test func consolidatedFilerDoesNotFallBackToStandaloneSchedule() async throws {
        guard await Self.ensureAvailable("S100W4HU") else { return }
        let dir = Self.xbrlDir("S100W4HU")
        #expect(BorrowingsSchedule.filerHasConsolidatedStatements(xbrlDir: dir) == true)
        guard case .notApplicable(let reason) = StatementNotesResolver.resolveBorrowingsSchedule(
            xbrlDir: dir)
        else {
            Issue.record("S100W4HU: borrowings_schedule should be not_found")
            return
        }
        #expect(reason == statementNoteNotApplicableNotFound)
    }

    // MARK: - BS 基準の行選択（in_total / excluded_reason / 入れ子）の実 XBRL ゴールデン

    /// 6503 三菱電機: BS は合算科目（社債、借入金及びリース負債）だけで入れ子の親にならない。明細表 363,278 百万円をそのまま数える（手検証ゴールデン）。
    @Test func ledger6503S100YD3V() async throws {
        guard await Self.ensureAvailable("S100YD3V") else { return }
        let (payload, _) = try await resolve("S100YD3V", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 363_278_000_000, [
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 36_453_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 100_580_000_000, nil, true, nil, nil, nil),
            ("社債", ibdRowSourceBorrowingsSchedule, 49_933_000_000, nil, true, nil, nil, nil),
            ("コマーシャル・ペーパー", ibdRowSourceBorrowingsSchedule, 30_000_000_000, nil, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 146_312_000_000, nil, true, nil, nil, nil),
        ])
    }

    /// 5411 JFE: BS は合算科目だけ。明細表 1,959,380 百万円（手検証ゴールデン。利率は別表なので average_rate は持たない）。
    @Test func ledger5411S100YCUD() async throws {
        guard await Self.ensureAvailable("S100YCUD") else { return }
        let (payload, _) = try await resolve("S100YCUD", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 1_959_380_000_000, [
            ("短期借入金（注１）", ibdRowSourceBorrowingsSchedule, 202_992_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("１年内返済長期借入金（注１）", ibdRowSourceBorrowingsSchedule, 116_077_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("１年内償還予定の社債（注２）", ibdRowSourceBorrowingsSchedule, 39_990_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("コマーシャル・ペーパー（注１）", ibdRowSourceBorrowingsSchedule, 33_973_000_000, nil, true, nil, nil, nil),
            ("社債（注２）", ibdRowSourceBorrowingsSchedule, 214_219_000_000, nil, true, nil, nil, nil),
            ("転換社債型新株予約権付社債（注２）", ibdRowSourceBorrowingsSchedule, 88_407_000_000, nil, true, nil, nil, nil),
            ("長期借入金（注１）", ibdRowSourceBorrowingsSchedule, 1_099_473_000_000, nil, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 164_249_000_000, nil, true, nil, nil, nil),
        ])
    }

    /// 2897 日清食品: 会社独自 TextBlock の主表（担保表ではない）。BS「借入金」（流動）が短期 + 1年内の親、BS CP が明細表 CP の親。長期受入保証金 320 はラベルで非有利子。表の合計 204,314 ではなく 203,992 百万円。
    @Test func ledger2897S100YEWB() async throws {
        guard await Self.ensureAvailable("S100YEWB") else { return }
        let (payload, _) = try await resolve("S100YEWB", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 203_992_000_000, [
            ("社債", ibdRowSourceBorrowingsSchedule, 49_870_000_000, nil, true, nil, nil, nil),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 52_882_000_000, nil, true, nil, nil, nil),
            ("借入金", ibdRowSourceBalanceSheet, 50_782_000_000, ibdMaturityCurrent, true, nil, nil, "借入金"),
            ("コマーシャル・ペーパー", ibdRowSourceBalanceSheet, 22_000_000_000, ibdMaturityCurrent, true, nil, nil, "コマーシャル・ペーパー"),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 28_458_000_000, nil, true, nil, nil, nil),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 30_192_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "借入金"),
            ("１年内返済長期借入金", ibdRowSourceBorrowingsSchedule, 20_590_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "借入金"),
            ("コマーシャル・ペーパー", ibdRowSourceBorrowingsSchedule, 22_000_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, 3, "コマーシャル・ペーパー"),
            ("長期受入保証金", ibdRowSourceBorrowingsSchedule, 320_000_000, nil, false, ibdExcludedReasonNonInterestBearing, nil, nil),
        ])
    }

    /// 2154 BS「借入金」（流動）5,000 が明細表の短期借入金と1年内（当期末なし）の親。社債 4,983 は明細表。9,983 百万円（手検証ゴールデン）。
    @Test func ledger2154S100Z35K() async throws {
        guard await Self.ensureAvailable("S100Z35K") else { return }
        let (payload, _) = try await resolve("S100Z35K", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 9_983_000_000, [
            ("社債", ibdRowSourceBorrowingsSchedule, 4_983_000_000, nil, true, nil, nil, nil),
            ("借入金", ibdRowSourceBalanceSheet, 5_000_000_000, ibdMaturityCurrent, true, nil, nil, "借入金"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 5_000_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "借入金"),
            ("１年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, nil, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "借入金"),
        ])
    }

    /// 8570 B6: BS の CP 5,932 を足す。BS 借入金3科目が明細表の各行の親。明細表リース 34,288（BS にリース科目なし）。期待 1,439,386 は再現せず、コード値 1,439,391 百万円。
    @Test func ledger8570S100Y53G() async throws {
        guard await Self.ensureAvailable("S100Y53G") else { return }
        let (payload, _) = try await resolve("S100Y53G", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 1_439_391_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 160_808_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 259_536_000_000, ibdMaturityCurrent, true, nil, nil, "１年内返済予定の長期借入金"),
            ("コマーシャル・ペーパー", ibdRowSourceBalanceSheet, 5_932_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("長期借入金", ibdRowSourceBalanceSheet, 619_634_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("１年内償還予定の社債", ibdRowSourceBalanceSheet, 84_124_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("社債", ibdRowSourceBalanceSheet, 275_069_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 11_624_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース債務（１年以内に返済予定のものを除く。）", ibdRowSourceBorrowingsSchedule, 22_664_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 160_808_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 259_536_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "１年内返済予定の長期借入金"),
            ("長期借入金（１年以内に返済予定のものを除く。）", ibdRowSourceBorrowingsSchedule, 619_634_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 3, "長期借入金"),
        ])
    }

    /// 4186 B6: BS 短期借入金 383 を数え、当期末値の無い明細表の短期・1年内はその内訳。
    @Test func ledger4186S100XT0N() async throws {
        guard await Self.ensureAvailable("S100XT0N") else { return }
        let (payload, _) = try await resolve("S100XT0N", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 26_483_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 383_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 16_100_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("社債", ibdRowSourceBalanceSheet, 10_000_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, nil, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, nil, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("長期借入金（１年以内に返済予定のものを除く。）", ibdRowSourceBorrowingsSchedule, 16_100_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "長期借入金"),
        ])
    }

    /// 2798 B6: BS の短期借入金 49.816 百万円（= 49,816 千円）。BS リースが明細表リースに勝つ。
    @Test func ledger2798S100Y6U1() async throws {
        guard await Self.ensureAvailable("S100Y6U1") else { return }
        let (payload, _) = try await resolve("S100Y6U1", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 1_656_790_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 49_816_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 129_664_000, ibdMaturityCurrent, true, nil, nil, "１年内返済予定の長期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 1_440_081_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース負債", ibdRowSourceBalanceSheet, 6_645_000, ibdMaturityCurrent, true, nil, nil, "リース負債"),
            ("リース負債", ibdRowSourceBalanceSheet, 30_584_000, ibdMaturityNonCurrent, true, nil, nil, "リース負債"),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 6_645_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 3, "リース負債"),
            ("リース債務（１年以内に返済予定のものを除く）", ibdRowSourceBorrowingsSchedule, 30_584_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 4, "リース負債"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 129_664_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "１年内返済予定の長期借入金"),
            ("長期借入金（１年以内に返済予定のものを除く）", ibdRowSourceBorrowingsSchedule, 1_440_081_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "長期借入金"),
        ])
    }

    /// 9413 テレビ東京: 字下げ（text-indent / padding-left）の食い違いで落ちていた 1年内リース 214 を拾う。BS 科目が親、明細表行は同額の内訳。
    @Test func ledger9413S100YCRR() async throws {
        guard await Self.ensureAvailable("S100YCRR") else { return }
        let (payload, _) = try await resolve("S100YCRR", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 6_365_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 5_100_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 141_000_000, ibdMaturityCurrent, true, nil, nil, "１年内返済予定の長期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 323_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース債務", ibdRowSourceBalanceSheet, 214_000_000, ibdMaturityCurrent, true, nil, nil, "リース債務"),
            ("リース債務", ibdRowSourceBalanceSheet, 587_000_000, ibdMaturityNonCurrent, true, nil, nil, "リース債務"),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 214_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 3, "リース債務"),
            ("リース債務(１年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 587_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 4, "リース債務"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 5_100_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 141_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "１年内返済予定の長期借入金"),
            ("長期借入金(１年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 323_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "長期借入金"),
        ])
    }

    /// 7906 BS リース 756 + 1,102 が明細表リースに勝つ（範囲違いは scope_differs）。
    @Test func ledger7906S100YCTQ() async throws {
        guard await Self.ensureAvailable("S100YCTQ") else { return }
        let (payload, _) = try await resolve("S100YCTQ", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 18_198_000_000, [
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 1_322_000_000, ibdMaturityCurrent, true, nil, nil, "１年内返済予定の長期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 15_018_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース債務", ibdRowSourceBalanceSheet, 756_000_000, ibdMaturityCurrent, true, nil, nil, "リース債務"),
            ("リース債務", ibdRowSourceBalanceSheet, 1_102_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 554_000_000, ibdMaturityCurrent, false, ibdExcludedReasonScopeDiffers, 2, "リース債務"),
            ("リース債務", ibdRowSourceBorrowingsSchedule, 507_000_000, nil, false, ibdExcludedReasonScopeDiffers, nil, nil),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 1_322_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "１年内返済予定の長期借入金"),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 15_018_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "長期借入金"),
        ])
    }

    /// 3197 すかいらーく: 担保表（対応する債務 1,259 / 2,823）を読まず、合計の後の「（その他の金融負債）」のリース 29,023 + 94,938 を拾う。BS は合算科目だけ。
    @Test func ledger3197S100XUBI() async throws {
        guard await Self.ensureAvailable("S100XUBI") else { return }
        let (payload, _) = try await resolve("S100XUBI", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 247_629_000_000, [
            ("短期借入金（注２）（注３）（注４）（注７）（注８）（注９）", ibdRowSourceBorrowingsSchedule, 14_339_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("社債（注１）", ibdRowSourceBorrowingsSchedule, 34_126_000_000, nil, true, nil, nil, nil),
            ("長期借入金（注２）（注３）（注５）（注６）（注７）（注８）（注９）", ibdRowSourceBorrowingsSchedule, 75_203_000_000, nil, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 29_023_000_000, nil, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 94_938_000_000, nil, true, nil, nil, nil),
        ])
    }

    /// 7282 豊田合成: 担保表の 285 を読まない。
    @Test func ledger7282S100YC23() async throws {
        guard await Self.ensureAvailable("S100YC23") else { return }
        let (payload, _) = try await resolve("S100YC23", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 123_335_000_000, [
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 10_865_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("１年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 35_944_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 51_618_000_000, nil, true, nil, nil, nil),
            ("社債", ibdRowSourceBorrowingsSchedule, 24_908_000_000, nil, true, nil, nil, nil),
        ])
    }

    /// 6869 シスメックス（意図的な不一致）: BS 長期借入金 31,646 が親で数え、明細表 32,359（1年内分込み）は scope_differs の内訳。needs_review にしない。
    @Test func ledger6869S100YFAW() async throws {
        guard await Self.ensureAvailable("S100YFAW") else { return }
        let (payload, _) = try await resolve("S100YFAW", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 70_481_000_000, [
            ("長期借入金", ibdRowSourceBalanceSheet, 31_646_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース負債", ibdRowSourceBalanceSheet, 9_555_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 29_280_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 38_835_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, nil, nil),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 32_359_000_000, nil, false, ibdExcludedReasonScopeDiffers, 0, "長期借入金"),
        ])
    }

    /// 6376 日機装: BS 短期借入金 8,684 = 明細表 短期 786 + 1年内 7,898 の入れ子。リースは BS 3,963 + 23,529。注記は列レイアウト表の帳簿価額 27,492（使用権資産の 28,396 ではない）。
    @Test func ledger6376S100XU3R() async throws {
        guard await Self.ensureAvailable("S100XU3R") else { return }
        let (payload, _) = try await resolve("S100XU3R", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 110_100_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 8_684_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 73_924_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース負債", ibdRowSourceBalanceSheet, 3_963_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 23_529_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceLeaseNote, 27_492_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, nil, nil),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 786_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年内返済予定長期借入金", ibdRowSourceBorrowingsSchedule, 7_898_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 73_924_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "長期借入金"),
        ])
    }

    /// 5987 B6 対象会社: BS 科目が親、明細表は同額の内訳。
    @Test func ledger5987S100Z50O() async throws {
        guard await Self.ensureAvailable("S100Z50O") else { return }
        let (payload, _) = try await resolve("S100Z50O", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 1_587_112_000, [
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 677_485_000, ibdMaturityCurrent, true, nil, nil, "１年内返済予定の長期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 767_985_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース債務", ibdRowSourceBalanceSheet, 46_562_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース債務", ibdRowSourceBalanceSheet, 95_080_000, ibdMaturityNonCurrent, true, nil, nil, "リース債務"),
            ("リース債務(１年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 95_080_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 3, "リース債務"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 677_485_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "１年内返済予定の長期借入金"),
            ("長期借入金(１年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 767_985_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "長期借入金"),
        ])
    }

    /// 6537 B6 対象会社: BS 科目が親、明細表は同額の内訳。
    @Test func ledger6537S100XVE0() async throws {
        guard await Self.ensureAvailable("S100XVE0") else { return }
        let (payload, _) = try await resolve("S100XVE0", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 1_030_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 800_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 40_000_000, ibdMaturityCurrent, true, nil, nil, "１年内返済予定の長期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 164_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース負債", ibdRowSourceBalanceSheet, 7_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 19_000_000, ibdMaturityNonCurrent, true, nil, nil, "リース負債"),
            ("リース債務（１年以内に返済予定のものを除く）", ibdRowSourceBorrowingsSchedule, 19_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 4, "リース負債"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 800_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 40_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "１年内返済予定の長期借入金"),
            ("長期借入金(１年以内に返済予定のものを除く)", ibdRowSourceBorrowingsSchedule, 164_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "長期借入金"),
        ])
    }

    /// 7878 B6 対象会社（単体）: BS 科目が親。
    @Test func ledger7878S100Y03W() async throws {
        guard await Self.ensureAvailable("S100Y03W") else { return }
        let (payload, _) = try await resolve("S100Y03W", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 1_165_177_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 1_140_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("リース負債", ibdRowSourceBalanceSheet, 5_305_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 19_872_000, ibdMaturityNonCurrent, true, nil, nil, "リース負債"),
            ("リース債務(１年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 19_872_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "リース負債"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 1_140_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
        ])
    }

    /// 5248 B6 対象会社（意図的な不一致）: BS 長期借入金 2,704.069 が親で数え、明細表 2,450.892 は scope_differs。BS に流動区分の無い明細表の1年内リースは数える。
    @Test func ledger5248S100Y02W() async throws {
        guard await Self.ensureAvailable("S100Y02W") else { return }
        let (payload, _) = try await resolve("S100Y02W", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 9_915_371_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 5_799_790_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 1_023_198_000, ibdMaturityCurrent, true, nil, nil, "１年内返済予定の長期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 2_704_069_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("１年内償還予定の社債", ibdRowSourceBalanceSheet, 115_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("社債", ibdRowSourceBalanceSheet, 170_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 58_639_000, ibdMaturityNonCurrent, true, nil, nil, "リース負債"),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 44_675_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース債務(１年以内に返済予定のものを除く)", ibdRowSourceBorrowingsSchedule, 58_639_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 5, "リース負債"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 5_799_790_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 1_023_198_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "１年内返済予定の長期借入金"),
            ("長期借入金(１年以内に返済予定のものを除く)", ibdRowSourceBorrowingsSchedule, 2_450_892_000, ibdMaturityNonCurrent, false, ibdExcludedReasonScopeDiffers, 2, "長期借入金"),
        ])
    }

    /// 5805 B6 対象会社: BS 短期借入金 23,000 = 明細表 短期 17,492 + 1年内 5,507（端数差 1）の入れ子。長期は範囲違い。
    @Test func ledger5805S100YE42() async throws {
        guard await Self.ensureAvailable("S100YE42") else { return }
        let (payload, _) = try await resolve("S100YE42", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 40_016_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 23_000_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 16_484_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 178_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース債務（１年以内に返済予定のものを除く）", ibdRowSourceBorrowingsSchedule, 354_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 17_492_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 5_507_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("長期借入金（１年以内に返済予定のものを除く）", ibdRowSourceBorrowingsSchedule, 16_401_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonScopeDiffers, 1, "長期借入金"),
        ])
    }

    /// 3501 B6 対象会社: BS 短期借入金 13,395 = 明細表 短期 9,684 + 1年内 3,711 の入れ子。
    @Test func ledger3501S100YYVN() async throws {
        guard await Self.ensureAvailable("S100YYVN") else { return }
        let (payload, _) = try await resolve("S100YYVN", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 21_364_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 13_395_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 5_572_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("１年内償還予定の社債", ibdRowSourceBalanceSheet, 0, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース債務", ibdRowSourceBalanceSheet, 874_000_000, ibdMaturityCurrent, true, nil, nil, "リース債務"),
            ("リース債務", ibdRowSourceBalanceSheet, 1_523_000_000, ibdMaturityNonCurrent, true, nil, nil, "リース債務"),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 848_000_000, ibdMaturityCurrent, false, ibdExcludedReasonScopeDiffers, 3, "リース債務"),
            ("リース債務(１年以内に返済予定のものを除く)", ibdRowSourceBorrowingsSchedule, 1_521_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonScopeDiffers, 4, "リース債務"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 9_684_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 3_711_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("長期借入金(１年以内に返済予定のものを除く)", ibdRowSourceBorrowingsSchedule, 5_572_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "長期借入金"),
        ])
    }

    /// 1332 ニッスイ（入れ子・ラベルで明示）: BS 短期借入金 128,003 = 明細表「短期借入金」111,530 +「短期借入金(１年以内に返済予定の長期借入金)」16,473。
    @Test func ledger1332S100YHOQ() async throws {
        guard await Self.ensureAvailable("S100YHOQ") else { return }
        let (payload, _) = try await resolve("S100YHOQ", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 270_751_000_000, [
            ("その他有利子負債", ibdRowSourceBorrowingsSchedule, 1_149_000_000, nil, true, nil, nil, nil),
            ("短期借入金", ibdRowSourceBalanceSheet, 128_003_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("コマーシャル・ペーパー", ibdRowSourceBalanceSheet, 5_000_000_000, ibdMaturityCurrent, true, nil, nil, "コマーシャル・ペーパー"),
            ("長期借入金", ibdRowSourceBalanceSheet, 120_934_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("社債", ibdRowSourceBalanceSheet, 10_000_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("リース債務", ibdRowSourceBalanceSheet, 1_503_000_000, ibdMaturityCurrent, true, nil, nil, "リース債務"),
            ("リース債務", ibdRowSourceBalanceSheet, 4_162_000_000, ibdMaturityNonCurrent, true, nil, nil, "リース債務"),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 1_503_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 5, "リース債務"),
            ("リース債務(１年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 4_162_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 6, "リース債務"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 111_530_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "短期借入金"),
            ("短期借入金(１年以内に返済予定の長期借入金)", ibdRowSourceBorrowingsSchedule, 16_473_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "短期借入金"),
            ("コマーシャル・ペーパー", ibdRowSourceBorrowingsSchedule, 5_000_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "コマーシャル・ペーパー"),
            ("長期借入金(１年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 120_934_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 3, "長期借入金"),
        ])
    }

    /// 2607 不二製油（入れ子）: BS「借入金」（流動）158,541 = 明細表 短期 97,393 + 1年内 41,147 + CP 20,000（BS に CP 科目が無く、含めると一致するときだけ入れ子）。
    @Test func ledger2607S100YEWN() async throws {
        guard await Self.ensureAvailable("S100YEWN") else { return }
        let (payload, _) = try await resolve("S100YEWN", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 281_096_000_000, [
            ("社債（１年内償還予定を除く）", ibdRowSourceBorrowingsSchedule, 30_859_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("借入金", ibdRowSourceBalanceSheet, 158_541_000_000, ibdMaturityCurrent, true, nil, nil, "借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 78_980_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース負債", ibdRowSourceBalanceSheet, 2_615_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 10_101_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 97_393_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "借入金"),
            ("１年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 41_147_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "借入金"),
            ("コマーシャル・ペーパー", ibdRowSourceBorrowingsSchedule, 20_000_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "借入金"),
            ("長期借入金（１年内返済予定を除く）", ibdRowSourceBorrowingsSchedule, 78_980_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "長期借入金"),
        ])
    }

    /// 2413 エムスリー（逆向き）: 明細表「長期借入金（１年内返済予定の長期借入金を含む）」が BS の短期借入金と長期借入金に跨る。BS 科目を数え、明細表行は親を1行に決められないので対応先なし。
    @Test func ledger2413S100YJ25() async throws {
        guard await Self.ensureAvailable("S100YJ25") else { return }
        let (payload, _) = try await resolve("S100YJ25", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 60_494_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 4_166_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("長期借入金", ibdRowSourceBalanceSheet, 28_983_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("短期リース負債", ibdRowSourceBorrowingsSchedule, 6_371_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("長期リース負債", ibdRowSourceBorrowingsSchedule, 20_974_000_000, nil, true, nil, nil, nil),
            ("長期借入金（１年内返済予定の長期借入金を含む）", ibdRowSourceBorrowingsSchedule, 32_769_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, nil, nil),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 381_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, nil, nil),
        ])
    }

    /// 367A 逆向き: 明細表「借入金」1行が BS の流動・非流動の「借入金」2科目に跨る。BS 科目を数え、明細表行は対応先なし。
    @Test func ledger367AS100X66L() async throws {
        guard await Self.ensureAvailable("S100X66L") else { return }
        let (payload, _) = try await resolve("S100X66L", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 18_072_000_000, [
            ("借入金", ibdRowSourceBalanceSheet, 996_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("借入金", ibdRowSourceBalanceSheet, 12_447_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 1_684_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 2_945_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 4_629_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, nil, nil),
            ("借入金", ibdRowSourceBorrowingsSchedule, 13_444_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, nil, nil),
        ])
    }

    /// 3861 王子（入れ子）: J-GAAP 明細表の「その他有利子負債」67,000 は BS の CP 67,000 と同じ負債（同額でどの科目にも入らない行だけ）。
    @Test func ledger3861S100YJ8J() async throws {
        guard await Self.ensureAvailable("S100YJ8J") else { return }
        let (payload, _) = try await resolve("S100YJ8J", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 984_931_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 281_458_000_000, ibdMaturityCurrent, true, nil, nil, "短期借入金"),
            ("コマーシャル・ペーパー", ibdRowSourceBalanceSheet, 67_000_000_000, ibdMaturityCurrent, true, nil, nil, "コマーシャル・ペーパー"),
            ("長期借入金", ibdRowSourceBalanceSheet, 492_444_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("１年内償還予定の社債", ibdRowSourceBalanceSheet, 0, ibdMaturityCurrent, true, nil, nil, nil),
            ("社債", ibdRowSourceBalanceSheet, 115_000_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("１年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 6_536_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース債務(１年以内に返済予定のものを除く)", ibdRowSourceBorrowingsSchedule, 22_493_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 243_665_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("１年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 37_792_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "短期借入金"),
            ("その他有利子負債", ibdRowSourceBorrowingsSchedule, 67_000_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "コマーシャル・ペーパー"),
            ("長期借入金(１年以内に返済予定のものを除く)", ibdRowSourceBorrowingsSchedule, 492_444_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "長期借入金"),
        ])
    }

    /// 意図的な不一致の入れ子は needs_review にせず、BS と内訳の差を監査だけに残す（公開フィールドにしない）。
    @Test func nestingMismatchGapIsAuditedNotReviewed() async throws {
        guard await Self.ensureAvailable("S100Y02W") else { return }
        let (payload, audit) = try await resolve("S100Y02W", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.warnings.isEmpty)
        #expect(audit.sentences.contains {
            $0.contains("nesting_gap parent=長期借入金 balance_sheet=2704069000 components=2450892000 gap=253177000")
        })
        let json = try #require(payload.jsonObject()["rows"] as? [[String: Any]])
        #expect(json.allSatisfy { !$0.keys.contains("nesting_gap") && !$0.keys.contains("gap") })
    }

    // MARK: - パーサ修正の実 XBRL ゴールデン

    /// 豊田合成: 担保に供している資産の「対応する債務」表（285 百万円）を借入金の表として読まない。
    @Test func parserToyodaGoseiSkipsCollateralTable() async throws {
        guard await Self.ensureAvailable("S100YC23") else { return }
        let parsed = try #require(BorrowingsSchedule.extractRows(xbrlDir: Self.xbrlDir("S100YC23")))
        #expect(!parsed.rows.contains { $0.current == 285_000_000 || $0.prior == 285_000_000 })
        #expect(parsed.rows.compactMap(\.current).reduce(0, +) == 123_335_000_000)
    }

    /// すかいらーく: 担保表（1,259 / 2,823）を読まない。
    @Test func parserSkylarkSkipsCollateralTable() async throws {
        guard await Self.ensureAvailable("S100XUBI") else { return }
        let parsed = try #require(BorrowingsSchedule.extractRows(xbrlDir: Self.xbrlDir("S100XUBI")))
        let amounts = Set(parsed.rows.flatMap { [$0.current, $0.prior].compactMap { $0 } })
        #expect(!amounts.contains(1_259_000_000))
        #expect(!amounts.contains(2_823_000_000))
        #expect(parsed.rows.compactMap(\.current).reduce(0, +) == 123_668_000_000)
    }

    /// すかいらーく: 社債及び借入金注記の「合計」の後の「（その他の金融負債）」区分のリース負債。
    @Test func parserSkylarkTrailingOtherFinancialLiabilityLease() async throws {
        guard await Self.ensureAvailable("S100XUBI") else { return }
        let rows = BorrowingsSchedule.ifrsNoteOtherFinancialLiabilityLeaseRows(
            xbrlDir: Self.xbrlDir("S100XUBI"))
        #expect(rows.map(\.current) == [29_023_000_000, 94_938_000_000])
        #expect(rows.map(\.prior) == [27_032_000_000, 86_325_000_000])
        #expect(rows.allSatisfy { BorrowingsSchedule.isLeaseDebtScheduleRowLabel($0.sourceLabel ?? $0.label) })
    }

    /// 日機装: リース負債は列レイアウト表（帳簿価額 | 将来リース料 …）の帳簿価額。
    /// 使用権資産の表の帳簿価額 28,396 を拾わない。
    @Test func parserNikkisoColumnLayoutLeaseBookValue() async throws {
        guard await Self.ensureAvailable("S100XU3R") else { return }
        let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: Self.xbrlDir("S100XU3R"))
        #expect(lease.current == 27_492_000_000)
        #expect(lease.prior == 22_882_000_000)
    }

    /// テレビ東京: 1年内リース 214 の行（padding-left）を、隣の text-indent 行との字下げ食い違いで
    /// 区分小計と誤認して落とさない。
    @Test func parserTVTokyoKeepsCurrentLeaseRow() async throws {
        guard await Self.ensureAvailable("S100YCRR") else { return }
        let parsed = try #require(BorrowingsSchedule.extractRows(xbrlDir: Self.xbrlDir("S100YCRR")))
        #expect(parsed.rows.contains { $0.current == 214_000_000 && $0.prior == 181_000_000 })
    }

    /// 日清食品: 会社独自 TextBlock の主表（合計 204,314）を取る（担保表 592 / 1,971 ではない）。
    @Test func parserNissinPicksMainTableNotCollateral() async throws {
        guard await Self.ensureAvailable("S100YEWB") else { return }
        let parsed = try #require(BorrowingsSchedule.extractRows(xbrlDir: Self.xbrlDir("S100YEWB")))
        #expect(parsed.totalCurrent == 204_314_000_000)
        let amounts = Set(parsed.rows.compactMap(\.current))
        #expect(!amounts.contains(592_000_000))
        #expect(!amounts.contains(1_971_000_000))
        let deposit = try #require(parsed.rows.first { ($0.sourceLabel ?? $0.label).contains("受入保証金") })
        #expect(deposit.current == 320_000_000)
        #expect(InterestBearingDebtBreakdown.scheduleRowPreset("長期受入保証金") == .notInterestBearing)
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
        // 合計に数える行だけを比べる（除外行は expectLedger / 不変条件で見る）
        let actual = payload.rows.filter { $0.rowKind == "segment" && $0.inTotal == true }.map {
            ($0.label, $0.debtSource, $0.closing, $0.maturityClass)
        }
        #expect(actual.count == expected.count)
        for (got, want) in zip(actual, expected) {
            #expect(got.0 == want.0)
            #expect(got.1 == want.1)
            #expect(got.2 == want.2)
            #expect(got.3 == want.3)
        }
        expectInvariants(payload)
    }

    /// 全明細行（label_raw, source, closing, maturity, in_total, excluded_reason, paired_row_index）と合計。
    private func expectLedger(
        _ payload: BreakdownSnapshotPayload, total: Double,
        _ expected: [(String, String, Double?, String?, Bool, String?, Int?, String?)],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = payload.rows.filter { $0.rowKind == "segment" }
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (got, want) in zip(actual, expected) {
            #expect(got.labelRaw == want.0, sourceLocation: sourceLocation)
            #expect(got.debtSource == want.1, "\(want.0)", sourceLocation: sourceLocation)
            #expect(got.closing == want.2, "\(want.0)", sourceLocation: sourceLocation)
            #expect(got.maturityClass == want.3, "\(want.0)", sourceLocation: sourceLocation)
            #expect(got.inTotal == want.4, "\(want.0)", sourceLocation: sourceLocation)
            #expect(got.excludedReason == want.5, "\(want.0)", sourceLocation: sourceLocation)
            #expect(got.pairedRowIndex == want.6, "\(want.0)", sourceLocation: sourceLocation)
            #expect(got.categoryGroup == want.7, "\(want.0)", sourceLocation: sourceLocation)
            // 内訳行は category = 自分のラベル、親行は category = null
            if got.pairedRowIndex != nil {
                #expect(got.category == got.label, "\(want.0)", sourceLocation: sourceLocation)
            } else {
                #expect(got.category == nil, "\(want.0)", sourceLocation: sourceLocation)
            }
        }
        #expect(payload.rows.last?.label == "合計", sourceLocation: sourceLocation)
        #expect(payload.rows.last?.closing == total, sourceLocation: sourceLocation)
        expectInvariants(payload, sourceLocation: sourceLocation)
    }

    /// 合計 == in_total 行の和（完全一致）。除外行は 4 値の理由、数える行は理由・対応先なし。
    /// 対応先はこの payload の rows 添字で、数える行を指す。
    private func expectInvariants(
        _ payload: BreakdownSnapshotPayload, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let segments = payload.rows.filter { $0.rowKind == "segment" }
        let sum = segments.filter { $0.inTotal == true }.reduce(0.0) { $0 + ($1.closing ?? 0) }
        #expect(payload.rows.last?.closing == sum, sourceLocation: sourceLocation)
        for (index, row) in payload.rows.enumerated() where row.rowKind == "segment" {
            #expect(row.inTotal != nil, sourceLocation: sourceLocation)
            if row.inTotal == true {
                #expect(row.excludedReason == nil, sourceLocation: sourceLocation)
                #expect(row.pairedRowIndex == nil, sourceLocation: sourceLocation)
            } else {
                #expect(row.excludedReason.map { ibdExcludedReasons.contains($0) } == true,
                    sourceLocation: sourceLocation)
                if let paired = row.pairedRowIndex {
                    #expect(paired != index, sourceLocation: sourceLocation)
                    #expect(payload.rows.indices.contains(paired) && payload.rows[paired].inTotal == true,
                        sourceLocation: sourceLocation)
                }
            }
        }
    }

    private enum ResolveError: Error { case notResolved }
}
