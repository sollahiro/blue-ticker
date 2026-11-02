// 業種特化 KPI（benchmark）の格納契約。BLT-216 / BLT-217。
// 1 行 = 1 社 × 1 書類 × 1 業種グループ。payload.facts が KPI 値。
// 1 社に複数グループを付けられる（sony の銀行＋エンタメ等）が、ステップ 1 は銀行だけ。
// 公開 REST / MCP / iOS には出さない。次ステップ（MD&A 表 + Jev）は同じ payload に
// source_kind=textblock_table の fact を足す。

import Foundation

/// Neon `industry_kpi_facts.cache_version`。銀行 XBRL 数値の意味を変えるときだけバンプする。
public let industryKpiCacheVersion = "industry-kpi-bank-v1"

/// 業種グループ。ステップ 1 は `bank` のみ。後で insurance / railway 等を足す。
public let industryKpiGroupBank = "bank"

public let industryKpiSourceXbrlFacts = "xbrl_facts"

public let industryKpiNotApplicableNotBank = "not_bank"

public let industryKpiKeyDeposits = "deposits"
public let industryKpiKeyNegotiableCDs = "negotiable_cds"
public let industryKpiKeyLoans = "loans"
public let industryKpiKeyNetInterestIncome = "net_interest_income"
public let industryKpiKeyTrustFees = "trust_fees"
public let industryKpiKeyNetFeesAndCommissions = "net_fees_and_commissions"
public let industryKpiKeyNetTradingIncome = "net_trading_income"
public let industryKpiKeyNetOtherBusinessIncome = "net_other_business_income"
public let industryKpiKeyOperatingExpenses = "operating_expenses"
public let industryKpiKeyGrossBusinessProfit = "gross_business_profit"
public let industryKpiKeyLDR = "ldr"
public let industryKpiKeyOHR = "ohr"

public let industryKpiPeriodBasisPeriodEnd = "period_end"
public let industryKpiPeriodBasisAverage = "average"
public let industryKpiPeriodBasisDuration = "duration"

public let industryKpiScopeConsolidated = "consolidated"
public let industryKpiScopeFiler = "filer"
public let industryKpiScopeNamedSubsidiary = "named_subsidiary"

public let industryKpiSourceKindXbrlFact = "xbrl_fact"
public let industryKpiSourceKindDerived = "derived"
public let industryKpiSourceKindTextblockTable = "textblock_table"
public let industryKpiSourceKindTextblockProse = "textblock_prose"

/// 書類 1 件・業種グループ 1 つの抽出結果。
public enum IndustryKpiResolveResult: Sendable {
    case resolved(payload: IndustryKpiSnapshotPayload, source: String, contentHash: String)
    case notApplicable(reason: String)
    case failed
}

/// 1 つの KPI 値。範囲・単位・期末/平均・出所を必ず持つ。
public struct IndustryKpiFactValue: Codable, Sendable, Equatable {
    public var kpiKey: String
    public var value: Double
    public var unit: String
    public var periodBasis: String
    public var scope: String
    /// `named_subsidiary` のとき子会社名。filer / consolidated は nil。
    public var entityName: String?
    public var sourceKind: String
    /// XBRL 要素のローカル名。derived は式（タグまたは kpi_key）。
    public var sourceRef: String
    /// 後続の部門軸（国内業務部門等）。ステップ 1 は nil。
    public var axis: String?
    /// 後続の内訳次元（業種コード等）。ステップ 1 は nil。
    public var dimension: String?

    public init(
        kpiKey: String, value: Double, unit: String, periodBasis: String, scope: String,
        entityName: String? = nil, sourceKind: String, sourceRef: String,
        axis: String? = nil, dimension: String? = nil
    ) {
        self.kpiKey = kpiKey
        self.value = value
        self.unit = unit
        self.periodBasis = periodBasis
        self.scope = scope
        self.entityName = entityName
        self.sourceKind = sourceKind
        self.sourceRef = sourceRef
        self.axis = axis
        self.dimension = dimension
    }

    private enum CodingKeys: String, CodingKey {
        case kpiKey = "kpi_key"
        case value, unit
        case periodBasis = "period_basis"
        case scope
        case entityName = "entity_name"
        case sourceKind = "source_kind"
        case sourceRef = "source_ref"
        case axis, dimension
    }
}

/// `industry_kpi_facts.payload`。次ステップは `facts` に平均残高・不良債権等を足す。
public struct IndustryKpiSnapshotPayload: Codable, Sendable, Equatable {
    public var industryGroup: String
    public var facts: [IndustryKpiFactValue]
    public var needsReview: Bool
    public var warnings: [String]

    public init(
        industryGroup: String, facts: [IndustryKpiFactValue],
        needsReview: Bool = false, warnings: [String] = []
    ) {
        self.industryGroup = industryGroup
        self.facts = facts
        self.needsReview = needsReview
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case industryGroup = "industry_group"
        case facts
        case needsReview = "needs_review"
        case warnings
    }

    public func fact(key: String, scope: String) -> IndustryKpiFactValue? {
        facts.first { $0.kpiKey == key && $0.scope == scope }
    }
}
