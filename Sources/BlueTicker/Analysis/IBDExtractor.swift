import Foundation
import SwiftSoup

struct IBDResult {
    var total: Double?
    var priorTotal: Double?
    var components: [(label: String, current: Double?, prior: Double?)]
    var method: String
    var accountingStandard: String
}

enum IBDExtractor {

    // コンポーネント表示用ラベル
    private static let componentDefs: [(label: String, tags: [String])] = [
        ("短期借入金", ["ShortTermLoansPayable", "BorrowingsCLIFRS"]),
        ("コマーシャル・ペーパー", ["CommercialPapersLiabilities"]),
        ("短期社債", ["ShortTermBondsPayable"]),
        ("1年内償還予定の社債", ["CurrentPortionOfBonds", "BondsPayableCLIFRS", "CurrentPortionOfBondsCLIFRS"]),
        ("1年内返済予定の長期借入金", ["CurrentPortionOfLongTermLoansPayable",
                                      "CurrentPortionOfLongTermBorrowingsCLIFRS",
                                      "CurrentPortionOfLongTermDebtCLIFRS"]),
        ("リース負債（流動）", ["LeaseObligationsCL", "LeaseLiabilitiesCLIFRS"]),
        ("1年内償還予定の新株予約権付社債", ["CurrentPortionOfBondsWithSubscriptionRightsToShares"]),
        ("1年内償還予定の転換社債", ["CurrentPortionOfConvertibleBonds"]),
        ("関係会社短期借入金", ["ShortTermLoansPayableToSubsidiariesAndAffiliates"]),
        ("株主、役員又は従業員からの短期借入金", ["ShortTermLoansPayableToShareholdersDirectorsOrEmployees"]),
        ("1年内返済予定の関係会社長期借入金", ["CurrentPortionOfLongTermLoansPayableToSubsidiariesAndAffiliates",
                                              "CurrentPortionOfLongTermLoansPayableToSubsidiariesAndAffiliatesCLELC"]),
        ("関係会社短期債務", ["ShortTermDebtToSubsidiariesAndAffiliatesCLELE",
                              "ShortTermDebtToSubsidiariesAndAffiliatesCLGAS"]),
        ("債権流動化に伴う支払債務", ["PayablesUnderFluidityLeaseReceivablesCLLEA"]),
        ("1年内支払予定の債権流動化に伴う長期支払債務", ["CurrentPortionOfLongTermPayablesUnderFluidityLeaseReceivablesCLLEA"]),
        ("社債", ["BondsPayable", "BondsPayableNCLIFRS"]),
        ("長期借入金", ["LongTermLoansPayable", "BorrowingsNCLIFRS", "LongTermDebtNCLIFRS"]),
        ("リース負債（非流動）", ["LeaseObligationsNCL", "LeaseLiabilitiesNCLIFRS"]),
        ("新株予約権付社債", ["BondsWithSubscriptionRightsToSharesNCL"]),
        ("転換社債型新株予約権付社債", ["ConvertibleBondTypeBondsWithSubscriptionRightsToShares"]),
        ("転換社債", ["ConvertibleBonds"]),
        ("関係会社長期借入金", ["LongTermLoansPayableToSubsidiariesAndAffiliates"]),
        ("株主、役員又は従業員からの長期借入金", ["LongTermLoansPayableToShareholdersDirectorsOrEmployees"]),
        ("関係会社長期債務", ["LongTermDebtToSubsidiariesAndAffiliatesNCLELE",
                              "LongTermDebtToSubsidiariesAndAffiliatesNCLGAS"]),
        ("債権流動化に伴う長期支払債務", ["LongTermPayablesUnderFluidityLeaseReceivablesNCLLEA"]),
        ("有利子負債", ["InterestBearingLiabilitiesLiabilitiesIFRS"]),
        ("社債及び借入金", ["BondsAndBorrowingsLiabilitiesIFRS"]),
        ("借入金", ["BorrowingsLiabilitiesIFRS", "BorrowingsLiabilitiesINS"]),
        ("社債", ["BondsPayableLiabilitiesIFRS"]),
        ("リース負債", ["LeaseLiabilitiesLiabilitiesIFRS", "LeaseObligationsLiabilities"]),
    ]

    private static let tagToLabel: [String: String] = {
        var map: [String: String] = [:]
        for (label, tags) in componentDefs {
            for tag in tags { map[tag] = label }
        }
        return map
    }()

