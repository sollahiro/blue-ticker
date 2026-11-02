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

    private static let netComponents: [NetComponent] = [
        .init(
            kpiKey: industryKpiKeyNetInterestIncome,
            incomeTags: ["InterestIncomeOIBNK"],
            expenseTags: ["InterestExpensesOEBNK"]),
        .init(
            kpiKey: industryKpiKeyNetFeesAndCommissions,
            incomeTags: ["FeesAndCommissionsOIBNK"],
            expenseTags: ["FeesAndCommissionsPaymentsOEBNK"]),
        .init(
            kpiKey: industryKpiKeyNetTradingIncome,
            incomeTags: ["TradingIncomeOIBNK"],
            expenseTags: ["TradingExpensesOEBNK"]),
        .init(
            kpiKey: industryKpiKeyNetOtherBusinessIncome,
            incomeTags: ["OtherOrdinaryIncomeOIBNK"],
            expenseTags: ["OtherOrdinaryExpensesOEBNK"]),
    ]

    static func resolve(xbrlDir: URL, edinetIndustry: String? = nil) -> IndustryKpiResolveResult {
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        guard !tagElements.isEmpty else { return .failed }
        return resolve(tagElements: tagElements, edinetIndustry: edinetIndustry)
    }

    static func resolve(
        tagElements: XbrlTagElements, edinetIndustry: String? = nil
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

        var facts: [IndustryKpiFactValue] = []
        facts.append(contentsOf: factsForScope(
            instant: consInstant, duration: consDuration, scope: industryKpiScopeConsolidated))
        facts.append(contentsOf: factsForScope(
            instant: filerInstant, duration: filerDuration, scope: industryKpiScopeFiler))
        guard !facts.isEmpty else {
            return .notApplicable(reason: industryKpiNotApplicableNotBank)
        }

        let payload = IndustryKpiSnapshotPayload(
            industryGroup: industryKpiGroupBank, facts: facts)
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

        for net in netComponents {
            appendNet(&facts, fieldSet: duration, component: net, scope: scope)
        }
        appendSigned(
            &facts, fieldSet: duration, tags: ["TrustFeesBNK"],
            kpiKey: industryKpiKeyTrustFees, scope: scope, sign: 1)
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
    private static func appendLDR(_ facts: inout [IndustryKpiFactValue], scope: String) {
        guard let loans = factValue(facts, industryKpiKeyLoans, scope),
            let deposits = factValue(facts, industryKpiKeyDeposits, scope)
        else { return }
        let ncd = factValue(facts, industryKpiKeyNegotiableCDs, scope) ?? 0
        let denominator = deposits + ncd
        guard denominator != 0 else { return }
        let ncdRef = facts.first {
            $0.kpiKey == industryKpiKeyNegotiableCDs && $0.scope == scope
        }?.sourceRef ?? Xbrl.bankNegotiableCDTags[0]
        let loansRef = facts.first { $0.kpiKey == industryKpiKeyLoans && $0.scope == scope }?.sourceRef
            ?? Xbrl.bankLoansTags[0]
        let depositsRef = facts.first { $0.kpiKey == industryKpiKeyDeposits && $0.scope == scope }?
            .sourceRef ?? Xbrl.bankDepositsTags[0]
        facts.append(
            IndustryKpiFactValue(
                kpiKey: industryKpiKeyLDR, value: loans / denominator * Financial.percent,
                unit: AmountUnit.Code.percent.rawValue,
                periodBasis: industryKpiPeriodBasisPeriodEnd, scope: scope,
                sourceKind: industryKpiSourceKindDerived,
                sourceRef: "\(loansRef)/(\(depositsRef)+\(ncdRef))"))
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
