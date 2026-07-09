// Stage 5（有報セクションテキスト）の格納用 Codable 契約。
// filing-content を「serving=read-only」に載せるため、ingest 時に抽出したセクション本文を
// この payload で Neon（company_filing_sections）へ格納し、read は DB から復元して返す。
//
// 内部型 SegmentResult（Analysis/SegmentExtractor.swift, internal）は露出させず、
// Stage 3 の XbrlFact → XbrlFactRecord 写経と同じパターンで SegmentPayload へ写す。
// Foundation のみ依存（BlueTickerCore/Models 配置。Fluent モデルは BltServerCore 側）。

import Foundation

/// Neon Stage 5 キャッシュ（company_filing_sections.cache_version）の抽出／スキーマバージョン。
/// blueTickerVersion 非連動（fin-v2 / facts-v1 と同思想）。抽出ロジック（XBRLParser / SegmentExtractor /
/// cleanText の cap 等）または本 payload スキーマの意味を変えたときのみバンプする。
/// セクションの「追加」はバンプ不要（section_keys 列の不一致で当該行のみ再抽出される）。
public let filingSectionsCacheVersion = "sections-v2"

/// filing-content read（REST）が 200 を返す最低抽出バージョン番号（`sections-vN` の N）。
/// **明示指定**であり、「現行から N つ前」の機械オフセットではない。人手で上げる。
/// ingest の stale 判定・書き込みは常に `filingSectionsCacheVersion`。床未満の行は 404。
/// 床の引き上げは、該当旧版の stale 消化が終わってから行う。
/// 不変条件: `filingSectionsMinServableVersion` ≤ 現行 `sections-vN` の N。
public let filingSectionsMinServableVersion = 1

/// `sections-vN` 形式から世代番号 N を取り出す。パース不能なら nil（非 servable 扱い）。
public func filingSectionsCacheVersionNumber(_ version: String) -> Int? {
    guard version.hasPrefix("sections-v") else { return nil }
    let suffix = version.dropFirst("sections-v".count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
    return n
}

/// 格納行の `cache_version` が read 床以上か。文字列辞書順比較は使わない。
public func isServableFilingSectionsCacheVersion(_ version: String) -> Bool {
    guard let n = filingSectionsCacheVersionNumber(version) else { return false }
    return n >= filingSectionsMinServableVersion
}

/// 現在の抽出対象セクション集合を正規化した文字列（sorted・カンマ結合）。
/// company_filing_sections.section_keys に格納し、取り込み時に照合する。
/// セクションを追加すると本文字列が変わり、既存行が stale 判定され当該行のみ再抽出される
/// （cache_version バンプ不要）。BltServerCore はこの値を受け取るだけで内部定数を知らない。
public func currentFilingSectionKeys() -> String {
    (Array(xbrlSections.keys) + SegmentExtractor.specialSectionKeys).sorted().joined(separator: ",")
}

/// 書類1件分の抽出済みセクション。texts（本文）と specials（セグメント・地域別表）を型分離して持つ。
/// 公開レスポンス（{code, doc_id, sections}）の sections は String と dict の混在だが、格納では
/// 型で分け、read 時に `sectionsObject(sections:)` でマージして現行契約の形へ復元する。
public struct FilingSectionsPayload: Codable, Sendable, Equatable {
    /// xbrlSections 由来の本文テキスト（key → 本文）。ingest は全 key を格納する（未検出は ""）。
    public var texts: [String: String]
    /// segments / geography（key → セグメント表）。
    public var specials: [String: SegmentPayload]

    public init(texts: [String: String], specials: [String: SegmentPayload]) {
        self.texts = texts
        self.specials = specials
    }

    /// 現行公開契約の sections 形（[String: Any]：本文は String、特殊は dict）を復元する。
    /// `sections` 指定があればその key に絞る（未知 key は無視）。省略時は格納済み全 key。
    public func sectionsObject(sections: [String]?) -> [String: Any] {
        let keys = sections ?? (Array(texts.keys) + Array(specials.keys))
        var out: [String: Any] = [:]
        for key in keys {
            if let text = texts[key] {
                out[key] = text
            } else if let seg = specials[key] {
                out[key] = seg.toDictionary()
            }
        }
        return out
    }
}

/// SegmentResult（内部型）の公開 Codable 写経。toDictionary() は SegmentResult と同一キー構造。
public struct SegmentPayload: Codable, Sendable, Equatable {
    public var method: String
    public var tables: [SegmentTablePayload]
    public var facts: [SegmentFactPayload]

    public init(method: String, tables: [SegmentTablePayload], facts: [SegmentFactPayload]) {
        self.method = method
        self.tables = tables
        self.facts = facts
    }

    /// SegmentResult.toDictionary() と同じ形（remote CLI が SegmentResult(dictionary:) で復元できる）。
    public func toDictionary() -> [String: Any] {
        let tablesArr: [[String: Any]] = tables.map { t in
            var d: [String: Any] = ["heading": t.heading, "markdown": t.markdown]
            if let p = t.period { d["period"] = p }
            return d
        }
        let factsArr: [[String: Any]] = facts.map { f in
            var d: [String: Any] = [
                "tag": f.tag, "contextRef": f.contextRef,
                "dimensions": f.dimensions, "value": f.value,
            ]
            if let l = f.label { d["label"] = l }
            if let u = f.unitRef { d["unitRef"] = u }
            if let dec = f.decimals { d["decimals"] = dec }
            return d
        }
        return ["method": method, "tables": tablesArr, "facts": factsArr]
    }
}

public struct SegmentTablePayload: Codable, Sendable, Equatable {
    public var heading: String
    public var markdown: String
    public var period: String?

    public init(heading: String, markdown: String, period: String?) {
        self.heading = heading
        self.markdown = markdown
        self.period = period
    }
}

public struct SegmentFactPayload: Codable, Sendable, Equatable {
    public var tag: String
    public var contextRef: String
    public var dimensions: [String: String]
    public var value: Double
    public var label: String?
    public var unitRef: String?
    public var decimals: String?

    public init(
        tag: String, contextRef: String, dimensions: [String: String], value: Double,
        label: String?, unitRef: String?, decimals: String?
    ) {
        self.tag = tag
        self.contextRef = contextRef
        self.dimensions = dimensions
        self.value = value
        self.label = label
        self.unitRef = unitRef
        self.decimals = decimals
    }
}
