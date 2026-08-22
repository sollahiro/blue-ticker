// Feed Update / Trend の公開 JSON 組み立て（ネットワーク・DB 非依存）。
// 書類は `edinet_documents` 由来の正規化レコード。上場（5 桁 secCode 末尾 0）のみ載せる。

import Foundation

/// クエリ `limit` を [1, feedLimitMax] に閉じる。省略・0 以下は既定。
public func parseFeedLimit(_ raw: Int?) -> Int {
    guard let raw, raw > 0 else { return Api.feedLimitDefault }
    return min(raw, Api.feedLimitMax)
}

/// クエリ `days` を [1, feedTrendDaysMax] に閉じる。省略・0 以下は既定。
public func parseFeedDays(_ raw: Int?) -> Int {
    guard let raw, raw > 0 else { return Api.feedTrendDaysDefault }
    return min(raw, Api.feedTrendDaysMax)
}

/// クエリ `doc_type`（カンマ区切り）を許可種別へ正規化する。
/// 未知・空は落とし、残が無ければ有報(120)。順序は入力順（重複除去）。
public func parseFeedDocTypes(_ raw: String?) -> [String] {
    let parts = (raw ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    var seen = Set<String>()
    var types: [String] = []
    for part in parts where Api.feedAllowedDocTypes.contains(part) && seen.insert(part).inserted {
        types.append(part)
    }
    return types.isEmpty ? Api.feedDefaultDocTypes : types
}

/// Trend 集計窓の下限（UTC の YYYY-MM-DD）。`submit_date_time` の辞書順比較に使う。
public func feedCutoffDateString(days: Int, now: Date = Date()) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
    let formatter = DateFormatter()
    formatter.dateFormat = DateFormat.hyphenated
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: cutoff)
}

/// 上場の 4 桁コード。secCode が 5 桁かつ末尾 0 のときだけ。
public func listedTickerCode(fromSecCode secCode: String?) -> String? {
    guard let secCode, secCode.count == 5, secCode.hasSuffix("0") else { return nil }
    return String(secCode.dropLast())
}

/// Feed Update: 提出日時降順の書類ストリーム（1 行 = 1 書類）。
public func assembleFeedUpdates(
    from records: [EdinetDocumentRecord], limit: Int, docTypes: [String]
) -> [String: Any] {
    var items: [[String: Any]] = []
    for record in records {
        guard let item = feedFilingItem(from: record) else { continue }
        items.append(item)
        if items.count >= limit { break }
    }
    return [
        "schema_version": Api.feedSchemaVersion,
        "doc_types": docTypes,
        "items": items,
    ]
}

/// Feed Trend: 窓内の開示件数が多い上場銘柄。同数なら最新提出が新しい順。
/// `records` は呼び出し側が窓・種別で絞り、提出日時降順にして渡す。
public func assembleFeedTrend(
    from records: [EdinetDocumentRecord], limit: Int, days: Int, docTypes: [String]
) -> [String: Any] {
    var counts: [String: Int] = [:]
    var latest: [String: EdinetDocumentRecord] = [:]
    for record in records {
        guard let code = listedTickerCode(fromSecCode: record.secCode) else { continue }
        counts[code, default: 0] += 1
        if latest[code] == nil {
            latest[code] = record
        }
    }
    let ranked = latest.keys.sorted { left, right in
        let leftCount = counts[left] ?? 0
        let rightCount = counts[right] ?? 0
        if leftCount != rightCount { return leftCount > rightCount }
        return (latest[left]?.submitDateTime ?? "") > (latest[right]?.submitDateTime ?? "")
    }
    let items: [[String: Any]] = ranked.prefix(limit).compactMap { code in
        guard var item = latest[code].flatMap(feedFilingItem) else { return nil }
        item["filing_count"] = counts[code] ?? 0
        return item
    }
    return [
        "schema_version": Api.feedSchemaVersion,
        "days": days,
        "doc_types": docTypes,
        "items": items,
    ]
}

/// 1 書類の公開フィード行。非上場は nil。filings 1 件に code / name を足した形。
func feedFilingItem(from record: EdinetDocumentRecord) -> [String: Any]? {
    guard let code = listedTickerCode(fromSecCode: record.secCode) else { return nil }
    var item = filingDict(
        docID: record.docID,
        docType: record.docTypeCode ?? "",
        rawFyEnd: record.periodEnd ?? "",
        submitAt: record.submitDateTime,
        docDescription: record.docDescription ?? "")
    item["code"] = code
    item["name"] = record.filerName
    return item
}
