// 手動 XBRL 上書き（ingest 最終段）。訂正 overlay のあとに、会社-FY の個別 item だけを差し替える。
// overlay 自体は触らない。公開 payload の形は変えない（source / warnings の既存スロットを再利用）。
// cache_version はバンプしない。

import Foundation

/// `manual_xbrl_overrides.item` の閉集合。未知値は受理しない。
public enum ManualXbrlOverrideItem: String, Codable, Sendable, CaseIterable {
    case capex = "capex"
    case policyHoldingSecurities = "policy_holding_securities"
}

/// statement-notes の `source`。公開 `note` JSON には出さない（既存の source 列パターン）。
public let statementNoteSourceManualOverride = "manual_override"

/// 公開 `warnings` に載せる provenance トークン接頭辞。形は既存配列のまま。
public let manualXbrlOverrideWarningPrefix = "manual_override"

/// WRITE 経路（`overrides add` / `overrides revoke`）が要求する接続 URL。
public let manualXbrlOverrideWriteDatabaseURLEnv = "BLT_NEON_WRITE_DATABASE_URL"

public func manualXbrlOverrideWarningToken(
    item: ManualXbrlOverrideItem, sourceDocID: String
) -> String {
    "\(manualXbrlOverrideWarningPrefix):item=\(item.rawValue):source_doc_id=\(sourceDocID)"
}

/// capex 上書き。`value * 10^scale` が円。`unit` は `JPY` のみ。
public struct CapexManualOverridePayload: Equatable, Sendable {
    public var value: Double
    public var unit: String
    public var scale: Int

    public init(value: Double, unit: String, scale: Int) {
        self.value = value
        self.unit = unit
        self.scale = scale
    }

    /// XBRL の scale と同じく、表示値に 10^scale を掛けて円にする。
    public var yen: Double { value * pow(10.0, Double(scale)) }

    /// financials / Summary の格納単位（百万円）。
    public var millionYen: Double { yen / Financial.millionYen }
}

/// 政策保有株式上書き。公開 `StatementNotePayload` と同じ行形（当期。前期は現行モデルに無い）。
public struct PolicyHoldingSecuritiesManualOverridePayload: Sendable {
    public var securities: [PolicyHoldingSecurityPayload]?
    public var policyHoldingSummary: PolicyHoldingAggregateSummaryPayload?

    public init(
        securities: [PolicyHoldingSecurityPayload]?,
        policyHoldingSummary: PolicyHoldingAggregateSummaryPayload?
    ) {
        self.securities = securities
        self.policyHoldingSummary = policyHoldingSummary
    }
}

public enum ManualXbrlOverridePayload: Sendable {
    case capex(CapexManualOverridePayload)
    case policyHoldingSecurities(PolicyHoldingSecuritiesManualOverridePayload)
}

/// 検証済み上書き 1 件（DB 行の値オブジェクト。id / 時刻はストア側）。
public struct ManualXbrlOverrideRecord: Sendable {
    public var edinetCode: String
    public var periodEnd: String
    public var item: ManualXbrlOverrideItem
    public var payload: ManualXbrlOverridePayload
    public var sourceDocID: String
    public var sourcePage: String
    public var reason: String
    public var createdBy: String

    public init(
        edinetCode: String, periodEnd: String, item: ManualXbrlOverrideItem,
        payload: ManualXbrlOverridePayload, sourceDocID: String, sourcePage: String,
        reason: String, createdBy: String
    ) {
        self.edinetCode = edinetCode
        self.periodEnd = periodEnd
        self.item = item
        self.payload = payload
        self.sourceDocID = sourceDocID
        self.sourcePage = sourcePage
        self.reason = reason
        self.createdBy = createdBy
    }
}

public struct ManualXbrlOverrideValidationError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// overlay 後・派生構築前の会社-FY スナップショット。item 単位の needs_review を持つ。
public struct ManualXbrlCompanyYearState: Sendable {
    public var capexMillionYen: Double?
    public var capexNeedsReview: Bool
    public var capexWarnings: [String]
    public var capexSource: String
    public var policyHoldings: StatementNotePayload?
    public var policyHoldingsNeedsReview: Bool
    public var policyHoldingsWarnings: [String]
    public var policyHoldingsSource: String
    /// 上書き対象外のフラグ（他 note / breakdown）。上書きしても残す。
    public var otherNeedsReview: Bool

