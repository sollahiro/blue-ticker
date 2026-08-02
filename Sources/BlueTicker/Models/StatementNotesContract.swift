// 財務諸表注記取り込み: 財務諸表注記（Statement Notes）の格納用 Codable 契約。
// docs/statement-normalization-concept.md「statement-notes（今後）」・plan（財務諸表注記取り込み実装計画）参照。
//
// company_breakdowns（Stage 6）と同型の設計: note_type ごとに1行（"\(docID)#\(noteType)" 合成キー）、
// 決定論経路は cache_version 世代でゲート、LLM 経由は needs_review + content_hash でのみ再計算する。
// company_statements（Stage 7 本体）とは別テーブル（バージョニング独立・課金境界をエンドポイント
// 単位で分離するため。docs/feature-tiers.md）。
//
// 政策保有株式（policyHoldingSecurities）は当初「LLM必須」と見込んでいたが、実データ検証
// （2026-08-02）の結果 EDINET標準タクソノミで銘柄ごとに完全構造化タグされていると判明したため、
// 現状 v1 は全 note_type が決定論経路（xbrl_facts）のみで、LLM経由は未使用（`PolicyHoldingSecurityPayload`
// はLLM正規化結果ではなく `StatementNotesResolver.resolvePolicyHoldingSecurities` の決定論抽出結果）。
//
// Foundation のみ依存（NIO/Vapor 非依存）。

import Foundation

/// company_statement_notes.note_type の公開定数（BltServerCore / REST / MCP / ingest で共用）。
/// v1 時点は全 note_type が決定論経路（xbrl_facts）。
public let statementNoteTypePerShareInformation = "per_share_information"
public let statementNoteTypeIssuedShares = "issued_shares"
public let statementNoteTypeResearchAndDevelopment = "research_and_development"
public let statementNoteTypeCapitalExpendituresOverview = "capital_expenditures_overview"
public let statementNoteTypeDividends = "dividends"
public let statementNoteTypeTreasuryStockAcquisition = "treasury_stock_acquisition"
public let statementNoteTypeSGABreakdown = "sga_breakdown"
public let statementNoteTypeBorrowingsScheduleCFSupplement = "borrowings_schedule_cf_supplement"
/// 決定論（EDINET標準タクソノミの銘柄別構造化タグ、`StatementNotesResolver.resolvePolicyHoldingSecurities`
/// 参照）。当初「LLM必須」と見込んでいたが実データ検証で構造化タグの存在が判明し方針転換した。
public let statementNoteTypePolicyHoldingSecurities = "policy_holding_securities"
public let statementNoteTypePropertyPlantEquipmentSchedule = "property_plant_equipment_schedule"
public let statementNoteTypeGoodwillAndIntangibles = "goodwill_and_intangibles"

/// note_type ごとの現行 cache_version（決定論経路のみが対象。`isVersionGatedStatementNoteType` 参照）。
/// blueTickerVersion とは独立し、当該 note_type の抽出ロジック変更時のみバンプする
/// （`.agents/rules/project/versioning.md` の cache_version 運用と同型）。
public let perShareInformationNoteCacheVersion = "notes-eps-v1"
public let issuedSharesNoteCacheVersion = "notes-issued-shares-v1"
public let researchAndDevelopmentNoteCacheVersion = "notes-rd-v1"
public let capitalExpendituresOverviewNoteCacheVersion = "notes-capex-overview-v1"
public let dividendsNoteCacheVersion = "notes-dividends-v1"
public let treasuryStockAcquisitionNoteCacheVersion = "notes-treasury-stock-v1"
public let sgaBreakdownNoteCacheVersion = "notes-sga-breakdown-v1"
public let borrowingsScheduleCFSupplementNoteCacheVersion = "notes-borrowings-schedule-v1"
public let policyHoldingSecuritiesNoteCacheVersion = "notes-policy-holding-securities-v1"
public let propertyPlantEquipmentScheduleNoteCacheVersion = "notes-ppe-schedule-v1"
public let goodwillAndIntangiblesNoteCacheVersion = "notes-goodwill-v1"

