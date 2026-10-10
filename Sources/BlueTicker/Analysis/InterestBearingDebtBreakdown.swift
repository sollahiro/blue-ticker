// 有利子負債（interest_bearing_debt）軸の内訳解決。
// 社債・借入金（借入金等明細表を優先、帯外なら BS 科目）とリース負債（明細表 or リース注記）を
// 1表にする。Jev は行の分類と明細表/注記の近似重複判定だけを返す。金額は選ばせない
// （閾値は SegmentNoteDecision.applyProbabilityThreshold = 0.9）。
// 行合計が同じ財務諸表の BS 有利子負債（リース含む）の 95–105% 帯に入らない場合は
// needs_review で公開しない（Jev の判断で帯判定は覆らない）。

import Foundation

/// 行の分類。rawValue が Jev の選択肢キー。
enum IBDRowClass: String, CaseIterable, Sendable {
    case interestBearingDebt = "interest_bearing_debt"
    case leaseLiability = "lease_liability"
    case notInterestBearing = "not_interest_bearing"
}

/// 明細表とリース注記の近似重複に対する Jev の選択肢。
enum IBDDuplicateRole {
    static let sameLiability = "same_liability"
    static let differentLiabilities = "different_liabilities"
    static let optionKeys = [sameLiability, differentLiabilities]
}

/// 内訳の候補1行。`presetClass` はコードによる確定分類（nil = Jev に聞く）。
struct IBDCandidate: Equatable, Sendable {
    var labelRaw: String
    var label: String
    var tag: String?
    /// 期首残高（円）
    var opening: Double?
    /// 期末残高（円）
    var closing: Double?
    var averageRatePercent: Double?
    /// `ibdRowSource*`
    var source: String
    /// `ibdMaturity*` または nil
    var maturityClass: String?
    var presetClass: IBDRowClass?
}

/// リース注記（IFRS リース TextBlock）由来の行と合計。
struct IBDLeaseNote: Equatable, Sendable {
    var rows: [IBDCandidate]
    var total: Double?
    var priorTotal: Double?
}

/// `inputs(xbrlDir:)` の出力。XBRL から決定論で取れる材料一式。
struct IBDInputs: Sendable {
    var consolidated: Bool
    var financialInstitution: Bool
    var balanceSheet: [IBDCandidate]
    var schedule: [IBDCandidate]
    var leaseNote: IBDLeaseNote?
}

/// Jev に一度聞いた Choice。適用しなくても監査に残す。
struct IBDChoice: Equatable, Sendable {
    var selected: String?
    var probability: Double?
}

/// 有利子負債の行分類と近似重複判定。金額は返さない（選ばせない）。
protocol InterestBearingDebtDeciding: Sendable {
    func classifyRow(
        label: String, source: String, tag: String?, closingYen: Double?,
        siblingLabels: [String]
    ) async -> IBDChoice
    func classifyNearDuplicate(
        scheduleLabel: String, scheduleYen: Double, leaseNoteLabel: String, leaseNoteYen: Double
    ) async -> IBDChoice
}

/// 解決結果。`.unavailable` は Jev 応答無し等で行を作れない（再試行する）。
enum IBDResolution: Sendable {
    case resolved(payload: BreakdownSnapshotPayload, audit: SegmentNoteJevAuditPayload)
    case notApplicable(reason: String)
    case unavailable
}

enum InterestBearingDebtBreakdown {
    /// geography / セグメント分母チェックと同じ 95–105% 帯。
    static let coverageBand = 0.95...1.05
    /// 近似重複の相対許容誤差。完全一致は |a-b| < 0.5 円。
    static let nearDuplicateTolerance = 0.02
    static let rowQuestion = "interest_bearing_debt_row"
    static let duplicateQuestion = "interest_bearing_debt_near_duplicate"

    private static let threshold = SegmentNoteDecision.applyProbabilityThreshold