    public init(
        capexMillionYen: Double? = nil, capexNeedsReview: Bool = false,
        capexWarnings: [String] = [], capexSource: String = statementNoteSourceXbrlFacts,
        policyHoldings: StatementNotePayload? = nil, policyHoldingsNeedsReview: Bool = false,
        policyHoldingsWarnings: [String] = [],
        policyHoldingsSource: String = statementNoteSourceXbrlFacts,
        otherNeedsReview: Bool = false
    ) {
        self.capexMillionYen = capexMillionYen
        self.capexNeedsReview = capexNeedsReview
        self.capexWarnings = capexWarnings
        self.capexSource = capexSource
        self.policyHoldings = policyHoldings
        self.policyHoldingsNeedsReview = policyHoldingsNeedsReview
        self.policyHoldingsWarnings = policyHoldingsWarnings
        self.policyHoldingsSource = policyHoldingsSource
        self.otherNeedsReview = otherNeedsReview
    }
}

/// overlay 済みの会社-FY 状態へ、対象 item だけを最後に載せる。他 item のフラグは触らない。
public func applyManualXbrlOverrides(
    to state: ManualXbrlCompanyYearState, overrides: [ManualXbrlOverrideRecord]
) -> ManualXbrlCompanyYearState {
    var next = state
    for override in overrides {
        switch override.payload {
        case .capex(let payload):
            next.capexMillionYen = payload.millionYen
            next.capexNeedsReview = false
            next.capexWarnings = provenanceWarnings(
                existing: next.capexWarnings, item: override.item, sourceDocID: override.sourceDocID)
            next.capexSource = statementNoteSourceManualOverride
        case .policyHoldingSecurities(let payload):
            var note = next.policyHoldings ?? StatementNotePayload()
            note.securities = payload.securities
            note.policyHoldingSummary = payload.policyHoldingSummary
            note.needsReview = false
            note.warnings = provenanceWarnings(
                existing: note.warnings,
                item: override.item, sourceDocID: override.sourceDocID)
            next.policyHoldings = note
            next.policyHoldingsNeedsReview = false
            next.policyHoldingsWarnings = note.warnings
            next.policyHoldingsSource = statementNoteSourceManualOverride
        }
    }
    return next
}

/// 政策保有株式 note の解決結果へ上書きを載せる。失敗・対象外でも payload があれば resolved にする。
public func applyManualPolicyHoldingOverride(
    to result: StatementNoteResolveResult, override: ManualXbrlOverrideRecord
) -> StatementNoteResolveResult {
    guard override.item == .policyHoldingSecurities,
        case .policyHoldingSecurities(let payload) = override.payload
    else { return result }

    var base = StatementNotePayload()
    var contentHash = ""
    if case .resolved(let existing, _, let hash) = result {
        base = existing
        contentHash = hash
    }
    base.securities = payload.securities
    base.policyHoldingSummary = payload.policyHoldingSummary
    base.needsReview = false
    base.warnings = provenanceWarnings(
        existing: base.warnings, item: override.item, sourceDocID: override.sourceDocID)
    let overrideHash = manualPolicyHoldingOverrideContentHash(
        payload, sourceDocID: override.sourceDocID)
    return .resolved(
        payload: base, source: statementNoteSourceManualOverride,
        contentHash: contentHash.isEmpty ? overrideHash : contentHash + ";" + overrideHash)
}

/// financials 計算結果の当該 FY `capex`（百万円）だけを差し替える。
public func applyingManualCapexOverrides(
    to result: FinancialsComputeResult, overrides: [ManualXbrlOverrideRecord]
) -> FinancialsComputeResult {
    guard case .success(var response) = result else { return result }
    var changed = false
    for override in overrides {
        guard case .capex(let payload) = override.payload else { continue }
        if response.replaceCapex(periodEnd: override.periodEnd, millionYen: payload.millionYen) {
            changed = true
        }
    }
    return changed ? .success(response) : result
}

