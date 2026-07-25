// Stage 6（事業別・地域別売上の正規化スナップショット）の格納用 Codable 契約。
// docs/breakdown-normalization-concept.md「今後の検討事項5」参照。
//
// 内部型 BreakdownSnapshot/BreakdownRow/LLMBreakdownAudit（Analysis/BreakdownNormalizer.swift,
// Analysis/GeographyBreakdownLLMNormalizer.swift, internal）は露出させず、Stage 5 の
// ExtractedBreakdown → ExtractedBreakdownPayload 写経と同じパターンで公開 Codable 型へ写す。
// Foundation のみ依存（BlueTickerCore/Models 配置。Fluent モデルは BltServerCore 側）。

import Foundation

/// Neon Stage 6 キャッシュ（company_breakdowns.cache_version）の契約スキーマバージョン。
/// blueTickerVersion 非連動。`BreakdownSnapshotPayload` の意味を変える破壊的変更のみバンプする。
/// LLM 経由の行（source != "xbrl_facts"）は本バージョンのバンプだけでは再計算しない
/// （content_hash 一致・needs_review=false の行はそのまま据え置く。今後の検討事項8参照）。
public let breakdownCacheVersion = "breakdown-v6"

/// business 軸は `BusinessBreakdownResolver` が、geography 軸は呼び出し側が
/// `GeographyBreakdownLLMNormalizer`（html_table）または xbrl_facts 経路（`BreakdownNormalizer`）で
/// 解決した経路。監査・再計算方針の判断に使う（xbrl_facts は決定的でバンプ全件再計算してよいが、
/// LLM 経由（*_llm）は content_hash + needs_review でのみ再計算する）。
/// `.notFound` は行を作らない方針のため、この文字列が DB に書かれることはない
/// （欠ける軸は出さない）。
public let breakdownSourceXbrlFacts = "xbrl_facts"
public let breakdownSourceRevenueRecognitionLLM = "revenue_recognition_llm"
public let breakdownSourceSegmentInfoLLM = "segment_info_llm"
/// geography 軸を `GeographyBreakdownLLMNormalizer`（html_table）経由で解決した行の source。
public let breakdownSourceGeographyLLM = "geography_llm"

/// business breakdown が解決できなかった理由（issue #130、E/F判定の検知結果明示化）。
/// `BreakdownExtractor.BusinessBreakdownNotApplicableReason`（internal 型）の rawValue と揃える
/// 公開文字列定数（`breakdownSource*` と同じ「internal enum ⇔ public 文字列定数」パターン）。
/// ingest ログ・診断ツール専用（`.notFound` は行を作らない方針のため company_breakdowns には永続化しない）。
/// E: 報告セグメントが地域別のみで、business 軸への swap（収益認識注記等）が見つからなかった。
public let breakdownNotApplicableGeographyOnly = "geography_only"
/// F: 単一セグメントのため報告セグメント開示自体が省略されていた
/// （`DescriptionOfFactThatCompanysBusinessComprisesSingleSegment` タグで確認）。
public let breakdownNotApplicableSingleSegmentDisclosed = "single_segment_disclosed"
/// 上記いずれにも該当しない・原因未特定（要調査）。
public let breakdownNotApplicableUnknown = "unknown"

/// breakdown read（REST/MCP）が xbrl_facts 経由の行に適用する最低スキーマバージョン番号
/// （`breakdown-vN` の N）。**明示指定**。LLM 経由の行（source != xbrl_facts）には適用しない
/// （`isServableBreakdown` 参照。content_hash + needs_review でのみ再計算する据え置き運用のため、
/// cache_version の世代でゲートすると正しい行まで 404 になってしまう）。
/// 不変条件: `breakdownMinServableVersion` ≤ 現行 `breakdown-vN` の N。
public let breakdownMinServableVersion = 1

