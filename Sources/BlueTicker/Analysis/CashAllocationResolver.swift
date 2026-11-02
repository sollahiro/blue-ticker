// 資金配分（waterfall の現金増減ブリッジ）の材料。正本は statement の CF 本表行。
//
// フリーCF（cfo + cfi）→ 有利子負債の増減 → 親会社株主への配当 → その他の財務CF →
// 換算差額 → その他 → 現金増減。財務CFの各行は次の順で区分する（`docs/financials-summary-separation.md`）。
// 1. 標準タグの一覧（債務・リース → debt、親会社株主への配当 → dividend_parent、それ以外の既知 → other）
// 2. 会社拡張タグはラベルの決まり（借入金・社債・CP・リース負債 → debt など）
// 3. それでも決まらない行だけ Jev に区分を選ばせる（金額は返させない。0.9 未満・不一致は fail closed）
// 財務CFの内訳は、区分した行の和が財務CF合計に（行ごとの丸めの範囲で）一致したときだけ出す。
// 営業・投資・財務の3区分の外にある行は、換算差額を除いて「その他」（`other_cash_change`）にまとめる。

import Foundation

/// 財務CFの1行の区分。
enum CashFlowFinancingRole: String, CaseIterable, Sendable {
    /// 借入金・社債・CP・リース負債の調達と返済（有利子負債の増減。BS の interest_bearing_debt 軸と同じくリース込み）。
    case debt
    /// 親会社株主への配当金の支払。
    case dividendParent = "dividend_parent"
    /// それ以外（自己株式・非支配持分への配当・子会社株式の取引・利息の支払・その他）。
    case other
}

/// 区分を決める財務CF行（Jev に渡す候補）。値は判定に使わない。
struct CashFlowFinancingRowCandidate: Equatable, Sendable {
    var key: String
    var tag: String
    var label: String
    var value: Double
    var order: Int
}

struct CashFlowFinancingRowChoice: Equatable, Sendable {
    var selected: String?
    var probability: Double?
    var probabilities: [String: Double] = [:]
    var options: [String] = []
    var model: String = ""
}

protocol CashFlowFinancingRowDeciding: Sendable {
    func classifyFinancingRow(
        row: CashFlowFinancingRowCandidate,
        financingRows: [CashFlowFinancingRowCandidate],
        docID: String
    ) async -> CashFlowFinancingRowChoice
}

/// 資金配分の材料（円・CF の符号。収入が正、支出が負）。
struct CashAllocationValues: Equatable, Sendable {
    /// 財務活動によるキャッシュ・フロー（合計行）。
    var cff: Double?
    /// 有利子負債の増減（debt 行の和）。
    var debtChange: Double?
    /// 親会社株主への配当（dividend_parent 行の和。支払は負）。
    var dividendsParent: Double?
    /// その他の財務CF（財務CF − 有利子負債の増減 − 配当）。
    var otherFinancing: Double?
    /// 現金及び現金同等物に係る換算差額。行が無い書類は 0。
    var fxEffect: Double?
    /// 現金及び現金同等物の増減（CF 本表の期末残高 − 期首残高）。
    var cashChange: Double?
    /// 3区分と換算差額のどれにも入らない現金の動き（連結範囲の変更・売却目的資産への振替など）。
    var otherCashChange: Double?
    /// Jev で区分した行があるときの非公開監査。
    var jevAudit: SegmentNoteJevAuditPayload? = nil
}

