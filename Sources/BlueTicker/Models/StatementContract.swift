// Statement（BS/PL/CF 完全正規化、Stage 7）API の公開契約の骨組み。
// docs/statement-normalization-concept.md 参照。
//
// 現時点では型定義のみ（compute 関数・DB モデル・ingest・REST・MCP 配線は未実装）。
// FinancialsContract.swift のバージョニング四点セット（cache_version 文字列・
// min_servable 整数・数値パーサー・servable 判定）と同型で用意しておく。
//
// Foundation のみ依存（NIO/Vapor 非依存）。

import Foundation

/// Stage 7（Statement 本体）の計算結果。「対象外」（有価証券報告書未提出等）と「失敗」
/// （書類はあるが抽出できない）を区別する（`FinancialsComputeResult` と同型。issue #86）。
public enum StatementComputeResult: Sendable {
    case success(StatementResponse)
    case notApplicable
    case failed
}

/// Neon Stage 7 キャッシュ（`company_statements.cache_version`、未実装）の計算バージョン。
/// `blueTickerVersion` とは独立し、抽出ロジックまたは本契約型の意味を変えたときのみバンプする
/// （`companyFinancialsCacheVersion` と同じ運用。`.agents/rules/project/versioning.md`）。
/// 注記（Stage 8）は別バージョン系統になる想定で、本定数には連動させない。
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

/// BS/PL/CF いずれかの1行分。標準タグ・企業拡張タグの区別や表示順（`order`）の取得方法は
/// docs/statement-normalization-concept.md「未決事項」参照（Stage 7 実装時に確定）。
public struct StatementLineItem: Codable, Sendable {
    public var tag: String
    public var label: String?
    public var value: Double
    public var unit: String?
    public var order: Int?

    private enum CodingKeys: String, CodingKey {
        case tag, label, value, unit, order
    }

    public init(tag: String, label: String?, value: Double, unit: String?, order: Int?) {
        self.tag = tag
        self.label = label
        self.value = value
        self.unit = unit
        self.order = order
    }

    /// REST/MCP 応答用 JSON オブジェクト。`order` は v1 では常に nil（未対応、
    /// docs/statement-normalization-concept.md「実装方針」3）。
    public func jsonObject() -> [String: Any] {
        [
            "tag": tag,
            "label": label as Any? ?? NSNull(),
            "value": value,
            "unit": unit as Any? ?? NSNull(),
            "order": order as Any? ?? NSNull(),
        ]
    }
}

/// 1年度分の BS/PL/CF。
public struct StatementYear: Codable, Sendable {
    public var fyEnd: String?
    public var financialPeriod: String?
    public var docId: String?
    public var balanceSheet: [StatementLineItem]
    public var incomeStatement: [StatementLineItem]
    public var cashFlow: [StatementLineItem]

    private enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case financialPeriod = "financial_period"
        case docId = "doc_id"
        case balanceSheet = "balance_sheet"
        case incomeStatement = "income_statement"
        case cashFlow = "cash_flow"
    }

    public init(
        fyEnd: String?, financialPeriod: String?, docId: String?,
        balanceSheet: [StatementLineItem], incomeStatement: [StatementLineItem],
        cashFlow: [StatementLineItem]
    ) {
        self.fyEnd = fyEnd
        self.financialPeriod = financialPeriod
        self.docId = docId
        self.balanceSheet = balanceSheet
        self.incomeStatement = incomeStatement
        self.cashFlow = cashFlow
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
        ]
    }
}

/// Statement API の公開レスポンス（本体・Stage 7）。
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