/// `breakdown-vN` 形式から世代番号 N を取り出す。パース不能なら nil（非 servable 扱い）。
public func breakdownCacheVersionNumber(_ version: String) -> Int? {
    guard version.hasPrefix("breakdown-v") else { return nil }
    let suffix = version.dropFirst("breakdown-v".count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
    return n
}

/// 格納行が read 可能か。xbrl_facts 経由（決定的）は cache_version が床以上のときのみ
/// （バンプで全件再計算してよい）。LLM 経由は存在すれば常に read 可能（据え置き運用。
/// docs/breakdown-normalization-concept.md「今後の検討事項8」参照）。
public func isServableBreakdown(source: String, cacheVersion: String) -> Bool {
    guard source == breakdownSourceXbrlFacts else { return true }
    guard let n = breakdownCacheVersionNumber(cacheVersion) else { return false }
    return n >= breakdownMinServableVersion
}

/// BreakdownRow（内部型）の公開 Codable 写経。
public struct BreakdownRowPayload: Codable, Sendable, Equatable {
    public var labelRaw: String
    public var amount: Double
    public var profit: Double?
    public var rowKind: String

    public init(labelRaw: String, amount: Double, profit: Double?, rowKind: String) {
        self.labelRaw = labelRaw
        self.amount = amount
        self.profit = profit
        self.rowKind = rowKind
    }
}

/// BreakdownSnapshot（内部型）の公開 Codable 写経。company_breakdowns.payload の中身。
public struct BreakdownSnapshotPayload: Codable, Sendable, Equatable {
    public var axis: String
    public var denominator: Double
    public var denominatorTag: String
    public var rows: [BreakdownRowPayload]
    public var sourceKind: String
    public var needsReview: Bool
    public var warnings: [String]

    public init(
        axis: String, denominator: Double, denominatorTag: String, rows: [BreakdownRowPayload],
        sourceKind: String, needsReview: Bool, warnings: [String]
    ) {
        self.axis = axis
        self.denominator = denominator
        self.denominatorTag = denominatorTag
        self.rows = rows
        self.sourceKind = sourceKind
        self.needsReview = needsReview
        self.warnings = warnings
    }
}

/// LLMBreakdownAudit（内部型）の公開 Codable 写経。LLM 経由の行にのみ添える軽量な監査情報
/// （どの表・期間列・単位・利益開示有無を採用したか）。生レスポンス全文のログ化は別途未着手
/// （今後の検討事項8）。
public struct LLMBreakdownAuditPayload: Codable, Sendable, Equatable {
    public var sourceTableIndex: Int?
    public var periodColumn: String?
    public var unit: String
    /// 表がそもそも事業別/製品別の利益情報を含んでいたか。`profit == nil` だけでは
    /// 「未開示（確認済み）」と「見落とし」を区別できないため独立して持つ。
    public var profitDisclosed: Bool
    public var notes: String

    public init(sourceTableIndex: Int?, periodColumn: String?, unit: String, profitDisclosed: Bool, notes: String) {
        self.sourceTableIndex = sourceTableIndex
        self.periodColumn = periodColumn
        self.unit = unit
        self.profitDisclosed = profitDisclosed
        self.notes = notes
    }
}

public extension BreakdownRowPayload {
    /// REST/MCP 応答用 JSON オブジェクト（snake_case キー）。欠損は NSNull（`FinancialsYear` の
    /// delta フィールドと同じ表現方針）。
    func jsonObject() -> [String: Any] {
        [
            "label_raw": labelRaw,
            "amount": amount,
            "profit": profit ?? NSNull(),
            "row_kind": rowKind,
        ]
    }
}

public extension BreakdownSnapshotPayload {
    /// REST/MCP 応答用 JSON オブジェクト（snake_case キー）。
    func jsonObject() -> [String: Any] {
        [
            "axis": axis,
            "denominator": denominator,
            "denominator_tag": denominatorTag,
            "rows": rows.map { $0.jsonObject() },
            "source_kind": sourceKind,
            "needs_review": needsReview,
            "warnings": warnings,
        ]
    }
}

public extension LLMBreakdownAuditPayload {
    /// REST/MCP 応答用 JSON オブジェクト（snake_case キー）。欠損は NSNull。
    /// `notes` は「どの表・期間列・単位・転置有無を採用したか」の自由文で、`denominator_tag`が
    /// "income_statement.sales" 以外（例: "llm_table_subtotal"）のときに実際の指標名を知る手がかりになる。
    func jsonObject() -> [String: Any] {
        [
            "source_table_index": sourceTableIndex ?? NSNull(),
            "period_column": periodColumn ?? NSNull(),
            "unit": unit,
            "profit_disclosed": profitDisclosed,
            "notes": notes,
        ]
    }
}
