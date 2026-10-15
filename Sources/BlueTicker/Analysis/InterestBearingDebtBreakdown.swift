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
    /// `ibdRowSource*`
    var source: String
    /// `ibdMaturity*` または nil
    var maturityClass: String?
    var presetClass: IBDRowClass?
    /// 値を読んだ XBRL 要素のローカル名（payload の `source_tag`）。BS 行は科目の要素、
    /// 明細表・注記の行は表の TextBlock。コードで足した値は nil。
    var sourceTag: String? = nil
    /// `presetClass == .notInterestBearing` の行を除外するときの理由。nil は
    /// `non_interest_bearing`。証券業の営業上の借入は `scope_differs`。
    var excludedReason: String? = nil
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
    /// 銀行（`Xbrl.isBankFiling`: `DepositsLiabilitiesBNK` が statement Instant FieldSet にある、または EDINET 提出者業種が銀行業）。
    /// 保険は通常パイプライン（除外しない）。
    var isBank: Bool
    /// 銀行の BS コンポーネント行。`source` は `financials_bank_components`。
    /// 非銀行は空。
    var bankComponents: [IBDCandidate]
    var balanceSheet: [IBDCandidate]
    var schedule: [IBDCandidate]
    var leaseNote: IBDLeaseNote?

    init(
        consolidated: Bool, isBank: Bool = false, bankComponents: [IBDCandidate] = [],
        balanceSheet: [IBDCandidate], schedule: [IBDCandidate], leaseNote: IBDLeaseNote?
    ) {
        self.consolidated = consolidated
        self.isBank = isBank
        self.bankComponents = bankComponents
        self.balanceSheet = balanceSheet
        self.schedule = schedule
        self.leaseNote = leaseNote
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
    static let rowPolicy = JevDecisionPolicy(
        kind: .classify,
        question: rowQuestion,
        noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)
    static let duplicatePolicy = JevDecisionPolicy(
        kind: .classify,
        question: duplicateQuestion,
        noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    private static let threshold = SegmentNoteDecision.applyProbabilityThreshold

    /// BS の既知の有利子負債タグ（リース負債タグは除き .leaseLiability 側で確定する）。
    private static let knownDebtTags: Set<String> = {
        let leaseTags = Set(Xbrl.leaseLiabilitiesBSTags)
        var tags = Set(Xbrl.ibdIFRSCLTags)
        tags.formUnion(Xbrl.ibdIFRSNCLTags)
        tags.formUnion(["USGAAP_HTML_IBDCurrent", "USGAAP_HTML_IBDNonCurrent"])
        for group in Xbrl.ibdCurrentComponents + Xbrl.ibdNonCurrentComponents
            + Xbrl.ibdLiquidityOrderComponents {
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
    /// `edinetIndustry` は EDINET 提出者業種（銀行判定に使う。不明なら nil）。
    static func inputs(xbrlDir: URL, edinetIndustry: String? = nil) -> IBDInputs {
        let tags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let consolidated = BorrowingsSchedule.filerHasConsolidatedStatements(xbrlDir: xbrlDir)
        let accountingStandard = detectAccountingStandard(tags)
        // 銀行判定は旧 `IBDExtractor.extractBankIBD` と同じ statement Instant FieldSet。
        // 保険は通常パイプライン（資金調達の本業でも内訳を出す）。
        let instantFS = statementInstantFieldSet(
            xbrlDir: xbrlDir, allTags: tags, accountingStandard: accountingStandard)
        let isBank = Xbrl.isBankFiling(instantFS, edinetIndustry: edinetIndustry)
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
                : leaseNoteCandidates(xbrlDir: xbrlDir))
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
                    opening: item.prior, closing: item.current,
                    source: ibdRowSourceFinancialsBankComponents,
                    maturityClass: maturityClass(fromLabel: component.label),
                    presetClass: .interestBearingDebt, sourceTag: item.tag))
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
        var tags = Set(Xbrl.ibdIFRSCLTags)
        tags.formUnion(Xbrl.ibdIFRSNCLTags)
        tags.formUnion(Xbrl.leaseLiabilitiesBSTags)
        for group in Xbrl.ibdCurrentComponents { tags.formUnion(group) }
        for group in Xbrl.ibdNonCurrentComponents { tags.formUnion(group) }
        for group in Xbrl.ibdLiquidityOrderComponents { tags.formUnion(group) }
        for component in Xbrl.bankIBDComponents { tags.formUnion(component.tags) }
        tags.insert(Xbrl.bankMarkerTag)
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
            guard BorrowingsSchedule.isLeaseScheduleRow(row) else { return nil }
            guard row.current != nil || row.prior != nil else { return nil }
            let labelRaw = row.sourceLabel ?? row.label
            return IBDCandidate(
                labelRaw: labelRaw, label: row.label, tag: nil,
                opening: row.prior, closing: row.current,
                source: ibdRowSourceBorrowingsSchedule,
                maturityClass: maturityClass(fromLabel: labelRaw) ?? row.sectionMaturity,
                presetClass: .leaseLiability, sourceTag: row.sourceTag)
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
                    source: ibdRowSourceLeaseNote,
                    maturityClass: maturityClass(fromLabel: component.label),
                    presetClass: .leaseLiability, sourceTag: Xbrl.ifrsLeasesTextblockTag))
        }
        if rows.isEmpty, lease.current != nil || lease.prior != nil {
            rows.append(
                IBDCandidate(
                    labelRaw: "リース負債", label: "リース負債", tag: nil,
                    opening: lease.prior, closing: lease.current,
                    source: ibdRowSourceLeaseNote, maturityClass: nil,
                    presetClass: .leaseLiability, sourceTag: Xbrl.ifrsLeasesTextblockTag))
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
            // 判定順: 明示除外 → 証券業の営業借入 → 既知の債務 → 既知のリース → キーワード。
            // キーワードだけ当たる行は、標準タクソノミの要素なら Jev、会社拡張要素なら
            // 明細表と同じラベル規則（決まらなければ Jev）。
            var preset: IBDRowClass?
            var excludedReason: String?
            if Xbrl.ibdNonInterestBearingBSTags.contains(tag) {
                preset = .notInterestBearing
            } else if Xbrl.ibdSecuritiesBusinessBorrowingTags.contains(tag) {
                preset = .notInterestBearing
                excludedReason = ibdExcludedReasonScopeDiffers
            } else if knownDebtTags.contains(tag) {
                preset = .interestBearingDebt
            } else if Xbrl.leaseLiabilitiesBSTags.contains(tag) {
                preset = .leaseLiability
            } else if debtTagKeywords.contains(where: { tag.contains($0) })
                || debtLabelKeywords.contains(where: { label.contains($0) })
            {
                // US-GAAP の BS は HTML 表の行に仮想タグ（USGAAP_HTML_*）を振っただけで提出要素では
                // ないので、会社拡張のラベル規則に載せない（キヤノン: 「長期債務」行がキーワードに
                // 当たらず候補外のため、ラベル規則で残りを確定すると分母が欠けたまま帯内になる）。
                if standardLabels[tag] == nil, !tag.hasPrefix("USGAAP_HTML_") {
                    (preset, excludedReason) = balanceSheetExtensionPreset(label)
                } else {
                    preset = nil
                }
            } else {
                continue
            }
            candidates.append(
                IBDCandidate(
                    labelRaw: label, label: label, tag: tag,
                    opening: opening, closing: line.value,
                    source: ibdRowSourceBalanceSheet,
                    maturityClass: maturityClass(fromTag: tag) ?? maturityClass(fromLabel: label),
                    presetClass: preset, sourceTag: tag, excludedReason: excludedReason))
        }
        return candidates
    }

    /// 借入金等明細表（社債及び借入金注記）の行。`sourceLabel`（表示正規化前）を判定材料に使う。
    private static func scheduleCandidates(xbrlDir: URL) -> [IBDCandidate] {
        guard let extracted = BorrowingsSchedule.extractRows(xbrlDir: xbrlDir) else { return [] }
        var rows = extracted.rows
        // IFRS 社債及び借入金注記で「合計」の後に「（その他の金融負債）」区分としてリース負債を
        // 載せる会社（すかいらーく S100XUBI）。明細表にリース行が無いときだけ拾う。
        if !rows.contains(where: { BorrowingsSchedule.isLeaseDebtScheduleRowLabel($0.sourceLabel ?? $0.label) }) {
            rows += BorrowingsSchedule.ifrsNoteOtherFinancialLiabilityLeaseRows(xbrlDir: xbrlDir)
        }
        return rows.compactMap { row in
            guard row.current != nil || row.prior != nil else { return nil }
            let labelRaw = row.sourceLabel ?? row.label
            let securities = isSecuritiesBusinessBorrowingLabel(labelRaw)
            return IBDCandidate(
                labelRaw: labelRaw, label: row.label, tag: nil,
                opening: row.prior, closing: row.current,
                source: ibdRowSourceBorrowingsSchedule,
                maturityClass: maturityClass(fromLabel: labelRaw) ?? row.sectionMaturity,
                presetClass: securities ? .notInterestBearing : scheduleRowPreset(labelRaw),
                sourceTag: row.sourceTag,
                excludedReason: securities ? ibdExcludedReasonScopeDiffers : nil)
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
                    source: ibdRowSourceLeaseNote,
                    maturityClass: maturityClass(fromLabel: component.label),
                    presetClass: .leaseLiability, sourceTag: Xbrl.ifrsLeasesTextblockTag))
        }
        if rows.isEmpty, lease.current != nil {
            rows.append(
                IBDCandidate(
                    labelRaw: "リース負債", label: "リース負債", tag: nil,
                    opening: lease.prior, closing: lease.current,
                    source: ibdRowSourceLeaseNote, maturityClass: nil,
                    presetClass: .leaseLiability, sourceTag: Xbrl.ifrsLeasesTextblockTag))
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
        // 受入保証金・預り保証金は利息の付かない預り（日清食品 S100YEWB「長期受入保証金」）。
        // コードで非有利子に確定する。
        if cleaned.contains("受入保証金") || cleaned.contains("預り保証金") || cleaned.contains("敷金") {
            return .notInterestBearing
        }
        // 非有利子の典型（デリバティブ・和解金・預り金・引当金・債務保証等）は Jev に回す
        let nonDebt = ["デリバティブ", "和解", "預り", "預金", "保証金", "未払", "先渡", "引当", "債務保証"]
        if nonDebt.contains(where: { cleaned.contains($0) }) { return nil }
        if BorrowingsSchedule.isLeaseDebtScheduleRowLabel(cleaned) { return .leaseLiability }
        if scheduleDebtWords.contains(where: { cleaned.contains($0) }) { return .interestBearingDebt }
        return nil
    }

    /// 明細表・会社拡張 BS 科目のラベルで債務と確定する語。「借入債務」（トヨタの明細）・
    /// 「長期債務」「短期債務」（ニデック BS「１年以内返済予定長期債務」）を含む。
    private static let scheduleDebtWords = [
        "借入金", "借入債務", "社債", "コマーシャル・ペーパー", "コマーシャルペーパー", "借用金",
        "有利子負債", "長期債務", "短期債務",
    ]

    /// 証券業の営業上の借入（信用取引・有価証券担保・現先）のラベルか。
    static func isSecuritiesBusinessBorrowingLabel(_ label: String) -> Bool {
        let cleaned = cleanedLabel(label)
        return Xbrl.ibdSecuritiesBusinessBorrowingLabelWords.contains { cleaned.contains($0) }
    }

    /// 会社拡張要素の BS 科目の分類（標準要素は使わない）。明細表と同じラベル規則に、
    /// 証券業の営業借入（scope_differs で除外）と「社債、借入金及びリース負債」のような
    /// リース込みの債務科目（債務）を足したもの。決まらなければ nil（Jev）。
    static func balanceSheetExtensionPreset(_ label: String) -> (IBDRowClass?, String?) {
        if isSecuritiesBusinessBorrowingLabel(label) {
            return (.notInterestBearing, ibdExcludedReasonScopeDiffers)
        }
        let preset = scheduleRowPreset(label)
        if preset == .leaseLiability {
            let cleaned = cleanedLabel(label)
            if scheduleDebtWords.contains(where: { cleaned.contains($0) }) { return (.interestBearingDebt, nil) }
        }
        return (preset, nil)
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
            // 漢数字の「一年以内」「一年内」も同じ印（借入金等明細表の行ラベルに実在する）
            .replacingOccurrences(of: "一年", with: "1年")
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
        // 業種別接尾辞（…NCLGAS / …CLELC / …CLLEA 等）
        if tag.range(of: "NCL[A-Z]{3}$", options: .regularExpression) != nil { return ibdMaturityNonCurrent }
        if tag.range(of: "CL[A-Z]{3}$", options: .regularExpression) != nil { return ibdMaturityCurrent }
        let currentTags = [
            "ShortTermLoansPayable", "CurrentPortionOfLongTermLoansPayable",
            "CurrentPortionOfBonds",
            "CommercialPapersLiabilities", "ShortTermBondsPayable",
            "CurrentPortionOfBondsWithSubscriptionRightsToShares", "CurrentPortionOfConvertibleBonds",
            "ShortTermLoansPayableToSubsidiariesAndAffiliates",
            "ShortTermLoansPayableToShareholdersDirectorsOrEmployees",
            "CurrentPortionOfLongTermLoansPayableToSubsidiariesAndAffiliates",
            "USGAAP_HTML_IBDCurrent",
        ]
        if currentTags.contains(tag) { return ibdMaturityCurrent }
        let nonCurrentTags = [
            "LongTermLoansPayable", "BondsPayable",
            "ConvertibleBondTypeBondsWithSubscriptionRightsToShares", "ConvertibleBonds",
            "LongTermLoansPayableToSubsidiariesAndAffiliates",
            "LongTermLoansPayableToShareholdersDirectorsOrEmployees",
            "USGAAP_HTML_IBDNonCurrent",
        ]
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
        // リース込みの BS 債務科目: BondsBorrowingsAndLeaseLiabilities* のような合算タグ、
        // ラベルにリース負債を含む債務科目、または BS に別建てのリース科目が無いときの
        // 「有利子負債」集約（InterestBearingLiabilities*。トヨタ・RIZAP 等は注記でリースを内訳に含む）。
        // 貸手の債権流動化（…FluidityLeaseReceivables…）は名前に Lease があってもリースではない。
        let leaseInDebt = bsDebt.contains { row in
            let tag = row.tag ?? ""
            if Xbrl.ibdLessorSecuritizationTags.contains(tag) { return false }
            return tag.contains("Lease") || BorrowingsSchedule.isLeaseDebtScheduleRowLabel(row.labelRaw)
        } || (bsLease.isEmpty && bsDebt.contains { Xbrl.ibdInterestBearingAggregateTags.contains($0.tag ?? "") })
        let schedLease = rows(inputs.schedule, schedClassified.classes, .leaseLiability)
        let schedLeaseSum = schedLease.reduce(0) { $0 + ($1.closing ?? 0) }
        let noteRows = inputs.leaseNote?.rows ?? []

        func yen(_ value: Double) -> String { String(format: "%.0f", value) }
        // 明細表リースと同じ負債だと決まったリース注記（完全一致または Jev が同一と判断）
        var leaseNoteSuperseded = false

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
                leaseNoteSuperseded = true
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
            let result = await JevDecisionSampler.decide(
                policy: duplicatePolicy,
                options: IBDDuplicateRole.optionKeys,
                sentences: [
                    "\(ibdRowSourceBorrowingsSchedule): \(scheduleLabel)",
                    "\(ibdRowSourceLeaseNote): \(noteLabel)",
                ]
            ) {
                let choice = await decider.classifyNearDuplicate(
                    scheduleLabel: scheduleLabel, scheduleYen: schedLeaseSum,
                    leaseNoteLabel: noteLabel, leaseNoteYen: noteTotal)
                return JevChoiceAggregate.Sample(
                    selected: choice.selected, probability: choice.probability)
            }
            let applied = result.status == .accepted(IBDDuplicateRole.sameLiability)
                || result.status == .accepted(IBDDuplicateRole.differentLiabilities)
            if applied { anyApplied = true }
            calls.append(contentsOf: result.calls)
            let probabilityText = result.aggregate.probability.map { String(format: "%.2f", $0) } ?? "null"
            sentences.append(
                "lease_near_duplicate schedule=\(yen(schedLeaseSum)) lease_note=\(yen(noteTotal)) decision=\(result.aggregate.selected ?? "nil") p=\(probabilityText)")
            guard let selected = result.selectedKey else {
                if result.isEmpty { return nil }
                needsReview = true
                warnings.append(breakdownWarningIBDNearDuplicateUnresolved)
                return schedLease
            }
            if selected == IBDDuplicateRole.sameLiability, applied {
                leaseNoteSuperseded = true
                return schedLease
            }
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
        // BS のリース科目（コード分類）があれば、明細表・注記のリースより BS を合計に入れる。
        // 満期区分ごとに見て、BS に無い区分の明細表リース行（例: 流動分が BS「その他」に含まれる）は残す。
        let bsLeaseCode = bsLease.filter { $0.presetClass != nil }
        let bsLeaseWins = !bsLeaseCode.isEmpty && !leaseInDebt
        let primary: String
        let leaseRows: [IBDCandidate]
        var scheduleRejected = false
        if !schedDebt.isEmpty {
            let picked: [IBDCandidate]
            if bsLeaseWins {
                // BS のリース科目 + BS に区分の無い明細表リース行（最終の帳簿と同じ行で帯を見る）
                picked = reconcileLease(balanceSheet: bsLeaseCode, schedule: schedLease, note: noteRows).included
            } else {
                guard let scheduleLease = await scheduleLeaseRows() else { return .unavailable }
                picked = scheduleLease
            }
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

        // 6. BS を基準に明細表と突き合わせ、合計に入れる行（in_total）と除外行（理由つき）を決める。
        var ledger = IBDRowLedger()
        let nestingOutcome: AggregateNesting = primary == ibdRowSourceBorrowingsSchedule && leaseInDebt && bsBondRows.isEmpty
            ? nestUnderLeaseInclusiveAggregates(
                balanceSheet: bsDebt.filter { $0.presetClass != nil }, bsUnresolved: bsUnresolved,
                children: schedDebtRows + leaseRows)
            : .notApplicable
        var aggregateNesting: (parents: [IBDCandidate], children: [(row: IBDCandidate, parent: IBDCandidate?)], sentences: [String])?
        switch nestingOutcome {
        case .nested(let parents, let children, let nestSentences):
            aggregateNesting = (parents, children, nestSentences)
        case .unresolved(let reason):
            // 集約を親にできる形なのに内訳を割り当てられない。明細表の行を数えるが、黙って戻さない
            needsReview = true
            warnings.append(breakdownWarningIBDNestingParentUnresolved)
            sentences.append("nesting_lease_inclusive_aggregate_unresolved \(reason)")
        case .notApplicable:
            break
        }
        if let aggregateNesting {
            ledger.include(aggregateNesting.parents)
            for child in aggregateNesting.children {
                ledger.exclude(child.row, reason: ibdExcludedReasonDuplicateOfBalanceSheet, pairedTo: child.parent)
            }
            if leaseNoteSuperseded {
                for note in noteRows where !leaseRows.contains(note) {
                    ledger.exclude(note, reason: ibdExcludedReasonOtherTable, pairedTo: nil)
                }
            }
            sentences.append(contentsOf: aggregateNesting.sentences)
            for row in rows(inputs.schedule, schedClassified.classes, .notInterestBearing) {
                ledger.exclude(row, reason: row.excludedReason ?? ibdExcludedReasonNonInterestBearing, pairedTo: nil)
            }
            for row in rows(inputs.balanceSheet, bsClassified.classes, .notInterestBearing) {
                ledger.exclude(row, reason: row.excludedReason ?? ibdExcludedReasonNonInterestBearing, pairedTo: nil)
            }
        } else if primary == ibdRowSourceBorrowingsSchedule {
            let reconciled = reconcileScheduleDebt(
                schedule: schedDebtRows,
                balanceSheet: bsDebt.filter { $0.presetClass != nil })
            ledger.include(reconciled.included + bsBondRows)
            if reconciled.parentUnresolved {
                needsReview = true
                if !warnings.contains(breakdownWarningIBDNestingParentUnresolved) {
                    warnings.append(breakdownWarningIBDNestingParentUnresolved)
                }
            }
            sentences.append(contentsOf: reconciled.sentences)
            if bsLeaseWins {
                let leaseLedger = reconcileLease(
                    balanceSheet: bsLeaseCode, schedule: schedLease, note: noteRows)
                ledger.include(leaseLedger.included)
                for excluded in leaseLedger.excluded {
                    ledger.exclude(excluded.row, reason: excluded.reason, pairedTo: excluded.pairedTo)
                }
                sentences.append("lease_from_balance_sheet")
            } else {
                ledger.include(leaseRows)
                // 明細表リースと同じ負債を示しただけのリース注記行は別表の重複として残す
                if leaseNoteSuperseded {
                    for note in noteRows where !leaseRows.contains(note) {
                        ledger.exclude(note, reason: ibdExcludedReasonOtherTable, pairedTo: nil)
                    }
                }
            }
            for excluded in reconciled.excluded {
                ledger.exclude(excluded.row, reason: excluded.reason, pairedTo: excluded.pairedTo)
            }
            for row in rows(inputs.schedule, schedClassified.classes, .notInterestBearing) {
                ledger.exclude(row, reason: row.excludedReason ?? ibdExcludedReasonNonInterestBearing, pairedTo: nil)
            }
            // BS の明示除外・証券業の営業借入も行として残す（合計には入れない）
            for row in rows(inputs.balanceSheet, bsClassified.classes, .notInterestBearing) {
                ledger.exclude(row, reason: row.excludedReason ?? ibdExcludedReasonNonInterestBearing, pairedTo: nil)
            }
        } else {
            ledger.include(bsDebt + leaseRows)
            for row in rows(inputs.balanceSheet, bsClassified.classes, .notInterestBearing) {
                ledger.exclude(row, reason: row.excludedReason ?? ibdExcludedReasonNonInterestBearing, pairedTo: nil)
            }
        }

        // 7. 合計と coverage は in_total 行だけ（Jev の判断で帯判定は覆らない）。
        let includedRows = ledger.entries.filter(\.inTotal).map(\.row)
        let total = includedRows.reduce(0) { $0 + ($1.closing ?? 0) }
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
        // 除外行は4つの理由のどれかを必ず持つ。付けられない行があれば公開しない。
        if ledger.entries.contains(where: { !$0.inTotal && !ibdExcludedReasons.contains($0.excludedReason ?? "") }) {
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

        // 8. 格納用ペイロード。合計 = in_total 行の closing の和。
        // 入れ子は product_service と同じ category_group（親 = BS 科目）/ category（内訳）で示す。
        // 親行は category_group = 自分のラベル・category = null、内訳行は category_group = 親のラベル。
        let parentIndices = Set(ledger.entries.compactMap(\.pairedTo))
        var payloadRows = ledger.entries.enumerated().map { index, entry in
            var categoryGroup: String?
            var category: String?
            if let parent = entry.pairedTo {
                categoryGroup = ledger.entries[parent].row.label
                category = entry.row.label
            } else if parentIndices.contains(index) {
                categoryGroup = entry.row.label
            }
            return BreakdownRowPayload(
                labelRaw: entry.row.labelRaw, label: entry.row.label,
                amount: entry.row.closing ?? 0, profit: nil, rowKind: "segment",
                categoryGroup: categoryGroup, category: category,
                opening: entry.row.opening, closing: entry.row.closing,
                debtSource: entry.row.source, maturityClass: entry.row.maturityClass,
                inTotal: entry.inTotal, excludedReason: entry.excludedReason,
                pairedRowIndex: entry.pairedTo, sourceTag: entry.row.sourceTag)
        }
        // 期首が1行でも欠けると部分合計は比較不能なので nil。
        let openingTotal: Double? =
            includedRows.allSatisfy { $0.opening != nil }
            ? includedRows.reduce(0) { $0 + ($1.opening ?? 0) }
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

    // MARK: - BS 基準の突き合わせ

    /// 明細表と BS を比べる科目のまとまり。BS の合算科目（社債及び借入金等）は対象外。
    enum LineGroup: Equatable {
        case loansCurrent, loansNonCurrent, commercialPaper
    }

    /// 同じ科目とみなす金額差。表示単位（百万円）の端数を行ごとに 0.5 まで許す。
    static func sameAmount(_ a: Double?, _ b: Double?, rows: Int) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) <= 500_000 * Double(max(rows, 1))
    }

    /// BS 行のまとまり（タグで決める）と、短期借入金・CP（B6 の足し戻し対象）か。
    static func balanceSheetGroup(_ row: IBDCandidate) -> (group: LineGroup, shortTermKind: Bool)? {
        guard let tag = row.tag else { return nil }
        if tag.contains("CommercialPaper") { return (.commercialPaper, true) }
        switch tag {
        case "ShortTermLoansPayable", "ShortTermBorrowingsCLIFRS":
            return (.loansCurrent, true)
        case "CurrentPortionOfLongTermLoansPayable", "CurrentPortionOfLongTermBorrowingsCLIFRS":
            return (.loansCurrent, false)
        case "BorrowingsCLIFRS":
            return (.loansCurrent, cleanedLabel(row.labelRaw) == "短期借入金")
        case "LongTermLoansPayable", "BorrowingsNCLIFRS", "LongTermBorrowingsNCLIFRS":
            return (.loansNonCurrent, false)
        default:
            return nil
        }
    }

    /// IFRS の流動「借入金」1科目（短期借入金だけを表すラベルでないもの）。
    static func isGenericCurrentBorrowings(_ row: IBDCandidate) -> Bool {
        row.tag == "BorrowingsCLIFRS" && cleanedLabel(row.labelRaw) != "短期借入金"
    }

    /// 明細表行のまとまり（ラベルで決める）。社債・リース・判別できない行は nil。
    static func scheduleGroup(_ row: IBDCandidate) -> (group: LineGroup, shortTermKind: Bool)? {
        let label = cleanedLabel(row.labelRaw)
        if label.contains("コマーシャル") { return (.commercialPaper, true) }
        guard label.contains("借入金"), !label.contains("社債"), !label.contains("リース") else {
            return nil
        }
        if label.contains("短期") { return (.loansCurrent, true) }
        switch row.maturityClass {
        case ibdMaturityCurrent?: return (.loansCurrent, false)
        case ibdMaturityNonCurrent?: return (.loansNonCurrent, false)
        default: return label.contains("長期") ? (.loansNonCurrent, false) : nil
        }
    }

    /// 「(注n)」「*n」と空白を除いたラベル。
    static func cleanedLabel(_ label: String) -> String {
        var cleaned = label
        if let regex = try? NSRegularExpression(pattern: #"[（(]注[0-9０-９]+[）)]|\*[0-9０-９]+"#) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }
        return cleaned.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
    }

    struct ExcludedRow: Equatable {
        var row: IBDCandidate
        var reason: String
        /// 合計に入る対応行（候補そのもの。payload では rows の添字になる）
        var pairedTo: IBDCandidate?
    }

    /// 明細表主のとき、借入金・CP を BS の科目（親）ごとに突き合わせる（入れ子）。
    /// - BS に同じまとまりの科目があれば BS の行を合計に入れる。明細表の行はその BS 行の内訳
    ///   （参照行）として残す: 金額が親と一致すれば duplicate_of_balance_sheet、違えば scope_differs。
    ///   不一致は needs_review にしない（差額は監査 `nesting_gap` に残す）。
    /// - 親の決め方（コードだけ）: 短期借入金・CP の明細行 → BS の短期借入金・CP 行。1年内返済の長期
    ///   借入金 → BS の1年内返済行、無ければ BS の短期借入金行（BS 短期借入金に1年内返済分を含める
    ///   会社。ただし BS 短期借入金が明細表の短期借入金だけと一致し1年内分に当期末値があるときは
    ///   含めていないので入れ子にしない）。長期借入金 → BS の長期借入金行。
    /// - 区分を跨ぐ明細行（「借入金」「長期借入金（1年以内に返済予定のものを含む）」）は BS の借入金
    ///   各行の和と比べ、親を1行に決められないので対応先は付けない。
    /// - 親候補が2行以上で決まらないときだけ `parentUnresolved`（needs_review）。
    /// - 親が無い明細行（BS に同じ区分の科目が無い、または 1年内返済分を BS 短期借入金に含めていない）は
    ///   needs_review にせず、そのまま合計に入れる。重複・漏れは coverage 帯（95〜105%）の判定に任せる。
    /// - BS の合算科目（社債及び借入金等）は比べない（明細表の内訳をそのまま使う）。
    static func reconcileScheduleDebt(
        schedule: [IBDCandidate], balanceSheet: [IBDCandidate]
    ) -> (included: [IBDCandidate], excluded: [ExcludedRow], parentUnresolved: Bool, sentences: [String]) {
        var included = schedule
        var excluded: [ExcludedRow] = []
        var sentences: [String] = []
        var parentUnresolved = false
        let bsLoans = balanceSheet.filter { balanceSheetGroup($0) != nil }
        guard !bsLoans.isEmpty else { return (included, excluded, false, sentences) }
        func bs(_ group: LineGroup, short: Bool) -> [IBDCandidate] {
            bsLoans.filter { balanceSheetGroup($0)?.group == group && balanceSheetGroup($0)?.shortTermKind == short }
        }
        func closingSum(_ rows: [IBDCandidate]) -> Double { rows.reduce(0) { $0 + ($1.closing ?? 0) } }
        let schedShortLoans = schedule.filter {
            scheduleGroup($0)?.group == .loansCurrent && scheduleGroup($0)?.shortTermKind == true
        }
        // 流動の借入金を1科目にまとめた BS 行（IFRS「借入金」BorrowingsCLIFRS。短期・1年内・CP を含み得る）
        let genericCurrent = bsLoans.filter { isGenericCurrentBorrowings($0) }
        let currentPortion = bs(.loansCurrent, short: false).filter { !isGenericCurrentBorrowings($0) }
        var children: [(parent: IBDCandidate, row: IBDCandidate)] = []
        var spanning: [IBDCandidate] = []
        var pendingCP: [IBDCandidate] = []
        for row in schedule {
            let group = scheduleGroup(row)
            let label = cleanedLabel(row.labelRaw)
            let spansMaturities = label.contains("借入金")
                && (group == nil || (label.contains("含む") && (label.contains("1年") || label.contains("１年") || label.contains("一年"))))
                && !label.contains("社債") && !label.contains("リース")
            if spansMaturities, !label.contains("短期") {
                spanning.append(row)
                continue
            }
            guard let group else { continue }
            var parents: [IBDCandidate]
            switch (group.group, group.shortTermKind) {
            case (.loansCurrent, true):
                parents = bs(.loansCurrent, short: true)
                if parents.isEmpty { parents = genericCurrent }
            case (.loansCurrent, false):
                parents = currentPortion
                if parents.isEmpty { parents = genericCurrent }
                if parents.isEmpty {
                    let bsShort = bs(.loansCurrent, short: true)
                    // BS 短期借入金が明細表の短期借入金だけと一致し、1年内分に当期末値がある → 含めていない
                    let excludesCurrentPortion = (row.closing ?? 0) != 0
                        && sameAmount(closingSum(bsShort), closingSum(schedShortLoans), rows: bsShort.count + schedShortLoans.count)
                        && !sameAmount(closingSum(bsShort), closingSum(schedShortLoans) + (row.closing ?? 0),
                            rows: bsShort.count + schedShortLoans.count + 1)
                    parents = excludesCurrentPortion ? [] : bsShort
                }
            case (.commercialPaper, _):
                parents = bs(.commercialPaper, short: true)
                if parents.isEmpty { pendingCP.append(row); continue }
            default:
                parents = bs(group.group, short: group.shortTermKind)
            }
            if parents.count == 1 {
                children.append((parents[0], row))
            } else if parents.count > 1 {
                parentUnresolved = true
                sentences.append("nesting_parent_unresolved \(row.labelRaw) candidates=\(parents.count)")
            }
            // 親が無い（BS に載らない区分）明細行はそのまま合計に入れる
        }
        // BS に CP 科目が無い明細表の CP は、流動の借入金科目1行に含めるとその科目の内訳と一致する
        // ときだけ入れ子にする（例: S100YEWN の BS「借入金」= 短期 + 1年内 + CP）。それ以外は数える。
        if !pendingCP.isEmpty {
            let currentParents = genericCurrent.isEmpty ? bs(.loansCurrent, short: true) : genericCurrent
            if currentParents.count == 1 {
                let parent = currentParents[0]
                let nestedSum = closingSum(children.filter { $0.parent == parent }.map(\.row))
                let rows = 1 + children.filter { $0.parent == parent }.count + pendingCP.count
                if sameAmount(parent.closing, nestedSum + closingSum(pendingCP), rows: rows),
                   !sameAmount(parent.closing, nestedSum, rows: rows)
                {
                    children += pendingCP.map { (parent, $0) }
                }
            }
        }
        // 明細表の素の「長期借入金」（区分なし・1年内返済行が別に無い）が BS の非流動借入金を超え、
        // その差が BS の流動の合算科目（社債及び借入金 等。区分外）と一致するときは、その合算科目も
        // 親とする（区分を跨ぐ内訳。S100Y2PC: 15,208 + 5,837 = 21,045）。
        var coParents: [(rows: [IBDCandidate], parents: [IBDCandidate])] = []
        let scheduleHasCurrentPortion = schedule.contains {
            scheduleGroup($0)?.group == .loansCurrent && scheduleGroup($0)?.shortTermKind == false
        }
        if !scheduleHasCurrentPortion {
            let aggregatesCurrent = balanceSheet.filter {
                balanceSheetGroup($0) == nil && $0.maturityClass == ibdMaturityCurrent
                    && ($0.tag ?? "").contains("Borrowings")
            }
            for parent in bs(.loansNonCurrent, short: false) {
                let rows = children.filter { $0.parent == parent }.map(\.row)
                guard !rows.isEmpty, rows.allSatisfy({ $0.maturityClass == nil }) else { continue }
                let gap = closingSum(rows) - (parent.closing ?? 0)
                guard gap > 0, !sameAmount(gap, 0, rows: rows.count + 1) else { continue }
                let matches = aggregatesCurrent.filter { sameAmount($0.closing, gap, rows: rows.count + 2) }
                if matches.count == 1 {
                    coParents.append((rows, [parent, matches[0]]))
                    children.removeAll { child in rows.contains(child.row) }
                }
            }
        }
        // 合計に入れる BS 行: 内訳を持つ親、短期借入金・CP（B6 の足し戻し）、明細表に同じまとまりの
        // 行が無い BS 行。区分を跨ぐ明細行があれば、その親として CP 以外の BS 借入金行すべて。
        let spanningParents = spanning.isEmpty ? [] : bsLoans.filter {
            balanceSheetGroup($0)?.group != .commercialPaper
        }
        let countedBS = bsLoans.filter { bsRow in
            guard let bsGroup = balanceSheetGroup(bsRow) else { return false }
            if children.contains(where: { $0.parent == bsRow }) || spanningParents.contains(bsRow)
                || coParents.contains(where: { $0.parents.contains(bsRow) }) { return true }
            if bsGroup.shortTermKind { return true }
            return !schedule.contains { scheduleGroup($0)?.group == bsGroup.group }
        }
        // 足し戻す BS 行（内訳なし）と同額の、どの科目にも入らない明細行（J-GAAP 明細表の
        // 「その他有利子負債」に CP を載せる会社。S100YJ8J / S100YJRS / S100YL2M）は同じ負債の内訳。
        for bsRow in countedBS where !children.contains(where: { $0.parent == bsRow }) && !spanningParents.contains(bsRow) {
            guard (bsRow.closing ?? 0) != 0 else { continue }
            let matches = schedule.filter { row in
                scheduleGroup(row) == nil && !spanning.contains(row)
                    && !children.contains(where: { $0.row == row })
                    && !cleanedLabel(row.labelRaw).contains("社債")
                    && !BorrowingsSchedule.isLeaseDebtScheduleRowLabel(row.labelRaw)
                    && sameAmount(row.closing, bsRow.closing, rows: 2)
            }
            if matches.count == 1 { children.append((bsRow, matches[0])) }
        }
        included.removeAll { row in
            children.contains { $0.row == row } || spanning.contains(row)
                || coParents.contains { $0.rows.contains(row) }
        }
        included += countedBS + coParents.flatMap(\.parents).filter { !countedBS.contains($0) }
        for group in coParents {
            let parentSum = closingSum(group.parents)
            let componentSum = closingSum(group.rows)
            sentences.append(
                "nesting_gap parent=\(group.parents.map(\.labelRaw).joined(separator: "+")) balance_sheet=\(String(format: "%.0f", parentSum)) components=\(String(format: "%.0f", componentSum)) gap=\(String(format: "%.0f", parentSum - componentSum))")
            for row in group.rows {
                excluded.append(ExcludedRow(row: row, reason: ibdExcludedReasonDuplicateOfBalanceSheet, pairedTo: nil))
            }
        }
        func amount(_ value: Double) -> String { String(format: "%.0f", value) }
        for parent in countedBS where !spanningParents.contains(parent)
            && !coParents.contains(where: { $0.parents.contains(parent) }) {
            let rows = children.filter { $0.parent == parent }.map(\.row)
            guard !rows.isEmpty else {
                sentences.append("balance_sheet_add_back \(parent.labelRaw)=\(amount(parent.closing ?? 0))")
                continue
            }
            let componentSum = closingSum(rows)
            sentences.append(
                "nesting_gap parent=\(parent.labelRaw) balance_sheet=\(amount(parent.closing ?? 0)) components=\(amount(componentSum)) gap=\(amount((parent.closing ?? 0) - componentSum))")
            for row in rows {
                // 明細行が親の全額と一致するか、内訳の和が親と一致すれば重複、違えば範囲違い
                let duplicate = row.closing == nil
                    || sameAmount(row.closing, parent.closing, rows: 2)
                    || sameAmount(componentSum, parent.closing, rows: rows.count + 1)
                excluded.append(ExcludedRow(
                    row: row,
                    reason: duplicate ? ibdExcludedReasonDuplicateOfBalanceSheet : ibdExcludedReasonScopeDiffers,
                    pairedTo: parent))
            }
        }
        if !spanning.isEmpty {
            let nested = children.filter { spanningParents.contains($0.parent) }.map(\.row)
            let parentSum = closingSum(spanningParents)
            let componentSum = closingSum(spanning + nested)
            sentences.append(
                "nesting_gap parent=\(spanningParents.map(\.labelRaw).joined(separator: "+")) balance_sheet=\(amount(parentSum)) components=\(amount(componentSum)) gap=\(amount(parentSum - componentSum))")
            let duplicate = sameAmount(componentSum, parentSum, rows: spanning.count + nested.count + spanningParents.count)
            let reason = duplicate ? ibdExcludedReasonDuplicateOfBalanceSheet : ibdExcludedReasonScopeDiffers
            // 区分を跨ぐ行は親を1行に決められない（対応先なし）。同じ親群の他の内訳も同じ扱い。
            for row in spanning + nested {
                excluded.append(ExcludedRow(
                    row: row, reason: reason,
                    pairedTo: spanningParents.count == 1 ? spanningParents[0] : nil))
            }
        }
        return (included, excluded, parentUnresolved, sentences)
    }

    /// リース込みの「有利子負債」集約（`Xbrl.ibdInterestBearingAggregateTags`）を親にして、明細表の
    /// 債務行とリース行をその内訳にする。親の候補は集約と、ラベル規則で債務に確定した会社拡張の
    /// BS 科目（AGC「1年内返済予定の長期有利子負債」）。BS のコード分類の債務科目はすべて親の候補で
    /// なければならない（他の科目があれば nil）。
    /// 割り当て: 流動の内訳は流動の親だけ、非流動の内訳は流動以外の親だけ、区分が無い（null）内訳は
    /// どの親にも入り得る。各親の closing が内訳の和と一致する（`sameAmount`）割り当てが**ただ1つ**
    /// のときだけ入れ子にする（区分の無い行に区分を作らない。金額の一致だけで決める）。期末値が
    /// 無い・0 の内訳は和に効かないので、入り得る親が1つならそこ、複数なら対応先なしにする。
    /// 集約が無い・BS に未分類行や他の債務科目があるときは `.notApplicable`（従来どおり明細表の行を
    /// 数える）。集約を親にできる形なのに割り当てが一致しない・複数ある・探索の上限を超えたときは
    /// `.unresolved`（呼び出し側が明細表の行を数えたうえで needs_review と監査に理由を残す。黙って
    /// 明細表に戻さない）。
    enum AggregateNesting {
        case notApplicable
        case unresolved(reason: String)
        case nested(parents: [IBDCandidate], children: [(row: IBDCandidate, parent: IBDCandidate?)], sentences: [String])
    }

    /// 割り当て探索で訪れる節点の上限（最悪 4^16）。超えたら `.unresolved`。
    static let aggregateNestingNodeBudget = 200_000

    static func nestUnderLeaseInclusiveAggregates(
        balanceSheet: [IBDCandidate], bsUnresolved: Bool, children: [IBDCandidate],
        nodeBudget: Int = aggregateNestingNodeBudget
    ) -> AggregateNesting {
        guard !bsUnresolved, !children.isEmpty else { return .notApplicable }
        let aggregates = balanceSheet.filter { Xbrl.ibdInterestBearingAggregateTags.contains($0.tag ?? "") }
        guard !aggregates.isEmpty else { return .notApplicable }
        let parents = balanceSheet.filter { row in
            let tag = row.tag ?? ""
            if Xbrl.ibdInterestBearingAggregateTags.contains(tag) { return true }
            // ラベル規則で確定した会社拡張の債務科目（区分つき）
            return !knownDebtTags.contains(tag) && !tag.hasPrefix("USGAAP_HTML_") && row.maturityClass != nil
        }
        guard parents.count == balanceSheet.count else { return .notApplicable }
        guard parents.count <= 4 else { return .unresolved(reason: "too_many_parents count=\(parents.count)") }
        func allowed(_ child: IBDCandidate) -> [Int] {
            parents.indices.filter { i in
                switch child.maturityClass {
                case ibdMaturityCurrent?: return parents[i].maturityClass == ibdMaturityCurrent
                case ibdMaturityNonCurrent?: return parents[i].maturityClass != ibdMaturityCurrent
                default: return true
                }
            }
        }
        let valued = children.filter { ($0.closing ?? 0) != 0 }
        let unvalued = children.filter { ($0.closing ?? 0) == 0 }
        guard valued.count <= 16 else { return .unresolved(reason: "too_many_components count=\(valued.count)") }
        let options = valued.map(allowed)
        if let k = options.firstIndex(where: \.isEmpty) {
            return .unresolved(reason: "no_parent_for_maturity component=\(valued[k].labelRaw)")
        }
        // 各親の内訳が何行入るかで端数許容が変わるので、最後に sameAmount で確かめる
        var solutions: [[Int]] = []
        var assignment = Array(repeating: -1, count: valued.count)
        var sums = Array(repeating: 0.0, count: parents.count)
        let tolerance = 500_000.0 * Double(valued.count + parents.count)
        var nodes = 0
        var budgetExceeded = false
        func search(_ k: Int) {
            if solutions.count > 1 || budgetExceeded { return }
            nodes += 1
            if nodes > nodeBudget {
                budgetExceeded = true
                return
            }
            if k == valued.count {
                let ok = parents.indices.allSatisfy { i in
                    let n = assignment.filter { $0 == i }.count
                    return n > 0 && sameAmount(sums[i], parents[i].closing, rows: n + 1)
                }
                if ok { solutions.append(assignment) }
                return
            }
            for i in options[k] {
                let amount = valued[k].closing ?? 0
                // 親を超える和は打ち切る（金額は正の前提。負の行があれば打ち切らない）
                if amount > 0, sums[i] + amount > (parents[i].closing ?? 0) + tolerance { continue }
                assignment[k] = i
                sums[i] += amount
                search(k + 1)
                sums[i] -= amount
                assignment[k] = -1
            }
        }
        search(0)
        if budgetExceeded { return .unresolved(reason: "search_budget_exceeded nodes=\(nodeBudget)") }
        if solutions.count > 1 { return .unresolved(reason: "ambiguous_assignment") }
        guard let solution = solutions.first else {
            let parentTotal = parents.reduce(0) { $0 + ($1.closing ?? 0) }
            let childTotal = valued.reduce(0) { $0 + ($1.closing ?? 0) }
            return .unresolved(reason: "no_matching_assignment balance_sheet=\(String(format: "%.0f", parentTotal)) components=\(String(format: "%.0f", childTotal))")
        }
        var assigned: [(row: IBDCandidate, parent: IBDCandidate?)] = zip(valued, solution).map { ($0, parents[$1]) }
        for row in unvalued {
            let candidates = allowed(row)
            assigned.append((row, candidates.count == 1 ? parents[candidates[0]] : nil))
        }
        // 表示順は明細表の順
        assigned.sort { a, b in
            (children.firstIndex(of: a.row) ?? 0) < (children.firstIndex(of: b.row) ?? 0)
        }
        var sentences: [String] = []
        for parent in parents {
            let sum = assigned.filter { $0.parent == parent }.reduce(0) { $0 + ($1.row.closing ?? 0) }
            sentences.append(
                "nesting_lease_inclusive_aggregate parent=\(parent.labelRaw) balance_sheet=\(String(format: "%.0f", parent.closing ?? 0)) components=\(String(format: "%.0f", sum))")
        }
        return .nested(parents: parents, children: assigned, sentences: sentences)
    }

    /// BS にリース科目があるとき、BS のリース行を合計に入れる。明細表のリース行は満期区分が
    /// 同じ BS 行があれば除外（同額は duplicate、違えば scope_differs）、BS に無い区分なら残す。
    /// 区分の無い明細表リース行とリース注記は、まず BS リース科目1行と同額か見て（同額なら
    /// duplicate でその行を対応先にする）、残りを BS リース合計と比べて除外する。
    static func reconcileLease(
        balanceSheet: [IBDCandidate], schedule: [IBDCandidate], note: [IBDCandidate]
    ) -> (included: [IBDCandidate], excluded: [ExcludedRow]) {
        var included = balanceSheet
        var excluded: [ExcludedRow] = []
        // 明細表・注記の行が BS のリース科目1行と同額なら、その行の重複（対応先あり）。
        func exactBSMatch(_ row: IBDCandidate, among rows: [IBDCandidate]? = nil) -> IBDCandidate? {
            guard (row.closing ?? 0) != 0 else { return nil }
            let matches = (rows ?? balanceSheet).filter { sameAmount(row.closing, $0.closing, rows: 2) }
            return matches.count == 1 ? matches[0] : nil
        }
        func againstTotal(_ candidates: [IBDCandidate]) {
            var rows: [IBDCandidate] = []
            var matched: [IBDCandidate] = []
            for row in candidates {
                if let match = exactBSMatch(row) {
                    matched.append(match)
                    excluded.append(ExcludedRow(row: row, reason: ibdExcludedReasonDuplicateOfBalanceSheet, pairedTo: match))
                } else {
                    rows.append(row)
                }
            }
            guard !rows.isEmpty else { return }
            // 残りは、同額で対応した BS 行を除いた BS リース科目の和と比べる。
            let remainingBS = matched.isEmpty ? balanceSheet : balanceSheet.filter { !matched.contains($0) }
            let remainingTotal = remainingBS.reduce(0) { $0 + ($1.closing ?? 0) }
            let sum = rows.reduce(0) { $0 + ($1.closing ?? 0) }
            let reason = sameAmount(sum, remainingTotal, rows: rows.count + remainingBS.count)
                ? ibdExcludedReasonDuplicateOfBalanceSheet : ibdExcludedReasonScopeDiffers
            // 一部が同額で対応したあとの残りは、残った BS 行と1対1とは言えないので対応先を付けない。
            let pair = matched.isEmpty && balanceSheet.count == 1 ? balanceSheet[0] : nil
            excluded += rows.map { ExcludedRow(row: $0, reason: reason, pairedTo: pair) }
        }
        var unbucketed: [IBDCandidate] = []
        for row in schedule {
            guard let maturity = row.maturityClass else {
                unbucketed.append(row)
                continue
            }
            let bsSame = balanceSheet.filter { $0.maturityClass == maturity }
            guard !bsSame.isEmpty else {
                included.append(row)  // BS に無い区分（例: 流動分が BS の「その他」に含まれる）
                continue
            }
            if let match = exactBSMatch(row, among: bsSame) {
                excluded.append(ExcludedRow(row: row, reason: ibdExcludedReasonDuplicateOfBalanceSheet, pairedTo: match))
                continue
            }
            let bsSum = bsSame.reduce(0) { $0 + ($1.closing ?? 0) }
            let reason = sameAmount(row.closing, bsSum, rows: 1 + bsSame.count)
                ? ibdExcludedReasonDuplicateOfBalanceSheet : ibdExcludedReasonScopeDiffers
            excluded.append(ExcludedRow(
                row: row, reason: reason, pairedTo: bsSame.count == 1 ? bsSame[0] : nil))
        }
        againstTotal(unbucketed)
        againstTotal(note)
        return (included, excluded)
    }

    /// 合計に入る行と除外行の帳簿。除外行の対応先は合計に入る行の位置で持つ。
    struct IBDRowLedger {
        struct Entry {
            var row: IBDCandidate
            var inTotal: Bool
            var excludedReason: String?
            var pairedTo: Int?
        }
        private(set) var entries: [Entry] = []

        mutating func include(_ rows: [IBDCandidate]) {
            for row in rows where !entries.contains(where: { $0.row == row }) {
                entries.append(Entry(row: row, inTotal: true, excludedReason: nil, pairedTo: nil))
            }
        }

        mutating func exclude(_ row: IBDCandidate, reason: String, pairedTo: IBDCandidate?) {
            guard !entries.contains(where: { $0.row == row }) else { return }
            let index = pairedTo.flatMap { pair in
                entries.firstIndex { $0.inTotal && $0.row == pair }
            }
            entries.append(Entry(row: row, inTotal: false, excludedReason: reason, pairedTo: index))
        }
    }

    /// 銀行は `Xbrl.bankIBDComponents` の statement BS 行をそのまま積む（預金・譲渡性預金は含めない）。
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
                debtSource: candidate.source, maturityClass: candidate.maturityClass,
                inTotal: true, sourceTag: candidate.sourceTag)
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
            let result = await JevDecisionSampler.decide(
                policy: rowPolicy,
                options: IBDRowClass.allCases.map(\.rawValue),
                sentences: ["\(candidate.source): \(candidate.labelRaw)"]
            ) {
                let choice = await decider.classifyRow(
                    label: candidate.labelRaw, source: candidate.source, tag: candidate.tag,
                    closingYen: candidate.closing, siblingLabels: siblings)
                return JevChoiceAggregate.Sample(
                    selected: choice.selected, probability: choice.probability)
            }
            if result.isEmpty { return ([], calls, applied, true) }
            calls.append(contentsOf: result.calls)
            if let selected = result.selectedKey, let rowClass = IBDRowClass(rawValue: selected) {
                applied = true
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
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: InterestBearingDebtBreakdown.rowPolicy.transportRetries,
            onFailure: "InterestBearingDebtBreakdown: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[question]?.choice
        else { return unavailable }
        return IBDChoice(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities))
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
