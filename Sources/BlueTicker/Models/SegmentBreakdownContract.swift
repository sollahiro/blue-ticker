// Stage 6（事業別・地域別売上の正規化スナップショット）の格納用 Codable 契約。
// docs/segment-normalization-concept.md「今後の検討事項5」参照。
//
// 内部型 BreakdownSnapshot/BreakdownRow/LLMBreakdownAudit（Analysis/SegmentNormalizer.swift,
// Analysis/SegmentBreakdownLLMNormalizer.swift, internal）は露出させず、Stage 5 の
// SegmentResult → SegmentPayload 写経と同じパターンで公開 Codable 型へ写す。
// Foundation のみ依存（BlueTickerCore/Models 配置。Fluent モデルは BltServerCore 側）。

import Foundation

/// Neon Stage 6 キャッシュ（company_segment_breakdowns.cache_version）の契約スキーマバージョン。
/// blueTickerVersion 非連動。`BreakdownSnapshotPayload` の意味を変える破壊的変更のみバンプする。
/// LLM 経由の行（source != "xbrl_facts"）は本バージョンのバンプだけでは再計算しない
/// （content_hash 一致・needs_review=false の行はそのまま据え置く。今後の検討事項8参照）。
public let segmentBreakdownCacheVersion = "breakdown-v1"

/// `SegmentBusinessBreakdownResolver`（business 軸）が解決に使った経路。
/// 監査・再計算方針の判断に使う（xbrl_facts は決定的でバンプ全件再計算してよいが、
/// html_table_llm / revenue_recognition_llm は content_hash + needs_review でのみ再計算する）。
/// `.notFound` は行を作らない方針のため、この文字列が DB に書かれることはない
/// （欠ける軸は出さない。今後の検討事項3のチェックリスト参照）。
public let segmentBreakdownSourceXbrlFacts = "xbrl_facts"
public let segmentBreakdownSourceHtmlTableLLM = "html_table_llm"
public let segmentBreakdownSourceRevenueRecognitionLLM = "revenue_recognition_llm"

/// BreakdownRow（内部型）の公開 Codable 写経。
public struct BreakdownRowPayload: Codable, Sendable, Equatable {
    public var labelRaw: String
    public var amount: Double
    public var share: Double?
    public var profit: Double?
    public var rowKind: String

    public init(labelRaw: String, amount: Double, share: Double?, profit: Double?, rowKind: String) {
        self.labelRaw = labelRaw
        self.amount = amount
        self.share = share
        self.profit = profit
        self.rowKind = rowKind
    }
}

/// BreakdownSnapshot（内部型）の公開 Codable 写経。company_segment_breakdowns.payload の中身。
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
/// （どの表・期間列・単位を採用したか）。生レスポンス全文のログ化は別途未着手（今後の検討事項8）。
public struct LLMBreakdownAuditPayload: Codable, Sendable, Equatable {
    public var sourceTableIndex: Int?
    public var periodColumn: String?
    public var unit: String
    public var notes: String

    public init(sourceTableIndex: Int?, periodColumn: String?, unit: String, notes: String) {
        self.sourceTableIndex = sourceTableIndex
        self.periodColumn = periodColumn
        self.unit = unit
        self.notes = notes
    }
}
