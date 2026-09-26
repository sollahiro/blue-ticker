import Foundation

/// 訂正 overlay を公開しない理由。`warnings` にも同じトークンを載せる。
public let xbrlOverlayRegressionWarningPrefix = "overlay_regression"

/// 行メンバー表の行減：これ以上の割合かつ絶対件数を失ったら回帰。
public let xbrlOverlayRowLossMinFraction = 0.30
public let xbrlOverlayRowLossMinAbsolute = 5

/// 同一 element+context の絶対値がだいたい 10 倍動いたとみなす下限比。
public let xbrlOverlayScaleJumpMinRatio = 8.0

/// 合計が内訳行の和と一致していたとみなす相対許容。
public let xbrlOverlayReconcileRelativeTolerance = 0.02

let xbrlOverlayRegressionsFileName = ".blt-xbrl-overlay-regressions"

public let xbrlOverlayRegressionKindRowLoss = "row_loss"
public let xbrlOverlayRegressionKindReconcile = "reconcile"
public let xbrlOverlayRegressionKindScaleJump = "scale_jump"

/// 1 件の訂正レイヤで差し戻した fact の理由。公開面の `needs_review` とログに使う。
public struct XbrlOverlayRegression: Equatable, Sendable, Codable {
    public var originalDocID: String
    public var correctionDocID: String
    public var kind: String
    public var tag: String
    public var contextRef: String?
    public var beforeCount: Int?
    public var afterCount: Int?
    public var beforeValue: Double?
    public var afterValue: Double?

    public init(
        originalDocID: String, correctionDocID: String, kind: String, tag: String,
        contextRef: String? = nil, beforeCount: Int? = nil, afterCount: Int? = nil,
        beforeValue: Double? = nil, afterValue: Double? = nil
    ) {
        self.originalDocID = originalDocID
        self.correctionDocID = correctionDocID
        self.kind = kind
        self.tag = tag
        self.contextRef = contextRef
        self.beforeCount = beforeCount
        self.afterCount = afterCount
        self.beforeValue = beforeValue
        self.afterValue = afterValue
    }

    /// `overlay_regression:<kind>:<correctionDocID>:...`
    public var warningToken: String {
        var parts = [
            xbrlOverlayRegressionWarningPrefix, kind, correctionDocID, "orig=\(originalDocID)",
            "tag=\(tag)",
        ]
        if let contextRef { parts.append("ctx=\(contextRef)") }
        if let beforeCount { parts.append("before=\(beforeCount)") }
        if let afterCount { parts.append("after=\(afterCount)") }
        if let beforeValue { parts.append("from=\(beforeValue)") }
        if let afterValue { parts.append("to=\(afterValue)") }
        return parts.joined(separator: ":")
    }

    /// ingest ログの `reason`（種別と件数・倍率）。
    public var reasonSummary: String {
        var parts = [kind, "tag=\(tag)"]
        if let contextRef { parts.append("ctx=\(contextRef)") }
        if let beforeCount, let afterCount {
            parts.append("before=\(beforeCount)")
            parts.append("after=\(afterCount)")
        }
        if let beforeValue, let afterValue {
            parts.append("from=\(beforeValue)")
            parts.append("to=\(afterValue)")
        }
        return parts.joined(separator: " ")
    }
}

struct XbrlOverlayRegressionManifest: Codable {
    var originalDocID: String
    var skipped: [XbrlOverlayRegression]
}

/// 1 レイヤ分の overlay 結果を直前状態と比べ、差し戻す fact があれば理由を返す。
/// `overlay` は当該 130 インスタンスの fact（継承分を含まない）。省略時は `after` を明示置換とみなす。
public func xbrlOverlayRegressions(
    before: [String: [String: Double]],
    after: [String: [String: Double]],
    originalDocID: String,
    correctionDocID: String,
    overlay: [String: [String: Double]]? = nil
) -> [XbrlOverlayRegression] {
    let layer = overlay ?? after
    var found: [XbrlOverlayRegression] = []
    found.append(
        contentsOf: rowLossRegressions(
            before: before, after: after, originalDocID: originalDocID,
            correctionDocID: correctionDocID))
    found.append(
        contentsOf: scaleJumpRegressions(
            before: before, after: after, overlay: layer, originalDocID: originalDocID,
            correctionDocID: correctionDocID))
    found.append(
        contentsOf: reconcileRegressions(
            before: before, after: after, originalDocID: originalDocID,
            correctionDocID: correctionDocID))
    return found
}

