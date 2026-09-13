// Feed Update の公開 JSON 組み立て（ネットワーク・DB 非依存）。
// 書類は `edinet_documents` 由来の正規化レコード。上場（5 桁 secCode 末尾 0。00000 は未割当）のみ載せる。

import Foundation

/// クエリ `limit` を [1, feedLimitMax] に閉じる。省略・0 以下は `defaultLimit`。
public func parseFeedLimit(_ raw: Int?, defaultLimit: Int = Api.feedLimitDefault) -> Int {
    guard let raw, raw > 0 else { return defaultLimit }
    return min(raw, Api.feedLimitMax)
}

/// Feed Trend の `limit`。省略時は Update より広いランキング。
public func parseFeedTrendLimit(_ raw: Int?) -> Int {
    parseFeedLimit(raw, defaultLimit: Api.feedTrendLimitDefault)
}

/// filings の `max_years` を [1, filingsMaxYearsMax] に閉じる。省略・0 以下は既定。
public func parseFilingsMaxYears(_ raw: Int?) -> Int {
    guard let raw, raw > 0 else { return Api.filingsMaxYearsDefault }
    return min(raw, Api.filingsMaxYearsMax)
}

/// クエリ `days` を [1, feedTrendDaysMax] に閉じる。省略・0 以下は `defaultDays`。
public func parseFeedDays(_ raw: Int?, defaultDays: Int = Api.feedTrendDaysDefault) -> Int {
    guard let raw, raw > 0 else { return defaultDays }
    return min(raw, Api.feedTrendDaysMax)
}

/// Feed Update の `days`。省略時は items を埋めるための長い窓。
public func parseFeedUpdateDays(_ raw: Int?) -> Int {
    parseFeedDays(raw, defaultDays: Api.feedUpdateDaysDefault)
}

/// Feed Trend の `days`。省略時は直近 7 日。
public func parseFeedTrendDays(_ raw: Int?) -> Int {
    parseFeedDays(raw, defaultDays: Api.feedTrendDaysDefault)
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

/// UTC 暦日（YYYY-MM-DD）。`submit_date_time` の日付部分および Update の `date` に使う。
public func feedDateString(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = DateFormat.hyphenated
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

/// 今日を含む UTC 暦日数の下限。`days=1` はその日、`days=7` は直近1週間。
public func feedInclusiveCutoffDateString(days: Int, now: Date = Date()) -> String {
    let todayStart = utcStartOfDay(now)
    let back = max(days, 1) - 1
    let cutoff = utcCalendar.date(byAdding: .day, value: -back, to: todayStart) ?? todayStart
    return feedDateString(cutoff)
}

/// `submit_date_time` の日付部分（YYYY-MM-DD）。短い値はそのまま。
func feedSubmitDatePrefix(_ submitDateTime: String) -> String {
    if submitDateTime.count >= DateFormat.hyphenatedLength {
        return String(submitDateTime.prefix(DateFormat.hyphenatedLength))
    }
    return submitDateTime
}

/// 上場の 4 桁コード。secCode が 5 桁かつ末尾 0 のときだけ。
/// `00000`（未割当・上場前プレースホルダ）は上場にしない。
public func listedTickerCode(fromSecCode secCode: String?) -> String? {
    guard let secCode, secCode.count == 5, secCode.hasSuffix("0") else { return nil }
    let code = String(secCode.dropLast())
    guard code.contains(where: { $0 != "0" }) else { return nil }
    return code
}

/// Feed Update: 提出日時降順の書類ストリーム（1 行 = 1 書類）。
/// `records` は呼び出し側が max(days, week) 窓・種別で絞り、提出日時降順にして渡す。
/// `total.day` はその UTC 暦日、`total.week` は直近 7 日の上場提出件数（`limit` で切る前）。
/// `items` はクエリ `days` 窓を新しい暦日から埋め、同日が `limit` を超えるとその日から安定サンプリングする。
public func assembleFeedUpdates(
    from records: [EdinetDocumentRecord], limit: Int, days: Int, docTypes: [String],
    now: Date = Date()
) -> [String: Any] {
    let today = feedDateString(now)
    let itemsCutoff = feedInclusiveCutoffDateString(days: days, now: now)
    let weekCutoff = feedInclusiveCutoffDateString(days: Api.feedUpdateWeekDays, now: now)
    var rows: [FeedUpdateRow] = []
    var dayTotal = 0
    var weekTotal = 0
    for record in records {
        guard let item = feedFilingItem(from: record) else { continue }
        let submitted = record.submitDateTime
        let date = feedSubmitDatePrefix(submitted)
        if date == today { dayTotal += 1 }
        if submitted >= weekCutoff { weekTotal += 1 }
        if submitted >= itemsCutoff {
            rows.append(
                FeedUpdateRow(docID: record.docID, submitted: submitted, date: date, item: item))
        }
    }
    return [
        "schema_version": Api.feedSchemaVersion,
        "date": today,
        "days": days,
        "total": ["day": dayTotal, "week": weekTotal] as [String: Any],
        "doc_types": docTypes,
        "items": feedSelectItems(rows, limit: limit, seed: today),
    ]
}

struct FeedUpdateRow {
    let docID: String
    let submitted: String
    let date: String
    let item: [String: Any]
}

/// 新しい暦日から `limit` 件埋める。1 日の件数が残り枠を超えるときは seed 付きで選ぶ。
func feedSelectItems(_ rows: [FeedUpdateRow], limit: Int, seed: String) -> [[String: Any]] {
    guard limit > 0 else { return [] }
    var groups: [(date: String, rows: [FeedUpdateRow])] = []
    for row in rows {
        if groups.last?.date == row.date {
            var last = groups.removeLast()
            last.rows.append(row)
            groups.append(last)
        } else {
            groups.append((row.date, [row]))
        }
    }
    var picked: [FeedUpdateRow] = []
    var remaining = limit
    for group in groups {
        if remaining <= 0 { break }
        if group.rows.count <= remaining {
            picked.append(contentsOf: group.rows)
            remaining -= group.rows.count
            continue
        }
        let chosen = Set(feedSampleIDs(group.rows.map(\.docID), count: remaining, seed: seed))
        picked.append(
            contentsOf: group.rows.filter { chosen.contains($0.docID) }
                .sorted { $0.submitted > $1.submitted })
        remaining = 0
    }
    return picked.map(\.item)
}

/// 同日過多の安定サンプル。seed（通常は集計 UTC 暦日）が同じなら同じ docID 集合。
func feedSampleIDs(_ ids: [String], count: Int, seed: String) -> [String] {
    guard count > 0 else { return [] }
    guard ids.count > count else { return ids }
    let ranked = ids.sorted { a, b in
        let ha = feedStableHash(seed + "\0" + a)
        let hb = feedStableHash(seed + "\0" + b)
        if ha != hb { return ha < hb }
        return a < b
    }
    return Array(ranked.prefix(count))
}

func feedStableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return hash
}

/// 1 書類の公開フィード行。非上場・会社開示府令以外は nil。filings 1 件に code / name を足した形。
func feedFilingItem(from record: EdinetDocumentRecord) -> [String: Any]? {
    guard Api.isCompanyDisclosureOrdinance(record.ordinanceCode) else { return nil }
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
