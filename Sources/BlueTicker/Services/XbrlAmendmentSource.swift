import Foundation

/// 有報(120)の同一性と、訂正(130)の XBRL 置換候補を表す。公開 payload の `doc_id` には使わず、
/// 取得する ZIP の選定だけに使う。
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

/// XBRL のみの全文置換（「記載内容に訂正はありません」）を示す提出パッケージ内の文言。
/// 数値・科目を差し替える通常の訂正有報には現れない。
public let fullXbrlReplacementPhrases = [
    "XBRLデータのみ",
    "記載内容に訂正はありません",
]

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

/// 訂正 ZIP を新しい順に試し、全文 XBRL 置換かつパースできるものがあればその展開ディレクトリを返す。
/// どれも失敗したら原本を取得する（原本のパース成否は呼び出し側に委ねる）。
public func resolveAnnualXbrlDirectory(
    originalDocID: String,
    correctionDocIDs: [String],
    download: @Sendable (String) async -> URL?,
    parses: @Sendable (URL) -> Bool = { xbrlPackageParses($0) },
    isFullReplacement: @Sendable (URL) -> Bool = { xbrlPackageIsFullReplacement($0) }
) async -> URL? {
    for docID in correctionDocIDs {
        guard let dir = await download(docID) else { continue }
        guard isFullReplacement(dir), parses(dir) else { continue }
        return dir
    }
    return await download(originalDocID)
}

/// 展開済み XBRL に数値 fact が1件でもあればパース成功とみなす。
public func xbrlPackageParses(_ dir: URL) -> Bool {
    !XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false).isEmpty
}

/// 提出パッケージが XBRL のみの全文置換かを本文から判定する。
public func xbrlPackageIsFullReplacement(_ dir: URL) -> Bool {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
        return false
    }
    while let url = enumerator.nextObject() as? URL {
        let ext = url.pathExtension.lowercased()
        guard ["htm", "html", "xbrl", "xml"].contains(ext) else { continue }
        guard let data = try? Data(contentsOf: url) else { continue }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .shiftJIS)
            ?? ""
        if fullXbrlReplacementPhrases.contains(where: { text.contains($0) }) {
            return true
        }
    }
    return false
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
