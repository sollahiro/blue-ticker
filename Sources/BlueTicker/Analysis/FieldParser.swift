// FieldSet 正規化レイヤー
// Python の blue_ticker/analysis/field_parser.py 相当

import Foundation

// MARK: - Types

struct FieldValue {
    var current: Double?
    var prior: Double?
}

typealias FieldSet = [String: FieldValue]

struct ResolvedItem {
    var tag: String?
    var current: Double?
    var prior: Double?
}

// MARK: - Accounting Standard Detection

func detectAccountingStandard(_ tagElements: XbrlTagElements) -> String {
    let hasUSGAAP = tagElements.keys.contains(where: { $0.contains("USGAAP") })
    let hasIFRS = tagElements.keys.contains(where: { $0.contains("IFRS") })
    if hasUSGAAP && !hasIFRS { return "US-GAAP" }
    if hasIFRS { return "IFRS" }
    return "J-GAAP"
}

// MARK: - FieldSet Builders

/// XbrlTagElements から Duration（フロー）コンテキストを正規化して FieldSet を返す。
func fieldSetFromDuration(
    _ tagElements: XbrlTagElements,
    financialTags: Set<String>? = nil
) -> FieldSet {
    var fieldSet = normalizeConsolidatedDuration(tagElements)

    let check = financialTags.map { ft in tagElements.filter { ft.contains($0.key) } } ?? tagElements
    if !ContextHelpers.hasNonConsolidatedContexts(check) {
        let ncSet = normalizeNonConsolidatedDuration(tagElements)
        for (tag, fv) in ncSet where fieldSet[tag] == nil {
            fieldSet[tag] = fv
        }
    }
    // Instant コンテキストのみのタグ（会計基準マーカー等）も存在記録として追加
    for tag in tagElements.keys where fieldSet[tag] == nil {
        fieldSet[tag] = FieldValue(current: nil, prior: nil)
    }
    return fieldSet
}

/// XbrlTagElements から Instant（残高）コンテキストを正規化して FieldSet を返す。
func fieldSetFromInstant(
    _ tagElements: XbrlTagElements,
    financialTags: Set<String>? = nil
) -> FieldSet {
    var fieldSet = normalizeConsolidatedInstant(tagElements)

    let check = financialTags.map { ft in tagElements.filter { ft.contains($0.key) } } ?? tagElements
    if !ContextHelpers.hasNonConsolidatedContexts(check) {
        let ncSet = normalizeNonConsolidatedInstant(tagElements)
        for (tag, fv) in ncSet where fieldSet[tag] == nil {
            fieldSet[tag] = fv
        }
    }
    return fieldSet
}

/// XbrlTagElements から非連結 Duration コンテキストのみを正規化して FieldSet を返す。
/// 自己株式取得の非連結フォールバック解決に使用する。
func fieldSetFromNonConsolidatedDuration(_ tagElements: XbrlTagElements) -> FieldSet {
    normalizeNonConsolidatedDuration(tagElements)
}

// MARK: - Normalization (private)

private func normalizeConsolidated(
    _ tagElements: XbrlTagElements,
    exactCurrent: Set<String>,
    exactPrior: Set<String>,
    isCurrent: (String) -> Bool,
    isPrior: (String) -> Bool
) -> FieldSet {
    var fieldSet: FieldSet = [:]
    for (tag, ctxMap) in tagElements {
        var current: Double?
        var prior: Double?

        for (ctx, val) in ctxMap {
            if exactCurrent.contains(ctx) { current = val }
            else if exactPrior.contains(ctx) { prior = val }
        }

        if current == nil || prior == nil {
            for (ctx, val) in ctxMap {
                if current == nil && isCurrent(ctx) { current = val }
                if prior == nil && isPrior(ctx) { prior = val }
            }
        }

        if current != nil || prior != nil {
            fieldSet[tag] = FieldValue(current: current, prior: prior)
        }
    }
    return fieldSet
}

private func normalizeNonConsolidated(
    _ tagElements: XbrlTagElements,
    exactCurrent: Set<String>,
    exactPrior: Set<String>,
    isCurrent: (String) -> Bool,
    isPrior: (String) -> Bool
) -> FieldSet {
    var fieldSet: FieldSet = [:]
    let currentPatterns = Array(exactCurrent)
    let priorPatterns = Array(exactPrior)
    for (tag, ctxMap) in tagElements {
        var current: Double?
        var prior: Double?

        for (ctx, val) in ctxMap {
            if isCurrent(ctx) {
                if isPureNonConsolidated(ctx, patterns: currentPatterns) {
                    current = val
                } else if current == nil {
                    current = val
                }
            } else if isPrior(ctx) {
                if isPureNonConsolidated(ctx, patterns: priorPatterns) {
                    prior = val
                } else if prior == nil {
                    prior = val
                }
            }
        }

        if current != nil || prior != nil {
            fieldSet[tag] = FieldValue(current: current, prior: prior)
        }
    }
    return fieldSet
}

private func isPureNonConsolidated(_ ctx: String, patterns: [String]) -> Bool {
    return patterns.contains(where: {
        ctx == "\($0)_NonConsolidatedMember" || ctx == "\($0)_NonConsolidated"
    })
}

