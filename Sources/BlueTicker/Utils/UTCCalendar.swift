import Foundation

/// EDINET・キャッシュの日付処理で共有する UTC 固定カレンダー。
/// `Calendar.current` を使うと JST 環境で日付境界（0:00〜8:59）に、
/// UTC 固定の EDINET 処理（`EdinetAPIClient`）と TTL・現在年の判定が 1 日ずれる。
/// 新規コードは `Calendar.current` ではなくこれを使う（`.agents/rules/data-handling.md`）。
let utcCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}()

/// 過去日時（ファイル mtime など）から現在（UTC）までの経過日数。負にはならない。
/// キャッシュ TTL 判定で共有する（`CacheManager` / `CachePruner` / `EdinetCacheStore`）。
func elapsedDaysUTC(since date: Date, now: Date = Date()) -> Int {
    max(0, utcCalendar.dateComponents([.day], from: date, to: now).day ?? 0)
}

/// 過去日時（ファイル mtime など）から現在までの経過時間（時間単位）。負にはならない。
/// 当日分キャッシュの TTL 判定で使う（日単位の `elapsedDaysUTC` は同一暦日内の経過を
/// 検知できないため、EDINET 日次キャッシュの当日分だけ時間単位で区切る）。
func elapsedHoursUTC(since date: Date, now: Date = Date()) -> Double {
    max(0, now.timeIntervalSince(date) / 3600)
}

/// 指定日時を UTC の暦日の開始（0時）へ切り詰める。
func utcStartOfDay(_ date: Date) -> Date {
    let comps = utcCalendar.dateComponents([.year, .month, .day], from: date)
    return utcCalendar.date(from: comps)!
}

// MARK: - EDINET 日（JST）

/// EDINET の日付ラベル（書類一覧 API の `date`）は日本時間（JST, UTC+9・夏時間なし）の暦日。
/// 「今日」「その日が締まったか」は UTC の暦日ではなく JST で判定する（JST 0:00〜8:59 に
/// UTC 暦日で判定すると 1 日ずれる）。ラベルの Date 表現は従来どおり `parseDateString` と同じ
/// 「UTC 0時」形のまま扱い、境界の判定だけを JST で行う。
private let edinetDayCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
    return cal
}()

/// EDINET（JST）の今日を日付ラベル形（UTC 0時表現。`parseDateString` と比較可能）で返す。
func edinetToday(_ now: Date = Date()) -> Date {
    let comps = edinetDayCalendar.dateComponents([.year, .month, .day], from: now)
    return utcCalendar.date(from: comps)!
}

/// 日付ラベル（UTC 0時表現）の EDINET 日が締まる瞬間（翌日 0:00 JST）。
/// これ以降に書いた日次検索キャッシュだけが、その日の確定版になりうる。
func edinetDayClose(_ day: Date) -> Date {
    let comps = utcCalendar.dateComponents([.year, .month, .day], from: day)
    let start = edinetDayCalendar.date(from: comps)!
    return edinetDayCalendar.date(byAdding: .day, value: 1, to: start)!
}