    /// BS の既知の有利子負債タグ（リース負債タグは除き .leaseLiability 側で確定する）。
    private static let knownDebtTags: Set<String> = {
        let leaseTags = Set(Xbrl.leaseLiabilitiesBSTags)
        var tags = Set(Xbrl.ibdDirectTags)
        tags.formUnion(Xbrl.ibdIFRSCLTags)
        tags.formUnion(Xbrl.ibdIFRSNCLTags)
        tags.formUnion(["USGAAP_HTML_IBDCurrent", "USGAAP_HTML_IBDNonCurrent"])
        for group in Xbrl.ibdCurrentComponents + Xbrl.ibdNonCurrentComponents {
            tags.formUnion(group.filter { !leaseTags.contains($0) })
        }
        return tags
    }()

    /// 未知タグ行を候補に挙げるタグ名キーワード。
    private static let debtTagKeywords = [
        "Borrow", "Bond", "Loan", "Debt", "CommercialPaper", "InterestBearing", "Lease",
    ]
    /// 未知タグ行を候補に挙げるラベルキーワード。
    private static let debtLabelKeywords = ["借入", "社債", "コマーシャル", "有利子", "リース", "借用"]

    // MARK: - inputs

    /// XBRL 展開ディレクトリから決定論の材料を集める（Jev は呼ばない）。
    static func inputs(xbrlDir: URL) -> IBDInputs {
        let tags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let consolidated = BorrowingsSchedule.filerHasConsolidatedStatements(xbrlDir: xbrlDir)
        // 銀行（預金）・保険は資金調達が本業で、BS に比較可能な有利子負債の合計が無い。
        let instantFS = fieldSetFromInstant(tags)
        let deposits = instantFS["DepositsLiabilitiesBNK"]
        let financialInstitution =
            deposits?.current != nil || deposits?.prior != nil
            || Xbrl.isInsuranceFiling(fieldSetFromDuration(tags))
        return IBDInputs(
            consolidated: consolidated,
            financialInstitution: financialInstitution,
            balanceSheet: balanceSheetCandidates(xbrlDir: xbrlDir, consolidated: consolidated),
            schedule: scheduleCandidates(xbrlDir: xbrlDir),
            leaseNote: leaseNoteCandidates(xbrlDir: xbrlDir))
    }

