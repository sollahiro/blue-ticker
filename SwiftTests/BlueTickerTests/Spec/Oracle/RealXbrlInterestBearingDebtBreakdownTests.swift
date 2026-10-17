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

/// 明細表の未分類行（「その他」）も有利子負債と答えるデサイダ（LINEヤフーの単一集約の検証用）。
private struct AllInterestBearingIBDDecider: InterestBearingDebtDeciding {
    func classifyRow(
        label: String, source: String, tag: String?, closingYen: Double?,
        siblingLabels: [String]
    ) async -> IBDChoice {
        IBDChoice(selected: IBDRowClass.interestBearingDebt.rawValue, probability: 0.95)
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

    /// ソニー: 明細表が帯内。リースは BS。BS「長期借入債務」（会社拡張 LongTermDebt2NCLIFRS）は
    /// ラベル規則（借入債務）でコード分類になり分母に入るので coverage 1.0。
    @Test func sonyUsesBorrowingsSchedule() async throws {
        guard await Self.ensureAvailable("S100YE2C") else { return }
        let (payload, _) = try await resolve("S100YE2C", decider: GoldenIBDDecider())
        #expect(payload.needsReview == false)
        #expect(payload.warnings.isEmpty)
        #expect(payload.denominator == 1_669_669_000_000)
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

    /// ソニーの「長期借入債務」は会社拡張要素。Jev 無しでもラベル規則で債務に確定する。
    @Test func sonyWithoutDeciderResolvesExtensionByLabelRule() async throws {
        guard await Self.ensureAvailable("S100YE2C") else { return }
        let inputs = InterestBearingDebtBreakdown.inputs(xbrlDir: Self.xbrlDir("S100YE2C"))
        let ext = try #require(inputs.balanceSheet.first { $0.tag == "LongTermDebt2NCLIFRS" })
        #expect(ext.presetClass == .interestBearingDebt)
        #expect(ext.sourceTag == "LongTermDebt2NCLIFRS")
        let (payload, _) = try await resolve("S100YE2C", decider: nil, inputs: inputs)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 1_669_669_000_000)
        expectSourceTags(payload, [
            "長期借入金": "NotesShortTermBorrowingsAndLongTermDebtConsolidatedFinancialStatementsIFRSTextBlock",
        ])
        let leaseTags = payload.rows.filter { $0.labelRaw == "リース負債" }.map(\.sourceTag)
        #expect(leaseTags == ["LeaseLiabilitiesCLIFRS", "LeaseLiabilitiesNCLIFRS"])
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
            ("リース負債", ibdRowSourceBorrowingsSchedule, 74_540_000_000, nil),  // 区分の分からない行は開示どおり
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
            // 2026-10-11: 会社拡張「長期借入債務」をラベル規則で確定し、軸が解決する（旧 845,276 は
            // legacy が拡張要素を読めず長期借入債務を落としていた値）。
            ("S100YE2C", 1_669_669_000_000, "breakdown.interest_bearing_debt"),
        ]
        for (docID, expected, method) in cases {
            guard await Self.ensureAvailable(docID) else { continue }
            let canonical = await BreakdownFinancialsResolver.financialsCanonicalInterestBearingDebt(
                xbrlDir: Self.xbrlDir(docID))
            #expect(canonical.total == expected)
            #expect(canonical.method == method)
        }
    }

    /// 三菱UFJ: 銀行は bank components を行にする。預金 228,512,749・譲渡性預金 17,374,010 は
    /// 有利子負債に含めない（Sorahiro 判断 2026-10-11）。旧合計 286,946,640 − 245,886,759 = 41,059,881。
    @Test func mufgUsesBankComponents() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let (payload, audit) = try await resolve("S100W4FB", decider: GoldenIBDDecider())
        #expect(payload.needsReview == false)
        #expect(payload.denominatorTag == "bank_components")
        expectRows(payload, [
            ("コマーシャル・ペーパー", ibdRowSourceFinancialsBankComponents, 3_475_042_000_000, nil),
            ("借用金", ibdRowSourceFinancialsBankComponents, 22_101_954_000_000, nil),
            ("短期社債", ibdRowSourceFinancialsBankComponents, 1_373_236_000_000, ibdMaturityCurrent),
            ("社債", ibdRowSourceFinancialsBankComponents, 14_018_955_000_000, nil),
            ("リース債務", ibdRowSourceBorrowingsSchedule, 90_694_000_000, nil),  // 区分の分からない行は開示どおり
        ])
        #expect(payload.rows.last?.closing == 41_059_881_000_000)
        #expect(!payload.rows.contains { $0.labelRaw.contains("預金") })
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
            // 「その他有利子負債」見出しの下の内訳（値セルの `<p>` は1つ）。見出しで有利子負債に確定する。
            ("関係会社預り金（１年以内に返済予定）", ibdRowSourceBorrowingsSchedule, 1_149_000_000, ibdMaturityCurrent, true, nil, nil, nil),
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

