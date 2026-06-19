// 財務指標モデル
// Python の TypedDict(total=False) → Swift の struct + Optional フィールド

struct IBDComponent: Codable {
    var label: String?
    var current: Double?
    var prior: Double?
}

struct BalanceSheetComponent: Codable {
    var label: String?
    var current: Double?
    var prior: Double?
}

struct PPEComponent: Codable {
    var label: String?
    var value: Double?
}

struct MetricSource: Codable {
    var source: String?
    var method: String?
    var docID: String?
    var unit: String?
    var label: String?
    var statement: String?
    var confidence: Double?
}

struct StockSplitEvent: Codable {
    var ratio: Double?
    var effectiveDate: String?
    var scope: String?
    var alreadyReflected: Bool?
    var appliesTo: String?
    var dividendBasis: String?
    var sourceStatement: String?
    var contextExcerpt: String?

    enum CodingKeys: String, CodingKey {
        case ratio, scope
        case effectiveDate    = "effective_date"
        case alreadyReflected = "already_reflected"
        case appliesTo        = "applies_to"
        case dividendBasis    = "dividend_basis"
        case sourceStatement  = "source_statement"
        case contextExcerpt   = "context_excerpt"
    }
}

// MARK: - RawData

struct RawData: Codable {
    var curPerType: String?
    var curFYSt: String?
    var curFYEn: String?
    var discDate: String?
    var salesLabel: String?
    var sales: Double?
    var op: Double?
    var np: Double?
    var netAssets: Double?
    var cfo: Double?
    var cfi: Double?
    var capex: Double?
    var buyback: Double?
    var rd: Double?
    var eps: Double?
    var bps: Double?
    var shOutFY: Double?
    var averageShares: Double?
    var treasuryShares: Double?
    var sharesForBPS: Double?
    var parentEquity: Double?
    var stockSplitRatio: Double?
    var cumulativeStockSplitRatio: Double?
    var stockSplitEvents: [StockSplitEvent]?
    var calculatedEPS: Double?
    var calculatedBPS: Double?
    var epsDirectDiff: Double?
    var bpsDirectDiff: Double?
    var divTotalAnn: Double?
    var payoutRatioAnn: Double?
    var cashEq: Double?
    var div2Q: Double?
    var divAnn: Double?

    enum CodingKeys: String, CodingKey {
        case curPerType = "CurPerType"; case curFYSt = "CurFYSt"; case curFYEn = "CurFYEn"
        case discDate = "DiscDate"; case salesLabel = "SalesLabel"; case sales = "Sales"
        case op = "OP"; case np = "NP"; case netAssets = "NetAssets"
        case cfo = "CFO"; case cfi = "CFI"; case capex = "Capex"; case buyback = "Buyback"
        case rd = "RD"; case eps = "EPS"; case bps = "BPS"; case shOutFY = "ShOutFY"
        case averageShares = "AverageShares"; case treasuryShares = "TreasuryShares"
        case sharesForBPS = "SharesForBPS"; case parentEquity = "ParentEquity"
        case stockSplitRatio = "StockSplitRatio"
        case cumulativeStockSplitRatio = "CumulativeStockSplitRatio"
        case stockSplitEvents = "StockSplitEvents"
        case calculatedEPS = "CalculatedEPS"; case calculatedBPS = "CalculatedBPS"
        case epsDirectDiff = "EPSDirectDiff"; case bpsDirectDiff = "BPSDirectDiff"
        case divTotalAnn = "DivTotalAnn"; case payoutRatioAnn = "PayoutRatioAnn"
        case cashEq = "CashEq"; case div2Q = "Div2Q"; case divAnn = "DivAnn"
    }
}

// MARK: - CalculatedData

struct CalculatedData: Codable {
    // 収益性
    var payoutRatio: Double?
    var cfc: Double?
    var roe: Double?
    var cfcvr: Double?
    // 粗利
    var grossProfit: Double?
    var grossProfitMargin: Double?
    var grossProfitMethod: String?
    var grossProfitLabel: String?
    // 有利子負債
    var interestBearingDebt: Double?
    var ibdComponents: [IBDComponent]?
    var ibdAccountingStandard: String?
    var roic: Double?
    // ネットキャッシュ
    var netCash: Double?
    var netDE: Double?
    // 貸借対照表
    var totalAssets: Double?
    var currentAssets: Double?
    var nonCurrentAssets: Double?
    var currentLiabilities: Double?
    var nonCurrentLiabilities: Double?
    var netAssets: Double?
    var balanceSheetComponents: [BalanceSheetComponent]?
    var balanceSheetAccountingStandard: String?
    // 損益
    var interestExpense: Double?
    var pretaxIncome: Double?
    var incomeTax: Double?
    var effectiveTaxRate: Double?
    var nopat: Double?
    var operatingMargin: Double?
    var opLabel: String?
    // SGA・営業利益分解
    var sellingGeneralAdministrativeExpenses: Double?
    var businessProfit: Double?
    var businessProfitMargin: Double?
    var businessProfitChange: Double?
    var salesChangeImpact: Double?
    var grossMarginChangeImpact: Double?
    var sgaChangeImpact: Double?
    // 従業員・受注
    var employees: Int?
    var orderIntake: Double?
    var orderBacklog: Double?
    // 有形固定資産
    var ppeTotal: Double?
    var ppeAccountingStandard: String?
    // 書類ID
    var docID: String?
    var amendmentDocID: String?
    // ROIC ウォーターフォール
    var nopatMargin: Double?
    var investedCapitalTurnover: Double?
    var roicDelta: Double?
    var roicMarginEffect: Double?
    var roicTurnoverEffect: Double?
    // ROE ウォーターフォール
    var netMargin: Double?
    var assetTurnover: Double?
    var financialLeverage: Double?
    var roeDelta: Double?
    var roeNetMarginEffect: Double?
    var roeAssetTurnoverEffect: Double?
    var roeLeverageEffect: Double?
    // CF自己株式・配当
    var cfTreasuryStock: Double?
    var dividendSS: Double?
    var dividendPaidCF: Double?
    // BS運転資本
    var accountsReceivable: Double?
    var inventory: Double?
    var accountsPayable: Double?
    // 運転資本・CCC
    var workingCapital: Double?
    var dso: Double?
    var dio: Double?
    var dpo: Double?
    var ccc: Double?