    /// BS 負債の部の行（合計行は除く）。既知タグはコードで確定、キーワード一致だけは Jev 候補、
    /// それ以外は候補にしない。期末 0 で期首も 0 / 欠測の行は落とす。
    private static func balanceSheetCandidates(xbrlDir: URL, consolidated: Bool) -> [IBDCandidate] {
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir, docID: nil, statementTypes: [.balanceSheet])
        else { return [] }
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        let standardLabels = XBRLUtils.loadStandardTaxonomyLabels()
        let priorContext = consolidated ? "Prior1YearInstant" : "Prior1YearInstant_NonConsolidatedMember"
        var candidates: [IBDCandidate] = []
        for line in year.balanceSheet
        where line.section == .liabilities && !line.isTotal {
            let tag = line.tag
            let label = line.label ?? standardLabels[tag] ?? tag
            let opening = facts[tag]?[priorContext]?.value
            if line.value == 0, (opening ?? 0) == 0 { continue }
            let preset: IBDRowClass?
            if knownDebtTags.contains(tag) {
                preset = .interestBearingDebt
            } else if Xbrl.leaseLiabilitiesBSTags.contains(tag) {
                preset = .leaseLiability
            } else if debtTagKeywords.contains(where: { tag.contains($0) })
                || debtLabelKeywords.contains(where: { label.contains($0) })
            {
                preset = nil
            } else {
                continue
            }
            candidates.append(
                IBDCandidate(
                    labelRaw: label, label: label, tag: tag,
                    opening: opening, closing: line.value, averageRatePercent: nil,
                    source: ibdRowSourceBalanceSheet,
                    maturityClass: maturityClass(fromTag: tag) ?? maturityClass(fromLabel: label),
                    presetClass: preset))
        }
        return candidates
    }

    /// 借入金等明細表（社債及び借入金注記）の行。`sourceLabel`（表示正規化前）を判定材料に使う。
    private static func scheduleCandidates(xbrlDir: URL) -> [IBDCandidate] {
        guard let extracted = BorrowingsSchedule.extractRows(xbrlDir: xbrlDir) else { return [] }
        return extracted.rows.compactMap { row in
            guard row.current != nil || row.prior != nil else { return nil }
            let labelRaw = row.sourceLabel ?? row.label
            return IBDCandidate(
                labelRaw: labelRaw, label: row.label, tag: nil,
                opening: row.prior, closing: row.current,
                averageRatePercent: row.averageInterestRatePercent,
                source: ibdRowSourceBorrowingsSchedule,
                maturityClass: maturityClass(fromLabel: labelRaw),
                presetClass: scheduleRowPreset(labelRaw))
        }
    }

    /// IFRS リース注記の行。TextBlock が無い書類では nil。区分行が無く合計だけあるときは
    /// 「リース負債」1行にする。
    private static func leaseNoteCandidates(xbrlDir: URL) -> IBDLeaseNote? {
        // TextBlock があるときだけ IFRSLease を呼ぶ。fieldSet は空渡しでパターンA（BSタグ）を
        // スキップ（StatementNotesResolver の lease_liabilities と同じ運用）。
        guard XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: Xbrl.ifrsLeasesTextblockTag) != nil
        else { return nil }
        let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir)
        var rows: [IBDCandidate] = []
        for component in lease.components where component.current != nil || component.prior != nil {
            rows.append(
                IBDCandidate(
                    labelRaw: component.label, label: component.label, tag: nil,
                    opening: component.prior, closing: component.current,
                    averageRatePercent: nil,
                    source: ibdRowSourceLeaseNote,
                    maturityClass: maturityClass(fromLabel: component.label),
                    presetClass: .leaseLiability))
        }
        if rows.isEmpty, lease.current != nil {
            rows.append(
                IBDCandidate(
                    labelRaw: "リース負債", label: "リース負債", tag: nil,
                    opening: lease.prior, closing: lease.current, averageRatePercent: nil,
                    source: ibdRowSourceLeaseNote, maturityClass: nil,
                    presetClass: .leaseLiability))
        }
        guard !rows.isEmpty || lease.current != nil || lease.prior != nil else { return nil }
        return IBDLeaseNote(rows: rows, total: lease.current, priorTotal: lease.prior)
    }

    // MARK: - helpers

    /// 明細表の区分ラベルからコードで確定できる分類。確定できない（Jev に聞く）とき nil。
    static func scheduleRowPreset(_ label: String) -> IBDRowClass? {
        // 「(注n)」「（注n）」「*n」の注記参照マーカーを除いてから判定する
        var cleaned = label
        if let regex = try? NSRegularExpression(pattern: #"[（(]注[0-9０-９]+[）)]|\*[0-9０-９]+"#) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }
        // 非有利子の典型（デリバティブ・和解金・預り金等）は Jev に回す
        let nonDebt = ["デリバティブ", "和解", "預り", "預金", "保証金", "未払", "先渡"]
        if nonDebt.contains(where: { cleaned.contains($0) }) { return nil }
        if BorrowingsSchedule.isLeaseDebtScheduleRowLabel(cleaned) { return .leaseLiability }
        let debt = ["借入金", "社債", "コマーシャル・ペーパー", "コマーシャルペーパー", "借用金", "有利子負債"]
        if debt.contains(where: { cleaned.contains($0) }) { return .interestBearingDebt }
        return nil
    }

    /// ラベルの流動/非流動区分。開示区分をそのまま取るだけで計算しない。
    /// 素の「長期借入金」「社債」は 1年内返済分を含み得るため nil。
    static func maturityClass(fromLabel label: String) -> String? {
        // 全角数字を半角へ正規化してから判定する（「１年以内」を拾う）
        let normalized = String(
            label.map { char -> Character in
                guard char.unicodeScalars.count == 1, let scalar = char.unicodeScalars.first,
                    scalar.value >= 0xFF10, scalar.value <= 0xFF19
                else { return char }
                return Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
            })
        if normalized.contains("非流動") || normalized.contains("除く") || normalized.contains("固定") {
            return ibdMaturityNonCurrent
        }
        if normalized.contains("1年以内") || normalized.contains("1年内")
            || normalized.contains("流動") || normalized.contains("短期")
        {
            return ibdMaturityCurrent
        }
        return nil
    }

    /// タグ名の流動/非流動区分。IFRS 接尾辞（NCLIFRS は CLIFRS を内包するので先に判定）と
    /// J-GAAP / US-GAAP HTML 仮想タグの明示リスト。
    static func maturityClass(fromTag tag: String) -> String? {
        if tag.hasSuffix("NCLIFRS") || tag.hasSuffix("NCL") { return ibdMaturityNonCurrent }
        if tag.hasSuffix("CLIFRS") || tag.hasSuffix("CL") { return ibdMaturityCurrent }
        let currentTags = [
            "ShortTermLoansPayable", "CurrentPortionOfLongTermLoansPayable",
            "CurrentPortionOfBonds", "RedeemableBondsWithinOneYear",
            "CommercialPapersLiabilities", "ShortTermBondsPayable",
            "USGAAP_HTML_IBDCurrent",
        ]
        if currentTags.contains(tag) { return ibdMaturityCurrent }
        let nonCurrentTags = ["LongTermLoansPayable", "BondsPayable", "USGAAP_HTML_IBDNonCurrent"]
        if nonCurrentTags.contains(tag) { return ibdMaturityNonCurrent }
        return nil
    }

    // MARK: - resolve

    /// 内訳を解決する。Jev は行分類と近似重複判定のみ（金額はコードの値をそのまま使う）。
    static func resolve(
        inputs: IBDInputs, decider: (any InterestBearingDebtDeciding)?,
        code: String = "", docID: String = ""
    ) async -> IBDResolution {
        // 銀行・保険は預金・保険契約準備金が資金調達の本業で、比較可能な有利子負債の合計が無い。
        if inputs.financialInstitution {
            return .notApplicable(reason: breakdownNotApplicableFinancialInstitution)
        }

        var sentences: [String] = []
        var calls: [SegmentNoteJevCallPayload] = []
        var anyApplied = false
        var warnings: [String] = []
        var needsReview = false

        // 1. 候補行の分類（リース注記行は preset 済み。未解決行は行・合計に載せない）
        let bsClassified = await classifyRows(inputs.balanceSheet, decider: decider)
        guard !bsClassified.unavailable else { return .unavailable }
        let schedClassified = await classifyRows(inputs.schedule, decider: decider)
        guard !schedClassified.unavailable else { return .unavailable }
        calls.append(contentsOf: bsClassified.calls + schedClassified.calls)
        anyApplied = bsClassified.applied || schedClassified.applied

        func rows(_ candidates: [IBDCandidate], _ classes: [IBDRowClass?], _ cls: IBDRowClass)
            -> [IBDCandidate]
        {
            zip(candidates, classes).compactMap { $0.1 == cls ? $0.0 : nil }
        }

        // 2. BS の合計（分母の材料）
        let bsDebt = rows(inputs.balanceSheet, bsClassified.classes, .interestBearingDebt)
        let bsLease = rows(inputs.balanceSheet, bsClassified.classes, .leaseLiability)
        let bsDebtSum = bsDebt.reduce(0) { $0 + ($1.closing ?? 0) }
        let bsLeaseSum = bsLease.reduce(0) { $0 + ($1.closing ?? 0) }
        let bsUnresolved = bsClassified.classes.contains(nil)
        // BondsBorrowingsAndLeaseLiabilities* のようにリース込みの BS 合算タグ
        let leaseInDebt = bsDebt.contains { $0.tag?.contains("Lease") == true }
        let schedLease = rows(inputs.schedule, schedClassified.classes, .leaseLiability)
        let schedLeaseSum = schedLease.reduce(0) { $0 + ($1.closing ?? 0) }
        let noteRows = inputs.leaseNote?.rows ?? []

        func yen(_ value: Double) -> String { String(format: "%.0f", value) }

        // 3. 明細表主時のリース行。注記合計との近似重複だけ Jev に聞く（金額は選ばせない）。
        //    判定不能なら明細表側を採用して needs_review。
        func scheduleLeaseRows() async -> [IBDCandidate]? {
            guard !schedLease.isEmpty else {
                return !noteRows.isEmpty ? noteRows : bsLease
            }
            guard let noteTotal = inputs.leaseNote?.total else { return schedLease }
            let diff = abs(schedLeaseSum - noteTotal)
            if diff < 0.5 {
                sentences.append(
                    "lease_exact_match schedule=\(yen(schedLeaseSum)) lease_note=\(yen(noteTotal))")
                return schedLease
            }
            let base = max(schedLeaseSum, noteTotal)
            guard base > 0, diff / base <= nearDuplicateTolerance else {
                warnings.append(breakdownWarningIBDLeaseSourcesDiffer)
                sentences.append(
                    "lease_sources_differ schedule=\(yen(schedLeaseSum)) lease_note=\(yen(noteTotal))")
                return schedLease
            }
            let scheduleLabel = schedLease.map(\.label).joined(separator: "、")
            let noteLabel = noteRows.isEmpty
                ? "リース負債" : noteRows.map(\.label).joined(separator: "、")
            guard let decider else {
                needsReview = true
                warnings.append(breakdownWarningIBDNearDuplicateUnresolved)
                sentences.append(
                    "lease_near_duplicate schedule=\(yen(schedLeaseSum)) lease_note=\(yen(noteTotal)) decision=unresolved_no_decider")
                return schedLease
            }
            let choice = await decider.classifyNearDuplicate(
                scheduleLabel: scheduleLabel, scheduleYen: schedLeaseSum,
                leaseNoteLabel: noteLabel, leaseNoteYen: noteTotal)
            let applied = SegmentNoteDecision.meetsThreshold(choice.probability)
            if applied { anyApplied = true }
            calls.append(
                SegmentNoteJevCallPayload(
                    question: duplicateQuestion, options: IBDDuplicateRole.optionKeys,
                    selected: choice.selected, probability: choice.probability,
                    sentences: [
                        "\(ibdRowSourceBorrowingsSchedule): \(scheduleLabel)",
                        "\(ibdRowSourceLeaseNote): \(noteLabel)",
                    ],
                    applied: applied))
            let probabilityText = choice.probability.map { String(format: "%.2f", $0) } ?? "null"
            sentences.append(
                "lease_near_duplicate schedule=\(yen(schedLeaseSum)) lease_note=\(yen(noteTotal)) decision=\(choice.selected ?? "nil") p=\(probabilityText)")
            guard let selected = choice.selected else { return nil }
            if selected == IBDDuplicateRole.sameLiability, applied { return schedLease }
            if selected == IBDDuplicateRole.differentLiabilities, applied {
                return schedLease + noteRows
            }
            needsReview = true
            warnings.append(breakdownWarningIBDNearDuplicateUnresolved)
            return schedLease
        }

        // BS 主時のリース行（同期。近似重複の Jev は明細表主のときだけ）。
        func balanceSheetLeaseRows() -> [IBDCandidate] {
            if !bsLease.isEmpty { return bsLease }
            if leaseInDebt { return [] }
            // BS にリース科目が無い（その他に含む等）ときは分母と同じ順で注記 → 明細表
            return !noteRows.isEmpty ? noteRows : schedLease
        }

        // 4. 分母 = 同じ財務諸表の BS 有利子負債（リース含む）。
        let rawDenominator: Double? =
            (bsDebt.isEmpty && bsLease.isEmpty)
            ? nil
            : bsDebtSum
                + (bsLeaseSum > 0
                    ? bsLeaseSum
                    : (leaseInDebt ? 0 : (inputs.leaseNote?.total ?? schedLeaseSum)))
        // 0 以下の分母では coverage を測れない（0/0 を帯内と誤判定しない）
        let denominator = rawDenominator.flatMap { $0 > 0 ? $0 : nil }

        // 5. 主データ源の選択。明細表に債務行があれば明細表優先、coverage 帯外で BS が
        //    完全なら BS へ差し替える（schedule_rejected）。
        let schedDebt = rows(inputs.schedule, schedClassified.classes, .interestBearingDebt)
        let primary: String
        let leaseRows: [IBDCandidate]
        var scheduleRejected = false
        if !schedDebt.isEmpty {
            guard let picked = await scheduleLeaseRows() else { return .unavailable }
            let schedTotal = (schedDebt + picked).reduce(0) { $0 + ($1.closing ?? 0) }
            if let denominator {
                let ratio = schedTotal / denominator
                if coverageBand.contains(ratio) {
                    primary = ibdRowSourceBorrowingsSchedule
                    leaseRows = picked
                } else if !bsUnresolved, !bsDebt.isEmpty {
                    primary = ibdRowSourceBalanceSheet
                    leaseRows = balanceSheetLeaseRows()
                    warnings.append(breakdownWarningIBDScheduleRejected)
                    scheduleRejected = true
                    sentences.append(
                        "schedule_rejected schedule_total=\(yen(schedTotal)) denominator=\(yen(denominator)) coverage=\(coverageText(ratio))")
                } else {
                    // 帯外でも BS が不完全なら明細表のまま（step 6 の帯判定が needs_review にする）
                    primary = ibdRowSourceBorrowingsSchedule
                    leaseRows = picked
                }
            } else {
                primary = ibdRowSourceBorrowingsSchedule
                leaseRows = picked
                needsReview = true
                warnings.append(breakdownWarningIBDCoverageUnavailable)
            }
        } else if !bsDebt.isEmpty || !bsLease.isEmpty || !noteRows.isEmpty {
            primary = ibdRowSourceBalanceSheet
            leaseRows = balanceSheetLeaseRows()
        } else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }

        // 6. 最終行と coverage 判定（Jev の判断で帯判定は覆らない）。
        let debtRows = primary == ibdRowSourceBorrowingsSchedule ? schedDebt : bsDebt
        let finalCandidates = debtRows + leaseRows
        let total = finalCandidates.reduce(0) { $0 + ($1.closing ?? 0) }
        if let denominator {
            if !coverageBand.contains(total / denominator) {
                needsReview = true
                warnings.append(breakdownWarningIBDCoverageOutOfBand)
            }
        } else if !warnings.contains(breakdownWarningIBDCoverageUnavailable) {
            needsReview = true
            warnings.append(breakdownWarningIBDCoverageUnavailable)
        }
        // BS の未解決行（分母が不完全）、または明細表の未解決行は needs_review。
        // 明細表の行は BS 主でも有利子負債の可能性がある（割賦未払金等）。帯外で
        // 退けた明細表だけは対象外。
        if bsUnresolved || (schedClassified.classes.contains(nil) && !scheduleRejected) {
            needsReview = true
            warnings.append(breakdownWarningIBDRowUnclassified)
        }
        // 未分類行は合計に入れないが、金額ごと監査に残す（黙って落とさない）
        for (candidate, rowClass) in zip(inputs.balanceSheet + inputs.schedule,
                                         bsClassified.classes + schedClassified.classes)
        where rowClass == nil {
            sentences.append(
                "unclassified \(candidate.source): \(candidate.labelRaw) closing=\(candidate.closing.map(yen) ?? "null")")
        }
        sentences.append("primary=\(primary)")
        sentences.append("rows_total=\(yen(total))")
        sentences.append("denominator=\(denominator.map(yen) ?? "null")")
        sentences.append(
            "coverage=\(denominator.map { coverageText(total / $0) } ?? "null")")

        // 7. 格納用ペイロード。合計行の average_rate は開示値が無いため常に nil
        //    （加重平均は計算しない）。
        var payloadRows = finalCandidates.map { candidate in
            BreakdownRowPayload(
                labelRaw: candidate.labelRaw, label: candidate.label,
                amount: candidate.closing ?? 0, profit: nil, rowKind: "segment",
                opening: candidate.opening, closing: candidate.closing,
                averageRate: candidate.averageRatePercent,
                debtSource: candidate.source, maturityClass: candidate.maturityClass)
        }
        let openings = finalCandidates.compactMap(\.opening)
        payloadRows.append(
            BreakdownRowPayload(
                labelRaw: "合計", label: "合計", amount: total, profit: nil,
                rowKind: "subtotal",
                opening: openings.isEmpty ? nil : openings.reduce(0, +), closing: total))
        let payload = BreakdownSnapshotPayload(
            axis: breakdownAxisInterestBearingDebt,
            denominator: denominator ?? total,
            denominatorTag: denominator == nil
                ? "interest_bearing_debt.rows_total" : "balance_sheet.interest_bearing_debt",
            rows: payloadRows, sourceKind: breakdownSourceXbrlFacts,
            needsReview: needsReview, warnings: warnings)
        let audit = SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: breakdownAxisInterestBearingDebt,
            model: Api.openrouterDecisionsModel, threshold: threshold,
            applied: anyApplied, needsReview: needsReview,
            sentences: sentences, calls: calls,
            decisionSource: "interest_bearing_debt_pipeline")
        return .resolved(payload: payload, audit: audit)
    }

    private static func coverageText(_ ratio: Double) -> String {
        String((ratio * 10_000).rounded() / 10_000)
    }

    /// 候補行を分類する。preset 済みはそのまま、Jev 未設定なら未解決、応答無しなら
    /// `.unavailable`（行を作らず再試行）。閾値未満・選択肢外は未解決。
    private static func classifyRows(
        _ candidates: [IBDCandidate], decider: (any InterestBearingDebtDeciding)?
    ) async -> (
        classes: [IBDRowClass?], calls: [SegmentNoteJevCallPayload], applied: Bool,
        unavailable: Bool
    ) {
        var classes: [IBDRowClass?] = []
        var calls: [SegmentNoteJevCallPayload] = []
        var applied = false
        let siblings = candidates.map(\.label)
        for candidate in candidates {
            if let preset = candidate.presetClass {
                classes.append(preset)
                continue
            }
            guard let decider else {
                classes.append(nil)
                continue
            }
            let choice = await decider.classifyRow(
                label: candidate.labelRaw, source: candidate.source, tag: candidate.tag,
                closingYen: candidate.closing, siblingLabels: siblings)
            guard let selected = choice.selected else { return ([], calls, applied, true) }
            let meets = SegmentNoteDecision.meetsThreshold(choice.probability)
            if meets { applied = true }
            calls.append(
                SegmentNoteJevCallPayload(
                    question: rowQuestion, options: IBDRowClass.allCases.map(\.rawValue),
                    selected: selected, probability: choice.probability,
                    sentences: ["\(candidate.source): \(candidate.labelRaw)"], applied: meets))
            if meets, let rowClass = IBDRowClass(rawValue: selected) {
                classes.append(rowClass)
            } else {
                classes.append(nil)
            }
        }
        return (classes, calls, applied, false)
    }
}