enum CashAllocationResolver {
    static let question = "cash_flow_financing_row"
    static let axis = "cash_allocation"
    /// 区分した行の和と財務CF合計の許容差（円、1行あたり）。百万円単位の本表は行ごとに丸めるので、
    /// 行の和は合計と行数 × 1百万円まで食い違う（大成建設 1801・キリン 2502 で 1〜3百万円）。
    static let financingSumTolerancePerRowYen = Financial.millionYen
    /// 1書類で Jev に回す行の上限。超えたら呼ばずに fail closed。
    static let maxJevRows = 8
    static let jevPolicy = JevDecisionPolicy(
        kind: .classify,
        question: question,
        noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    struct FinancingRow: Sendable {
        var item: StatementLineItem
        var order: Int
        /// 決定論で決まった区分。nil は Jev 行き。
        var role: CashFlowFinancingRole?
    }

    struct Prepared: Sendable {
        var cff: Double?
        var rows: [FinancingRow]
        var fxEffect: Double?
        var cashChange: Double?
        var cfo: Double?
        var cfi: Double?
    }

    // MARK: - 決定論

    /// CF 本表を読み、財務CF行の決定論の区分と、3区分の外の値を組む。
    static func prepare(
        cashFlow: [StatementLineItem], cfo: Double?, cfi: Double?
    ) -> Prepared {
        let ordered = cashFlow.enumerated().map { index, item in (item: item, order: item.order ?? index) }
        let financing = ordered.filter { $0.item.section == .financing }
        let cff = financing.first(where: { financingTotalTags.contains($0.item.tag) })?.item.value
            ?? financing.first(where: { isFinancingTotalLabel($0.item.label) })?.item.value
            ?? ordered.first(where: { financingTotalTags.contains($0.item.tag) })?.item.value
        let rows = financing
            .filter { !$0.item.isTotal && !financingTotalTags.contains($0.item.tag)
                && !isFinancingTotalLabel($0.item.label) }
            .map { FinancingRow(item: $0.item, order: $0.order, role: classify($0.item)) }

        let outside = ordered.filter { row in
            guard let section = row.item.section else { return true }
            return section != .operating && section != .investing && section != .financing
        }
        let fxRows = outside.filter { isFxEffect($0.item) }
        let fx: Double? = fxRows.isEmpty ? 0 : fxRows.reduce(0) { $0 + $1.item.value }
        let beginning = outside.first(where: { isCashBalance($0.item, marker: "期首") })?.item.value
        let ending = outside.last(where: { isCashBalance($0.item, marker: "期末") })?.item.value
        let cashChange: Double? = {
            guard let beginning, let ending else { return nil }
            return ending - beginning
        }()
        return Prepared(
            cff: cff, rows: rows, fxEffect: fx, cashChange: cashChange, cfo: cfo, cfi: cfi)
    }

    /// 標準タグ → ラベルの決まり。決まらなければ nil（Jev 行き）。
    static func classify(_ item: StatementLineItem) -> CashFlowFinancingRole? {
        if debtTags.contains(item.tag) { return .debt }
        if dividendParentTags.contains(item.tag) { return .dividendParent }
        if otherTags.contains(item.tag) { return .other }
        return classify(label: item.label ?? "")
    }

    /// 会社拡張タグのラベルの決まり。債務の語と債務以外の語が両方当たる行・曖昧な行は nil。
    static func classify(label raw: String) -> CashFlowFinancingRole? {
        let label = normalize(raw)
        guard !label.isEmpty else { return nil }
        if otherExactLabels.contains(label) { return .other }
        let ambiguous = ambiguousKeywords.contains { label.contains($0) }
        let debt = debtKeywords.contains { label.contains($0) }
        if debt {
            // 「新株予約権付社債」は社債。それ以外で債務の語と資本取引・デリバティブの語が重なる行は Jev。
            let withoutConvertible = label.replacingOccurrences(of: "新株予約権付社債", with: "社債")
            let otherHit = otherKeywords.contains { withoutConvertible.contains($0) }
            return (ambiguous || otherHit) ? nil : .debt
        }
        if ambiguous { return nil }
        if label.contains("配当") || label.contains("分配") {
            return dividendToOthersKeywords.contains { label.contains($0) } ? .other : .dividendParent
        }
        if otherKeywords.contains(where: { label.contains($0) }) { return .other }
        return nil
    }

    /// 区分が揃った行から値を組む。未区分の行が残る・和が財務CF合計に合わないときは内訳を出さない。
    static func values(
        from prepared: Prepared, roles: [CashFlowFinancingRole?], isBank: Bool
    ) -> CashAllocationValues {
        var out = CashAllocationValues(
            cff: prepared.cff, fxEffect: prepared.fxEffect, cashChange: prepared.cashChange)
        if let cash = prepared.cashChange, let cfo = prepared.cfo, let cfi = prepared.cfi,
           let cff = prepared.cff, let fx = prepared.fxEffect {
            out.otherCashChange = cash - cfo - cfi - cff - fx
        }
        // 銀行は預金を有利子負債に含めない（net_cash / debt_change_impact と同じく出さない）。
        guard !isBank, let cff = prepared.cff, roles.count == prepared.rows.count,
              roles.allSatisfy({ $0 != nil })
        else { return out }
        var debt = 0.0
        var dividends = 0.0
        var other = 0.0
        for (row, role) in zip(prepared.rows, roles) {
            switch role {
            case .debt: debt += row.item.value
            case .dividendParent: dividends += row.item.value
            case .other, .none: other += row.item.value
            }
        }
        let tolerance = Double(max(prepared.rows.count, 1)) * financingSumTolerancePerRowYen
        guard abs(debt + dividends + other - cff) <= tolerance else { return out }
        out.debtChange = debt
        out.dividendsParent = dividends
        out.otherFinancing = cff - debt - dividends
        return out
    }

    /// 決定論だけで組む（Jev なし）。未区分の行があれば内訳は nil。
    static func resolve(
        cashFlow: [StatementLineItem], cfo: Double?, cfi: Double?, isBank: Bool
    ) -> CashAllocationValues {
        let prepared = prepare(cashFlow: cashFlow, cfo: cfo, cfi: cfi)
        return values(from: prepared, roles: prepared.rows.map(\.role), isBank: isBank)
    }

    // MARK: - Jev

    /// 決定論で決まらない行だけ Jev に区分を選ばせる。キーが無いときは決定論のまま（内訳は nil）。
    static func resolve(
        cashFlow: [StatementLineItem], cfo: Double?, cfi: Double?, isBank: Bool,
        decider: (any CashFlowFinancingRowDeciding)?, docID: String
    ) async -> CashAllocationValues {
        let prepared = prepare(cashFlow: cashFlow, cfo: cfo, cfi: cfi)
        var roles = prepared.rows.map(\.role)
        let pending = roles.indices.filter { roles[$0] == nil }
        guard !isBank, !pending.isEmpty, let decider else {
            return values(from: prepared, roles: roles, isBank: isBank)
        }
        let candidates = prepared.rows.enumerated().map { index, row in
            CashFlowFinancingRowCandidate(
                key: "r\(index)", tag: row.item.tag,
                label: row.item.label ?? row.item.tag, value: row.item.value, order: row.order)
        }
        var sentences = ["cash_allocation_jev_rows=\(pending.count)"]
        var calls: [SegmentNoteJevCallPayload] = []
        var model = ""
        guard pending.count <= maxJevRows else {
            sentences.append("cash_allocation_jev=too_many_rows")
            var out = values(from: prepared, roles: roles, isBank: isBank)
            out.jevAudit = audit(docID: docID, model: model, applied: false, sentences: sentences, calls: calls)
            return out
        }
        let options = CashFlowFinancingRole.allCases.map(\.rawValue)
        for index in pending {
            let candidate = candidates[index]
            let samples = await JevDecisionSampler.collect(count: jevPolicy.sampling.sampleCount) {
                await decider.classifyFinancingRow(
                    row: candidate, financingRows: candidates, docID: docID)
            }
            let result = JevDecision.evaluate(
                policy: jevPolicy,
                samples: samples.map {
                    JevChoiceAggregate.Sample(
                        selected: $0.selected, probability: $0.probability,
                        probabilities: $0.probabilities, options: $0.options, model: $0.model)
                },
                options: options,
                sentences: ["row=\(candidate.key) tag=\(candidate.tag) label=\(candidate.label)"])
            calls += result.calls
            if model.isEmpty { model = result.aggregate.model }
            if let key = result.selectedKey, let role = CashFlowFinancingRole(rawValue: key) {
                roles[index] = role
                sentences.append("\(candidate.key)=\(role.rawValue)")
            } else {
                sentences.append("\(candidate.key)=fail_closed")
            }
        }
        var out = values(from: prepared, roles: roles, isBank: isBank)
        let applied = out.debtChange != nil
        if !applied { sentences.append("cash_allocation_jev=fail_closed") }
        out.jevAudit = audit(docID: docID, model: model, applied: applied, sentences: sentences, calls: calls)
        return out
    }

    private static func audit(
        docID: String, model: String, applied: Bool, sentences: [String],
        calls: [SegmentNoteJevCallPayload]
    ) -> SegmentNoteJevAuditPayload {
        SegmentNoteJevAuditPayload(
            code: "", docID: docID, axis: axis,
            model: model.isEmpty ? Api.openrouterDecisionsModel : model,
            threshold: jevPolicy.auditThreshold,
            applied: applied, needsReview: !applied, sentences: sentences, calls: calls,
            withheldReason: applied ? nil : (sentences.last ?? "cash_allocation_jev=fail_closed"),
            decisionSource: applied ? "jev_cash_flow_financing_row" : nil)
    }

    // MARK: - 行の判定

    private static func normalize(_ label: String) -> String {
        label.filter { !$0.isWhitespace }
    }

    private static func isFinancingTotalLabel(_ label: String?) -> Bool {
        let text = normalize(label ?? "")
        return text.contains("財務活動によるキャッシュ・フロー") || text.contains("財務活動によるキャッシュフロー")
    }

    private static func isFxEffect(_ item: StatementLineItem) -> Bool {
        if fxTags.contains(item.tag) { return true }
        let text = normalize(item.label ?? "")
        return text.contains("現金") && (text.contains("換算差額") || text.contains("為替変動")
            || text.contains("為替相場"))
    }

    private static func isCashBalance(_ item: StatementLineItem, marker: String) -> Bool {
        let text = normalize(item.label ?? "")
        return text.contains("現金") && text.contains(marker) && text.contains("残高")
    }

    static let financingTotalTags: Set<String> = [
        "NetCashProvidedByUsedInFinancingActivities",
        "NetCashProvidedByUsedInFinancingActivitiesIFRS",
        "CashFlowsFromUsedInFinancingActivitiesIFRS",
        "CashFlowsUsedInFinancingActivitiesIFRS",
    ]

    static let fxTags: Set<String> = [
        "EffectOfExchangeRateChangeOnCashAndCashEquivalents",
        "EffectOfExchangeRateChangesOnCashAndCashEquivalentsIFRS",
    ]

    /// 標準タクソノミ（jppfs / jpigp）の債務・リースの調達と返済。
    static let debtTags: Set<String> = [
        // 日本基準
        "NetIncreaseDecreaseInShortTermLoansPayableFinCF",
        "IncreaseDecreaseInShortTermLoansPayableFinCF",
        "IncreaseInShortTermLoansPayableFinCF",
        "DecreaseInShortTermLoansPayableFinCF",
        "ProceedsFromLongTermLoansPayableFinCF",
        "RepaymentOfLongTermLoansPayableFinCF",
        "ProceedsFromLoansPayableFinCF",
        "RepaymentsOfLoansPayableFinCF",
        "ProceedsFromIssuanceOfBondsFinCF",
        "RedemptionOfBondsFinCF",
        "RepaymentOfBondsFinCF",
        "ProceedsFromIssuanceOfShortTermBondsFinCF",
        "RedemptionOfShortTermBondsFinCF",
        "NetIncreaseDecreaseInShortTermBondsPayableFinCF",
        "NetIncreaseDecreaseInCommercialPapersFinCF",
        "IncreaseDecreaseInCommercialPapersFinCF",
        "ProceedsFromIssuanceOfCommercialPapersFinCF",
        "RedemptionOfCommercialPapersFinCF",
        "IncreaseDecreaseInShortTermBankLoansAndCommercialPapersFinCF",
        "RepaymentsOfLeaseObligationsFinCF",
        "RepaymentsOfFinanceLeaseObligationsFinCF",
        "RedemptionOfConvertibleBondTypeBondsWithShareAcquisitionRightsFinCF",
        "ProceedsFromLongTermNonRecourseLoansPayableFinCF",
        "RepaymentOfLongTermNonRecourseLoansPayableFinCF",
        "ProceedsFromIssuanceOfNonRecourceBondsFinCF",
        // IFRS
        "NetIncreaseDecreaseInShortTermBorrowingsFinCFIFRS",
        "ProceedsFromShortTermBorrowingsFinCFIFRS",
        "RepaymentsOfShortTermBorrowingsFinCFIFRS",
        "ProceedsFromLongTermBorrowingsFinCFIFRS",
        "RepaymentsOfLongTermBorrowingsFinCFIFRS",
        "ProceedsFromBorrowingsFinCFIFRS",
        "RepaymentsOfBorrowingsFinCFIFRS",
        "ProceedsFromIssuanceOfBondsFinCFIFRS",
        "RedemptionOfBondsFinCFIFRS",
        "ProceedsFromIssuanceOfBondsAndLongTermBorrowingsFinCFIFRS",
        "RedemptionOfBondsAndRepaymentsOfLongTermBorrowingsFinCFIFRS",
        "ProceedsFromIssuanceOfBondsAndBorrowingsFinCFIFRS",
        "RedemptionOfBondsAndRepaymentsOfBorrowingsFinCFIFRS",
        "PaymentsForRepaymentsOfLoansAndRedemptionOfBondsFinCFIFRS",
        "PaymentForRedemptionOfBondsWithSubscriptionRightsToSharesFinCFIFRS",
        "NetIncreaseDecreaseInCommercialPaperFinCFIFRS",
        "NetIncreaseDecreaseInCommercialPapersFinCFIFRS",
        "IncreaseDecreaseInCommercialPaperFinCFIFRS",
        "ProceedsFromIssuanceOfCommercialPaperFinCFIFRS",
        "RedemptionOfCommercialPaperFinCFIFRS",
        "NetIncreaseDecreaseInShortTermBorrowingsAndCommercialPaperFinCFIFRS",
        "IncreaseDecreaseInShortTermBorrowingsAndCommercialPaperFinCFIFRS",
        "IncreaseDecreaseInShortTermBorrowingsAndCommercialPapersFinCFIFRS",
        "RepaymentsOfLeaseObligationsFinCFIFRS",
        "LeaseLiabilitiesPaidFinCFIFRS",
        "IncreaseDecreaseInShortTermDebtFinCFIFRS",
        "NetIncreaseDecreaseInShortTermDebtFinCFIFRS",
        "ChangeInShortTermDebtFinCFIFRS",
        "ProceedsFromLongTermDebtFinCFIFRS",
        "PaymentsOfLongTermDebtFinCFIFRS",
        "RepaymentsOfLongTermDebtFinCFIFRS",
        "RepaymentOfLongTermDebtFinCFIFRS",
        "ProceedsFromIssuanceOfLongTermDebtFinCFIFRS",
        "ProceedsFromIncreasesInLongTermDebtFinCFIFRS",
        "PaymentsOnLongTermDebtFinCFIFRS",
        "ProceedsFromInterestBearingDebtFinCFIFRS",
        "RepaymentOfInterestBearingDebtFinCFIFRS",
        "ProceedsInShortTermInterestBearingDebtNetFinCFIFRS",
    ]

    /// 親会社株主への配当（`Xbrl.dividendPaidCF*Tags` と同じ）。
    static let dividendParentTags: Set<String> = Set(
        Xbrl.dividendPaidCFJGAAPTags + Xbrl.dividendPaidCFIFRSTags)

    /// 債務でも親会社株主への配当でもない既知の標準タグ。
    static let otherTags: Set<String> = [
        "OtherNetFinCF", "OtherFinCFIFRS", "OtherNetFinCFINS", "OtherPaymentsFinCF",
        "PurchaseOfTreasuryStockFinCF", "ProceedsFromSalesOfTreasuryStockFinCF",
        "ProceedsFromDisposalOfTreasuryStockFinCF", "DecreaseIncreaseInTreasuryStockFinCF",
        "NetDecreaseIncreaseInTreasuryStockFinCF",
        "PaymentsForPurchaseOfTreasurySharesFinCFIFRS", "ProceedsFromSaleOfTreasurySharesFinCFIFRS",
        "NetDecreaseIncreaseInTreasurySharesFinCFIFRS", "PurchasesAndSalesOfTreasuryStockNetFinCFIFRS",
        "ReissuanceRepurchaseOfTreasuryStockFinCFIFRS", "ProceedsFromDisposalOfTreasurySharesFinCFIFRS",
        "ProceedsFromDispositionOfTreasuryStockFinCFIFRS",
        "PurchaseOfTreasuryStockOfSubsidiariesInConsolidationFinCF",
        "PurchaseOfTreasuryStockOfSubsidiariesInConsolidationFinCFIFRS",
        "DividendsPaidToNonControllingInterestsFinCF", "DividendsPaidToNonControllingInterestsFinCFIFRS",
        "ProceedsFromShareIssuanceToNonControllingShareholdersFinCF",
        "CapitalContributionFromNonControllingInterestsFinCFIFRS",
        "RepaymentsToNonControllingShareholdersFinCF", "RepaymentsToNonControllingInterestsFinCFIFRS",
        "PaymentsFromChangesInOwnershipInterestsInSubsidiariesThatDoNotResultInChangeInScopeOfConsolidationFinCF",
        "ProceedsFromChangesInOwnershipInterestsInSubsidiariesThatDoNotResultInChangeInScopeOfConsolidationFinCF",
        "PaymentsForAcquisitionOfInterestsInSubsidiariesFromNonControllingInterestsFinCFIFRS",
        "ProceedsFromChangesInOwnershipInterestsInSubsidiariesThatDoNotResultInLossOfControlFinCFIFRS",
        "ProceedsFromIssuanceOfCommonStockFinCF", "ProceedsFromIssuanceOfSharesFinCFIFRS",
        "ProceedsFromExerciseOfEmployeeShareOptionsFinCFIFRS",
        "ProceedsFromIssuanceOfSubscriptionRightsToSharesFinCF",
        "InterestPaidFinCFIFRS", "CommissionFeePaidFinCF",
        "DistributionToOwnersOfOtherEquityInstrumentsFinCFIFRS",
        "ProceedsFromIssuanceOfOtherEquityInstrumentsFinCFIFRS",
    ]

    /// 債務の語。会社拡張タグのラベルに使う（BS の interest_bearing_debt 軸のラベル規則と同じ語）。
    static let debtKeywords: [String] = [
        "借入", "社債", "コマーシャル・ペーパー", "コマーシャルペーパー", "有利子負債",
        "長期債務", "短期債務", "借入債務", "リース負債", "リース債務",
    ]

    /// 債務と決めきれない語（事業ごとの借入、債権流動化、割賦・未払金、預り金、その他の金融負債）。Jev 行き。
    static let ambiguousKeywords: [String] = [
        "事業の", "債権流動化", "割賦", "未払金", "預り金", "金融負債", "リースバック", "資金調達",
    ]

    /// 資本取引・デリバティブ・利息など、債務ではない財務CFの語。
    static let otherKeywords: [String] = [
        "自己株式", "新株予約権", "株式の発行", "株式の取得", "株式の売却", "払込", "出資",
        "非支配", "少数株主", "子会社株式", "子会社持分", "減資", "利息", "手数料",
        "デリバティブ", "スワップ", "先渡",
    ]

    /// 配当・分配のうち親会社株主以外への支払。
    static let dividendToOthersKeywords: [String] = [
        "非支配", "少数株主", "外部投資家", "その他の資本性", "子会社",
    ]

    static let otherExactLabels: Set<String> = [
        "その他", "その他、純額", "その他（純額）", "その他の支出", "その他の収入", "その他の財務活動",
    ]
}

struct OpenRouterCashFlowFinancingRowDecider: CashFlowFinancingRowDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func classifyFinancingRow(
        row: CashFlowFinancingRowCandidate,
        financingRows: [CashFlowFinancingRowCandidate],
        docID: String
    ) async -> CashFlowFinancingRowChoice {
        let options = CashFlowFinancingRole.allCases.map(\.rawValue)
        let unavailable = CashFlowFinancingRowChoice(
            selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(
            model: model, row: row, financingRows: financingRows, docID: docID)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: CashAllocationResolver.jevPolicy.transportRetries,
            onFailure: "CashAllocationResolver: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[
            CashAllocationResolver.question]?.choice
        else { return unavailable }
        return CashFlowFinancingRowChoice(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities,
            options: options,
            model: model)
    }