public func parseManualXbrlOverrideItem(_ raw: String) throws -> ManualXbrlOverrideItem {
    guard let item = ManualXbrlOverrideItem(rawValue: raw) else {
        throw ManualXbrlOverrideValidationError(
            "unknown item '\(raw)' (allowed: \(ManualXbrlOverrideItem.allCases.map(\.rawValue).joined(separator: ", ")))"
        )
    }
    return item
}

/// `overrides add` の JSON ファイル。未知キーは拒否する。
public func parseManualXbrlOverrideAddFile(
    _ data: Data, createdByOverride: String? = nil
) throws -> ManualXbrlOverrideRecord {
    let object = try jsonObject(from: data)
    try rejectUnknownKeys(
        object, allowed: manualXbrlOverrideAddFileKeys, label: "override file")
    let edinetCode = try requireNonEmptyString(object, "edinet_code")
    let periodEnd = try requirePeriodEnd(object["period_end"])
    let item = try parseManualXbrlOverrideItem(try requireNonEmptyString(object, "item"))
    let sourceDocID = try requireNonEmptyString(object, "source_doc_id")
    let sourcePage = try requireNonEmptyString(object, "source_page")
    let reason = try requireNonEmptyString(object, "reason")
    let createdBy = try requireCreatedBy(
        fileValue: stringValue(object["created_by"]), override: createdByOverride)
    guard let payloadValue = object["payload"] else {
        throw ManualXbrlOverrideValidationError("missing key 'payload'")
    }
    guard let payloadObject = payloadValue as? [String: Any] else {
        throw ManualXbrlOverrideValidationError("'payload' must be an object")
    }
    let payload = try parseManualXbrlOverridePayload(item: item, object: payloadObject)
    return ManualXbrlOverrideRecord(
        edinetCode: edinetCode, periodEnd: periodEnd, item: item, payload: payload,
        sourceDocID: sourceDocID, sourcePage: sourcePage, reason: reason, createdBy: createdBy)
}

public func parseManualXbrlOverridePayload(
    item: ManualXbrlOverrideItem, object: [String: Any]
) throws -> ManualXbrlOverridePayload {
    switch item {
    case .capex:
        return .capex(try parseCapexManualOverridePayload(object))
    case .policyHoldingSecurities:
        return .policyHoldingSecurities(try parsePolicyHoldingManualOverridePayload(object))
    }
}

public func manualXbrlOverridePayloadJSONObject(_ payload: ManualXbrlOverridePayload) -> [String: Any] {
    switch payload {
    case .capex(let capex):
        return ["value": capex.value, "unit": capex.unit, "scale": capex.scale]
    case .policyHoldingSecurities(let holdings):
        return [
            "securities": holdings.securities.map { $0.map { $0.jsonObject() } } as Any? ?? NSNull(),
            "policy_holding_summary": holdings.policyHoldingSummary?.jsonObject() as Any? ?? NSNull(),
        ]
    }
}

func parseCapexManualOverridePayload(_ object: [String: Any]) throws -> CapexManualOverridePayload {
    try rejectUnknownKeys(object, allowed: ["value", "unit", "scale"], label: "capex payload")
    let value = try requireFiniteNumber(object, "value")
    let unit = try requireNonEmptyString(object, "unit")
    guard unit == "JPY" else {
        throw ManualXbrlOverrideValidationError("capex unit must be 'JPY' (got '\(unit)')")
    }
    let scale = try requireInt(object, "scale")
    guard (-6...9).contains(scale) else {
        throw ManualXbrlOverrideValidationError("capex scale must be an integer in -6...9 (got \(scale))")
    }
    let payload = CapexManualOverridePayload(value: value, unit: unit, scale: scale)
    guard payload.yen.isFinite, payload.yen >= 0 else {
        throw ManualXbrlOverrideValidationError("capex yen value must be a finite non-negative number")
    }
    return payload
}

func parsePolicyHoldingManualOverridePayload(
    _ object: [String: Any]
) throws -> PolicyHoldingSecuritiesManualOverridePayload {
    try rejectUnknownKeys(
        object, allowed: ["securities", "policy_holding_summary"],
        label: "policy_holding_securities payload")
    let securities = try parseOptionalSecurityRows(object["securities"])
    let summary = try parseOptionalHoldingSummary(object["policy_holding_summary"])
    if (securities == nil || securities?.isEmpty == true) && summary == nil {
        throw ManualXbrlOverrideValidationError(
            "policy_holding_securities payload needs securities and/or policy_holding_summary")
    }
    return PolicyHoldingSecuritiesManualOverridePayload(
        securities: securities, policyHoldingSummary: summary)
}

