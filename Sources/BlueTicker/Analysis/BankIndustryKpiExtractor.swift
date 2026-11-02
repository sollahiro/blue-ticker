// 銀行業種 KPI ステップ 1: jppfs BNK 数値 fact（期末預金・譲渡性預金・貸出金、
// 連結粗利益の構成要素、営業経費）と預貸率・OHR。Jev / 表抽出はしない。
//
// 次ステップ（MD&A 表 + Jev）は同じ `IndustryKpiSnapshotPayload.facts` に
// period_basis=average / source_kind=textblock_table の行を足す。

import Foundation

enum BankIndustryKpiExtractor {

    private struct NetComponent {
        let kpiKey: String
        let incomeTags: [String]
        let expenseTags: [String]
    }

    static func resolve(xbrlDir: URL, edinetIndustry: String? = nil) -> IndustryKpiResolveResult {
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        guard !tagElements.isEmpty else { return .failed }
        return resolve(
            tagElements: tagElements, edinetIndustry: edinetIndustry,
            hasConsolidatedStatements: BorrowingsSchedule.filerHasConsolidatedStatements(
                xbrlDir: xbrlDir))
    }

    /// `hasConsolidatedStatements` は DEI（`BorrowingsSchedule.filerHasConsolidatedStatements`）。
    /// `nil` は tagElements 単体テスト用で、未指定コンテキストを連結として扱う。
    static func resolve(
        tagElements: XbrlTagElements, edinetIndustry: String? = nil,
        hasConsolidatedStatements: Bool? = nil
    ) -> IndustryKpiResolveResult {
        let consInstant = fieldSetFromConsolidatedInstant(tagElements)
        let consDuration = fieldSetFromConsolidatedDuration(tagElements)
        let filerInstant = fieldSetFromNonConsolidatedInstant(tagElements)
        let filerDuration = fieldSetFromNonConsolidatedDuration(tagElements)
        guard Xbrl.isBankFiling(consInstant, edinetIndustry: edinetIndustry)
            || Xbrl.isBankFiling(filerInstant, edinetIndustry: edinetIndustry)
        else {
            return .notApplicable(reason: industryKpiNotApplicableNotBank)
        }

        let hasConsolidated = hasConsolidatedStatements ?? true
        var facts: [IndustryKpiFactValue] = []
        if hasConsolidated {
            facts.append(contentsOf: factsForScope(
                instant: consInstant, duration: consDuration, scope: industryKpiScopeConsolidated))
            facts.append(contentsOf: factsForScope(
                instant: filerInstant, duration: filerDuration, scope: industryKpiScopeFiler))
        } else {
            // 連結を作らない銀行は、ふつうメンバー無しのコンテキストに単体の値を付ける。
            // ただし NonConsolidatedMember 付きで付ける書類もある（豊和銀行 8559）。
            // メンバー無しで何も取れなければ NonConsolidatedMember へ切り替える。
            let unmarked = factsForScope(
                instant: consInstant, duration: consDuration, scope: industryKpiScopeFiler)
            facts.append(contentsOf: unmarked.isEmpty
                ? factsForScope(
                    instant: filerInstant, duration: filerDuration, scope: industryKpiScopeFiler)
                : unmarked)
        }
        guard !facts.isEmpty else { return .failed }

        let (needsReview, warnings) = payloadFlags(facts)
        let payload = IndustryKpiSnapshotPayload(
            industryGroup: industryKpiGroupBank, facts: facts,
            needsReview: needsReview, warnings: warnings)
        return .resolved(
            payload: payload, source: industryKpiSourceXbrlFacts,
            contentHash: contentHash(facts))
    }

    private static func factsForScope(
        instant: FieldSet, duration: FieldSet, scope: String
    ) -> [IndustryKpiFactValue] {
        var facts: [IndustryKpiFactValue] = []
        appendBalance(
            &facts, fieldSet: instant, tags: Xbrl.bankDepositsTags,
            kpiKey: industryKpiKeyDeposits, scope: scope)
        appendBalance(
            &facts, fieldSet: instant, tags: Xbrl.bankNegotiableCDTags,
            kpiKey: industryKpiKeyNegotiableCDs, scope: scope)
        appendBalance(
            &facts, fieldSet: instant, tags: Xbrl.bankLoansTags,
            kpiKey: industryKpiKeyLoans, scope: scope)

        appendGrossProfitComponents(&facts, fieldSet: duration, scope: scope)
        appendSigned(
            &facts, fieldSet: duration, tags: Xbrl.bankOperatingExpensesTags,
            kpiKey: industryKpiKeyOperatingExpenses, scope: scope, sign: 1)

        if let gp = BankBusinessGrossProfit.signedTotal(from: duration).current {
            let gpRef = Xbrl.businessGrossProfitComponents.map { comp in
                "\(comp.sign < 0 ? "-" : "")\(comp.tags[0])"
            }.joined(separator: "+")
            facts.append(
                IndustryKpiFactValue(
                    kpiKey: industryKpiKeyGrossBusinessProfit, value: gp,
                    unit: AmountUnit.Code.currencyAmount.rawValue,
                    periodBasis: industryKpiPeriodBasisDuration, scope: scope,
                    sourceKind: industryKpiSourceKindDerived, sourceRef: gpRef))
        }

        appendLDR(&facts, scope: scope)
        appendOHR(&facts, scope: scope)
        return facts
    }