    /// 3861 王子（入れ子）: J-GAAP 明細表の「その他有利子負債」見出しの下の CP 67,000 は BS の CP 67,000 と同じ負債。
    /// 値セルの `<p>` は1つで、見出しではなく CP の行に付く。
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
            ("コマーシャル・ペーパー（１年以内に返済予定）", ibdRowSourceBorrowingsSchedule, 67_000_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "コマーシャル・ペーパー"),
            ("長期借入金(１年以内に返済予定のものを除く)", ibdRowSourceBorrowingsSchedule, 492_444_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "長期借入金"),
        ])
    }

    /// 9531 東京ガス: 明細表のラベルセルに「その他有利子負債」「コマーシャル・ペーパー（１年以内返済予定）」の
    /// 2つの `<p>`、値セルは `<p>` 1つ（前期 10,000 / 当期 50,000）。値は見出しではなく CP の行に付く。
    /// BS に CP 科目は無い（その他の流動負債に含む）ので明細表の CP を数える。
    @Test func tokyoGasCommercialPaperKeepsItsLabel() async throws {
        guard await Self.ensureAvailable("S100YH8W") else { return }
        let (payload, _) = try await resolve("S100YH8W", decider: nil)
        #expect(payload.needsReview == false)
        let cp = payload.rows.filter { $0.debtSource == ibdRowSourceBorrowingsSchedule && $0.inTotal == true }
            .first { $0.labelRaw.contains("コマーシャル") }
        #expect(cp?.labelRaw == "コマーシャル・ペーパー（１年以内返済予定）")
        #expect(cp?.closing == 50_000_000_000)
        #expect(cp?.opening == 10_000_000_000)
        #expect(cp?.maturityClass == ibdMaturityCurrent)
        #expect(!payload.rows.contains { $0.labelRaw == "その他有利子負債" })
        #expect(payload.rows.last?.closing == 1_277_236_000_000)
    }

    /// 4665: BS に流動リース科目が無い（非流動 0 だけ）とき、明細表の1年内リース 2 を選択段階の帯判定でも数える（明細表を退けない）。
    @Test func ledger4665S100YEAI() async throws {
        guard await Self.ensureAvailable("S100YEAI") else { return }
        let (payload, _) = try await resolve("S100YEAI", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 5_000_000, [
            ("１年内返済予定の長期借入金", ibdRowSourceBalanceSheet, 1_000_000, ibdMaturityCurrent, true, nil, nil, "１年内返済予定の長期借入金"),
            ("長期借入金", ibdRowSourceBalanceSheet, 2_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期借入金"),
            ("リース債務", ibdRowSourceBalanceSheet, 0, ibdMaturityNonCurrent, true, nil, nil, "リース債務"),
            ("1年以内に返済予定のリース債務", ibdRowSourceBorrowingsSchedule, 2_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース債務(1年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 0, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 2, "リース債務"),
            ("1年以内に返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 1_000_000, ibdMaturityCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 0, "１年内返済予定の長期借入金"),
            ("長期借入金(1年以内に返済予定のものを除く。)", ibdRowSourceBorrowingsSchedule, 2_000_000, ibdMaturityNonCurrent, false, ibdExcludedReasonDuplicateOfBalanceSheet, 1, "長期借入金"),
        ])
    }

    /// 3387（区分を跨ぐ入れ子）: 明細表の素の「長期借入金」21,045 = BS 非流動「借入金」15,208 + 流動の合算科目「社債及び借入金」5,837。両方を親として数え、明細表行は対応先なしの重複。
    @Test func ledger3387S100Y2PC() async throws {
        guard await Self.ensureAvailable("S100Y2PC") else { return }
        let (payload, _) = try await resolve("S100Y2PC", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 65_037_000_000, [
            ("短期借入金", ibdRowSourceBorrowingsSchedule, nil, ibdMaturityCurrent, true, nil, nil, nil),
            ("社債", ibdRowSourceBorrowingsSchedule, nil, nil, true, nil, nil, nil),
            ("借入金", ibdRowSourceBalanceSheet, 15_208_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("社債及び借入金", ibdRowSourceBalanceSheet, 5_837_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 11_319_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 32_673_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 43_992_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, nil, nil),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 21_045_000_000, nil, false, ibdExcludedReasonDuplicateOfBalanceSheet, nil, nil),
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

    // MARK: - タクソノミ preset・リース込み有利子負債・除外リスト（2026-10-11）

    private static let jgaapSchedule = "AnnexedConsolidatedDetailedScheduleOfBorrowingsTextBlock"
    private static let ifrsLeaseNote = "NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock"

    /// source_tag（期待値）: label_raw → ローカル名。
    private func expectSourceTags(
        _ payload: BreakdownSnapshotPayload, _ expected: [String: String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (label, tag) in expected {
            let rows = payload.rows.filter { $0.labelRaw == label && $0.rowKind == "segment" }
            #expect(!rows.isEmpty, "\(label)", sourceLocation: sourceLocation)
            for row in rows {
                #expect(row.sourceTag == tag, "\(label)", sourceLocation: sourceLocation)
            }
        }
        #expect(payload.rows.last?.label == "合計", sourceLocation: sourceLocation)
        #expect(payload.rows.last?.sourceTag == nil, sourceLocation: sourceLocation)
    }

    /// ニデック: BS「１年以内返済予定長期債務」は会社拡張要素（LongTermDebtDueWithinOneYearCLIFRS）。
    /// 手書きのタグ一覧ではなくラベル規則（長期債務）で債務に確定する。Jev 無しで 1,113,404。
    @Test func nidecExtensionCurrentPortionByLabelRule() async throws {
        guard await Self.ensureAvailable("S100Z5CA") else { return }
        let (payload, _) = try await resolve("S100Z5CA", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 1_113_404_000_000, [
            ("短期借入金", ibdRowSourceBalanceSheet, 587_026_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("１年以内返済予定長期債務", ibdRowSourceBalanceSheet, 95_106_000_000, ibdMaturityCurrent, true, nil, nil, nil),
            ("長期債務", ibdRowSourceBalanceSheet, 431_272_000_000, ibdMaturityNonCurrent, true, nil, nil, nil),
        ])
        // 標準要素・会社拡張要素とも、提出どおりのローカル名
        expectSourceTags(payload, [
            "短期借入金": "BorrowingsCLIFRS",
            "１年以内返済予定長期債務": "LongTermDebtDueWithinOneYearCLIFRS",
            "長期債務": "LongTermDebtNCLIFRS",
        ])
    }

    /// トヨタ: BS は「有利子負債」集約（流動/非流動）だけでリース科目が無い。明細表（借入債務・
    /// リース負債）はその内訳で、集約がリースを含む。リースを二重に足さない。
    @Test func toyotaLeaseInclusiveInterestBearingAggregate() async throws {
        guard await Self.ensureAvailable("S100Y8NY") else { return }
        let (payload, _) = try await resolve("S100Y8NY", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.denominator == 43_205_469_000_000)
        let dup = ibdExcludedReasonDuplicateOfBalanceSheet
        expectLedger(payload, total: 43_205_469_000_000, [
            ("有利子負債", ibdRowSourceBalanceSheet, 17_581_104_000_000, ibdMaturityCurrent, true, nil, nil, "有利子負債"),
            ("有利子負債", ibdRowSourceBalanceSheet, 25_624_365_000_000, ibdMaturityNonCurrent, true, nil, nil, "有利子負債"),
            ("短期借入債務", ibdRowSourceBorrowingsSchedule, 5_699_083_000_000, ibdMaturityCurrent, false, dup, 0, "有利子負債"),
            ("１年以内返済予定長期借入債務", ibdRowSourceBorrowingsSchedule, 11_718_586_000_000, ibdMaturityCurrent, false, dup, 0, "有利子負債"),
            ("長期借入債務", ibdRowSourceBorrowingsSchedule, 25_076_787_000_000, nil, false, dup, 1, "有利子負債"),
            ("１年以内返済予定長期リース負債", ibdRowSourceBorrowingsSchedule, 163_435_000_000, ibdMaturityCurrent, false, dup, 0, "有利子負債"),
            ("長期リース負債", ibdRowSourceBorrowingsSchedule, 547_578_000_000, nil, false, dup, 1, "有利子負債"),
        ])
        expectSourceTags(payload, [
            "短期借入債務": Xbrl.ifrsInterestBearingLiabilitiesTextblockTag,
            "長期リース負債": Xbrl.ifrsInterestBearingLiabilitiesTextblockTag,
        ])
        let legacy = IBDExtractor.extractCanonical(xbrlDir: Self.xbrlDir("S100Y8NY"))
        #expect(legacy.total == 43_205_469_000_000)
    }

    /// ブロードリーフ: 千円の有利子負債注記に区分見出しが無く、流動分のリース負債が素の「リース負債」。
    /// 区分を作らず（maturity=null・ラベルは開示どおり）、金額の一致で流動の親
    /// （2,559,182 + 514,505 = 3,073,687 千円）に入れる。
    @Test func broadleafBareLeaseRowNestsUnderCurrentAggregate() async throws {
        guard await Self.ensureAvailable("S100XS43") else { return }
        let (payload, _) = try await resolve("S100XS43", decider: nil)
        #expect(payload.needsReview == false)
        let dup = ibdExcludedReasonDuplicateOfBalanceSheet
        expectLedger(payload, total: 4_457_558_000, [
            ("短期有利子負債", ibdRowSourceBalanceSheet, 3_073_687_000, ibdMaturityCurrent, true, nil, nil, "短期有利子負債"),
            ("長期有利子負債", ibdRowSourceBalanceSheet, 1_383_871_000, ibdMaturityNonCurrent, true, nil, nil, "長期有利子負債"),
            ("１年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 2_559_182_000, ibdMaturityCurrent, false, dup, 0, "短期有利子負債"),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 1_159_135_000, nil, false, dup, 1, "長期有利子負債"),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 514_505_000, nil, false, dup, 0, "短期有利子負債"),
            ("長期リース負債", ibdRowSourceBorrowingsSchedule, 224_736_000, nil, false, dup, 1, "長期有利子負債"),
        ])
        // 区分の分からない行に「（非流動）」を作らない
        let bare = try #require(payload.rows.first { $0.labelRaw == "リース負債" })
        #expect(bare.label == "リース負債")
        #expect(payload.rows.first { $0.labelRaw == "長期リース負債" }?.label == "リース負債（非流動）")
    }

    /// AGC: 集約2本（短期／長期有利子負債）に、ラベル規則で債務に確定した会社拡張
    /// `LongTermInterestBearingDebtDueWithinOneYearCLIFRS`（1年内返済予定の長期有利子負債）が3本目の
    /// BS 行として並ぶ。拡張行も流動の親として内訳を受ける。期末値の無い「1年内償還予定の社債」は
    /// 流動の親が2つあるので対応先なし。
    @Test func agcExtensionCurrentRowJoinsAggregateParents() async throws {
        guard await Self.ensureAvailable("S100XSTU") else { return }
        let (payload, _) = try await resolve("S100XSTU", decider: nil)
        #expect(payload.needsReview == false)
        let dup = ibdExcludedReasonDuplicateOfBalanceSheet
        let ext = "1年内返済予定の長期有利子負債"
        expectLedger(payload, total: 646_463_000_000, [
            ("短期有利子負債", ibdRowSourceBalanceSheet, 98_538_000_000, ibdMaturityCurrent, true, nil, nil, "短期有利子負債"),
            (ext, ibdRowSourceBalanceSheet, 118_411_000_000, ibdMaturityCurrent, true, nil, nil, ext),
            ("長期有利子負債", ibdRowSourceBalanceSheet, 429_514_000_000, ibdMaturityNonCurrent, true, nil, nil, "長期有利子負債"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 85_556_000_000, ibdMaturityCurrent, false, dup, 0, "短期有利子負債"),
            ("コマーシャル・ペーパー", ibdRowSourceBorrowingsSchedule, 12_981_000_000, nil, false, dup, 0, "短期有利子負債"),
            ("1年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 103_450_000_000, ibdMaturityCurrent, false, dup, 1, ext),
            ("1年内償還予定の社債", ibdRowSourceBorrowingsSchedule, nil, ibdMaturityCurrent, false, dup, nil, nil),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 265_384_000_000, nil, false, dup, 2, "長期有利子負債"),
            ("社債", ibdRowSourceBorrowingsSchedule, 99_789_000_000, nil, false, dup, 2, "長期有利子負債"),
            ("短期リース負債", ibdRowSourceBorrowingsSchedule, 14_960_000_000, ibdMaturityCurrent, false, dup, 1, ext),
            ("長期リース負債", ibdRowSourceBorrowingsSchedule, 64_340_000_000, nil, false, dup, 2, "長期有利子負債"),
        ])
        expectSourceTags(payload, [
            ext: "LongTermInterestBearingDebtDueWithinOneYearCLIFRS",
            "短期有利子負債": "InterestBearingLiabilitiesCLIFRS",
        ])
    }

    /// 東静: 千円の有利子負債注記が「流動負債」「非流動負債」の区分ごとに合計を置く。以前は最初の
    /// 「合計」で打ち切り非流動を落として明細表が帯外（coverage 0.1513）。両区分を読み、区分の
    /// 素の「リース負債」は区分で流動／非流動になる。
    @Test func toseiSectionedThousandYenNoteReadsBothSections() async throws {
        guard await Self.ensureAvailable("S100XMC1") else { return }
        let (payload, _) = try await resolve("S100XMC1", decider: nil)
        #expect(payload.needsReview == false)
        #expect(!payload.warnings.contains(breakdownWarningIBDScheduleRejected))
        let dup = ibdExcludedReasonDuplicateOfBalanceSheet
        expectLedger(payload, total: 182_640_328_000, [
            ("有利子負債", ibdRowSourceBalanceSheet, 27_625_866_000, ibdMaturityCurrent, true, nil, nil, "有利子負債"),
            ("有利子負債", ibdRowSourceBalanceSheet, 155_014_462_000, ibdMaturityNonCurrent, true, nil, nil, "有利子負債"),
            ("短期借入金", ibdRowSourceBorrowingsSchedule, 6_350_090_000, ibdMaturityCurrent, false, dup, 0, "有利子負債"),
            ("１年内返済予定の長期借入金", ibdRowSourceBorrowingsSchedule, 21_020_294_000, ibdMaturityCurrent, false, dup, 0, "有利子負債"),
            ("１年内償還予定の社債", ibdRowSourceBorrowingsSchedule, 11_356_000, ibdMaturityCurrent, false, dup, 0, "有利子負債"),
            ("長期借入金", ibdRowSourceBorrowingsSchedule, 153_382_261_000, ibdMaturityNonCurrent, false, dup, 1, "有利子負債"),
            ("社債", ibdRowSourceBorrowingsSchedule, 232_118_000, ibdMaturityNonCurrent, false, dup, 1, "有利子負債"),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 244_125_000, ibdMaturityCurrent, false, dup, 0, "有利子負債"),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 1_400_083_000, ibdMaturityNonCurrent, false, dup, 1, "有利子負債"),
        ])
        let leases = payload.rows.filter { $0.labelRaw == "リース負債" }.map(\.label)
        #expect(leases == ["リース負債（流動）", "リース負債（非流動）"])
        // 注記の表合計（notes の borrowings_schedule・/financials フォールバック）は区分小計の和で、
        // 内訳の和と一致する（流動の小計を二重に数えない）
        let dir = Self.xbrlDir("S100XMC1")
        let notes = try #require(BorrowingsSchedule.extractRows(xbrlDir: dir))
        #expect(notes.totalCurrent == 182_640_328_000)
        #expect(notes.totalPrior == 165_900_807_000)
        // 開示の端数: 流動の内訳の和 27,625,865 千円に対し小計 27,625,866 千円
        #expect(notes.rows.compactMap(\.current).reduce(0, +) == 182_640_327_000)
        let fallback = try #require(BorrowingsSchedule.extract(xbrlDir: dir, accountingStandard: "IFRS"))
        #expect(fallback.total == 182_640_328_000)
        #expect(fallback.priorTotal == 165_900_807_000)
        #expect(IBDExtractor.extractCanonical(xbrlDir: dir).total == 182_640_328_000)
    }

    /// LINEヤフー: BS は区分の無い単一の集約 `InterestBearingLiabilitiesLiabilitiesIFRS`（リース込み）。
    /// 明細表の行（リース・その他を含む）はすべてその1つの親に入る。デサイダ無しでは「その他」が
    /// 未分類のため入れ子にせず明細表の行を数える（needs_review）。
    @Test func lineYahooSingleLiquidityOrderAggregateParent() async throws {
        guard await Self.ensureAvailable("S100YBXD") else { return }
        let (payload, _) = try await resolve("S100YBXD", decider: AllInterestBearingIBDDecider())
        #expect(payload.needsReview == false)
        let dup = ibdExcludedReasonDuplicateOfBalanceSheet
        expectLedger(payload, total: 1_961_998_000_000, [
            ("有利子負債", ibdRowSourceBalanceSheet, 1_961_998_000_000, nil, true, nil, nil, "有利子負債"),
            ("借入金(注)３", ibdRowSourceBorrowingsSchedule, 1_208_219_000_000, nil, false, dup, 0, "有利子負債"),
            ("コマーシャル・ペーパー", ibdRowSourceBorrowingsSchedule, 73_000_000_000, nil, false, dup, 0, "有利子負債"),
            ("社債(注)４", ibdRowSourceBorrowingsSchedule, 474_344_000_000, nil, false, dup, 0, "有利子負債"),
            ("その他", ibdRowSourceBorrowingsSchedule, 1_232_000_000, nil, false, dup, 0, "有利子負債"),
            ("リース負債", ibdRowSourceBorrowingsSchedule, 205_201_000_000, nil, false, dup, 0, "有利子負債"),
        ])
        expectSourceTags(payload, ["有利子負債": "InterestBearingLiabilitiesLiabilitiesIFRS"])
        let (noDecider, _) = try await resolve("S100YBXD", decider: nil)
        #expect(noDecider.needsReview == true)
        #expect(noDecider.rows.last?.closing == 1_960_764_000_000)
        let legacy = IBDExtractor.extractCanonical(xbrlDir: Self.xbrlDir("S100YBXD"))
        #expect(legacy.total == 1_961_998_000_000)
    }

    /// RIZAP: 「有利子負債」集約 63,674 = 明細表（リース込み）。以前はリース 36,159 を二重に足し 99,833。
    @Test func rizapLeaseInclusiveInterestBearingAggregate() async throws {
        guard await Self.ensureAvailable("S100YF9Y") else { return }
        let (payload, _) = try await resolve("S100YF9Y", decider: nil)
        #expect(payload.needsReview == false)
        expectRows(payload, [
            ("有利子負債", ibdRowSourceBalanceSheet, 31_406_000_000, ibdMaturityCurrent),
            ("有利子負債", ibdRowSourceBalanceSheet, 32_268_000_000, ibdMaturityNonCurrent),
        ])
        #expect(payload.rows.last?.closing == 63_674_000_000)
        let lease = try #require(payload.rows.first { $0.labelRaw == "１年内返済予定のリース負債" })
        #expect(lease.inTotal == false)
        #expect(lease.excludedReason == ibdExcludedReasonDuplicateOfBalanceSheet)
        #expect(payload.rows[lease.pairedRowIndex ?? -1].maturityClass == ibdMaturityCurrent)
        let legacy = IBDExtractor.extractCanonical(xbrlDir: Self.xbrlDir("S100YF9Y"))
        #expect(legacy.total == 63_674_000_000)
    }

    /// 夢展望: IFRS 有利子負債注記は千円表で、単位は表の外の見出しにだけある。百万円と読まない。
    @Test func yumetenboThousandYenNoteAndLeaseInclusiveAggregate() async throws {
        guard await Self.ensureAvailable("S100YG5J") else { return }
        let parsed = try #require(BorrowingsSchedule.extractRows(xbrlDir: Self.xbrlDir("S100YG5J")))
        let lease = try #require(parsed.rows.first { ($0.sourceLabel ?? $0.label).contains("１年内返済予定のリース負債") })
        #expect(lease.current == 36_556_000)
        let (payload, _) = try await resolve("S100YG5J", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 1_308_733_000)
        #expect(payload.rows.filter { $0.inTotal == true }.map(\.closing) == [1_157_640_000, 151_093_000])
    }

    /// 大和証券グループ: 信用取引借入金・現先取引借入金（証券業の営業借入）は合計に入れず
    /// scope_differs、有価証券貸借取引受入金（担保受入）は non_interest_bearing の行として残す。
    @Test func daiwaSecuritiesBusinessBorrowingsExcluded() async throws {
        guard await Self.ensureAvailable("S100YCMP") else { return }
        let (payload, _) = try await resolve("S100YCMP", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 5_779_091_000_000)
        func row(_ label: String, _ source: String) throws -> BreakdownRowPayload {
            try #require(payload.rows.first { $0.labelRaw == label && $0.debtSource == source })
        }
        for (label, source, reason, amount) in [
            ("信用取引借入金", ibdRowSourceBalanceSheet, ibdExcludedReasonScopeDiffers, 4_904_000_000.0),
            ("現先取引借入金", ibdRowSourceBalanceSheet, ibdExcludedReasonScopeDiffers, 4_428_695_000_000),
            ("信用取引借入金（１年内返済予定）", ibdRowSourceBorrowingsSchedule, ibdExcludedReasonScopeDiffers, 4_904_000_000),
            ("有価証券貸借取引受入金", ibdRowSourceBalanceSheet, ibdExcludedReasonNonInterestBearing, 9_379_709_000_000),
        ] {
            let r = try row(label, source)
            #expect(r.inTotal == false, "\(label)")
            #expect(r.excludedReason == reason, "\(label)")
            #expect(r.closing == amount, "\(label)")
        }
        expectSourceTags(payload, [
            "信用取引借入金": "BorrowingsOnMarginTransactionsCLSEC",
            "現先取引借入金": "BorrowingsOnGensakiTransactionCLSEC",
            "信用取引借入金（１年内返済予定）": Self.jgaapSchedule,
            "コマーシャル・ペーパー": "CommercialPapersLiabilities",
        ])
        expectInvariants(payload)
    }

    /// 住友ファーマ: リース注記の「リース負債（流動）／（非流動）」行（B/C 以外の形）を拾う。
    @Test func sumitomoPharmaLeaseNoteCurrentNonCurrentRows() async throws {
        guard await Self.ensureAvailable("S100YH3M") else { return }
        let (payload, _) = try await resolve("S100YH3M", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 224_216_000_000)
        let current = try #require(payload.rows.first { $0.labelRaw == "リース負債（流動）" })
        #expect(current.closing == 1_914_000_000)
        #expect(current.maturityClass == ibdMaturityCurrent)
        #expect(current.inTotal == true)
        expectSourceTags(payload, [
            "リース負債（流動）": Self.ifrsLeaseNote,
            "リース負債（非流動）": Self.ifrsLeaseNote,
            "借入金": "BorrowingsCLIFRS",
            "短期借入金": Xbrl.ifrsBondsAndBorrowingsTextblockTag,
        ])
        expectInvariants(payload)
    }

    /// 丸紅: BS は社債及び借入金だけ。リース注記の流動 73,894 / 非流動 172,480 を足す（+246,374）。
    @Test func marubeniLeaseNoteRowsAdded() async throws {
        guard await Self.ensureAvailable("S100YAY4") else { return }
        let (payload, _) = try await resolve("S100YAY4", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 2_656_351_000_000)
        let lease = payload.rows.filter { $0.debtSource == ibdRowSourceLeaseNote && $0.inTotal == true }
        #expect(lease.map(\.closing) == [73_894_000_000, 172_480_000_000])
        #expect(lease.allSatisfy { $0.sourceTag == Self.ifrsLeaseNote })
    }

    /// 4755 楽天グループ: BS 4科目（社債及び借入金・証券/カード/銀行事業の借入金）に、リース注記
    /// 「財政状態計算書で認識された金額」表の「リース負債(注)２」361,443 を足す（BS はその他の金融負債に含めて
    /// 表示）。年度末 5,931,065 = 有報 注記28 の調整表合計。期首 5,461,713 + 352,856 = 5,814,569。
    @Test func rakutenLeaseNoteRecognisedAmountsRow() async throws {
        guard await Self.ensureAvailable("S100XTNW") else { return }
        let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: Self.xbrlDir("S100XTNW"))
        #expect(lease.current == 361_443_000_000)
        #expect(lease.prior == 352_856_000_000)
        let (payload, _) = try await resolve("S100XTNW", decider: nil)
        #expect(payload.needsReview == false)
        let rows = payload.rows.filter { $0.rowKind == "segment" }
        #expect(rows.map(\.labelRaw) == ["社債及び借入金", "証券事業の借入金", "カード事業の社債及び借入金", "銀行事業の借入金", "リース負債"])
        #expect(rows.map(\.closing) == [1_598_052_000_000, 269_228_000_000, 810_559_000_000, 2_891_783_000_000, 361_443_000_000])
        #expect(rows.allSatisfy { $0.inTotal == true })
        #expect(rows.last?.debtSource == ibdRowSourceLeaseNote)
        #expect(payload.rows.last?.closing == 5_931_065_000_000)
        #expect(payload.rows.last?.opening == 5_814_569_000_000)
        expectInvariants(payload)
    }

    /// 8508 Ｊトラスト（S100XSDT）: 前期・当期で分けた満期表の列「帳簿価額」を読む。
    @Test func splitMaturityTablesLeaseBookValue() async throws {
        guard await Self.ensureAvailable("S100XSDT") else { return }
        let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: Self.xbrlDir("S100XSDT"))
        #expect(lease.current == 4_653_000_000)
        #expect(lease.prior == 5_278_000_000)
    }

    /// 8697 日本取引所グループ（S100YA84）: 1表を期間行で区切った満期表の列「帳簿残高」を読む。
    @Test func periodRowMaturityTableLeaseBookBalance() async throws {
        guard await Self.ensureAvailable("S100YA84") else { return }
        let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: Self.xbrlDir("S100YA84"))
        #expect(lease.current == 4_511_000_000)
        #expect(lease.prior == 584_000_000)
        let (payload, _) = try await resolve("S100YA84", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 57_004_000_000)
    }

    /// サワイ: リース注記の値の後ろの空 <td> を飛ばす（当期 3,967 を前期と読まない）。
    @Test func sawaiLeaseNoteSpacerCells() async throws {
        guard await Self.ensureAvailable("S100YITS") else { return }
        let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: Self.xbrlDir("S100YITS"))
        #expect(lease.current == 3_967_000_000)
        #expect(lease.prior == 3_767_000_000)
        let (payload, _) = try await resolve("S100YITS", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 108_990_000_000)
    }

    /// 新日本科学: 明細表の「一年以内に返済予定の…」（漢数字）を流動と読む。
    @Test func shinNipponBiomedicalKanjiOneYearMaturity() async throws {
        guard await Self.ensureAvailable("S100YK73") else { return }
        let (payload, _) = try await resolve("S100YK73", decider: nil)
        #expect(payload.needsReview == false)
        #expect(payload.rows.last?.closing == 41_391_601_000)
        for label in ["一年以内に返済予定の長期借入金", "一年以内に返済予定のリース債務"] {
            let row = try #require(payload.rows.first { $0.labelRaw == label })
            #expect(row.maturityClass == ibdMaturityCurrent, "\(label)")
        }
        let nonCurrent = try #require(payload.rows.first { $0.labelRaw == "長期借入金(一年以内に返済予定のものを除く)" })
        #expect(nonCurrent.maturityClass == ibdMaturityNonCurrent)
        expectSourceTags(payload, [
            "一年以内に返済予定のリース債務": Self.jgaapSchedule,
            "リース債務": "LeaseObligationsNCL",
        ])
    }

    /// SBI アルヒ: 流動性配列の IFRS BS（BorrowingsLiabilitiesIFRS / BondsPayableLiabilitiesIFRS /
    /// LeaseLiabilitiesLiabilitiesIFRS）をコードで確定する。
    @Test func sbiAruhiLiquidityOrderBalanceSheet() async throws {
        guard await Self.ensureAvailable("S100YFMO") else { return }
        let (payload, _) = try await resolve("S100YFMO", decider: nil)
        #expect(payload.needsReview == false)
        expectLedger(payload, total: 132_182_000_000, [
            ("社債", ibdRowSourceBalanceSheet, 11_377_000_000, nil, true, nil, nil, nil),
            ("借入債務", ibdRowSourceBalanceSheet, 120_313_000_000, nil, true, nil, nil, nil),
            ("リース負債", ibdRowSourceBalanceSheet, 492_000_000, nil, true, nil, nil, nil),
        ])
        expectSourceTags(payload, [
            "社債": "BondsPayableLiabilitiesIFRS",
            "借入債務": "BorrowingsLiabilitiesIFRS",
            "リース負債": "LeaseLiabilitiesLiabilitiesIFRS",
        ])
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
        // source_tag: 合計行（コードで足した値）は null。明細行は XBRL 要素のローカル名
        // （名前空間・URI なし）。明細表・注記の行は TextBlock か直接タグ経路の数値要素。
        #expect(payload.rows.last?.sourceTag == nil, sourceLocation: sourceLocation)
        for row in segments {
            let tag = row.sourceTag ?? ""
            #expect(!tag.isEmpty, "\(row.labelRaw)", sourceLocation: sourceLocation)
            #expect(!tag.contains(":") && !tag.contains("/") && !tag.contains("{") && !tag.contains("#"),
                "\(row.labelRaw) \(tag)", sourceLocation: sourceLocation)
            if row.debtSource == ibdRowSourceLeaseNote {
                #expect(tag.hasSuffix("TextBlock"), "\(row.labelRaw) \(tag)", sourceLocation: sourceLocation)
            }
        }
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