private let manualXbrlOverrideAddFileKeys: Set<String> = [
    "edinet_code", "period_end", "item", "payload", "source_doc_id", "source_page", "reason",
    "created_by",
]

private func provenanceWarnings(
    existing: [String], item: ManualXbrlOverrideItem, sourceDocID: String
) -> [String] {
    let kept = existing.filter { !$0.hasPrefix(xbrlOverlayRegressionWarningPrefix) }
    var unique: [String] = []
    for warning in kept where !unique.contains(warning) {
        unique.append(warning)
    }
    let token = manualXbrlOverrideWarningToken(item: item, sourceDocID: sourceDocID)
    if unique.contains(token) { return unique }
    return unique + [token]
}

private func manualPolicyHoldingOverrideContentHash(
    _ payload: PolicyHoldingSecuritiesManualOverridePayload, sourceDocID: String
) -> String {
    let rows = (payload.securities ?? []).map {
        "\($0.issuerName)=\($0.numberOfShares ?? -1),\($0.carryingAmount ?? -1),\($0.isDeemedHolding)"
    }.joined(separator: ";")
    let summary = payload.policyHoldingSummary.map {
        "summary=\($0.unlistedIssueCount ?? -1),\($0.unlistedCarryingAmount ?? -1),"
            + "\($0.listedIssueCount ?? -1),\($0.listedCarryingAmount ?? -1)"
    } ?? ""
    return "manual_override:\(sourceDocID):\(rows);\(summary)"
}

private func jsonObject(from data: Data) throws -> [String: Any] {
    let parsed: Any
    do {
        parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw ManualXbrlOverrideValidationError("invalid JSON: \(error.localizedDescription)")
    }
    guard let object = parsed as? [String: Any] else {
        throw ManualXbrlOverrideValidationError("JSON root must be an object")
    }
    return object
}

private func rejectUnknownKeys(
    _ object: [String: Any], allowed: Set<String>, label: String
) throws {
    let extra = Set(object.keys).subtracting(allowed)
    if !extra.isEmpty {
        throw ManualXbrlOverrideValidationError(
            "\(label) has unknown keys: \(extra.sorted().joined(separator: ", "))")
    }
}

private func requireNonEmptyString(_ object: [String: Any], _ key: String) throws -> String {
    guard object[key] != nil else {
        throw ManualXbrlOverrideValidationError("missing key '\(key)'")
    }
    guard let value = stringValue(object[key]), !value.isEmpty else {
        throw ManualXbrlOverrideValidationError("'\(key)' must be a non-empty string")
    }
    return value
}

private func requireCreatedBy(fileValue: String?, override: String?) throws -> String {
    let trimmedOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedOverride.isEmpty { return trimmedOverride }
    let trimmedFile = fileValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedFile.isEmpty { return trimmedFile }
    throw ManualXbrlOverrideValidationError(
        "created_by is required (JSON key or --created-by)")
}

private func requirePeriodEnd(_ value: Any?) throws -> String {
    guard let raw = stringValue(value), !raw.isEmpty else {
        throw ManualXbrlOverrideValidationError("'period_end' must be a non-empty string")
    }
    let normalized = normalizeDateFormat(raw)
    guard let normalized, normalized.count == DateFormat.hyphenatedLength else {
        throw ManualXbrlOverrideValidationError(
            "period_end must be YYYY-MM-DD (got '\(raw)')")
    }
    return normalized
}

private func requireFiniteNumber(_ object: [String: Any], _ key: String) throws -> Double {
    guard object[key] != nil else {
        throw ManualXbrlOverrideValidationError("missing key '\(key)'")
    }
    guard let number = doubleValue(object[key]), number.isFinite else {
        throw ManualXbrlOverrideValidationError("'\(key)' must be a finite number")
    }
    return number
}

