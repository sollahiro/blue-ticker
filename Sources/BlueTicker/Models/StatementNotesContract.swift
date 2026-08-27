// 財務諸表注記取り込み: 財務諸表注記（Statement Notes）の格納用 Codable 契約。
// docs/statement.md · plan（財務諸表注記取り込み実装計画）参照。
//
// company_breakdowns（内訳取り込み）と同型の設計: note_type ごとに1行（"\(docID)#\(noteType)" 合成キー）、
// 決定論経路は cache_version 世代でゲート、LLM 経由は needs_review + content_hash でのみ再計算する。
// company_statements（Statement取り込み 本体）とは別テーブル（バージョニング独立。
// 提供面は docs/feature-tiers.md）。
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
public let statementNoteTypeIssuedSharesAndCapital = "issued_shares_and_capital"
public let statementNoteTypeDividends = "dividends"
public let statementNoteTypeBorrowingsSchedule = "borrowings_schedule"
/// 決定論（EDINET標準タクソノミの銘柄別構造化タグ、`StatementNotesResolver.resolvePolicyHoldingSecurities`
/// 参照）。当初「LLM必須」と見込んでいたが実データ検証で構造化タグの存在が判明し方針転換した。
public let statementNoteTypePolicyHoldingSecurities = "policy_holding_securities"
public let statementNoteTypePropertyPlantEquipmentSchedule = "property_plant_equipment_schedule"
public let statementNoteTypeGoodwillAndIntangibles = "goodwill_and_intangibles"
/// リース負債（連結）。IFRS リース注記 TextBlock（`IFRSLease`）から決定論で抽出する。
/// BS 構造化タグは `available_via_statement`、借入金等明細表のリース債務は `available_via_notes`。
/// 使用権資産の増減表は対象外。
public let statementNoteTypeLeaseLiabilities = "lease_liabilities"
/// 販売費及び一般管理費の主要な費目内訳（連結損益計算書関係注記）。決定論（構造化 `*SGA` /
/// IFRS 販管費注記タグ）。発生支出の `research_and_development` breakdown とは別物。
/// US-GAAP は `us_gaap_unsupported`。銀行など連結に費目タグが無い場合は `not_found`
/// （個別注記のみの開示は拾わない）。
/// **未公開・未配線**（BLT-46）: `allStatementNoteTypes` / ingest / job-03 / ApiSkills に載せない。
/// resolver・cache_version・smoke/golden は実装済み。公開時に一覧へ戻す。
public let statementNoteTypeSgaExpenseBreakdown = "sga_expense_breakdown"

/// ingest / `--note-types` バリデーション用の公開 note_type 一覧（`FactsIngest` の走査順）。
/// `sga_expense_breakdown` は未公開のため含めない。
public let allStatementNoteTypes: [String] = [
    statementNoteTypePerShareInformation,
    statementNoteTypeIssuedSharesAndCapital,
    statementNoteTypeDividends,
    statementNoteTypeBorrowingsSchedule,
    statementNoteTypePropertyPlantEquipmentSchedule,
    statementNoteTypeGoodwillAndIntangibles,
    statementNoteTypeLeaseLiabilities,
    statementNoteTypePolicyHoldingSecurities,
]

/// 既知の note_type かどうか（`allStatementNoteTypes` と一致）。
public func isKnownStatementNoteType(_ noteType: String) -> Bool {
    allStatementNoteTypes.contains(noteType)
}