    /// `Xbrl.businessGrossProfitComponents` を +1/−1 の対は純額、単独は符号付きで出す。
    private static func appendGrossProfitComponents(
        _ facts: inout [IndustryKpiFactValue], fieldSet: FieldSet, scope: String
    ) {
        let comps = Xbrl.businessGrossProfitComponents
        var i = 0
        while i < comps.count {
            let current = comps[i]
            if current.sign > 0, i + 1 < comps.count, comps[i + 1].sign < 0 {
                if let kpiKey = netKpiKey(forIncomeTags: current.tags) {
                    appendNet(
                        &facts, fieldSet: fieldSet,
                        component: NetComponent(
                            kpiKey: kpiKey, incomeTags: current.tags,
                            expenseTags: comps[i + 1].tags),
                        scope: scope)
                }
                i += 2
            } else {
                if let kpiKey = singletonKpiKey(forTags: current.tags) {
                    appendSigned(
                        &facts, fieldSet: fieldSet, tags: current.tags,
                        kpiKey: kpiKey, scope: scope, sign: current.sign)
                }
                i += 1
            }
        }
    }

    private static func netKpiKey(forIncomeTags tags: [String]) -> String? {
        switch tags.first {
        case "InterestIncomeOIBNK": return industryKpiKeyNetInterestIncome
        case "FeesAndCommissionsOIBNK": return industryKpiKeyNetFeesAndCommissions
        case "TradingIncomeOIBNK": return industryKpiKeyNetTradingIncome
        case "OtherOrdinaryIncomeOIBNK": return industryKpiKeyNetOtherBusinessIncome
        default: return nil
        }
    }

    private static func singletonKpiKey(forTags tags: [String]) -> String? {
        tags.first == "TrustFeesBNK" ? industryKpiKeyTrustFees : nil
    }

    private static func appendBalance(
        _ facts: inout [IndustryKpiFactValue], fieldSet: FieldSet, tags: [String],
        kpiKey: String, scope: String
    ) {
        let item = resolveItem(fieldSet, tags: tags)
        guard let tag = item.tag, let value = item.current else { return }
        facts.append(
            IndustryKpiFactValue(
                kpiKey: kpiKey, value: value,
                unit: AmountUnit.Code.currencyAmount.rawValue,
                periodBasis: industryKpiPeriodBasisPeriodEnd, scope: scope,
                sourceKind: industryKpiSourceKindXbrlFact, sourceRef: tag))
    }

    private static func appendSigned(
        _ facts: inout [IndustryKpiFactValue], fieldSet: FieldSet, tags: [String],
        kpiKey: String, scope: String, sign: Int
    ) {
        let item = resolveItem(fieldSet, tags: tags)
        guard let tag = item.tag, let raw = item.current else { return }
        facts.append(
            IndustryKpiFactValue(
                kpiKey: kpiKey, value: Double(sign) * raw,
                unit: AmountUnit.Code.currencyAmount.rawValue,
                periodBasis: industryKpiPeriodBasisDuration, scope: scope,
                sourceKind: industryKpiSourceKindXbrlFact, sourceRef: tag))
    }

    private static func appendNet(
        _ facts: inout [IndustryKpiFactValue], fieldSet: FieldSet, component: NetComponent,
        scope: String
    ) {
        let income = resolveItem(fieldSet, tags: component.incomeTags)
        let expense = resolveItem(fieldSet, tags: component.expenseTags)
        guard income.current != nil || expense.current != nil else { return }
        let value = (income.current ?? 0) - (expense.current ?? 0)
        var refs: [String] = []
        if let tag = income.tag { refs.append(tag) }
        if let tag = expense.tag { refs.append("-\(tag)") }
        facts.append(
            IndustryKpiFactValue(
                kpiKey: component.kpiKey, value: value,
                unit: AmountUnit.Code.currencyAmount.rawValue,
                periodBasis: industryKpiPeriodBasisDuration, scope: scope,
                sourceKind: industryKpiSourceKindDerived, sourceRef: refs.joined()))
    }

