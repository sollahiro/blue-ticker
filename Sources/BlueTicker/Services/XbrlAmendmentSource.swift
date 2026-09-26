import Foundation

/// 展開ディレクトリに置く訂正 overlay のマニフェスト（1行1パス、提出が古い順）。
let xbrlOverlayManifestFileName = ".blt-xbrl-overlays"

/// 有報(120)の同一性と、訂正(130)の XBRL overlay 候補を表す。公開 payload の `doc_id` には使わず、
/// 取得する ZIP / fact overlay の選定だけに使う。
public struct XbrlSourceDocument: Equatable, Sendable {
    public var docID: String
    public var docTypeCode: String?
    public var parentDocID: String?
    public var edinetCode: String
    public var periodStart: String?
    public var periodEnd: String?
    public var submitDateTime: String
    public var docDescription: String?

    public init(
        docID: String,
        docTypeCode: String? = nil,
        parentDocID: String? = nil,
        edinetCode: String,
        periodStart: String? = nil,
        periodEnd: String? = nil,
        submitDateTime: String,
        docDescription: String? = nil
    ) {
        self.docID = docID
        self.docTypeCode = docTypeCode
        self.parentDocID = parentDocID
        self.edinetCode = edinetCode
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.submitDateTime = submitDateTime
        self.docDescription = docDescription
    }
}

/// 同一会社・同一期間・同一親有報に紐づく訂正(130)を提出日時の新しい順で返す。
/// `parentDocID` があるときは親一致を必須にし、期間が取れる場合は親の期末と一致するものだけ残す。
/// 親リンクが無い行は、期末（または概要文の西暦期間）が原本と一致するときだけ採用する。
public func matchingXbrlCorrections(
    original: XbrlSourceDocument,
    corrections: [XbrlSourceDocument]
) -> [XbrlSourceDocument] {
    corrections.filter { isMatchingXbrlCorrection($0, original: original) }
        .sorted { lhs, rhs in
            if lhs.submitDateTime != rhs.submitDateTime {
                return lhs.submitDateTime > rhs.submitDateTime
            }
            return lhs.docID > rhs.docID
        }
}

/// 原本 docID → 採用候補の訂正 docID（新しい順）。該当なしの原本は載せない。
public func preferredCorrectionDocIDsByOriginal(
    originals: [XbrlSourceDocument],
    corrections: [XbrlSourceDocument]
) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for original in originals {
        let ids = matchingXbrlCorrections(original: original, corrections: corrections).map(\.docID)
        if !ids.isEmpty {
            result[original.docID] = ids
        }
    }
    return result
}

/// 原本 ZIP を土台に、パースできる訂正を提出が古い順へ overlay した展開ディレクトリを返す。
/// 訂正の取得失敗・パース失敗はその件だけ飛ばす。適格な訂正が無ければ原本。
/// `correctionDocIDs` は新しい順（`matchingXbrlCorrections` と同じ）。
public func resolveAnnualXbrlDirectory(
    originalDocID: String,
    correctionDocIDs: [String],
    download: @Sendable (String) async -> URL?,
    parses: @Sendable (URL) -> Bool = { xbrlPackageParses($0) },
    materialize: (@Sendable (URL, [URL]) -> URL?)? = nil,
    numericFacts: (@Sendable (URL) -> [String: [String: Double]])? = nil
) async -> URL? {
    guard let originalDir = await download(originalDocID) else { return nil }
    let factsOf = numericFacts ?? {
        overlayFactValues(XBRLUtils.collectAllNumericFacts(in: $0, nilAsZero: false))
    }
    var overlayDirs: [URL] = []
    var regressions: [XbrlOverlayRegression] = []
    var currentFacts = factsOf(originalDir)
    for docID in correctionDocIDs.reversed() {
        guard let dir = await download(docID), parses(dir) else { continue }
        let layer = factsOf(dir)
        let candidate = overlayKeyedFacts(base: currentFacts, overlay: layer)
        let found = xbrlOverlayRegressions(
            before: currentFacts, after: candidate, originalDocID: originalDocID,
            correctionDocID: docID)
        if found.isEmpty {
            currentFacts = candidate
            overlayDirs.append(dir)
        } else {
            regressions.append(contentsOf: found)
        }
    }
    if overlayDirs.isEmpty, regressions.isEmpty { return originalDir }
    let skippedRegressions = regressions
    let merged = (materialize ?? {
        materializeOverlaidXbrlDirectory(
            original: $0, overlayDirs: $1, originalDocID: originalDocID,
            regressions: skippedRegressions)
    })(originalDir, overlayDirs)
    if let merged {
        writeOverlayRegressions(skippedRegressions, originalDocID: originalDocID, to: merged)
    }
    return merged ?? originalDir
}