/// 提出が古い順の訂正を重ねる。回帰した fact だけ直前値へ戻し、レイヤの残りは採用する。
/// `base` / 各 `layers[].facts` はこの原本 `originalDocID` のパッケージ。他 doc は見ない。
public func applyGuardedXbrlOverlays(
    base: [String: [String: Double]],
    layers: [(correctionDocID: String, facts: [String: [String: Double]])],
    originalDocID: String
) -> (facts: [String: [String: Double]], skipped: [XbrlOverlayRegression]) {
    var current = base
    var skipped: [XbrlOverlayRegression] = []
    for layer in layers {
        let candidate = overlayKeyedFacts(base: current, overlay: layer.facts)
        let found = xbrlOverlayRegressions(
            before: current, after: candidate, originalDocID: originalDocID,
            correctionDocID: layer.correctionDocID, overlay: layer.facts)
        let filtered = excludingRevertedFacts(layer.facts, reverts: found)
        current = overlayKeyedFacts(base: current, overlay: filtered)
        skipped.append(contentsOf: found)
    }
    return (current, skipped)
}

/// 回帰した tag/context（`row_loss` / `reconcile` は当該タグの Row{N}Member 表）を overlay から除く。
func excludingRevertedFacts<Value>(
    _ overlay: [String: [String: Value]],
    reverts: [XbrlOverlayRegression]
) -> [String: [String: Value]] {
    guard !reverts.isEmpty else { return overlay }
    var result = overlay
    for revert in reverts {
        guard var ctxMap = result[revert.tag] else { continue }
        switch revert.kind {
        case xbrlOverlayRegressionKindRowLoss:
            ctxMap = ctxMap.filter { !isRowMemberContext($0.key) }
        case xbrlOverlayRegressionKindReconcile:
            ctxMap = ctxMap.filter { !isRowMemberContext($0.key) }
            if let stem = revert.contextRef {
                ctxMap.removeValue(forKey: stem)
            }
        default:
            if let ctx = revert.contextRef {
                ctxMap.removeValue(forKey: ctx)
            }
        }
        result[revert.tag] = ctxMap
    }
    return result
}

func overlayFactValues(_ index: XbrlFactIndex) -> [String: [String: Double]] {
    var result: [String: [String: Double]] = [:]
    for (tag, ctxMap) in index {
        result[tag] = ctxMap.mapValues(\.value)
    }
    return result
}

func readOverlayRegressions(in dir: URL) -> [XbrlOverlayRegression] {
    let marker = dir.appendingPathComponent(xbrlOverlayRegressionsFileName)
    guard let data = try? Data(contentsOf: marker),
        let decoded = try? JSONDecoder().decode(XbrlOverlayRegressionManifest.self, from: data)
    else { return [] }
    return decoded.skipped
}

func writeOverlayRegressions(
    _ regressions: [XbrlOverlayRegression], originalDocID: String, to dir: URL
) {
    guard !regressions.isEmpty else { return }
    let body = XbrlOverlayRegressionManifest(originalDocID: originalDocID, skipped: regressions)
    guard let data = try? JSONEncoder().encode(body) else { return }
    try? data.write(to: dir.appendingPathComponent(xbrlOverlayRegressionsFileName), options: .atomic)
}

func statementNoteByRecordingOverlayRegressions(
    _ result: StatementNoteResolveResult, xbrlDir: URL
) -> StatementNoteResolveResult {
    guard case .resolved(var payload, let source, let contentHash) = result else { return result }
    let relevant = readOverlayRegressions(in: xbrlDir).filter {
        overlayRegressionAffectsStatementNote($0, payload: payload)
    }
    guard !relevant.isEmpty else { return result }
    payload.needsReview = true
    var warnings = payload.warnings
    for token in relevant.map(\.warningToken) where !warnings.contains(token) {
        warnings.append(token)
    }
    payload.warnings = warnings
    return .resolved(payload: payload, source: source, contentHash: contentHash)
}

func breakdownByRecordingOverlayRegressions(
    _ result: BreakdownResolveResult, xbrlDir: URL
) -> BreakdownResolveResult {
    guard case .resolved(var payload, let source, let contentHash, let audit) = result else {
        return result
    }
    let relevant = readOverlayRegressions(in: xbrlDir).filter {
        overlayRegressionAffectsBreakdown($0, payload: payload)
    }
    guard !relevant.isEmpty else { return result }
    payload.needsReview = true
    var warnings = payload.warnings
    for token in relevant.map(\.warningToken) where !warnings.contains(token) {
        warnings.append(token)
    }
    payload.warnings = warnings
    return .resolved(payload: payload, source: source, contentHash: contentHash, audit: audit)
}

