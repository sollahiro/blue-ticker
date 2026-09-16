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
        ("コマーシャル・ペーパー", ["CommercialPapersLiabilities", "CommercialPapersCLIFRS"]),
        ("短期社債", ["ShortTermBondsPayable"]),
        ("1年内償還予定の社債", ["CurrentPortionOfBonds", "RedeemableBondsWithinOneYear",
                                 "BondsPayableCLIFRS", "CurrentPortionOfBondsCLIFRS"]),
        ("1年内返済予定の長期借入金", ["CurrentPortionOfLongTermLoansPayable",
                                      "CurrentPortionOfLongTermBorrowingsCLIFRS",
                                      "CurrentPortionOfLongTermDebtCLIFRS"]),
        ("リース負債（流動）", ["LeaseObligationsCL", "LeaseLiabilitiesCLIFRS"]),
        ("社債", ["BondsPayable", "BondsPayableNCLIFRS"]),
        ("長期借入金", ["LongTermLoansPayable", "BorrowingsNCLIFRS", "LongTermDebtNCLIFRS"]),
        ("リース負債（非流動）", ["LeaseObligationsNCL", "LeaseLiabilitiesNCLIFRS"]),
    ]

    private static let tagToLabel: [String: String] = {
        var map: [String: String] = [:]
        for (label, tags) in componentDefs {
            for tag in tags { map[tag] = label }
        }
        return map
    }()

    static func extract(fieldSet: FieldSet, accountingStandard: String, xbrlDir: URL? = nil) -> IBDResult {
        // 銀行業: DepositsLiabilitiesBNK が存在すれば銀行業コンポーネント積み上げ
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
            guard BorrowingsSchedule.isLeaseDebtScheduleRowLabel(row.label) else { continue }
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
        var tags = Set(Xbrl.ibdDirectTags)
        tags.formUnion(Xbrl.ibdIFRSCLTags)
        tags.formUnion(Xbrl.ibdIFRSNCLTags)
        tags.formUnion(Xbrl.leaseLiabilitiesBSTags)
        for group in Xbrl.ibdCurrentComponents { tags.formUnion(group) }
        for group in Xbrl.ibdNonCurrentComponents { tags.formUnion(group) }
        for comp in Xbrl.bankIBDComponents { tags.formUnion(comp.tags) }
        return tags
    }()

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

    /// 解決順: 直接法 → IFRS集約タグ → コンポーネント積み上げ → US-GAAP HTML仮想タグ。
    private static func resolveIBD(_ fieldSet: FieldSet) -> ResolvedItem {
        let direct = resolveItem(fieldSet, tags: Xbrl.ibdDirectTags)
        if direct.tag != nil { return direct }

        let ifrsAgg = resolveAggregate(fieldSet, componentTagLists: [Xbrl.ibdIFRSCLTags, Xbrl.ibdIFRSNCLTags])
        if ifrsAgg.tag != nil { return ifrsAgg }

        let comp = resolveAggregate(fieldSet, componentTagLists: Xbrl.ibdCurrentComponents + Xbrl.ibdNonCurrentComponents)
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
        let marker = resolveItem(fieldSet, tags: ["DepositsLiabilitiesBNK"])
        guard marker.current != nil || marker.prior != nil else { return nil }

        var totalCurrent = 0.0
        var totalPrior = 0.0
        var hasCurrentAny = false
        var hasPriorAny = false
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
