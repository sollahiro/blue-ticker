import Foundation

// MARK: - 型変換

func toFloat(_ value: Any?) -> Double? {
    switch value {
    case let d as Double: return d.isNaN || d.isInfinite ? nil : d
    case let f as Float:  return Double(f).isNaN ? nil : Double(f)
    case let i as Int:    return Double(i)
    case let s as String: return Double(s)
    default:              return nil
    }
}

func toInt(_ value: Any?) -> Int? {
    switch value {
    case let i as Int:    return i
    case let d as Double: return d.isNaN || d.isInfinite ? nil : Int(d)
    case let s as String: return Int(s)
    default:              return nil
    }
}

func isValidValue(_ value: Double?) -> Bool {
    guard let v = value else { return false }
    return !v.isNaN && !v.isInfinite
}

func isValidFinancialRecord(_ record: [String: Any]) -> Bool {
    guard let sales = toFloat(record["Sales"]) else { return false }
    return isValidValue(sales) && sales > 0
}

// MARK: - 日付

func normalizeDate(_ dateStr: String?) -> String? { normalizeDateFormat(dateStr) }
func parseDate(_ dateStr: String?) -> Date? { parseDateString(dateStr) }

func isFutureDate(_ dateStr: String?) -> Bool {
    guard let date = parseDateString(dateStr) else { return false }
    return date > Date()
}