private func requireInt(_ object: [String: Any], _ key: String) throws -> Int {
    guard object[key] != nil else {
        throw ManualXbrlOverrideValidationError("missing key '\(key)'")
    }
    if let int = object[key] as? Int { return int }
    if object[key] is Bool {
        throw ManualXbrlOverrideValidationError("'\(key)' must be an integer")
    }
    if let number = object[key] as? NSNumber {
        let value = number.doubleValue
        guard value.rounded() == value, let parsed = Int(exactly: number.int64Value) else {
            throw ManualXbrlOverrideValidationError("'\(key)' must be an integer")
        }
        return parsed
    }
    throw ManualXbrlOverrideValidationError("'\(key)' must be an integer")
}

private func parseOptionalSecurityRows(_ value: Any?) throws -> [PolicyHoldingSecurityPayload]? {
    guard let value, !(value is NSNull) else { return nil }
    guard let rows = value as? [Any] else {
        throw ManualXbrlOverrideValidationError("'securities' must be an array")
    }
    return try rows.enumerated().map { index, row in
        guard let object = row as? [String: Any] else {
            throw ManualXbrlOverrideValidationError("securities[\(index)] must be an object")
        }
        return try parseSecurityRow(object, index: index)
    }
}

private func parseSecurityRow(
    _ object: [String: Any], index: Int
) throws -> PolicyHoldingSecurityPayload {
    try rejectUnknownKeys(
        object,
        allowed: [
            "issuer_name", "number_of_shares", "carrying_amount", "purpose", "is_deemed_holding",
        ],
        label: "securities[\(index)]")
    let issuerName = try requireNonEmptyString(object, "issuer_name")
    let shares = try optionalFiniteNumber(object, "number_of_shares")
    let carrying = try optionalFiniteNumber(object, "carrying_amount")
    let purpose = try optionalString(object, "purpose")
    let deemed = try optionalBool(object, "is_deemed_holding") ?? false
    return PolicyHoldingSecurityPayload(
        issuerName: issuerName, numberOfShares: shares, carryingAmount: carrying,
        purpose: purpose, isDeemedHolding: deemed)
}

private func parseOptionalHoldingSummary(
    _ value: Any?
) throws -> PolicyHoldingAggregateSummaryPayload? {
    guard let value, !(value is NSNull) else { return nil }
    guard let object = value as? [String: Any] else {
        throw ManualXbrlOverrideValidationError("'policy_holding_summary' must be an object")
    }
    try rejectUnknownKeys(
        object,
        allowed: [
            "unlisted_issue_count", "unlisted_carrying_amount", "listed_issue_count",
            "listed_carrying_amount",
        ],
        label: "policy_holding_summary")
    return PolicyHoldingAggregateSummaryPayload(
        unlistedIssueCount: try optionalInt(object, "unlisted_issue_count"),
        unlistedCarryingAmount: try optionalFiniteNumber(object, "unlisted_carrying_amount"),
        listedIssueCount: try optionalInt(object, "listed_issue_count"),
        listedCarryingAmount: try optionalFiniteNumber(object, "listed_carrying_amount"))
}

private func optionalFiniteNumber(_ object: [String: Any], _ key: String) throws -> Double? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let number = doubleValue(value), number.isFinite else {
        throw ManualXbrlOverrideValidationError("'\(key)' must be a finite number or null")
    }
    return number
}

private func optionalInt(_ object: [String: Any], _ key: String) throws -> Int? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    if let int = value as? Int { return int }
    if value is Bool {
        throw ManualXbrlOverrideValidationError("'\(key)' must be an integer or null")
    }
    if let number = value as? NSNumber {
        let double = number.doubleValue
        guard double.rounded() == double else {
            throw ManualXbrlOverrideValidationError("'\(key)' must be an integer or null")
        }
        return number.intValue
    }
    throw ManualXbrlOverrideValidationError("'\(key)' must be an integer or null")
}

private func optionalBool(_ object: [String: Any], _ key: String) throws -> Bool? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.boolValue }
    throw ManualXbrlOverrideValidationError("'\(key)' must be a boolean or null")
}

private func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let text = stringValue(value) else {
        throw ManualXbrlOverrideValidationError("'\(key)' must be a string or null")
    }
    return text
}

private func stringValue(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    return value as? String
}

private func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let number = value as? NSNumber {
        if value is Bool { return nil }
        return number.doubleValue
    }
    return nil
}
