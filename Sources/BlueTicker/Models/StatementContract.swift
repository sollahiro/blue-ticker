// Statement（BS/PL/CF/SS 完全正規化、Statement 取り込み）API の公開契約。
// docs/statement-normalization-concept.md 参照。
//
// compute 関数・DB モデル・ingest・REST・MCP 配線は実装済み（日経225限定）。
// FinancialsContract.swift のバージョニング四点セット（cache_version 文字列・
// min_servable 整数・数値パーサー・servable 判定）と同型で用意している。
//
// Foundation のみ依存（NIO/Vapor 非依存）。

import Foundation

/// Statement 取り込み（Statement 本体）の計算結果。「対象外」（有価証券報告書未提出等）と「失敗」
/// （書類はあるが抽出できない）を区別する（`FinancialsComputeResult` と同型。issue #86）。
public enum StatementComputeResult: Sendable {
    case success(StatementResponse)
    case notApplicable
    case failed
}

/// 書類1件分の Statement 抽出結果。notes の `StatementNoteResolveResult` と同型の3値。
public enum StatementDocResolveResult: Sendable {
    case resolved(StatementYear)
    case notApplicable(reason: String)
    case failed
}

/// US-GAAP 連結に HTML 本表が無く Statement を組み立てられないときの reason。
/// 通常は `USGAAPStatementHtml` 経路で解決する。notes（`borrowings_schedule` 等）は
/// 引き続きこの reason で明示対象外（2026-08-09 / HTML Statement 配線後も notes は別）。
public let statementNotApplicableUSGAAP = "us_gaap_unsupported"

/// ingest が US-GAAP 等の対象外を格納するときのプレースホルダ（BS/PL/CF/SS 空）。
/// read 経路はこれを除外し、実データ行が無ければ 404 相当（nil）を返す。
public func statementNotApplicablePlaceholderYear(docID: String) -> StatementYear {
    StatementYear(
        fyEnd: nil, financialPeriod: nil, docId: docID,
        balanceSheet: [], incomeStatement: [], cashFlow: [], changesInEquity: [])
}

public func isStatementNotApplicablePlaceholder(_ year: StatementYear) -> Bool {
    year.balanceSheet.isEmpty && year.incomeStatement.isEmpty && year.cashFlow.isEmpty
        && year.changesInEquity.isEmpty
}

/// Neon Statement 取り込み キャッシュ（`company_statements.cache_version`）の計算バージョン。
/// `blueTickerVersion` とは独立し、抽出ロジックまたは本契約型の意味を変えたときのみバンプする
/// （`companyFinancialsCacheVersion` と同じ運用。`.agents/rules/project/versioning.md`）。
/// 注記（注記取り込み）は別バージョン系統になる想定で、本定数には連動させない。
/// US-GAAP 明示 notApplicable（個別 BS silent fallback 廃止）は v1 のまま拡張（2026-08-09）。
/// SS（持分変動計算書）追加も v1 のまま拡張（2026-08-09。本番 `company_statements` は 0 行のため
/// 移行コスト実質ゼロ。旧 payload は `changes_in_equity` キー欠落を空配列として読む）。
/// US-GAAP HTML 経路（`USGAAPStatementHtml`、2026-08-10）も v1 のまま拡張。本番
/// `company_statements` はこの時点でも 0 行のため、旧 `.notApplicable(us_gaap_unsupported)`
/// プレースホルダが残っていても実害はない（意図的にバンプしない。要バンプならユーザー指示）。
public let statementCacheVersion = "statement-v1"

/// Statement read が 200 を返す最低計算バージョン番号（`statement-vN` の N）。
/// **明示指定**であり、「現行から N つ前」のような機械オフセットではない。
public let statementMinServableVersion = 1