    static func extract(fieldSet: FieldSet, accountingStandard: String, xbrlDir: URL? = nil) -> IBDResult {
        // 銀行業: DepositsLiabilitiesBNK（預金）が存在すれば銀行業コンポーネント積み上げ（預金自体は含めない）
        if let bankResult = extractBankIBD(fieldSet: fieldSet, accountingStandard: accountingStandard) {
            return appendingNotesLeaseIfMissing(
                bankResult, xbrlDir: xbrlDir, accountingStandard: accountingStandard)
        }

        let resolved = resolveIBD(fieldSet)
        var result: IBDResult

        if let tag = resolved.tag {
            let components: [IBDComponentEntry] = tag.split(separator: "+").map { t in
                let tagName = String(t)
                let fv = fieldSet[tagName]
                return (label: tagToLabel[tagName] ?? tagName,
                        current: fv?.current, prior: fv?.prior)
            }
            result = IBDResult(
                total: resolved.current,
                priorTotal: resolved.prior,
                components: components,
                method: "field_parser",
                accountingStandard: accountingStandard
            )
        } else if accountingStandard == "IFRS",
                  let dir = xbrlDir,
                  let textblockResult = IFRSLease.extractIBDFromTextblock(xbrlDir: dir) {
            // IFRS Summary型XBRLでは連結借入金タグが存在しないため、TextBlockから抽出する
            result = textblockResult
        } else if let dir = xbrlDir,
                  let scheduleResult = BorrowingsSchedule.extract(xbrlDir: dir, accountingStandard: accountingStandard) {
            // 連結BSに有利子負債タグが無い企業（リース債務が明細表のみに記載される等）:
            // 連結附属明細表「借入金等明細表」から積み上げる。合計にはリース債務が含まれるため、
            // 後続のリース加算をスキップして即返す。
            // J-GAAP リース注記だけの置換はしない（オペレーティング・リースの未経過リース料
            // で有利子負債を発明していた）。IFRS 16 のリース注記はオンバランスのため明細表が
            // 無い会社（中外製薬 S100XTBJ）ではここで読む。
            return scheduleResult
        } else if let dir = xbrlDir, hasLargeXbrlFile(in: dir) {
            // インスタンス文書が十分大きいのにIBDタグが皆無 → 無借金企業とみなす
            result = IBDResult(total: 0.0, priorTotal: 0.0, components: [],
                               method: "zero_debt", accountingStandard: accountingStandard)
            if accountingStandard != "IFRS" { return result }
        } else {
            return IBDResult(total: nil, priorTotal: nil, components: [],
                             method: "not_found", accountingStandard: accountingStandard)
        }

        // 有利子負債の集約タグがリース込み（BS に別建てのリース行が無い）なら、注記のリースを
        // 足すと二重計上になる（トヨタ・RIZAP・HOYA 等）。軸と同じ BS 形状の判定で加算を止める。
        if isLeaseInclusiveAggregate(resolvedTag: resolved.tag, fieldSet: fieldSet) {
            return result
        }

        // IFRS適用企業: リース負債を追加（XBRLタグで既に取得済みの場合はスキップ）
        if accountingStandard == "IFRS" {
            let resolvedTags = Set((resolved.tag ?? "").split(separator: "+").map(String.init))
            if !resolvedTags.isDisjoint(with: IFRSLease.leaseXbrlTags) {
                return result
            }
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: fieldSet, xbrlDir: xbrlDir)
            if lease.current != nil || lease.prior != nil {
                result = IBDResult(
                    total: (result.total ?? 0) + (lease.current ?? 0),
                    priorTotal: (result.priorTotal ?? 0) + (lease.prior ?? 0),
                    components: result.components + lease.components,
                    method: result.method + "+lease_textblock",
                    accountingStandard: accountingStandard
                )
            }
        }

        // US-GAAP適用企業: オペレーティング・リース負債を追加（ASC 842）
        if accountingStandard == "US-GAAP" {
            let lease = extractUSGAAPLeaseLiabilities(fieldSet: fieldSet)
            if let leaseC = lease.current {
                result = IBDResult(
                    total: (result.total ?? 0) + leaseC,
                    priorTotal: lease.prior != nil
                        ? (result.priorTotal ?? 0) + lease.prior! : result.priorTotal,
                    components: result.components + lease.components,
                    method: result.method + "+lease_html",
                    accountingStandard: accountingStandard
                )
            }
        }

