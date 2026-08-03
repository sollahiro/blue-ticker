// 内訳取り込み（事業別・地域別売上の正規化スナップショット）の格納用 Codable 契約。
// docs/breakdown-normalization-concept.md「今後の検討事項5」参照。
//
// 内部型 BreakdownSnapshot/BreakdownRow/LLMBreakdownAudit（Analysis/BreakdownNormalizer.swift,
// Analysis/GeographyBreakdownLLMNormalizer.swift, internal）は露出させず、有報セクション取り込み の
// ExtractedBreakdown → ExtractedBreakdownPayload 写経と同じパターンで公開 Codable 型へ写す。
// Foundation のみ依存（BlueTickerCore/Models 配置。Fluent モデルは BltServerCore 側）。

import Foundation

/// company_breakdowns.axis の公開定数（BltServerCore / REST / MCP / ingest で共用）。
public let breakdownAxisBusiness = "business"
public let breakdownAxisGeography = "geography"
/// 従業員数のセグメント別内訳軸（2026-08-01追加）。決定論のみ（LLMフォールバックなし）。
public let breakdownAxisEmployees = "employees"
/// 研究開発費（全社合計）のセグメント別内訳軸（2026-08-01追加）。決定論のみ（LLMフォールバックなし）。
public let breakdownAxisResearchAndDevelopment = "research_and_development"

/// Neon 内訳取り込み キャッシュ（company_breakdowns.cache_version）の契約スキーマバージョン。
/// **軸別に独立**（business / geography）。片軸の決定的ロジック変更で他軸の xbrl_facts /
/// not_applicable 全件再計算を起こさない。blueTickerVersion 非連動。
/// LLM 経由の行（source != "xbrl_facts"）は本バージョンのバンプだけでは再計算しない
/// （content_hash 一致・needs_review=false の行はそのまま据え置く。今後の検討事項8参照）。
///
/// 形式: `breakdown-business-vN` / `breakdown-geography-vN`（旧共通 `breakdown-vN` も read 時は受理）。
public let businessBreakdownCacheVersion = "breakdown-business-v8"
public let geographyBreakdownCacheVersion = "breakdown-geography-v9"
public let employeesBreakdownCacheVersion = "breakdown-employees-v1"
public let researchAndDevelopmentBreakdownCacheVersion = "breakdown-research-and-development-v1"

/// 軸に対応する現行 cache_version 文字列。未知の軸は business 扱い（安全側に決定的バンプ対象へ）。
public func breakdownCacheVersion(forAxis axis: String) -> String {
    switch axis {
    case breakdownAxisGeography: return geographyBreakdownCacheVersion
    case breakdownAxisEmployees: return employeesBreakdownCacheVersion
    case breakdownAxisResearchAndDevelopment: return researchAndDevelopmentBreakdownCacheVersion
    default: return businessBreakdownCacheVersion
    }
}

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
/// business 軸の内訳が解決できなかった（E/F/unknown）ことを表す行の source（issue #132）。
/// `BreakdownExtractor.classifyNotApplicableReason` による決定的判定のため、xbrl_facts と同様
/// `cache_version` 世代でゲートする（`isVersionGatedBreakdownSource` 参照）。
public let breakdownSourceNotApplicable = "not_applicable"

/// business breakdown が解決できなかった理由（issue #130、E/F判定の検知結果明示化）。
/// `BreakdownExtractor.BusinessBreakdownNotApplicableReason`（internal 型）の rawValue と揃える
/// 公開文字列定数（`breakdownSource*` と同じ「internal enum ⇔ public 文字列定数」パターン）。
/// `CompanyBreakdown.notApplicableReason` に永続化され、REST/MCP の 404 応答へ反映される（issue #132）。
/// E: 報告セグメントが地域別のみで、business 軸への swap（収益認識注記等）が見つからなかった。
public let breakdownNotApplicableGeographyOnly = "geography_only"
/// F: 単一セグメントのため報告セグメント開示自体が省略されていた
/// （`DescriptionOfFactThatCompanysBusinessComprisesSingleSegment` タグで確認）。
public let breakdownNotApplicableSingleSegmentDisclosed = "single_segment_disclosed"
/// 上記いずれにも該当しない・原因未特定（要調査）。ingest 側は `needsReview=true` で保存し、
/// 分類ロジック改善後の再 ingest（`--codes` 指名 or 通常巡回）で再分類できるようにする。
public let breakdownNotApplicableUnknown = "unknown"
/// geography 軸: 地域注記自体が無い（`BreakdownExtractor.extractGeographyInfo` の
/// `method == "not_found"`）。正当欠測として `needsReview=false` で永続化し、無駄な再 LLM を止める
/// （business の E/F と同型の決定的 not_applicable。REST/MCP の geography 公開は別途）。
public let breakdownNotApplicableNotFound = "not_found"

/// not_applicable 行のうち、決定的判定のため `needs_review=false` にする reason か。
/// E/F（business）と geography の正当欠測（`not_found`）が該当。`unknown` や正規化/LLM 失敗は
/// `needs_review=true` で再処理キューへ載せる（内訳取り込み ingest と共用）。
public func isDeterministicBreakdownNotApplicableReason(_ reason: String) -> Bool {
    reason == breakdownNotApplicableGeographyOnly
        || reason == breakdownNotApplicableSingleSegmentDisclosed
        || reason == breakdownNotApplicableNotFound
}