/// `statement-vN` 形式から世代番号 N を取り出す。パース不能なら nil（非 servable 扱い）。
public func statementCacheVersionNumber(_ version: String) -> Int? {
    guard version.hasPrefix("statement-v") else { return nil }
    let suffix = version.dropFirst("statement-v".count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
    return n
}

/// 格納行の `cache_version` が read 床以上か。文字列辞書順比較は使わない（`v10` 対策）。
public func isServableStatementCacheVersion(_ version: String) -> Bool {
    guard let n = statementCacheVersionNumber(version) else { return false }
    return n >= statementMinServableVersion
}

/// Statement API の公開契約バージョン。`blueTickerVersion` とは独立。
/// レスポンス形を破壊的に変更したときのみ +1 する（`Api.financialsSchemaVersion` と同型）。
public let statementSchemaVersion = 1

// MARK: - 契約型

/// BS/CF 行の区分。貸借対照表は資産/負債/純資産、キャッシュ・フロー計算書は営業/投資/財務活動を表す。
/// 損益計算書には適用しない（`StatementLineItem.section` は常に nil）。presentation linkbase の
/// 祖先タグから判定する（`StatementClassifier` 参照）。複数区分にまたがる合計行（例: 資産合計＋
/// 負債純資産合計）は該当する祖先を持たないため nil になる。
public enum StatementLineSection: String, Codable, Sendable {
    case assets
    case liabilities
    case netAssets = "net_assets"
    case operating
    case investing
    case financing
}

/// 合計行（`StatementLineItem.isTotal == true`）を構成する要素1件。計算リンクベース
/// （`_cal.xml`、`summation-item` arc）由来。`weight` は加算=1・控除=−1（実データ上 ±1 のみ確認）。
public struct StatementLineComponent: Codable, Sendable {
    public var tag: String
    public var weight: Int

    public init(tag: String, weight: Int) {
        self.tag = tag
        self.weight = weight
    }

    public func jsonObject() -> [String: Any] {
        ["tag": tag, "weight": weight]
    }
}

/// BS/PL/CF/SS いずれかの1行分。`order` は presentation linkbase の表示順（`StatementClassifier`
/// 参照)。role 内で取得できないタグは nil（呼び出し側がタグ名アルファベット順へフォールバック）。
/// `isTotal`/`components` は presentation ではなく計算リンクベース由来（`docs/statement-
/// normalization-concept.md` 実装方針8）。presentation の親子関係は表示上のネストでしかなく
/// 二重計上の防止を保証しないため、「この行が他の行の合計かどうか・何を足したものか」は
/// こちらでのみ決定的に判断できる。企業拡張タグの区別は docs/statement-normalization-concept.md
/// 「未決事項」参照（v1では未対応）。
/// US-GAAP HTML 経路（`USGAAPStatementHtml`）のみ例外: calculation linkbase が無いため
/// `is_total` はラベル規則、`components` はキヤノン型（合計直後の内訳が親と一致）の推定。
/// SS は合計列のみ（資本構成員次元は含めない）。
public struct StatementLineItem: Codable, Sendable {
    public var tag: String
    public var label: String?
    public var value: Double
    public var unit: String?
    public var order: Int?
    public var section: StatementLineSection?
    /// この行が計算リンクベース上の合計行（`summation-item` の from 側）かどうか。
    public var isTotal: Bool
    /// `isTotal == true` かつ構成要素が解決できた場合のみ非 nil。
    public var components: [StatementLineComponent]?

    private enum CodingKeys: String, CodingKey {
        case tag, label, value, unit, order, section
        case isTotal = "is_total"
        case components
    }

    public init(
        tag: String, label: String?, value: Double, unit: String?, order: Int?,
        section: StatementLineSection? = nil, isTotal: Bool = false,
        components: [StatementLineComponent]? = nil
    ) {
        self.tag = tag
        self.label = label
        self.value = value
        self.unit = unit
        self.order = order
        self.section = section
        self.isTotal = isTotal
        self.components = components
    }

    /// 手書き実装（Opus 監査で発見・修正、2026-07-31）: `isTotal` を非 Optional のまま
    /// `decodeIfPresent(_:default:)` で読む。`company_statements.payload` は JSON カラムで
    /// Fluent が直接デコードするため、この2フィールド追加前に格納された行（`is_total` キーが
    /// 無い）があると合成 `Decodable` では `keyNotFound` で読み取り自体が失敗し、REST 読み出しも
    /// `StatementIngest` の既存行チェックも共倒れする。現状 `company_statements` は本番・開発とも
    /// 未書き込みで実害は無いが、将来の取り違えを避けるため決定的に安全側へ倒す。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        value = try container.decode(Double.self, forKey: .value)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        order = try container.decodeIfPresent(Int.self, forKey: .order)
        section = try container.decodeIfPresent(StatementLineSection.self, forKey: .section)
        isTotal = try container.decodeIfPresent(Bool.self, forKey: .isTotal) ?? false
        components = try container.decodeIfPresent(
            [StatementLineComponent].self, forKey: .components)
    }

    /// REST/MCP 応答用 JSON オブジェクト。`order` は presentation linkbase から取得できた場合のみ
    /// 非 nil（docs/statement-normalization-concept.md「実装方針」3）。`section` は BS/CF のみ、
    /// 該当する祖先が判定できた行のみ非 nil。`components` は `is_total` が true かつ構成要素が
    /// 解決できた場合のみ非 nil。
    public func jsonObject() -> [String: Any] {
        [
            "tag": tag,
            "label": label as Any? ?? NSNull(),
            "value": value,
            "unit": unit as Any? ?? NSNull(),
            "order": order as Any? ?? NSNull(),
            "section": section?.rawValue as Any? ?? NSNull(),
            "is_total": isTotal,
            "components": components.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
        ]
    }
}