/// note_type に対応する現行 cache_version 文字列。未知の note_type は空文字（安全側で非 servable 扱い）。
public func statementNoteCacheVersion(forType noteType: String) -> String {
    switch noteType {
    case statementNoteTypePerShareInformation: return perShareInformationNoteCacheVersion
    case statementNoteTypeIssuedShares: return issuedSharesNoteCacheVersion
    case statementNoteTypeResearchAndDevelopment: return researchAndDevelopmentNoteCacheVersion
    case statementNoteTypeCapitalExpendituresOverview: return capitalExpendituresOverviewNoteCacheVersion
    case statementNoteTypeDividends: return dividendsNoteCacheVersion
    case statementNoteTypeTreasuryStockAcquisition: return treasuryStockAcquisitionNoteCacheVersion
    case statementNoteTypeSGABreakdown: return sgaBreakdownNoteCacheVersion
    case statementNoteTypeBorrowingsScheduleCFSupplement: return borrowingsScheduleCFSupplementNoteCacheVersion
    case statementNoteTypePolicyHoldingSecurities: return policyHoldingSecuritiesNoteCacheVersion
    case statementNoteTypePropertyPlantEquipmentSchedule: return propertyPlantEquipmentScheduleNoteCacheVersion
    case statementNoteTypeGoodwillAndIntangibles: return goodwillAndIntangiblesNoteCacheVersion
    default: return ""
    }
}

/// note_type ごとの read 床（`statementMinServableVersion` と同型、noteType 別に明示指定）。
/// v1 導入時点はすべて 1。
public func statementNoteMinServableVersion(forType noteType: String) -> Int { 1 }

/// `notes-xxx-vN` から世代番号 N を取り出す。プレフィックスは `statementNoteCacheVersion` の
/// 現行値と一致させる必要はなく、末尾の `-vN` だけを見る（note_type ごとに接頭辞が異なるため）。
/// パース不能なら nil（非 servable 扱い）。
public func statementNoteCacheVersionNumber(_ version: String) -> Int? {
    guard let dashVIndex = version.range(of: "-v", options: .backwards)?.upperBound else { return nil }
    let suffix = version[dashVIndex...]
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
    return n
}

/// 解決経路。決定論（"xbrl_facts"）は cache_version 世代でゲートする。LLM 経由（"llm"）と
/// 対象外（"not_applicable"）は content_hash + needs_review でのみ扱う
/// （`isVersionGatedStatementNoteType` 参照、company_breakdowns と同型）。
public let statementNoteSourceXbrlFacts = "xbrl_facts"
public let statementNoteSourceLLM = "llm"
public let statementNoteSourceNotApplicable = "not_applicable"

/// `.notApplicable` の理由（決定論経路で開示自体が無かった/タグが見つからなかった）。
public let statementNoteNotApplicableNotFound = "not_found"

/// xbrl_facts と同じく決定的ロジックで解決され、cache_version 世代で再計算・read 可否を
/// 判定すべき source かどうか。LLM 経由はここに含めない。
public func isVersionGatedStatementNoteSource(_ source: String) -> Bool {
    source == statementNoteSourceXbrlFacts || source == statementNoteSourceNotApplicable
}

/// 格納行が read 可能か。xbrl_facts / not_applicable（決定的）は cache_version が当該 note_type の
/// 床以上のときのみ。LLM 経由は存在すれば常に read 可能（据え置き運用、company_breakdowns と同型）。
public func isServableStatementNote(source: String, cacheVersion: String, noteType: String) -> Bool {
    guard isVersionGatedStatementNoteSource(source) else { return true }
    guard let n = statementNoteCacheVersionNumber(cacheVersion) else { return false }
    return n >= statementNoteMinServableVersion(forType: noteType)
}

/// 財務諸表注記取り込み ingest（書類1件・note_type1つ分）の計算結果。`BreakdownResolveResult`（Stage 6）と同型の
/// 3値パターン（`.agents/rules/project/error-handling.md`）。
public enum StatementNoteResolveResult: Sendable {
    case resolved(payload: StatementNotePayload, source: String, contentHash: String)
    case notApplicable(reason: String)
    case failed
}