    static func requestJSON(
        model: String,
        row: CashFlowFinancingRowCandidate,
        financingRows: [CashFlowFinancingRowCandidate],
        docID: String
    ) -> Data? {
        let candidates = [
            JevPresentedCandidate(
                key: CashFlowFinancingRole.debt.rawValue,
                criterion: """
                    Raising or repaying interest-bearing debt of the group: loans (借入金), bonds \
                    (社債, including convertible bonds 新株予約権付社債), commercial paper, lease \
                    liabilities (リース負債・リース債務), and other borrowings that bear interest.
                    """),
            JevPresentedCandidate(
                key: CashFlowFinancingRole.dividendParent.rawValue,
                criterion: """
                    Dividends paid to the shareholders (owners) of the parent company. Not \
                    dividends to non-controlling interests and not distributions to fund investors.
                    """),
            JevPresentedCandidate(
                key: CashFlowFinancingRole.other.rawValue,
                criterion: """
                    Anything else: treasury stock, share issuance, transactions with \
                    non-controlling interests, dividends to non-controlling interests, interest \
                    paid, derivatives, fees, deposits that do not bear interest, and "その他".
                    """),
        ]
        let state: [String: Any] = [
            "doc_id": docID,
            "row": [
                "key": row.key, "tag": row.tag, "label": row.label, "order": row.order,
            ],
            "financing_rows": financingRows.map { other -> [String: Any] in
                ["key": other.key, "tag": other.tag, "label": other.label, "order": other.order]
            },
        ]
        let instructions = """
            The state lists the rows of the financing-activities section (財務活動によるキャッシュ・フロー) \
            of a consolidated cash-flow statement in a Japanese annual securities report \
            (有価証券報告書, doc \(docID)). Classify the single row in `row` into one role by its \
            label and tag, using the other rows only as context. Do not read or return amounts.
            """
        return JevDecisionRequest.json(
            model: model, question: CashAllocationResolver.question,
            instructions: instructions, candidates: candidates, state: state)
    }
}
