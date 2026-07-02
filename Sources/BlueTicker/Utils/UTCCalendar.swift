import Foundation

/// EDINET・キャッシュの日付処理で共有する UTC 固定カレンダー。
/// `Calendar.current` を使うと JST 環境で日付境界（0:00〜8:59）に、
/// UTC 固定の EDINET 処理（`EdinetAPIClient`）と TTL・現在年の判定が 1 日ずれる。
/// 新規コードは `Calendar.current` ではなくこれを使う（`date-conversion.md`）。
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