/// company_statement_notes.payload の中身。note_type によって使うフィールドが変わる緩めの構造:
/// - スカラー値の note（EPS・発行済株式数・研究開発費合計・設備投資概要・配当金・自己株式取得）は
///   `value`/`unit` を使う
/// - 表形式の note（販管費内訳・PPE明細・のれん明細・借入金等明細表）は `items` を使う
///   （`StatementLineItem` を再利用し、Statement 本体と表現を揃える）
/// - 政策保有株式（決定論、銘柄別 XBRL タグ抽出）は `securities` を使う
public struct StatementNotePayload: Codable, Sendable {
    public var value: Double?
    public var unit: String?
    public var items: [StatementLineItem]?
    public var securities: [PolicyHoldingSecurityPayload]?
    public var dividendEvents: [DividendEventPayload]?
    public var needsReview: Bool
    public var warnings: [String]

    public init(
        value: Double? = nil, unit: String? = nil, items: [StatementLineItem]? = nil,
        securities: [PolicyHoldingSecurityPayload]? = nil,
        dividendEvents: [DividendEventPayload]? = nil, needsReview: Bool = false,
        warnings: [String] = []
    ) {
        self.value = value
        self.unit = unit
        self.items = items
        self.securities = securities
        self.dividendEvents = dividendEvents
        self.needsReview = needsReview
        self.warnings = warnings
    }

    /// REST/MCP 応答用 JSON オブジェクト。
    public func jsonObject() -> [String: Any] {
        [
            "value": value as Any? ?? NSNull(),
            "unit": unit as Any? ?? NSNull(),
            "items": items.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
            "securities": securities.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
            "dividend_events": dividendEvents.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
            "needs_review": needsReview,
            "warnings": warnings,
        ]
    }
}

/// 配当イベント1件分（決議単位、`dividends` note_type 専用）。中間・期末等の区分は
/// `resolutionBody`（決議機関、例: 「取締役会決議」「定時株主総会決議」）と `resolutionDate` から
/// 呼び出し側が判断する。実データ上、決議機関だけでは中間/期末を確定できない会社があるため
/// （臨時決議等）、本payloadでは推測した区分ラベルを持たず、開示された値のみを返す。
public struct DividendEventPayload: Codable, Sendable {
    public var resolutionDate: String?
    public var resolutionBody: String?
    public var dividendPerShare: Double?
    public var totalAmount: Double?

    public init(
        resolutionDate: String?, resolutionBody: String?, dividendPerShare: Double?,
        totalAmount: Double?
    ) {
        self.resolutionDate = resolutionDate
        self.resolutionBody = resolutionBody
        self.dividendPerShare = dividendPerShare
        self.totalAmount = totalAmount
    }

    public func jsonObject() -> [String: Any] {
        [
            "resolution_date": resolutionDate as Any? ?? NSNull(),
            "resolution_body": resolutionBody as Any? ?? NSNull(),
            "dividend_per_share": dividendPerShare as Any? ?? NSNull(),
            "total_amount": totalAmount as Any? ?? NSNull(),
        ]
    }
}

/// 政策保有株式1銘柄分（決定論抽出結果、`StatementNotesResolver.resolvePolicyHoldingSecurities` 参照）。
/// `policy_holding_securities` note_type 専用。
public struct PolicyHoldingSecurityPayload: Codable, Sendable {
    public var issuerName: String
    public var numberOfShares: Double?
    public var carryingAmount: Double?
    public var purpose: String?

    public init(issuerName: String, numberOfShares: Double?, carryingAmount: Double?, purpose: String?) {
        self.issuerName = issuerName
        self.numberOfShares = numberOfShares
        self.carryingAmount = carryingAmount
        self.purpose = purpose
    }

    public func jsonObject() -> [String: Any] {
        [
            "issuer_name": issuerName,
            "number_of_shares": numberOfShares as Any? ?? NSNull(),
            "carrying_amount": carryingAmount as Any? ?? NSNull(),
            "purpose": purpose as Any? ?? NSNull(),
        ]
    }
}