func overlayRegressionAffectsStatementNote(
    _ regression: XbrlOverlayRegression, payload: StatementNotePayload
) -> Bool {
    if payload.items?.contains(where: { $0.tag == regression.tag }) == true { return true }
    if payload.securities != nil || payload.policyHoldingSummary != nil {
        return isPolicyHoldingOverlayTag(regression.tag)
    }
    if payload.dividendEvents != nil {
        return regression.tag.localizedCaseInsensitiveContains("Dividend")
    }
    if payload.borrowingsComponents != nil {
        return regression.tag.localizedCaseInsensitiveContains("Borrow")
            || regression.tag.localizedCaseInsensitiveContains("Loan")
    }
    if payload.capexSegments != nil {
        return isCapitalExpenditureOverlayTag(regression.tag)
    }
    return false
}

func overlayRegressionAffectsBreakdown(
    _ regression: XbrlOverlayRegression, payload: BreakdownSnapshotPayload
) -> Bool {
    if regression.tag == payload.denominatorTag { return true }
    switch payload.axis {
    case breakdownAxisCapitalExpenditures, breakdownAxisCapitalExpendituresOverview,
        breakdownAxisNoncurrentAssetAdditions:
        return isCapitalExpenditureOverlayTag(regression.tag)
    default:
        return false
    }
}

func isPolicyHoldingOverlayTag(_ tag: String) -> Bool {
    tag.contains("HeldForPurposesOtherThanPureInvestment")
        || tag.contains("DeemedHoldings")
        || tag.contains("SpecifiedInvestment")
}

func isCapitalExpenditureOverlayTag(_ tag: String) -> Bool {
    tag.contains("CapitalExpenditure") || tag.contains("CapitalInvestment")
}

public func hasOverlayRegressionWarning(_ warnings: [String]) -> Bool {
    warnings.contains { $0.hasPrefix(xbrlOverlayRegressionWarningPrefix) }
}

/// `overlay_regression:<kind>:<correctionDocID>:orig=<originalDocID>:...`
public func parseXbrlOverlayRegressionWarning(_ token: String) -> (
    kind: String, correctionDocID: String, originalDocID: String, tag: String?,
    before: String?, after: String?
)? {
    let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 4, parts[0] == xbrlOverlayRegressionWarningPrefix else { return nil }
    var original = ""
    var tag: String?
    var before: String?
    var after: String?
    for part in parts.dropFirst(3) {
        if part.hasPrefix("orig=") {
            original = String(part.dropFirst(5))
        } else if part.hasPrefix("tag=") {
            tag = String(part.dropFirst(4))
        } else if part.hasPrefix("before=") {
            before = String(part.dropFirst(7))
        } else if part.hasPrefix("after=") {
            after = String(part.dropFirst(6))
        } else if part.hasPrefix("from="), before == nil {
            before = String(part.dropFirst(5))
        } else if part.hasPrefix("to="), after == nil {
            after = String(part.dropFirst(3))
        }
    }
    return (parts[1], parts[2], original, tag, before, after)
}

/// ingest / CLI が出す 1 行。code・FY・原本/訂正 doc_id・理由を必ず含む。
public func xbrlOverlayRegressionLogMessage(
    code: String, fy: String, originalDocID: String, correctionDocID: String, reason: String
) -> String {
    "XBRL overlay regression: code=\(code) fy=\(fy) original_doc_id=\(originalDocID) correction_doc_id=\(correctionDocID) reason=\(reason)"
}

private func rowMemberCount(_ ctxMap: [String: Double]) -> Int {
    ctxMap.keys.filter(isRowMemberContext).count
}

private func rowLossRegressions(
    before: [String: [String: Double]], after: [String: [String: Double]],
    originalDocID: String, correctionDocID: String
) -> [XbrlOverlayRegression] {
    var tags = Set(before.keys)
    tags.formUnion(after.keys)
    var found: [XbrlOverlayRegression] = []
    for tag in tags.sorted() {
        let beforeN = rowMemberCount(before[tag] ?? [:])
        let afterN = rowMemberCount(after[tag] ?? [:])
        let lost = beforeN - afterN
        guard lost >= xbrlOverlayRowLossMinAbsolute, beforeN > 0 else { continue }
        let fraction = Double(lost) / Double(beforeN)
        guard fraction >= xbrlOverlayRowLossMinFraction else { continue }
        found.append(
            XbrlOverlayRegression(
                originalDocID: originalDocID, correctionDocID: correctionDocID,
                kind: xbrlOverlayRegressionKindRowLoss, tag: tag, beforeCount: beforeN,
                afterCount: afterN))
    }
    return found
}