// MARK: - OpenRouter デサイダ

/// 行分類と近似重複判定の OpenRouter 実装（`OpenRouterCapexProseDecider` と同型）。
/// エラー・応答欠測は selected nil（呼び出し元が `.unavailable` として再試行する）。
struct OpenRouterInterestBearingDebtDecider: InterestBearingDebtDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func classifyRow(
        label: String, source: String, tag: String?, closingYen: Double?,
        siblingLabels: [String]
    ) async -> IBDChoice {
        await choice(
            question: InterestBearingDebtBreakdown.rowQuestion,
            body: Self.rowRequestJSON(
                model: model, label: label, source: source, tag: tag, closingYen: closingYen,
                siblingLabels: siblingLabels))
    }

    func classifyNearDuplicate(
        scheduleLabel: String, scheduleYen: Double, leaseNoteLabel: String, leaseNoteYen: Double
    ) async -> IBDChoice {
        await choice(
            question: InterestBearingDebtBreakdown.duplicateQuestion,
            body: Self.duplicateRequestJSON(
                model: model, scheduleLabel: scheduleLabel, scheduleYen: scheduleYen,
                leaseNoteLabel: leaseNoteLabel, leaseNoteYen: leaseNoteYen))
    }

    private func choice(question: String, body: Data?) async -> IBDChoice {
        let unavailable = IBDChoice(selected: nil, probability: nil)
        guard let body else { return unavailable }
        do {
            let data = try await client.decide(requestJSON: body)
            guard let choice = OpenRouterDecisionsCodec.answers(from: data)[question]?.choice
            else { return unavailable }
            return IBDChoice(
                selected: choice.selected,
                probability: OpenRouterSegmentNoteDecider.selectedProbability(
                    selected: choice.selected, probabilities: choice.probabilities))
        } catch {
            return unavailable
        }
    }

    static func rowRequestJSON(
        model: String, label: String, source: String, tag: String?, closingYen: Double?,
        siblingLabels: [String]
    ) -> Data? {
        let criteria: [String: String] = [
            IBDRowClass.interestBearingDebt.rawValue: """
                利息を払って返済する借入れ・社債・コマーシャル・ペーパー・割賦未払金など、 \
                会社の有利子負債に含まれる行。リースは除く。
                """,
            IBDRowClass.leaseLiability.rawValue: """
                リース負債・リース債務の行。
                """,
            IBDRowClass.notInterestBearing.rawValue: """
                デリバティブ負債、訴訟の和解金に係る負債、預り金・預り保証金、銀行業の預金、 \
                外部投資家持分、引当金、その他の非有利子負債。
                """,
        ]
        let state: [String: Any] = [
            "label": label,
            "source": source,
            "tag": tag ?? NSNull(),
            "closing_yen": closingYen ?? NSNull(),
            "sibling_labels": siblingLabels,
        ]
        let questions: [String: Any] = [
            InterestBearingDebtBreakdown.rowQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "行ラベルと出所から一つ選ぶ。金額は選ばない。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(model: model, state: state, questions: questions)
    }

    static func duplicateRequestJSON(
        model: String, scheduleLabel: String, scheduleYen: Double,
        leaseNoteLabel: String, leaseNoteYen: Double
    ) -> Data? {
        let criteria: [String: String] = [
            IBDDuplicateRole.sameLiability: """
                同じリース負債を別の表で示しただけ。差は端数・測定日・表示区分の違い。
                """,
            IBDDuplicateRole.differentLiabilities: """
                別の負債で、両方を足すべき。
                """,
        ]
        let state: [String: Any] = [
            "schedule_label": scheduleLabel,
            "schedule_yen": scheduleYen,
            "lease_note_label": leaseNoteLabel,
            "lease_note_yen": leaseNoteYen,
        ]
        let questions: [String: Any] = [
            InterestBearingDebtBreakdown.duplicateQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "借入金等明細表のリース行とリース注記のリース負債の金額が近似している。同じ負債の重複か、足すべき別の負債か一つ選ぶ。金額は選ばない。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(model: model, state: state, questions: questions)
    }
}