/// breakdown read（REST/MCP）が xbrl_facts / not_applicable 経由の行に適用する最低スキーマ
/// バージョン番号（軸別 `…-vN` の N）。**明示指定**。LLM 経由の行（segment_info_llm 等）には
/// 適用しない（`isServableBreakdown` 参照。content_hash + needs_review でのみ再計算する据え置き
/// 運用のため、cache_version の世代でゲートすると正しい行まで 404 になってしまう）。
/// 不変条件: 各軸の床 ≤ その軸の現行 `…-vN` の N。
public let businessBreakdownMinServableVersion = 1
public let geographyBreakdownMinServableVersion = 1
public let employeesBreakdownMinServableVersion = 1
public let researchAndDevelopmentBreakdownMinServableVersion = 1

/// 軸に対応する read 床。未知の軸は business 床。
public func breakdownMinServableVersion(forAxis axis: String) -> Int {
    switch axis {
    case breakdownAxisGeography: return geographyBreakdownMinServableVersion
    case breakdownAxisEmployees: return employeesBreakdownMinServableVersion
    case breakdownAxisResearchAndDevelopment: return researchAndDevelopmentBreakdownMinServableVersion
    default: return businessBreakdownMinServableVersion
    }
}

/// `breakdown-business-vN` / `breakdown-geography-vN` / `breakdown-employees-vN` /
/// `breakdown-research-and-development-vN` / 旧 `breakdown-vN` から世代番号 N を取り出す。
/// パース不能なら nil（非 servable 扱い）。
public func breakdownCacheVersionNumber(_ version: String) -> Int? {
    let prefixes = [
        "breakdown-business-v", "breakdown-geography-v", "breakdown-employees-v",
        "breakdown-research-and-development-v", "breakdown-v",
    ]
    for prefix in prefixes where version.hasPrefix(prefix) {
        let suffix = version.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
        return n
    }
    return nil
}

/// xbrl_facts と同じく決定的ロジックで解決され、`cache_version` 世代で再計算・read 可否を
/// 判定すべき source かどうか。LLM 経由（segment_info_llm 等）は content_hash + needs_review
/// でのみ扱うためここには含めない（`isServableBreakdown` / 内訳取り込み ingest の staleness 判定で共用）。
public func isVersionGatedBreakdownSource(_ source: String) -> Bool {
    source == breakdownSourceXbrlFacts || source == breakdownSourceNotApplicable
}

/// 格納行が read 可能か。xbrl_facts / not_applicable 経由（決定的）は cache_version が当該軸の床以上の
/// ときのみ（バンプで全件再計算してよい）。LLM 経由は存在すれば常に read 可能（据え置き運用。
/// docs/breakdown-normalization-concept.md「今後の検討事項8」参照）。
/// `axis` 省略時は business（現行 REST/MCP 公開軸）。
public func isServableBreakdown(source: String, cacheVersion: String, axis: String = "business") -> Bool {
    guard isVersionGatedBreakdownSource(source) else { return true }
    guard let n = breakdownCacheVersionNumber(cacheVersion) else { return false }
    return n >= breakdownMinServableVersion(forAxis: axis)
}

/// BreakdownRow（内部型）の公開 Codable 写経。
public struct BreakdownRowPayload: Codable, Sendable, Equatable {
    public var labelRaw: String
    // 表示用の解決済みラベル。xbrl_facts 経路は XBRL ラベルリンクベースの日本語ラベル（無ければ
    // labelRaw にフォールバック）、html_table/LLM 経路は元々開示書類のテキストのため labelRaw と同値。
    public var label: String
    public var amount: Double
    public var profit: Double?
    public var rowKind: String

    private enum CodingKeys: String, CodingKey {
        case labelRaw, label, amount, profit, rowKind
    }

    public init(labelRaw: String, label: String, amount: Double, profit: Double?, rowKind: String) {
        self.labelRaw = labelRaw
        self.label = label
        self.amount = amount
        self.profit = profit
        self.rowKind = rowKind
    }

    /// 手書き実装（`StatementLine.init(from:)` と同型、`StatementContract.swift` 参照）: `label` を
    /// 非 Optional のまま `decodeIfPresent` で読み、無ければ `labelRaw` にフォールバックする。
    /// `company_breakdowns.payload` は JSON カラムで Fluent が直接デコードするため、`label` 追加前に
    /// 格納された本番行（business/geography 225社分、`label` キーが無い）は合成 `Decodable` では
    /// `keyNotFound` で読み取り自体が失敗し、REST 読み出しも ingest の既存行チェックも共倒れする
    /// （cache_version バンプで再計算される前の行が対象。Opus 監査で発見、2026-08-03）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labelRaw = try container.decode(String.self, forKey: .labelRaw)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? labelRaw
        amount = try container.decode(Double.self, forKey: .amount)
        profit = try container.decodeIfPresent(Double.self, forKey: .profit)
        rowKind = try container.decode(String.self, forKey: .rowKind)
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
            "label": label,
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
