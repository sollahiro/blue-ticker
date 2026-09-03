import Foundation

enum Format {
    static func fy(_ raw: String?) -> String {
        guard let raw, raw.count >= 7 else { return raw ?? "—" }
        let year = raw.prefix(4)
        let month = raw.dropFirst(5).prefix(2)
        guard let y = Int(year) else { return raw }
        return String(format: "%02d/%@", y % 100, String(month))
    }

    /// API の百万円を、3〜4桁になる単位へ自動変換。整数部が2桁なら小数1桁。
    static func autoYen(_ millionYen: Double?) -> String {
        guard let millionYen else { return "—" }
        let scale = yenScale(abs(millionYen))
        return scaledYen(millionYen, scale: scale) + scale.unit
    }

    /// 指定の単位で金額文字列を返す。単位サフィックスは付けない。
    static func scaledYen(_ millionYen: Double?, scale: YenScale) -> String {
        guard let millionYen else { return "—" }
        let scaled = millionYen / scale.divisor
        return groupedNumber(scaled, fractionDigits: scale.fractionDigits)
    }

    /// 指定した値群から最適な共通の金額単位を返す。
    static func commonScale(for values: [Double?]) -> YenScale? {
        let maxValue = values.compactMap { $0 }.map(abs).max() ?? 0
        guard maxValue > 0 else { return nil }
        return yenScale(maxValue)
    }

    /// 百万円 → 億円。サフィックス付き（条件検索のスライダー用）。
    static func okuYen(_ value: Double?) -> String {
        guard let value else { return "—" }
        return groupedNumber(value / 100.0) + "億円"
    }

    static func chronological(_ years: [FinancialsYear]) -> [FinancialsYear] {
        years.sorted { ($0.fyEnd ?? "") < ($1.fyEnd ?? "") }
    }

    static func percent(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f%%", value)
    }

    static func times(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f倍", value)
    }

    static func percentPoints(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f%%", value)
    }

    static func groupedNumber(_ value: Double, fractionDigits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        let number = fractionDigits == 0 ? value.rounded() : value
        return formatter.string(from: NSNumber(value: number)) ?? "\(Int(value.rounded()))"
    }

    /// 自己資本比率 = 純資産 ÷ 総資産 × 100
    static func equityRatio(_ year: FinancialsYear) -> Double? {
        ratio(year.netAssets, dividedBy: year.totalAssets)
    }

    /// 流動比率 = 流動資産 ÷ 流動負債 × 100
    static func currentRatio(_ year: FinancialsYear) -> Double? {
        ratio(year.currentAssets, dividedBy: year.currentLiabilities)
    }

    /// 固定比率 = 固定資産 ÷ 自己資本 × 100
    static func fixedRatio(_ year: FinancialsYear) -> Double? {
        ratio(year.nonCurrentAssets, dividedBy: year.netAssets)
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

    private static func ratio(_ numerator: Double?, dividedBy denominator: Double?) -> Double? {
        guard let numerator, let denominator, denominator != 0 else { return nil }
        return numerator / denominator * 100
    }

    struct YenScale {
        var divisor: Double
        var unit: String
        var fractionDigits: Int
    }

    private static func yenScale(_ absMillion: Double) -> YenScale {
        let units: [(divisor: Double, name: String)] = [
            (1, "百万円"),
            (100, "億円"),
            (1_000, "十億円"),
            (1_000_000, "兆円"),
        ]
        let inRange = units.filter { scaled in
            let value = absMillion / scaled.divisor
            return value >= 100 && value < 10_000
        }
        let chosen: (divisor: Double, name: String)
        if let fourDigits = inRange.last(where: { absMillion / $0.divisor >= 1_000 }) {
            chosen = fourDigits
        } else if let threeDigits = inRange.last {
            chosen = threeDigits
        } else if absMillion < 100 {
            chosen = units[0]
        } else {
            chosen = units.last!
        }
        let scaled = absMillion / chosen.divisor
        return YenScale(
            divisor: chosen.divisor,
            unit: chosen.name,
            fractionDigits: scaled < 100 ? 1 : 0
        )
    }
}