        return appendingNotesLeaseIfMissing(
            result, xbrlDir: xbrlDir, accountingStandard: accountingStandard)
    }

    /// 解決したタグがリース込みの集約か。「社債、借入金及びリース負債」集約、または
    /// 「有利子負債」集約で BS にリース負債タグの値が無い場合（`InterestBearingDebtBreakdown` と同じ規則）。
    static func isLeaseInclusiveAggregate(resolvedTag: String?, fieldSet: FieldSet) -> Bool {
        guard let resolvedTag else { return false }
        let tags = Set(resolvedTag.split(separator: "+").map(String.init))
        if tags.contains(where: { $0.hasPrefix("BondsBorrowingsAndLeaseLiabilities") }) { return true }
        guard !tags.isDisjoint(with: Xbrl.ibdInterestBearingAggregateTags) else { return false }
        let hasBSLease = Xbrl.leaseLiabilitiesBSTags.contains { tag in
            guard let fv = fieldSet[tag] else { return false }
            return fv.current != nil || fv.prior != nil
        }
        return !hasBSLease
    }

    /// financials 組立が読む IBD。statement の有利子負債項目 ＋ statement に無い notes リース。
    /// ingest 順に依存せず、同一 XBRL パスで statement を直接解決する（#10b / #8）。
    static func extractCanonical(xbrlDir: URL) -> IBDResult {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        let instantFS = statementInstantFieldSet(
            xbrlDir: xbrlDir, allTags: allTags, accountingStandard: std)
        return extract(fieldSet: instantFS, accountingStandard: std, xbrlDir: xbrlDir)
    }

    /// statement 側にリース科目が無いとき、notes のリース帳簿だけを足す。
    /// IFRS TextBlock / US-GAAP HTML で既に足している場合は components にリースがあるので何もしない。
    /// 明細表フォールバック（method=borrowings_schedule）は合計にリース込みのため呼ばない。
    private static func appendingNotesLeaseIfMissing(
        _ result: IBDResult, xbrlDir: URL?, accountingStandard: String
    ) -> IBDResult {
        guard let dir = xbrlDir else { return result }
        if result.components.contains(where: { $0.label.contains("リース") }) { return result }
        let lease = notesLeaseComponents(xbrlDir: dir, accountingStandard: accountingStandard)
        guard lease.current != nil || lease.prior != nil else { return result }
        return IBDResult(
            total: (result.total ?? 0) + (lease.current ?? 0),
            priorTotal: (result.priorTotal ?? 0) + (lease.prior ?? 0),
            components: result.components + lease.components,
            method: result.method + "+lease_notes",
            accountingStandard: result.accountingStandard
        )
    }

    /// IFRS は `lease_liabilities` が resolved のとき帳簿価額。J-GAAP / 銀行は借入金等明細表のリース区分行。
    private static func notesLeaseComponents(xbrlDir: URL, accountingStandard: String) -> (
        current: Double?, prior: Double?, components: [IBDComponentEntry]
    ) {
        if accountingStandard == "IFRS",
           case .resolved = StatementNotesResolver.resolveLeaseLiabilities(xbrlDir: xbrlDir)
        {
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir)
            if lease.current != nil || lease.prior != nil {
                return (lease.current, lease.prior, lease.components)
            }
        }
        guard let parsed = BorrowingsSchedule.extractRows(xbrlDir: xbrlDir) else {
            return (nil, nil, [])
        }
        var components: [IBDComponentEntry] = []
        var currentTotal = 0.0
        var priorTotal = 0.0
        var hasCurrent = false
        var hasPrior = false
        for row in parsed.rows {
            guard BorrowingsSchedule.isLeaseScheduleRow(row) else { continue }
            guard row.current != nil || row.prior != nil else { continue }
            if let c = row.current { currentTotal += c; hasCurrent = true }
            if let p = row.prior { priorTotal += p; hasPrior = true }
            components.append((label: row.label, current: row.current, prior: row.prior))
        }
        return (hasCurrent ? currentTotal : nil, hasPrior ? priorTotal : nil, components)
    }

    /// statement BS だけを許可した Instant FieldSet。US-GAAP は Statement HTML の借入・リース行。
    private static func statementInstantFieldSet(
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
        for comp in Xbrl.bankIBDComponents { tags.formUnion(comp.tags) }
        tags.insert(Xbrl.bankMarkerTag)
        return tags
    }()

    /// 貸借対照表に既知の有利子負債・リース負債科目があるか。
    /// 注記フォールバックが Statement を置き換えてよいかの判定に使う。
    static func statementHasInterestBearingDebtItems(xbrlDir: URL) -> Bool {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        let fieldSet = statementInstantFieldSet(
            xbrlDir: xbrlDir, allTags: allTags, accountingStandard: std)
        if resolveIBD(fieldSet).tag != nil { return true }
        return Xbrl.leaseLiabilitiesBSTags.contains { tag in
            guard let fv = fieldSet[tag] else { return false }
            return fv.current != nil || fv.prior != nil
        }
    }

    /// statement 本表の IBD 当期値で Instant FieldSet を上書きする。
    /// `extractCanonical` の fact 収集は `nilAsZero: false` のため、当期 `xsi:nil` は落ちる。
    /// statement 組立は既定 `nilAsZero: true` で同じ fact を 0 として載せる（借入金 0 円の
    /// 日東電工 6988 / S100YCAR）。prior だけ残ると resolveIBD が tag あり・current nil になり
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

    /// 解決順: IFRS集約タグ → コンポーネント積み上げ（流動性配列を含む） → US-GAAP HTML仮想タグ。
    private static func resolveIBD(_ fieldSet: FieldSet) -> ResolvedItem {
        let ifrsAgg = resolveAggregate(fieldSet, componentTagLists: [Xbrl.ibdIFRSCLTags, Xbrl.ibdIFRSNCLTags])
        if ifrsAgg.tag != nil { return ifrsAgg }

        let comp = resolveAggregate(fieldSet, componentTagLists: Xbrl.ibdCurrentComponents + Xbrl.ibdNonCurrentComponents
                + Xbrl.ibdLiquidityOrderComponents)
        if comp.tag != nil { return comp }

        return resolveAggregate(fieldSet, componentTagLists: [["USGAAP_HTML_IBDCurrent"], ["USGAAP_HTML_IBDNonCurrent"]])
    }

    /// US-GAAP BS HTMLから取得済みのオペレーティング・リース負債残高を返す（ASC 842）。
    private static func extractUSGAAPLeaseLiabilities(
        fieldSet: FieldSet
    ) -> (current: Double?, prior: Double?, components: [IBDComponentEntry]) {
        let clFV = resolveItem(fieldSet, tags: ["USGAAP_HTML_LeaseLiabilitiesCurrent"])
        let nclFV = resolveItem(fieldSet, tags: ["USGAAP_HTML_LeaseLiabilitiesNonCurrent"])
        guard clFV.current != nil || nclFV.current != nil else { return (nil, nil, []) }

        let totalC = (clFV.current ?? 0) + (nclFV.current ?? 0)
        let hasP = clFV.prior != nil || nclFV.prior != nil
        let totalP: Double? = hasP ? (clFV.prior ?? 0) + (nclFV.prior ?? 0) : nil
        var components: [IBDComponentEntry] = []
        if clFV.current != nil {
            components.append((label: "リース負債（流動）", current: clFV.current, prior: clFV.prior))
        }
        if nclFV.current != nil {
            components.append((label: "リース負債（非流動）", current: nclFV.current, prior: nclFV.prior))
        }
        return (totalC, totalP, components)
    }

    /// インスタンス文書に 100KB 超のファイルがあるか（zero_debt 判定）。
    private static func hasLargeXbrlFile(in dir: URL) -> Bool {
        XBRLUtils.findXbrlFiles(in: dir).contains { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size > Xbrl.zeroDebtMinInstanceBytes
        }
    }

    private static func extractBankIBD(fieldSet: FieldSet, accountingStandard: String) -> IBDResult? {
        let marker = resolveItem(fieldSet, tags: [Xbrl.bankMarkerTag])
        guard marker.current != nil || marker.prior != nil else { return nil }

        // 預金は有利子負債に含めない。預金がある期は、借用金・社債等が無ければ 0。
        var totalCurrent = 0.0
        var totalPrior = 0.0
        var hasCurrentAny = marker.current != nil
        var hasPriorAny = marker.prior != nil
        var components: [(label: String, current: Double?, prior: Double?)] = []

        for comp in Xbrl.bankIBDComponents {
            let item = resolveItem(fieldSet, tags: comp.tags)
            if let c = item.current { totalCurrent += c; hasCurrentAny = true }
            if let p = item.prior { totalPrior += p; hasPriorAny = true }
            if item.current != nil || item.prior != nil {
                components.append((label: comp.label, current: item.current, prior: item.prior))
            }
        }

        return IBDResult(
            total: hasCurrentAny ? totalCurrent : nil,
            priorTotal: hasPriorAny ? totalPrior : nil,
            components: components,
            method: "bank_components",
            accountingStandard: accountingStandard
        )
    }
}
