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
    /// 銀行（`DepositsLiabilitiesBNK` が statement Instant FieldSet にある）。
    /// 保険は通常パイプライン（除外しない）。
    var isBank: Bool
    /// 銀行の BS コンポーネント行。`source` は `financials_bank_components`。
    /// 非銀行は空。
    var bankComponents: [IBDCandidate]
    var balanceSheet: [IBDCandidate]
    var schedule: [IBDCandidate]
    var leaseNote: IBDLeaseNote?
    /// インスタンス文書が `Xbrl.zeroDebtMinInstanceBytes` 超（not_found の zero_debt 判定）。
    var largeInstance: Bool

    init(
        consolidated: Bool, isBank: Bool = false, bankComponents: [IBDCandidate] = [],
        balanceSheet: [IBDCandidate], schedule: [IBDCandidate], leaseNote: IBDLeaseNote?,
        largeInstance: Bool = false
    ) {
        self.consolidated = consolidated
        self.isBank = isBank
        self.bankComponents = bankComponents
        self.balanceSheet = balanceSheet
        self.schedule = schedule
        self.leaseNote = leaseNote
        self.largeInstance = largeInstance
    }

    // 旧テスト呼び出し用。保険は除外しなくなったため `financialInstitution` は無視する。
    init(
        consolidated: Bool, financialInstitution _: Bool, balanceSheet: [IBDCandidate],
        schedule: [IBDCandidate], leaseNote: IBDLeaseNote?
    ) {
        self.init(
            consolidated: consolidated, isBank: false, bankComponents: [],
            balanceSheet: balanceSheet, schedule: schedule, leaseNote: leaseNote,
            largeInstance: false)
    }
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
        let accountingStandard = detectAccountingStandard(tags)
        // 銀行判定は旧 `IBDExtractor.extractBankIBD` と同じ statement Instant FieldSet。
        // 保険は通常パイプライン（資金調達の本業でも内訳を出す）。
        let instantFS = statementInstantFieldSet(
            xbrlDir: xbrlDir, allTags: tags, accountingStandard: accountingStandard)
        let deposits = instantFS["DepositsLiabilitiesBNK"]
        let isBank = deposits?.current != nil || deposits?.prior != nil
        return IBDInputs(
            consolidated: consolidated,
            isBank: isBank,
            bankComponents: isBank ? bankComponentCandidates(fieldSet: instantFS) : [],
            balanceSheet: isBank
                ? [] : balanceSheetCandidates(xbrlDir: xbrlDir, consolidated: consolidated),
            schedule: isBank ? [] : scheduleCandidates(xbrlDir: xbrlDir),
            leaseNote: isBank
                ? leaseNote(from: notesLeaseCandidates(
                    xbrlDir: xbrlDir, accountingStandard: accountingStandard))
                : leaseNoteCandidates(xbrlDir: xbrlDir),
            largeInstance: hasLargeXbrlFile(in: xbrlDir))
    }

    /// 銀行の BS コンポーネント。`Xbrl.bankIBDComponents` を `resolveItem` で先勝ちし、
    /// 当期または前期があるものだけ行にする（旧 `extractBankIBD` と同じ）。
    /// 独立した coverage 検算は無い（分母はこの合計そのもの）。
    private static func bankComponentCandidates(fieldSet: FieldSet) -> [IBDCandidate] {
        var rows: [IBDCandidate] = []
        for component in Xbrl.bankIBDComponents {
            let item = resolveItem(fieldSet, tags: component.tags)
            guard item.current != nil || item.prior != nil else { continue }
            rows.append(
                IBDCandidate(
                    labelRaw: component.label, label: component.label, tag: item.tag,
                    opening: item.prior, closing: item.current, averageRatePercent: nil,
                    source: ibdRowSourceFinancialsBankComponents,
                    maturityClass: maturityClass(fromLabel: component.label),
                    presetClass: .interestBearingDebt))
        }
        return rows
    }

    /// statement BS だけを許可した Instant FieldSet。旧 `IBDExtractor.statementInstantFieldSet`。
    /// 銀行判定と bank components の値はこれと一致させる（US-GAAP は Statement HTML）。
    static func statementInstantFieldSet(
        xbrlDir: URL, allTags: XbrlTagElements, accountingStandard: String
    ) -> FieldSet {
        if accountingStandard == "US-GAAP" {
            if case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
                xbrlDir: xbrlDir, docID: nil, statementTypes: [.balanceSheet]
            ) {
                let mapped = usgaapStatementIBDFieldSet(year.balanceSheet)
                if mapped["USGAAP_HTML_IBDCurrent"] != nil
                    || mapped["USGAAP_HTML_IBDNonCurrent"] != nil
                {
                    return mapped
                }
            }
            return USGAAPHtml.parseBSFields(in: xbrlDir)
        }
        if case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir, docID: nil, statementTypes: [.balanceSheet]
        ), !year.balanceSheet.isEmpty {
            let statementTags = Set(year.balanceSheet.map(\.tag))
            var fs = fieldSetFromInstant(allTags.filter { statementTags.contains($0.key) })
            overlayStatementCurrentValues(&fs, lines: year.balanceSheet)
            return fs
        }
        return fieldSetFromInstant(allTags)
    }

    private static let statementIBDTags: Set<String> = {
        var tags = Set(Xbrl.ibdDirectTags)
        tags.formUnion(Xbrl.ibdIFRSCLTags)
        tags.formUnion(Xbrl.ibdIFRSNCLTags)
        tags.formUnion(Xbrl.leaseLiabilitiesBSTags)
        for group in Xbrl.ibdCurrentComponents { tags.formUnion(group) }
        for group in Xbrl.ibdNonCurrentComponents { tags.formUnion(group) }
        for component in Xbrl.bankIBDComponents { tags.formUnion(component.tags) }
        return tags
    }()

    /// statement 本表の IBD 当期値で Instant FieldSet を上書きする。
    /// fact 収集は `nilAsZero: false` のため、当期 `xsi:nil` は落ちる。
    /// statement 組立は既定 `nilAsZero: true` で同じ fact を 0 として載せる（借入金 0 円の
    /// 日東電工 6988 / S100YCAR）。prior だけ残ると tag あり・current nil になり
    /// zero_debt へ落ちず ROIC が欠測する。
    static func overlayStatementCurrentValues(
        _ fieldSet: inout FieldSet, lines: [StatementLineItem]
    ) {
        for item in lines {
            guard statementIBDTags.contains(item.tag) else { continue }
            var fv = fieldSet[item.tag] ?? FieldValue(current: nil, prior: nil)
            fv.current = item.value
            fieldSet[item.tag] = fv
        }
    }

    private static let usgaapIBDLabelMap: [String: String] = [
        "社債及び短期借入金": "USGAAP_HTML_IBDCurrent",
        "社債及び長期借入金": "USGAAP_HTML_IBDNonCurrent",
        "短期借入金及び１年以内に返済する長期債務合計": "USGAAP_HTML_IBDCurrent",
        "Ⅱ　長期債務": "USGAAP_HTML_IBDNonCurrent",
        "短期オペレーティング": "USGAAP_HTML_LeaseLiabilitiesCurrent",
        "長期オペレーティング": "USGAAP_HTML_LeaseLiabilitiesNonCurrent",
    ]

    private static func usgaapStatementIBDFieldSet(_ items: [StatementLineItem]) -> FieldSet {
        var fs: FieldSet = [:]
        for item in items {
            guard let label = item.label else { continue }
            if let tag = bestMatchingUSGAAPIBDTag(label), fs[tag] == nil {
                fs[tag] = FieldValue(current: item.value, prior: nil)
            }
            let stripped = USGAAPHtml.stripSectionPrefix(label)
            if stripped == "長期債務", fs["USGAAP_HTML_IBDNonCurrent"] == nil {
                fs["USGAAP_HTML_IBDNonCurrent"] = FieldValue(current: item.value, prior: nil)
            }
        }
        return fs
    }

    private static func bestMatchingUSGAAPIBDTag(_ label: String) -> String? {
        let stripped = USGAAPHtml.stripSectionPrefix(label)
        var bestKey: String?
        for key in usgaapIBDLabelMap.keys {
            if stripped.contains(key) || label.contains(key) {
                if bestKey == nil || key.count > bestKey!.count {
                    bestKey = key
                }
            }
        }
        return bestKey.map { usgaapIBDLabelMap[$0]! }
    }

    /// インスタンス文書に 100KB 超のファイルがあるか（zero_debt 判定）。
    private static func hasLargeXbrlFile(in dir: URL) -> Bool {
        XBRLUtils.findXbrlFiles(in: dir).contains { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size > Xbrl.zeroDebtMinInstanceBytes
        }
    }

    /// statement 側にリース科目が無いとき、notes のリース帳簿だけを足す。
    /// IFRS TextBlock で既に足している場合は components にリースがあるので何もしない。
    /// 旧 `IBDExtractor.appendingNotesLeaseIfMissing`（銀行の bank_components も同じ規則）。
    static func notesLeaseCandidates(xbrlDir: URL, accountingStandard: String) -> [IBDCandidate] {
        if accountingStandard == "IFRS",
           case .resolved = StatementNotesResolver.resolveLeaseLiabilities(xbrlDir: xbrlDir)
        {
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir)
            let rows = leaseNoteRows(from: lease)
            if !rows.isEmpty { return rows }
        }
        guard let parsed = BorrowingsSchedule.extractRows(xbrlDir: xbrlDir) else { return [] }
        return parsed.rows.compactMap { row in
            guard BorrowingsSchedule.isLeaseDebtScheduleRowLabel(row.label) else { return nil }
            guard row.current != nil || row.prior != nil else { return nil }
            let labelRaw = row.sourceLabel ?? row.label
            return IBDCandidate(
                labelRaw: labelRaw, label: row.label, tag: nil,
                opening: row.prior, closing: row.current, averageRatePercent: nil,
                source: ibdRowSourceBorrowingsSchedule,
                maturityClass: maturityClass(fromLabel: labelRaw),
                presetClass: .leaseLiability)
        }
    }

    private static func leaseNoteRows(
        from lease: (
            current: Double?, prior: Double?, components: [IBDComponentEntry],
            maturityBuckets: [IBDComponentEntry]
        )
    ) -> [IBDCandidate] {
        var rows: [IBDCandidate] = []
        for component in lease.components where component.current != nil || component.prior != nil {
            rows.append(
                IBDCandidate(
                    labelRaw: component.label, label: component.label, tag: nil,
                    opening: component.prior, closing: component.current,
                    averageRatePercent: nil, source: ibdRowSourceLeaseNote,
                    maturityClass: maturityClass(fromLabel: component.label),
                    presetClass: .leaseLiability))
        }
        if rows.isEmpty, lease.current != nil || lease.prior != nil {
            rows.append(
                IBDCandidate(
                    labelRaw: "リース負債", label: "リース負債", tag: nil,
                    opening: lease.prior, closing: lease.current, averageRatePercent: nil,
                    source: ibdRowSourceLeaseNote, maturityClass: nil,
                    presetClass: .leaseLiability))
        }
        return rows
    }

    private static func leaseNote(from rows: [IBDCandidate]) -> IBDLeaseNote? {
        guard !rows.isEmpty else { return nil }
        let hasCurrent = rows.contains { $0.closing != nil }
        let hasPrior = rows.contains { $0.opening != nil }
        return IBDLeaseNote(
            rows: rows,
            total: hasCurrent ? rows.reduce(0) { $0 + ($1.closing ?? 0) } : nil,
            priorTotal: hasPrior ? rows.reduce(0) { $0 + ($1.opening ?? 0) } : nil)
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
    /// 「除く」は「1年以内/1年内 … 除く」のときだけ非流動。
    /// 「ノンリコース債務を除く」のような別の除外は区分にしない。
    static func maturityClass(fromLabel label: String) -> String? {
        // 全角数字を半角へ正規化してから判定する（「１年以内」を拾う）
        let normalized = String(
            label.map { char -> Character in
                guard char.unicodeScalars.count == 1, let scalar = char.unicodeScalars.first,
                    scalar.value >= 0xFF10, scalar.value <= 0xFF19
                else { return char }
                return Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
            })
        if normalized.contains("非流動") || normalized.contains("固定")
            || excludesCurrentPortion(normalized)
        {
            return ibdMaturityNonCurrent
        }
        if normalized.contains("1年以内") || normalized.contains("1年内")
            || normalized.contains("流動") || normalized.contains("短期")
        {
            return ibdMaturityCurrent
        }
        return nil
    }

    /// 「1年以内/1年内 … 除く」だけを非流動の印にする。裸の「除く」は使わない。
    private static func excludesCurrentPortion(_ normalized: String) -> Bool {
        guard normalized.contains("除く") else { return false }
        guard let range = normalized.range(of: "1年以内") ?? normalized.range(of: "1年内") else {
            return false
        }
        return normalized[range.upperBound...].contains("除く")
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
        if inputs.isBank {
            return resolveBank(inputs: inputs, code: code, docID: docID)
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

        // 2. BS の合計（分母の材料）。分母に入れるのはコード分類（presetClass）の行だけ。
        //    Jev が債務と答えた BS 行は行としては残すが、分母には入れない
        //    （同じ判断が分母と行の両方に入ると coverage が自己参照になる）。
        let bsDebt = rows(inputs.balanceSheet, bsClassified.classes, .interestBearingDebt)
        let bsLease = rows(inputs.balanceSheet, bsClassified.classes, .leaseLiability)
        let codeClassifiedBS = zip(inputs.balanceSheet, bsClassified.classes)
            .filter { $0.0.presetClass != nil }
        let bsDebtSum = codeClassifiedBS.reduce(0.0) { sum, pair in
            pair.1 == .interestBearingDebt ? sum + (pair.0.closing ?? 0) : sum
        }
        let bsLeaseSum = codeClassifiedBS.reduce(0.0) { sum, pair in
            pair.1 == .leaseLiability ? sum + (pair.0.closing ?? 0) : sum
        }
        // 主データ源の選択だけは分類済み BS 全行で見る。公開 coverage の分母とは別
        // （Jev 行を分母から外すと、帯内の明細表まで BS へ落ちてしまう）。
        let classifiedDebtSum = bsDebt.reduce(0) { $0 + ($1.closing ?? 0) }
        let classifiedLeaseSum = bsLease.reduce(0) { $0 + ($1.closing ?? 0) }
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
                // 2% を超える食い違いは黙って片方を採用しない。明細表側を残し公開保留。
                needsReview = true
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
        //    金額はコード分類の BS 行だけ。Jev 分類の BS 行は足さない。
        //    BS にリース科目が無くリース込み合算でもないとき、リース部分は注記合計、
        //    無ければ明細表リースを足す。そのときは分母の一部が行の出所と同じになり、
        //    coverage が自己参照になるので警告だけ残す（needs_review にはしない）。
        let leaseSupplement = leaseInDebt ? 0 : (inputs.leaseNote?.total ?? schedLeaseSum)
        // BS にリース科目が無く、注記または明細表のリースを分母へ足すときだけ自己参照になる。
        // コード分類の BS 債務が無いときは分母自体を作らない（注記リースだけで分母にしない）。
        let leaseFromNotes = bsLeaseSum <= 0 && !leaseInDebt && bsDebtSum > 0 && leaseSupplement > 0
        let rawDenominator: Double? =
            (bsDebtSum <= 0 && bsLeaseSum <= 0)
            ? nil
            : bsDebtSum + (bsLeaseSum > 0 ? bsLeaseSum : leaseSupplement)
        // 0 以下の分母では coverage を測れない（0/0 を帯内と誤判定しない）
        let denominator = rawDenominator.flatMap { $0 > 0 ? $0 : nil }
        if denominator != nil, leaseFromNotes {
            warnings.append(breakdownWarningIBDLeaseDenominatorFromNotes)
            sentences.append("lease_denominator_from_notes")
        }

        // 5. 主データ源の選択。明細表に債務行があれば明細表優先。帯判定は分類済み BS
        //    全行（Jev 含む）に対して行い、帯外で BS が完全なら BS へ差し替える。
        //    公開 coverage の分母（コード分類のみ）とは分ける。
        let selectionLease = leaseInDebt ? 0 : (inputs.leaseNote?.total ?? schedLeaseSum)
        let selectionBase = classifiedDebtSum
            + (classifiedLeaseSum > 0 ? classifiedLeaseSum : selectionLease)
        let selectionDenominator = selectionBase > 0 ? selectionBase : nil
        let schedDebtRows = rows(inputs.schedule, schedClassified.classes, .interestBearingDebt)
        // J-GAAP の借入金等明細表は社債を含まない（社債は別の社債明細表）。明細表に
        // 社債行が無いとき、BS の社債行（コード/Jev 分類済みの債務）をそのまま足す。
        let schedHasBond = schedDebtRows.contains { $0.labelRaw.contains("社債") }
        let bsBondRows = schedHasBond || schedDebtRows.isEmpty
            ? [] : bsDebt.filter {
                // 「社債及び借入金」等の合算行は借入金と二重になるので社債単独の行だけ
                $0.labelRaw.contains("社債") && !$0.labelRaw.contains("借入") && !$0.labelRaw.contains("及び")
            }
        if !bsBondRows.isEmpty {
            sentences.append(
                "schedule_bonds_from_balance_sheet " + bsBondRows.map { "\($0.labelRaw)=\($0.closing.map(yen) ?? "null")" }.joined(separator: ", "))
        }
        let schedDebt = schedDebtRows + bsBondRows
        let primary: String
        let leaseRows: [IBDCandidate]
        var scheduleRejected = false
        if !schedDebt.isEmpty {
            guard let picked = await scheduleLeaseRows() else { return .unavailable }
            let schedTotal = (schedDebt + picked).reduce(0) { $0 + ($1.closing ?? 0) }
            if let selectionDenominator {
                let ratio = schedTotal / selectionDenominator
                if coverageBand.contains(ratio) {
                    primary = ibdRowSourceBorrowingsSchedule
                    leaseRows = picked
                } else if !bsUnresolved, !bsDebt.isEmpty {
                    primary = ibdRowSourceBalanceSheet
                    leaseRows = balanceSheetLeaseRows()
                    warnings.append(breakdownWarningIBDScheduleRejected)
                    scheduleRejected = true
                    sentences.append(
                        "schedule_rejected schedule_total=\(yen(schedTotal)) denominator=\(yen(selectionDenominator)) coverage=\(coverageText(ratio))")
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
        // 期首が1行でも欠けると部分合計は比較不能なので nil。期末は従来どおり合計する。
        let openingTotal: Double? =
            finalCandidates.allSatisfy { $0.opening != nil }
            ? finalCandidates.reduce(0) { $0 + ($1.opening ?? 0) }
            : nil
        payloadRows.append(
            BreakdownRowPayload(
                labelRaw: "合計", label: "合計", amount: total, profit: nil,
                rowKind: "subtotal",
                opening: openingTotal, closing: total))
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

    /// 銀行は `Xbrl.bankIBDComponents` の statement BS 行をそのまま積む。
    /// 分母は同じ行合計で、独立した coverage 検算はしない。
    private static func resolveBank(inputs: IBDInputs, code: String, docID: String) -> IBDResolution {
        guard !inputs.bankComponents.isEmpty else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let finalCandidates = inputs.bankComponents + (inputs.leaseNote?.rows ?? [])
        let total = finalCandidates.reduce(0) { $0 + ($1.closing ?? 0) }
        let openingTotal: Double? =
            finalCandidates.allSatisfy { $0.opening != nil }
            ? finalCandidates.reduce(0) { $0 + ($1.opening ?? 0) }
            : nil
        var payloadRows = finalCandidates.map { candidate in
            BreakdownRowPayload(
                labelRaw: candidate.labelRaw, label: candidate.label,
                amount: candidate.closing ?? 0, profit: nil, rowKind: "segment",
                opening: candidate.opening, closing: candidate.closing,
                averageRate: candidate.averageRatePercent,
                debtSource: candidate.source, maturityClass: candidate.maturityClass)
        }
        payloadRows.append(
            BreakdownRowPayload(
                labelRaw: "合計", label: "合計", amount: total, profit: nil,
                rowKind: "subtotal", opening: openingTotal, closing: total))
        let payload = BreakdownSnapshotPayload(
            axis: breakdownAxisInterestBearingDebt,
            denominator: total,
            denominatorTag: "bank_components",
            rows: payloadRows,
            sourceKind: breakdownSourceXbrlFacts,
            needsReview: false,
            warnings: [])
        let audit = SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: breakdownAxisInterestBearingDebt,
            model: Api.openrouterDecisionsModel, threshold: threshold,
            applied: false, needsReview: false,
            sentences: ["bank_components", "rows_total=\(String(format: "%.0f", total))"],
            calls: [], decisionSource: "interest_bearing_debt_bank_components")
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