/// note_type ごとの現行 cache_version（決定論経路のみが対象。`isVersionGatedStatementNoteType` 参照）。
/// blueTickerVersion とは独立し、当該 note_type の抽出ロジック変更時のみバンプする
/// （`.agents/rules/project/versioning.md` の cache_version 運用と同型）。
/// v2: EPS 抽出。v3（2026-08-19）: IFRS の `JPYPerShares` BPS を日本基準
/// `NetAssetsPerShare` より優先（IFRS 移行年度の比較表残存、スズキ S100W4MT）。
public let perShareInformationNoteCacheVersion = "notes-eps-v3"
public let issuedSharesAndCapitalNoteCacheVersion = "notes-issued-shares-and-capital-v1"
public let dividendsNoteCacheVersion = "notes-dividends-v1"
/// v2（2026-08-05）: 抽出ロジック・payload構造を大幅改修（IFRS/J-GAAP多数のフォールバック経路追加、
/// J-GAAP附属明細表のスケール判定・インデント処理バグ修正、日経225全224銘柄の実データレビュー完了）。
/// v3（2026-08-12）: US-GAAP 連結を巨大注記 HTML（注記9の社債・借入金／長期債務表）から抽出。
public let borrowingsScheduleNoteCacheVersion = "notes-borrowings-schedule-v3"
/// v2（2026-08-11）: みなし保有株式（`isDeemedHolding`）・`policyHoldingSummary`（銘柄数及び貸借対照表
/// 計上額の合計額）を追加する payload 構造変更。本番は v1 時点で0件ingest済みのため実害はないが、
/// 将来の再発防止として抽出ロジック変更に揃えてバンプする。
public let policyHoldingSecuritiesNoteCacheVersion = "notes-policy-holding-securities-v2"
/// v2（2026-08-16）: `available_via_statement` を会計基準一括ではなく BS 区分タグ当期値あり判定に変更
/// （`lease_liabilities` と同型。区分タグ無し J-GAAP は `not_found`）。
public let propertyPlantEquipmentScheduleNoteCacheVersion = "notes-ppe-schedule-v2"
public let goodwillAndIntangiblesNoteCacheVersion = "notes-goodwill-v1"
/// v2（2026-08-12）: スズキ・クボタ型 TextBlock の満期バケット（割引前契約CF）を表単位で追加。
/// v3（2026-08-12）: BS 構造化タグ経路を廃止（`statement` と同一値のため `available_via_statement`）。
/// v4（2026-08-12）: クボタ型「割引前のリース負債総額」/ スズキ型「契約上のキャッシュ・フロー」を追加。
/// v5（2026-08-12）: クボタ型「控除：利息相当額」を追加。
/// v6（2026-08-16）: 借入金等明細表にリース債務があるとき `available_via_notes`。US-GAAP は
/// `us_gaap_unsupported`（statement の構造化タグ判定不可のため一括 `available_via_statement` を廃止）。
/// v7（2026-08-16）: `available_via_notes` を HTML「リース」部分一致から区分行ラベル
/// （`BorrowingsSchedule.hasLeaseDebtRowLabel`）判定へ変更。
public let leaseLiabilitiesNoteCacheVersion = "notes-lease-liabilities-v7"
/// v1（2026-08-27）: 連結の販管費費目（`*SGA` / IFRS 販管・一般管理費注記タグ）。
/// 発生支出タグは除外。US-GAAP 非対応。
/// v2（2026-08-27）: 日本語ラベル（タクソノミ優先、無ければ注記 HTML 行ラベル）。
/// v3（2026-08-27）: セグメント情報の `AmortizationOfGoodwillSGA`（のれんの償却額）を除外。
public let sgaExpenseBreakdownNoteCacheVersion = "notes-sga-expense-breakdown-v3"