/// 展開済み XBRL に数値 fact が1件でもあればパース成功とみなす。
public func xbrlPackageParses(_ dir: URL) -> Bool {
    !XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false).isEmpty
}

/// 原本をコピーし、訂正ディレクトリへのマニフェストを書く。収集側が fact / TextBlock を overlay する。
func materializeOverlaidXbrlDirectory(
    original: URL, overlayDirs: [URL], originalDocID: String = "",
    regressions: [XbrlOverlayRegression] = []
) -> URL? {
    if overlayDirs.isEmpty, regressions.isEmpty { return original }
    let merged = FileManager.default.temporaryDirectory
        .appendingPathComponent("blt-xbrl-overlay-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.copyItem(at: original, to: merged)
        if !overlayDirs.isEmpty {
            let body = overlayDirs.map(\.path).joined(separator: "\n") + "\n"
            try body.write(
                to: merged.appendingPathComponent(xbrlOverlayManifestFileName),
                atomically: true, encoding: .utf8)
        }
        writeOverlayRegressions(regressions, originalDocID: originalDocID, to: merged)
        return merged
    } catch {
        return original
    }
}

/// マニフェストに書かれた訂正展開ディレクトリ（提出が古い順）。無ければ空。
func overlayDirectories(in dir: URL) -> [URL] {
    let marker = dir.appendingPathComponent(xbrlOverlayManifestFileName)
    guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap { line in
        let path = line.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

/// 原本ディレクトリに続き、訂正 overlay を提出が古い順で返す。
func xbrlSearchRoots(in dir: URL) -> [URL] {
    [dir] + overlayDirectories(in: dir)
}

/// `contextRef` が行メンバー表（`Row{N}Member`）か。政策保有株式・配当決議など。
public func isRowMemberContext(_ contextRef: String) -> Bool {
    contextRef.range(of: #"Row[0-9]+Member"#, options: .regularExpression) != nil
}

/// 訂正 fact を原本へ重ねる。キーは tag + contextRef。
/// `Row{N}Member` を持つタグは、訂正にその表があれば行ごと置換（セル混在しない）。
public func overlayKeyedFacts<Value>(
    base: [String: [String: Value]],
    overlay: [String: [String: Value]]
) -> [String: [String: Value]] {
    var result = base
    let overlayTableTags = Set(
        overlay.compactMap { tag, ctxMap -> String? in
            ctxMap.keys.contains(where: isRowMemberContext) ? tag : nil
        })
    for tag in overlayTableTags {
        var ctxMap = result[tag] ?? [:]
        ctxMap = ctxMap.filter { !isRowMemberContext($0.key) }
        if let overlayCtx = overlay[tag] {
            for (ctx, value) in overlayCtx where isRowMemberContext(ctx) {
                ctxMap[ctx] = value
            }
        }
        result[tag] = ctxMap
    }
    for (tag, ctxMap) in overlay {
        for (ctx, value) in ctxMap {
            if overlayTableTags.contains(tag), isRowMemberContext(ctx) { continue }
            result[tag, default: [:]][ctx] = value
        }
    }
    return result
}

func overlayXbrlFactIndex(base: XbrlFactIndex, overlay: XbrlFactIndex) -> XbrlFactIndex {
    overlayKeyedFacts(base: base, overlay: overlay)
}

/// EDINET 日次一覧 / 年次インデックスの dict から選定用の書類メタを作る。
func xbrlSourceDocument(fromEdinetFields doc: [String: Any]) -> XbrlSourceDocument? {
    guard let docID = nonEmptyField(doc["docID"]) else { return nil }
    let periodEnd = normalizeDateFormat(doc["periodEnd"] as? String)
        ?? normalizeDateFormat(doc["edinet_fy_end"] as? String)
        ?? periodEndFromDocDescription(doc["docDescription"] as? String)
    return XbrlSourceDocument(
        docID: docID,
        docTypeCode: nonEmptyField(doc["docTypeCode"]),
        parentDocID: nonEmptyField(doc["parentDocID"]),
        edinetCode: nonEmptyField(doc["edinetCode"]) ?? "",
        periodStart: normalizeDateFormat(doc["periodStart"] as? String),
        periodEnd: periodEnd,
        submitDateTime: nonEmptyField(doc["submitDateTime"]) ?? "",
        docDescription: nonEmptyField(doc["docDescription"]))
}

func isMatchingXbrlCorrection(
    _ correction: XbrlSourceDocument, original: XbrlSourceDocument
) -> Bool {
    guard correction.docTypeCode == Api.docTypeAmendment else { return false }
    guard !correction.edinetCode.isEmpty, correction.edinetCode == original.edinetCode else {
        return false
    }
    let parent = nonEmptyField(correction.parentDocID)
    if let parent, parent != original.docID { return false }

    let originalPeriod = inferredPeriodEnd(original)
    let correctionPeriod = inferredPeriodEnd(correction)
    if let originalPeriod, let correctionPeriod, originalPeriod != correctionPeriod {
        return false
    }
    if parent == nil {
        guard let originalPeriod, let correctionPeriod, originalPeriod == correctionPeriod else {
            return false
        }
    }
    return true
}

func inferredPeriodEnd(_ doc: XbrlSourceDocument) -> String? {
    normalizeDateFormat(doc.periodEnd) ?? periodEndFromDocDescription(doc.docDescription)
}

/// 概要文の末尾の西暦日付を期末とみなす（例: `第23期(2024/04/01－2025/03/31)`）。
func periodEndFromDocDescription(_ description: String?) -> String? {
    guard let description, !description.isEmpty else { return nil }
    let chars = Array(description)
    var last: String?
    var i = 0
    while i + 10 <= chars.count {
        let y0 = chars[i], y1 = chars[i + 1], y2 = chars[i + 2], y3 = chars[i + 3]
        let s0 = chars[i + 4]
        let m0 = chars[i + 5], m1 = chars[i + 6]
        let s1 = chars[i + 7]
        let d0 = chars[i + 8], d1 = chars[i + 9]
        if y0.isASCII && y0.isNumber, y1.isASCII && y1.isNumber,
            y2.isASCII && y2.isNumber, y3.isASCII && y3.isNumber,
            isDateSeparator(s0),
            m0.isASCII && m0.isNumber, m1.isASCII && m1.isNumber,
            isDateSeparator(s1),
            d0.isASCII && d0.isNumber, d1.isASCII && d1.isNumber
        {
            last = "\(y0)\(y1)\(y2)\(y3)-\(m0)\(m1)-\(d0)\(d1)"
            i += 10
            continue
        }
        i += 1
    }
    return normalizeDateFormat(last)
}

private func isDateSeparator(_ c: Character) -> Bool {
    c == "/" || c == "." || c == "-"
}

private func nonEmptyField(_ value: Any?) -> String? {
    if let s = value as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return nil
}

private func nonEmptyField(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