/// 明示置換（130 インスタンスに同じ tag+context がある）はスケール変更を許す。
/// 同じタグの関連コンテキストが 130 にあり、片方だけおよそ 10 倍動いたときだけ回帰。
/// 130 に無く値が動いた継承 fact も回帰（overlay が触るべきでない）。
private func scaleJumpRegressions(
    before: [String: [String: Double]], after: [String: [String: Double]],
    overlay: [String: [String: Double]],
    originalDocID: String, correctionDocID: String
) -> [XbrlOverlayRegression] {
    var found: [XbrlOverlayRegression] = []
    for tag in before.keys.sorted() {
        guard let beforeCtx = before[tag], let afterCtx = after[tag] else { continue }
        let overlayCtx = overlay[tag] ?? [:]
        for ctx in beforeCtx.keys.sorted() where !isRowMemberContext(ctx) {
            guard let old = beforeCtx[ctx], let new = afterCtx[ctx], old != 0, new != 0 else {
                continue
            }
            let ratio = max(abs(new / old), abs(old / new))
            guard ratio >= xbrlOverlayScaleJumpMinRatio else { continue }
            if overlayCtx[ctx] != nil {
                let siblings = overlayCtx.keys.filter {
                    $0 != ctx && !isRowMemberContext($0) && beforeCtx[$0] != nil
                        && afterCtx[$0] != nil
                }
                if siblings.isEmpty { continue }
                let siblingJumpsInconsistently = siblings.contains { sib in
                    guard let sOld = beforeCtx[sib], let sNew = afterCtx[sib], sOld != 0, sNew != 0
                    else { return false }
                    return max(abs(sNew / sOld), abs(sOld / sNew)) < xbrlOverlayScaleJumpMinRatio
                }
                guard siblingJumpsInconsistently else { continue }
            }
            found.append(
                XbrlOverlayRegression(
                    originalDocID: originalDocID, correctionDocID: correctionDocID,
                    kind: xbrlOverlayRegressionKindScaleJump, tag: tag, contextRef: ctx,
                    beforeValue: old, afterValue: new))
        }
    }
    return found
}

private func reconcileRegressions(
    before: [String: [String: Double]], after: [String: [String: Double]],
    originalDocID: String, correctionDocID: String
) -> [XbrlOverlayRegression] {
    var found: [XbrlOverlayRegression] = []
    for tag in before.keys.sorted() {
        let beforeStems = reconciledStems(before[tag] ?? [:])
        guard !beforeStems.isEmpty else { continue }
        let afterStems = reconciledStems(after[tag] ?? [:])
        for stem in beforeStems.sorted() where !afterStems.contains(stem) {
            found.append(
                XbrlOverlayRegression(
                    originalDocID: originalDocID, correctionDocID: correctionDocID,
                    kind: xbrlOverlayRegressionKindReconcile, tag: tag, contextRef: stem))
        }
    }
    return found
}

/// 非行コンテキストの値が、同じ期間軸の Row{N}Member 合計と一致する stem 集合。
private func reconciledStems(_ ctxMap: [String: Double]) -> Set<String> {
    var rowsByStem: [String: [Double]] = [:]
    for (ctx, value) in ctxMap {
        guard let stem = rowMemberPeriodStem(ctx) else { continue }
        rowsByStem[stem, default: []].append(value)
    }
    var stems: Set<String> = []
    for (stem, rows) in rowsByStem {
        guard let total = ctxMap[stem], !rows.isEmpty else { continue }
        let sum = rows.reduce(0, +)
        let scale = max(abs(total), 1)
        if abs(sum - total) <= xbrlOverlayReconcileRelativeTolerance * scale {
            stems.insert(stem)
        }
    }
    return stems
}

func rowMemberPeriodStem(_ contextRef: String) -> String? {
    guard isRowMemberContext(contextRef) else { return nil }
    guard let range = contextRef.range(of: #"_Row[0-9]+Member$"#, options: .regularExpression)
    else { return nil }
    return String(contextRef[..<range.lowerBound])
}