/// note_type に対応する現行 cache_version 文字列。未知の note_type は空文字（安全側で非 servable 扱い）。
public func statementNoteCacheVersion(forType noteType: String) -> String {
    switch noteType {
    case statementNoteTypePerShareInformation: return perShareInformationNoteCacheVersion
    case statementNoteTypeIssuedSharesAndCapital: return issuedSharesAndCapitalNoteCacheVersion
    case statementNoteTypeDividends: return dividendsNoteCacheVersion
    case statementNoteTypeBorrowingsSchedule: return borrowingsScheduleNoteCacheVersion
    case statementNoteTypePolicyHoldingSecurities: return policyHoldingSecuritiesNoteCacheVersion
    case statementNoteTypePropertyPlantEquipmentSchedule: return propertyPlantEquipmentScheduleNoteCacheVersion
    case statementNoteTypeGoodwillAndIntangibles: return goodwillAndIntangiblesNoteCacheVersion
    case statementNoteTypeLeaseLiabilities: return leaseLiabilitiesNoteCacheVersion
    case statementNoteTypeSgaExpenseBreakdown: return sgaExpenseBreakdownNoteCacheVersion
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

/// `.notApplicable` の理由（本note_typeの対象外だが、同等の値は `statement`（Statement本体のBS）から
/// 取得できる）。`property_plant_equipment_schedule` / `lease_liabilities` は BS 構造化タグに
/// 当期値があるときこの reason を返す（各 resolver 参照）。
public let statementNoteNotApplicableAvailableViaStatement = "available_via_statement"

/// `.notApplicable` の理由（本note_typeの対象外だが、同等の値は他の statement note から取得できる）。
/// `lease_liabilities` は BS にリース負債タグが無く、借入金等明細表（`borrowings_schedule`）の
/// 区分行にリース債務／リース負債があるときこの reason を返す。
public let statementNoteNotApplicableAvailableViaNotes = "available_via_notes"

/// REST/MCP 404 の `reason` として返しうる statement-notes の既知コード一覧（公開契約）。
/// `us_gaap_unsupported` は Statement 本体と共用（`statementNotApplicableUSGAAP`）。
/// 追加・改名したら ApiSkills の description / instructions と本配列を同時更新する。
public let allStatementNoteNotApplicableReasons: [String] = [
    statementNoteNotApplicableNotFound,
    statementNoteNotApplicableAvailableViaStatement,
    statementNoteNotApplicableAvailableViaNotes,
    statementNotApplicableUSGAAP,
]

/// 404 `reason` が公開契約の既知コードか（クライアント／カタログ突合用）。
public func isKnownStatementNoteNotApplicableReason(_ reason: String) -> Bool {
    allStatementNoteNotApplicableReasons.contains(reason)
}

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

/// 財務諸表注記取り込み ingest（書類1件・note_type1つ分）の計算結果。`BreakdownResolveResult`（内訳取り込み）と同型の
/// 3値パターン（`.agents/rules/project/error-handling.md`）。
public enum StatementNoteResolveResult: Sendable {
    case resolved(payload: StatementNotePayload, source: String, contentHash: String)
    case notApplicable(reason: String)
    case failed
}

/// company_statement_notes.payload の中身。note_type によって使うフィールドが変わる緩めの構造:
/// - スカラー値の note は `value`/`unit` を使う
/// - 表形式の note（EPS/BPS等・PPE明細・のれん明細）は `items` を使う
///   （`StatementLineItem` を再利用し、Statement 本体と表現を揃える）
/// - 配当金は `dividendEvents`、設備投資概要は `capexSegments`、発行済株式・資本金等は
///   `issuedSharesEvents`（textblock表のイベント列）と `issuedSharesAsOf`（期末の離散タグ
///   スナップショット。summary 移行時はこちらを正とする）
/// - 借入金等明細表は `borrowingsComponents`（当期首/当期末残高・平均利率、2026-08-02再設計。
///   単一値の `items` では平均利率を表現できないため専用型に切り出した）
/// - 政策保有株式（決定論、銘柄別 XBRL タグ抽出）は `securities` を使う
public struct StatementNotePayload: Codable, Sendable {
    public var value: Double?
    public var unit: String?
    public var items: [StatementLineItem]?
    public var securities: [PolicyHoldingSecurityPayload]?
    public var policyHoldingSummary: PolicyHoldingAggregateSummaryPayload?
    public var dividendEvents: [DividendEventPayload]?
    public var capexSegments: [CapexSegmentPayload]?
    public var issuedSharesEvents: [IssuedSharesEventPayload]?
    /// 期末スナップショット（離散XBRLタグ）。`issued_shares_and_capital` note_type 専用。
    public var issuedSharesAsOf: IssuedSharesAsOfPayload?
    public var borrowingsComponents: [BorrowingsComponentPayload]?
    public var needsReview: Bool
    public var warnings: [String]

    public init(
        value: Double? = nil, unit: String? = nil, items: [StatementLineItem]? = nil,
        securities: [PolicyHoldingSecurityPayload]? = nil,
        policyHoldingSummary: PolicyHoldingAggregateSummaryPayload? = nil,
        dividendEvents: [DividendEventPayload]? = nil, capexSegments: [CapexSegmentPayload]? = nil,
        issuedSharesEvents: [IssuedSharesEventPayload]? = nil,
        issuedSharesAsOf: IssuedSharesAsOfPayload? = nil,
        borrowingsComponents: [BorrowingsComponentPayload]? = nil,
        needsReview: Bool = false, warnings: [String] = []
    ) {
        self.value = value
        self.unit = unit
        self.items = items
        self.securities = securities
        self.policyHoldingSummary = policyHoldingSummary
        self.dividendEvents = dividendEvents
        self.capexSegments = capexSegments
        self.issuedSharesEvents = issuedSharesEvents
        self.issuedSharesAsOf = issuedSharesAsOf
        self.borrowingsComponents = borrowingsComponents
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
            "policy_holding_summary": policyHoldingSummary?.jsonObject() as Any? ?? NSNull(),
            "dividend_events": dividendEvents.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
            "capex_segments": capexSegments.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
            "borrowings_components": borrowingsComponents.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
            "issued_shares_events": issuedSharesEvents.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
            "as_of_period_end": issuedSharesAsOf?.jsonObject() as Any? ?? NSNull(),
            "needs_review": needsReview,
            "warnings": warnings,
        ]
    }
}

/// 借入金等明細表1区分分（`borrowings_schedule` note_type 専用）。
/// `averageInterestRatePercent` は明細表「平均利率（％）」列の生数値（例: 0.80 は年0.80%）。
/// 開示されない行（一部のリース債務・合計行等）は「－」表記のため nil。
public struct BorrowingsComponentPayload: Codable, Sendable {
    public var label: String
    public var priorBalance: Double?
    public var currentBalance: Double?
    public var averageInterestRatePercent: Double?
    public var isTotal: Bool

    public init(
        label: String, priorBalance: Double?, currentBalance: Double?,
        averageInterestRatePercent: Double?, isTotal: Bool = false
    ) {
        self.label = label
        self.priorBalance = priorBalance
        self.currentBalance = currentBalance
        self.averageInterestRatePercent = averageInterestRatePercent
        self.isTotal = isTotal
    }

    public func jsonObject() -> [String: Any] {
        [
            "label": label,
            "prior_balance": priorBalance as Any? ?? NSNull(),
            "current_balance": currentBalance as Any? ?? NSNull(),
            "average_interest_rate_percent": averageInterestRatePercent as Any? ?? NSNull(),
            "is_total": isTotal,
        ]
    }
}

/// 設備投資1セグメント分（`capital_expenditures_overview` note_type 専用）。単一セグメント企業
/// （報告セグメントが1つで内訳表を持たない）は `segmentName: nil` の1行のみを返す。前年度比（％）・
/// 主な内容・目的はXBRLタグとして構造化されておらず注記のHTML表にのみ存在するため、
/// `resolveCapitalExpendituresOverview` が表をパースして埋める（複数セグメント企業のみ）。
public struct CapexSegmentPayload: Codable, Sendable {
    public var segmentName: String?
    public var investmentAmount: Double?
    public var yoyPercent: Double?
    public var description: String?
    public var isTotal: Bool

    public init(
        segmentName: String?, investmentAmount: Double?, yoyPercent: Double?, description: String?,
        isTotal: Bool = false
    ) {
        self.segmentName = segmentName
        self.investmentAmount = investmentAmount
        self.yoyPercent = yoyPercent
        self.description = description
        self.isTotal = isTotal
    }

    public func jsonObject() -> [String: Any] {
        [
            "segment_name": segmentName as Any? ?? NSNull(),
            "investment_amount": investmentAmount as Any? ?? NSNull(),
            "yoy_percent": yoyPercent as Any? ?? NSNull(),
            "description": description as Any? ?? NSNull(),
            "is_total": isTotal,
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
    /// `dividendPerShare` の由来タグ名（`jpcrp_cor:` 接頭辞なし）。値が取れた場合のみ非 nil。
    public var dividendPerShareTag: String?
    /// `totalAmount` の由来タグ名。値が取れた場合のみ非 nil。
    public var totalAmountTag: String?

    public init(
        resolutionDate: String?, resolutionBody: String?, dividendPerShare: Double?,
        totalAmount: Double?, dividendPerShareTag: String? = nil, totalAmountTag: String? = nil
    ) {
        self.resolutionDate = resolutionDate
        self.resolutionBody = resolutionBody
        self.dividendPerShare = dividendPerShare
        self.totalAmount = totalAmount
        self.dividendPerShareTag = dividendPerShareTag
        self.totalAmountTag = totalAmountTag
    }

    public func jsonObject() -> [String: Any] {
        [
            "resolution_date": resolutionDate as Any? ?? NSNull(),
            "resolution_body": resolutionBody as Any? ?? NSNull(),
            "dividend_per_share": dividendPerShare as Any? ?? NSNull(),
            "total_amount": totalAmount as Any? ?? NSNull(),
            "dividend_per_share_tag": dividendPerShareTag as Any? ?? NSNull(),
            "total_amount_tag": totalAmountTag as Any? ?? NSNull(),
        ]
    }
}

/// 発行済株式・資本金等の期末スナップショット（`issued_shares_and_capital` note_type 専用）。
/// textblock 表（`issuedSharesEvents`）とは別経路の離散XBRLタグ。表が千株丸めの会社でも
/// financials / 将来の summary←notes 移行で使う期末値はこちらを正とする。
/// - `issuedShares`: `PerShareExtractor` と同じタグ解決（生株）
/// - `capitalStock`: 資本金（円）
/// - `capitalReserve`: 資本準備金（`LegalCapitalSurplus`。資本剰余金全体ではない）
public struct IssuedSharesAsOfPayload: Codable, Sendable {
    public var issuedShares: Double?
    public var capitalStock: Double?
    public var capitalReserve: Double?

    public init(issuedShares: Double?, capitalStock: Double?, capitalReserve: Double?) {
        self.issuedShares = issuedShares
        self.capitalStock = capitalStock
        self.capitalReserve = capitalReserve
    }

    public func jsonObject() -> [String: Any] {
        [
            "issued_shares": issuedShares as Any? ?? NSNull(),
            "capital_stock": capitalStock as Any? ?? NSNull(),
            "capital_reserve": capitalReserve as Any? ?? NSNull(),
        ]
    }
}

/// 発行済株式総数・資本金等の推移1行分（`issued_shares_and_capital` note_type 専用）。表の「年月日」欄は
/// 単発日付（例:「2019年５月31日」）と期間表記（例:「自2018年４月１日 至2019年３月31日」）が
/// 会社によって混在するため、`date` はセルのテキストをそのまま保持し加工しない。株数・金額は
/// ヘッダーの単位表記（株/千株、千円/百万円）を判定して常に「株」「円」の生値へ正規化する。
public struct IssuedSharesEventPayload: Codable, Sendable {
    public var date: String
    public var sharesDelta: Double?
    public var sharesBalance: Double?
    public var capitalDelta: Double?
    public var capitalBalance: Double?
    public var capitalReserveDelta: Double?
    public var capitalReserveBalance: Double?

    public init(
        date: String, sharesDelta: Double?, sharesBalance: Double?, capitalDelta: Double?,
        capitalBalance: Double?, capitalReserveDelta: Double?, capitalReserveBalance: Double?
    ) {
        self.date = date
        self.sharesDelta = sharesDelta
        self.sharesBalance = sharesBalance
        self.capitalDelta = capitalDelta
        self.capitalBalance = capitalBalance
        self.capitalReserveDelta = capitalReserveDelta
        self.capitalReserveBalance = capitalReserveBalance
    }

    public func jsonObject() -> [String: Any] {
        [
            "date": date,
            "shares_delta": sharesDelta as Any? ?? NSNull(),
            "shares_balance": sharesBalance as Any? ?? NSNull(),
            "capital_delta": capitalDelta as Any? ?? NSNull(),
            "capital_balance": capitalBalance as Any? ?? NSNull(),
            "capital_reserve_delta": capitalReserveDelta as Any? ?? NSNull(),
            "capital_reserve_balance": capitalReserveBalance as Any? ?? NSNull(),
        ]
    }
}

/// 政策保有株式1銘柄分（決定論抽出結果、`StatementNotesResolver.resolvePolicyHoldingSecurities` 参照）。
/// `policy_holding_securities` note_type 専用。`isDeemedHolding` は「みなし保有株式」（退職給付信託等、
/// 議決権行使を指図する権限のみ保有するケース）か「特定投資株式」（提出会社・子会社が直接保有）かの区別。
public struct PolicyHoldingSecurityPayload: Codable, Sendable {
    public var issuerName: String
    public var numberOfShares: Double?
    public var carryingAmount: Double?
    public var purpose: String?
    public var isDeemedHolding: Bool

    public init(
        issuerName: String, numberOfShares: Double?, carryingAmount: Double?, purpose: String?,
        isDeemedHolding: Bool = false
    ) {
        self.issuerName = issuerName
        self.numberOfShares = numberOfShares
        self.carryingAmount = carryingAmount
        self.purpose = purpose
        self.isDeemedHolding = isDeemedHolding
    }

    /// `isDeemedHolding` 追加（2026-08-11）前に格納された行にも対応するため、欠落時は
    /// `false`（特定投資株式扱い）にフォールバックする。合成 Decodable のデフォルト値非対応を回避。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issuerName = try container.decode(String.self, forKey: .issuerName)
        numberOfShares = try container.decodeIfPresent(Double.self, forKey: .numberOfShares)
        carryingAmount = try container.decodeIfPresent(Double.self, forKey: .carryingAmount)
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
        isDeemedHolding = try container.decodeIfPresent(Bool.self, forKey: .isDeemedHolding) ?? false
    }

    public func jsonObject() -> [String: Any] {
        [
            "issuer_name": issuerName,
            "number_of_shares": numberOfShares as Any? ?? NSNull(),
            "carrying_amount": carryingAmount as Any? ?? NSNull(),
            "purpose": purpose as Any? ?? NSNull(),
            "is_deemed_holding": isDeemedHolding,
        ]
    }
}

/// 政策保有株式（保有目的が純投資目的以外の目的である投資株式）の銘柄数及び貸借対照表計上額の合計額
/// （決定論抽出結果、`StatementNotesResolver.resolvePolicyHoldingSecurities` 参照）。`policy_holding_securities`
/// note_type 専用。`securities`（個別開示される上位銘柄のみ）とは異なり、非開示の銘柄も含めた全銘柄の
/// 総数・総額を表す（提出会社・子会社の各variantを合算した値）。特定投資株式・みなし保有株式を区別
/// しない単一の合計（開示上もこの区分での合算しか存在しない）。
public struct PolicyHoldingAggregateSummaryPayload: Codable, Sendable {
    public var unlistedIssueCount: Int?
    public var unlistedCarryingAmount: Double?
    public var listedIssueCount: Int?
    public var listedCarryingAmount: Double?

    public init(
        unlistedIssueCount: Int?, unlistedCarryingAmount: Double?,
        listedIssueCount: Int?, listedCarryingAmount: Double?
    ) {
        self.unlistedIssueCount = unlistedIssueCount
        self.unlistedCarryingAmount = unlistedCarryingAmount
        self.listedIssueCount = listedIssueCount
        self.listedCarryingAmount = listedCarryingAmount
    }

    public func jsonObject() -> [String: Any] {
        [
            "unlisted_issue_count": unlistedIssueCount as Any? ?? NSNull(),
            "unlisted_carrying_amount": unlistedCarryingAmount as Any? ?? NSNull(),
            "listed_issue_count": listedIssueCount as Any? ?? NSNull(),
            "listed_carrying_amount": listedCarryingAmount as Any? ?? NSNull(),
        ]
    }
}