/// 1年度分の BS/PL/CF/SS。
public struct StatementYear: Codable, Sendable {
    public var fyEnd: String?
    public var financialPeriod: String?
    public var docId: String?
    public var balanceSheet: [StatementLineItem]
    public var incomeStatement: [StatementLineItem]
    public var cashFlow: [StatementLineItem]
    /// 持分変動計算書（IFRS）／株主資本等変動計算書（J-GAAP）。合計列のみ（資本構成員次元は含めない）。
    public var changesInEquity: [StatementLineItem]

    private enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case financialPeriod = "financial_period"
        case docId = "doc_id"
        case balanceSheet = "balance_sheet"
        case incomeStatement = "income_statement"
        case cashFlow = "cash_flow"
        case changesInEquity = "changes_in_equity"
    }

    public init(
        fyEnd: String?, financialPeriod: String?, docId: String?,
        balanceSheet: [StatementLineItem], incomeStatement: [StatementLineItem],
        cashFlow: [StatementLineItem], changesInEquity: [StatementLineItem] = []
    ) {
        self.fyEnd = fyEnd
        self.financialPeriod = financialPeriod
        self.docId = docId
        self.balanceSheet = balanceSheet
        self.incomeStatement = incomeStatement
        self.cashFlow = cashFlow
        self.changesInEquity = changesInEquity
    }

    /// 手書き実装: `changes_in_equity` 追加前の格納行（キー欠落）を空配列として読む。
    /// `StatementLineItem.isTotal` と同型の後方互換（本番は未書き込みだが決定的に安全側へ倒す）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fyEnd = try container.decodeIfPresent(String.self, forKey: .fyEnd)
        financialPeriod = try container.decodeIfPresent(String.self, forKey: .financialPeriod)
        docId = try container.decodeIfPresent(String.self, forKey: .docId)
        balanceSheet = try container.decodeIfPresent([StatementLineItem].self, forKey: .balanceSheet) ?? []
        incomeStatement =
            try container.decodeIfPresent([StatementLineItem].self, forKey: .incomeStatement) ?? []
        cashFlow = try container.decodeIfPresent([StatementLineItem].self, forKey: .cashFlow) ?? []
        changesInEquity =
            try container.decodeIfPresent([StatementLineItem].self, forKey: .changesInEquity) ?? []
    }

    /// REST/MCP 応答用 JSON オブジェクト。
    public func jsonObject() -> [String: Any] {
        [
            "fy_end": fyEnd as Any? ?? NSNull(),
            "financial_period": financialPeriod as Any? ?? NSNull(),
            "doc_id": docId as Any? ?? NSNull(),
            "balance_sheet": balanceSheet.map { $0.jsonObject() },
            "income_statement": incomeStatement.map { $0.jsonObject() },
            "cash_flow": cashFlow.map { $0.jsonObject() },
            "changes_in_equity": changesInEquity.map { $0.jsonObject() },
        ]
    }
}

/// Statement API の公開レスポンス（本体・Statement 取り込み）。
public struct StatementResponse: Codable, Sendable {
    public var schemaVersion: Int
    public var code: String
    public var name: String?
    public var sector: String?
    public var market: String?
    public var years: [StatementYear]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code, name, sector, market, years
    }

    public init(
        schemaVersion: Int, code: String, name: String?, sector: String?, market: String?,
        years: [StatementYear]
    ) {
        self.schemaVersion = schemaVersion
        self.code = code
        self.name = name
        self.sector = sector
        self.market = market
        self.years = years
    }

    /// 「対象外」（有価証券報告書未提出等）を表すプレースホルダ。ingest がこれを格納することで
    /// 恒久的な対象外を毎回再試行しない（`FinancialsResponse.notApplicablePlaceholder` と同型）。
    public static func notApplicablePlaceholder(code: String) -> StatementResponse {
        StatementResponse(
            schemaVersion: statementSchemaVersion, code: code, name: nil, sector: nil, market: nil,
            years: [])
    }

    /// REST/MCP 応答用 JSON オブジェクト。`name`/`sector`/`market` は v1 では常に nil
    /// （company_statements は company_filing_sections と同様 code のみ非正規化して持つ。
    /// docs/statement-normalization-concept.md）。
    public func jsonObject() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "code": code,
            "name": name as Any? ?? NSNull(),
            "sector": sector as Any? ?? NSNull(),
            "market": market as Any? ?? NSNull(),
            "years": years.map { $0.jsonObject() },
        ]
    }
}
