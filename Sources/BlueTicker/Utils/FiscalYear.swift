import Foundation

private let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = DateFormat.hyphenated
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

private let compactFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = DateFormat.compact
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

/// YYYYMMDD / YYYY-MM-DD → "YYYY-MM-DD". nil に安全。
func normalizeDateFormat(_ dateStr: String?) -> String? {
    guard let s = dateStr, !s.isEmpty else { return nil }
    if s.count == DateFormat.compactLength, s.allSatisfy(\.isNumber) {
        let y = s.prefix(4), m = s.dropFirst(4).prefix(2), d = s.dropFirst(6).prefix(2)
        return "\(y)-\(m)-\(d)"
    }
    if s.count >= DateFormat.hyphenatedLength {
        let part = String(s.prefix(DateFormat.hyphenatedLength))
        if isoFormatter.date(from: part) != nil { return part }
    }
    return nil
}

/// YYYYMMDD / YYYY-MM-DD → Date. nil に安全。
func parseDateString(_ dateStr: String?) -> Date? {
    guard let s = dateStr, !s.isEmpty else { return nil }
    if s.count == DateFormat.compactLength, s.allSatisfy(\.isNumber) {
        return compactFormatter.date(from: s)
    }
    if s.count >= DateFormat.hyphenatedLength {
        return isoFormatter.date(from: String(s.prefix(DateFormat.hyphenatedLength)))
    }
    return nil
}

/// Date → "YYYY-MM-DD"（UTC 固定）。
func formatDateString(_ date: Date) -> String {
    isoFormatter.string(from: date)
}

/// 今日（UTC）の "YYYY-MM-DD"。
public func todayUTC() -> String {
    isoFormatter.string(from: Date())
}

/// YYYYMMDD / YYYY-MM-DD → (year, month). 失敗時は (nil, nil)。
func extractYearMonth(_ dateStr: String?) -> (Int?, Int?) {
    guard let date = parseDateString(dateStr) else { return (nil, nil) }
    let comps = utcCalendar.dateComponents([.year, .month], from: date)
    return (comps.year, comps.month)
}

/// 年度終了日から年度を返す（期末月 < 12 なら year-1、12月なら year）。
func calculateFiscalYear(fyEnd: String?, fyStart: String? = nil) -> Int? {
    if let start = fyStart, let normalized = normalizeDateFormat(start) {
        return Int(normalized.prefix(4))
    }
    guard let end = fyEnd,
          let normalized = normalizeDateFormat(end),
          let date = isoFormatter.date(from: normalized)
    else { return nil }
    let comps = utcCalendar.dateComponents([.year, .month], from: date)
    guard let year = comps.year, let month = comps.month else { return nil }
    return month < 12 ? year - 1 : year
}

/// YYYY-MM-DD の前日を YYYY-MM-DD で返す。失敗時は nil。
public func dayBeforeISO(_ dateStr: String) -> String? {
    guard let date = parseDateString(dateStr),
          let prev = utcCalendar.date(byAdding: .day, value: -1, to: date)
    else { return nil }
    return formatDateString(prev)
}

/// 年度を "2023年度" 形式で返す。
func extractFiscalYearFromFyEnd(_ fyEnd: String?) -> String {
    guard let fy = calculateFiscalYear(fyEnd: fyEnd) else { return "" }
    return "\(fy)年度"
}