    enum CodingKeys: String, CodingKey {
        case payoutRatio = "PayoutRatio"; case cfc = "CFC"; case roe = "ROE"; case cfcvr = "CFCVR"
        case grossProfit = "GrossProfit"; case grossProfitMargin = "GrossProfitMargin"
        case grossProfitMethod = "GrossProfitMethod"; case grossProfitLabel = "GrossProfitLabel"
        case interestBearingDebt = "InterestBearingDebt"; case ibdComponents = "IBDComponents"
        case ibdAccountingStandard = "IBDAccountingStandard"; case roic = "ROIC"
        case netCash = "NetCash"; case netDE = "NetDE"
        case totalAssets = "TotalAssets"; case currentAssets = "CurrentAssets"
        case nonCurrentAssets = "NonCurrentAssets"; case currentLiabilities = "CurrentLiabilities"
        case nonCurrentLiabilities = "NonCurrentLiabilities"; case netAssets = "NetAssets"
        case balanceSheetComponents = "BalanceSheetComponents"
        case balanceSheetAccountingStandard = "BalanceSheetAccountingStandard"
        case interestExpense = "InterestExpense"
        case pretaxIncome = "PretaxIncome"; case incomeTax = "IncomeTax"
        case effectiveTaxRate = "EffectiveTaxRate"; case nopat = "NOPAT"
        case operatingMargin = "OperatingMargin"; case opLabel = "OPLabel"
        case sellingGeneralAdministrativeExpenses = "SellingGeneralAdministrativeExpenses"
        case businessProfit = "BusinessProfit"; case businessProfitMargin = "BusinessProfitMargin"
        case businessProfitChange = "BusinessProfitChange"
        case salesChangeImpact = "SalesChangeImpact"
        case grossMarginChangeImpact = "GrossMarginChangeImpact"
        case sgaChangeImpact = "SGAChangeImpact"
        case employees = "Employees"; case orderIntake = "OrderIntake"; case orderBacklog = "OrderBacklog"
        case ppeTotal = "PPETotal"; case ppeAccountingStandard = "PPEAccountingStandard"
        case docID = "DocID"; case amendmentDocID = "AmendmentDocID"
        case nopatMargin = "NOPATMargin"; case investedCapitalTurnover = "InvestedCapitalTurnover"
        case roicDelta = "ROICDelta"; case roicMarginEffect = "ROICMarginEffect"
        case roicTurnoverEffect = "ROICTurnoverEffect"
        case netMargin = "NetMargin"; case assetTurnover = "AssetTurnover"
        case financialLeverage = "FinancialLeverage"
        case roeDelta = "ROEDelta"; case roeNetMarginEffect = "ROENetMarginEffect"
        case roeAssetTurnoverEffect = "ROEAssetTurnoverEffect"
        case roeLeverageEffect = "ROELeverageEffect"
        case cfTreasuryStock = "CFTreasuryStock"
        case dividendSS = "DividendSS"; case dividendPaidCF = "DividendPaidCF"
        case accountsReceivable = "AccountsReceivable"
        case inventory = "Inventory"; case accountsPayable = "AccountsPayable"
        case workingCapital = "WorkingCapital"
        case dso = "DSO"; case dio = "DIO"; case dpo = "DPO"; case ccc = "CCC"
    }
}

// MARK: - YearEntry / MetricsResult

struct YearEntry: Codable {
    var fyEnd: String?
    var financialPeriod: String
    var rawData: RawData
    var calculatedData: CalculatedData

    enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case financialPeriod = "FinancialPeriod"
        case rawData = "RawData"
        case calculatedData = "CalculatedData"
    }
}

struct MetricsResult: Codable {
    var code: String?
    var latestFyEnd: String?
    var analysisYears: Int?
    var availableYears: Int?
    var years: [YearEntry]?
    var dataAvailability: String?
    var dataAvailabilityMessage: String?
    var dataValid: Bool?
    var validationMessage: String?

    enum CodingKeys: String, CodingKey {
        case code; case latestFyEnd = "latest_fy_end"
        case analysisYears = "analysis_years"; case availableYears = "available_years"
        case years; case dataAvailability = "data_availability"
        case dataAvailabilityMessage = "data_availability_message"
        case dataValid = "data_valid"; case validationMessage = "validation_message"
    }
}