    /// 預貸率 = 貸出金 ÷ (預金 + 譲渡性預金) × 100。
    /// 譲渡性預金タグが無いときは分母に 0 を足す（残高 0。預金・貸出金が無いときは作らない）。
    /// 欠測の NCD タグは sourceRef に載せない。
    private static func appendLDR(_ facts: inout [IndustryKpiFactValue], scope: String) {
        guard let loans = factValue(facts, industryKpiKeyLoans, scope),
            let deposits = factValue(facts, industryKpiKeyDeposits, scope)
        else { return }
        let ncdFact = facts.first {
            $0.kpiKey == industryKpiKeyNegotiableCDs && $0.scope == scope
        }
        let ncd = ncdFact?.value ?? 0
        let denominator = deposits + ncd
        guard denominator != 0 else { return }
        let loansRef = facts.first { $0.kpiKey == industryKpiKeyLoans && $0.scope == scope }?.sourceRef
            ?? Xbrl.bankLoansTags[0]
        let depositsRef = facts.first { $0.kpiKey == industryKpiKeyDeposits && $0.scope == scope }?
            .sourceRef ?? Xbrl.bankDepositsTags[0]
        let sourceRef: String
        if let ncdRef = ncdFact?.sourceRef {
            sourceRef = "\(loansRef)/(\(depositsRef)+\(ncdRef))"
        } else {
            sourceRef = "\(loansRef)/(\(depositsRef))"
        }
        facts.append(
            IndustryKpiFactValue(
                kpiKey: industryKpiKeyLDR, value: loans / denominator * Financial.percent,
                unit: AmountUnit.Code.percent.rawValue,
                periodBasis: industryKpiPeriodBasisPeriodEnd, scope: scope,
                sourceKind: industryKpiSourceKindDerived, sourceRef: sourceRef))
    }

    /// OHR = 営業経費 ÷ 連結粗利益 × 100。どちらか欠ければ作らない。
    private static func appendOHR(_ facts: inout [IndustryKpiFactValue], scope: String) {
        guard let opex = factValue(facts, industryKpiKeyOperatingExpenses, scope),
            let gp = factValue(facts, industryKpiKeyGrossBusinessProfit, scope), gp != 0
        else { return }
        let opexRef = facts.first {
            $0.kpiKey == industryKpiKeyOperatingExpenses && $0.scope == scope
        }?.sourceRef ?? Xbrl.bankOperatingExpensesTags[0]
        facts.append(
            IndustryKpiFactValue(
                kpiKey: industryKpiKeyOHR, value: opex / gp * Financial.percent,
                unit: AmountUnit.Code.percent.rawValue,
                periodBasis: industryKpiPeriodBasisDuration, scope: scope,
                sourceKind: industryKpiSourceKindDerived,
                sourceRef: "\(opexRef)/\(industryKpiKeyGrossBusinessProfit)"))
    }

    private static func payloadFlags(
        _ facts: [IndustryKpiFactValue]
    ) -> (needsReview: Bool, warnings: [String]) {
        var warnings: [String] = []
        let reviewScope: String?
        if facts.contains(where: { $0.scope == industryKpiScopeConsolidated }) {
            reviewScope = industryKpiScopeConsolidated
        } else if facts.contains(where: { $0.scope == industryKpiScopeFiler }) {
            reviewScope = industryKpiScopeFiler
        } else {
            reviewScope = nil
        }
        if let scope = reviewScope {
            if factValue(facts, industryKpiKeyLDR, scope) == nil {
                warnings.append(industryKpiWarningLDRUncomputed)
            }
            if factValue(facts, industryKpiKeyOHR, scope) == nil {
                warnings.append(industryKpiWarningOHRUncomputed)
            }
        }
        let ldrScopes = Set(
            facts.filter { $0.kpiKey == industryKpiKeyLDR }.map(\.scope))
        let ncdScopes = Set(
            facts.filter { $0.kpiKey == industryKpiKeyNegotiableCDs }.map(\.scope))
        if ldrScopes.contains(where: { !ncdScopes.contains($0) }) {
            warnings.append(industryKpiWarningNcdAbsentAssumedZero)
        }
        let needsReview =
            warnings.contains(industryKpiWarningLDRUncomputed)
            || warnings.contains(industryKpiWarningOHRUncomputed)
        return (needsReview, warnings)
    }

    private static func factValue(
        _ facts: [IndustryKpiFactValue], _ key: String, _ scope: String
    ) -> Double? {
        facts.first { $0.kpiKey == key && $0.scope == scope }?.value
    }

    private static func contentHash(_ facts: [IndustryKpiFactValue]) -> String {
        facts.map { "\($0.kpiKey)|\($0.scope)|\($0.value)|\($0.sourceRef)" }
            .sorted()
            .joined(separator: ";")
    }
}
