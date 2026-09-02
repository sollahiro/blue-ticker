import Foundation

enum Format {
    static func fy(_ raw: String?) -> String {
        guard let raw, raw.count >= 7 else { return raw ?? "—" }
        let year = raw.prefix(4)
        let month = raw.dropFirst(5).prefix(2)
        guard let y = Int(year) else { return raw }
        return String(format: "%02d/%@", y % 100, String(month))
    }

    static func millionYen(_ value: Double?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))") + "百万"
    }

    static func okuYen(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f億円", value / 100.0)
    }

    static func percentPoints(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f%%", value)
    }

    /// 検索結果・銘柄ヘッダ用。法人格の「株式会社」は出さない。
    static func displayName(_ name: String, fallback: String = "") -> String {
        let stripped = name
            .replacingOccurrences(of: "株式会社", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty {
            return fallback.isEmpty ? name : fallback
        }
        return stripped
    }
}