private func normalizeConsolidatedDuration(_ tagElements: XbrlTagElements) -> FieldSet {
    normalizeConsolidated(
        tagElements,
        exactCurrent: Set(Xbrl.durationContextPatterns),
        exactPrior: Set(Xbrl.priorDurationContextPatterns),
        isCurrent: ContextHelpers.isConsolidatedDuration,
        isPrior: ContextHelpers.isConsolidatedPriorDuration
    )
}

private func normalizeNonConsolidatedDuration(_ tagElements: XbrlTagElements) -> FieldSet {
    normalizeNonConsolidated(
        tagElements,
        exactCurrent: Set(Xbrl.durationContextPatterns),
        exactPrior: Set(Xbrl.priorDurationContextPatterns),
        isCurrent: ContextHelpers.isNonConsolidatedDuration,
        isPrior: ContextHelpers.isNonConsolidatedPriorDuration
    )
}

private func normalizeConsolidatedInstant(_ tagElements: XbrlTagElements) -> FieldSet {
    normalizeConsolidated(
        tagElements,
        exactCurrent: Set(Xbrl.instantContextPatterns),
        exactPrior: Set(Xbrl.priorInstantContextPatterns),
        isCurrent: ContextHelpers.isConsolidatedInstant,
        isPrior: ContextHelpers.isConsolidatedPriorInstant
    )
}

private func normalizeNonConsolidatedInstant(_ tagElements: XbrlTagElements) -> FieldSet {
    normalizeNonConsolidated(
        tagElements,
        exactCurrent: Set(Xbrl.instantContextPatterns),
        exactPrior: Set(Xbrl.priorInstantContextPatterns),
        isCurrent: ContextHelpers.isNonConsolidatedInstant,
        isPrior: ContextHelpers.isNonConsolidatedPriorInstant
    )
}

// MARK: - Resolution Functions

/// 候補タグを優先順に試し、current/prior いずれかが存在する最初のタグを返す。
func resolveItem(_ fieldSet: FieldSet, tags: [String]) -> ResolvedItem {
    for tag in tags {
        if let fv = fieldSet[tag], fv.current != nil || fv.prior != nil {
            return ResolvedItem(tag: tag, current: fv.current, prior: fv.prior)
        }
    }
    return ResolvedItem(tag: nil, current: nil, prior: nil)
}

/// current 値があるタグを優先。なければ prior のみのタグを返す。
func resolveItemPreferCurrent(_ fieldSet: FieldSet, tags: [String]) -> ResolvedItem {
    var fallback: ResolvedItem? = nil
    for tag in tags {
        if let fv = fieldSet[tag] {
            if fv.current != nil {
                return ResolvedItem(tag: tag, current: fv.current, prior: fv.prior)
            }
            if fallback == nil && fv.prior != nil {
                fallback = ResolvedItem(tag: tag, current: nil, prior: fv.prior)
            }
        }
    }
    return fallback ?? ResolvedItem(tag: nil, current: nil, prior: nil)
}

/// 複数コンポーネントを積み上げ合算する。
/// componentTagLists: [[候補タグ]] - 各要素が1コンポーネント
func resolveAggregate(_ fieldSet: FieldSet, componentTagLists: [[String]]) -> ResolvedItem {
    var currentTotal = 0.0
    var priorTotal = 0.0
    var currentFound = false
    var priorFound = false
    var tagsUsed: [String] = []

    for candidateTags in componentTagLists {
        let item = resolveItem(fieldSet, tags: candidateTags)
        if let t = item.tag { tagsUsed.append(t) }
        if let c = item.current { currentTotal += c; currentFound = true }
        if let p = item.prior { priorTotal += p; priorFound = true }
    }

    return ResolvedItem(
        tag: tagsUsed.isEmpty ? nil : tagsUsed.joined(separator: "+"),
        current: currentFound ? currentTotal : nil,
        prior: priorFound ? priorTotal : nil
    )
}

/// minuend − subtrahend で値を導出する。
func deriveSubtraction(_ fieldSet: FieldSet, minuendTags: [String], subtrahendTags: [String]) -> ResolvedItem {
    let m = resolveItem(fieldSet, tags: minuendTags)
    let s = resolveItem(fieldSet, tags: subtrahendTags)
    let current: Double? = m.current != nil && s.current != nil ? m.current! - s.current! : nil
    let prior: Double? = m.prior != nil && s.prior != nil ? m.prior! - s.prior! : nil
    let tag: String? = (m.tag != nil && s.tag != nil) ? "\(m.tag!)-\(s.tag!)" : nil
    return ResolvedItem(tag: tag, current: current, prior: prior)
}

// MARK: - FieldSet から XbrlTagElements を生成（既存コードとの橋渡し）

/// XBRL ディレクトリから Duration FieldSet を構築する。
func parseDurationFieldSet(in dir: URL, allowedTags: Set<String>? = nil) -> FieldSet {
    let tagElements = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
    let filtered: XbrlTagElements = allowedTags.map { allowed in
        tagElements.filter { allowed.contains($0.key) }
    } ?? tagElements
    return fieldSetFromDuration(filtered)
}

/// XBRL ディレクトリから Instant FieldSet を構築する。
func parseInstantFieldSet(in dir: URL, allowedTags: Set<String>? = nil) -> FieldSet {
    let tagElements = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
    let filtered: XbrlTagElements = allowedTags.map { allowed in
        tagElements.filter { allowed.contains($0.key) }
    } ?? tagElements
    return fieldSetFromInstant(filtered)
}
