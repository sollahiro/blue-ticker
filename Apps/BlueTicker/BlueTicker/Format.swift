import Foundation

enum Format {
    static func fy(_ raw: String?) -> String {
        guard let raw, raw.count >= 7 else { return raw ?? "—" }
        let year = raw.prefix(4)
        let month = raw.dropFirst(5).prefix(2)
        guard let y = Int(year) else { return raw }
        return String(format: "%02d/%@", y % 100, String(month))
    }

    /// 「26年2月期」のように、年度末を期の日本語表記で返す。
    static func fyJapanese(_ raw: String?) -> String {
        guard let raw, raw.count >= 7 else { return raw ?? "—" }
        guard let year = Int(raw.prefix(4)), let month = Int(raw.dropFirst(5).prefix(2)) else {
            return raw
        }
        return "\(year % 100)年\(month)月期"
    }

    /// API の金額（通貨の基本単位。円なら円）を、3〜4桁になる単位へ自動変換。整数部が2桁なら小数1桁。
    /// `currency` は ISO 4217（`years[].currency`）。円以外は「百万ドル」のように通貨名を付ける。
    static func autoYen(_ amount: Double?, currency: String? = nil) -> String {
        guard let amount else { return "—" }
        let scale = yenScale(abs(amount), currency: currency)
        return scaledYen(amount, scale: scale) + scale.unit
    }

    /// 指定の単位で金額文字列を返す。単位サフィックスは付けない。
    static func scaledYen(_ amount: Double?, scale: YenScale) -> String {
        guard let amount else { return "—" }
        let scaled = amount / scale.divisor
        return groupedNumber(scaled, fractionDigits: scale.fractionDigits)
    }

    /// 指定した値群から最適な共通の金額単位を返す。
    static func commonScale(for values: [Double?], currency: String? = nil) -> YenScale? {
        let maxValue = values.compactMap { $0 }.map(abs).max() ?? 0
        guard maxValue > 0 else { return nil }
        return yenScale(maxValue, currency: currency)
    }

    /// 円 → 億円。サフィックス付き。
    static func okuYen(_ yen: Double?) -> String {
        guard let yen else { return "—" }
        return groupedNumber(yen / 100_000_000) + "億円"
    }

    /// 応答の通貨のうち、全年度で同じものの表示名（円・ドル・ユーロ。ほかは通貨コード）。
    static func currencyName(_ currency: String?) -> String {
        switch currency ?? "JPY" {
        case "JPY": return "円"
        case "USD": return "ドル"
        case "EUR": return "ユーロ"
        case let other: return other
        }
    }

    static func chronological(_ years: [FinancialsYear]) -> [FinancialsYear] {
        years.sorted { ($0.fyEnd ?? "") < ($1.fyEnd ?? "") }
    }

    static func latestYear(_ years: [FinancialsYear]) -> FinancialsYear? {
        FundMath.latestYear(years, fyEnd: \.fyEnd)
    }

    /// 実円（ルックスルー・投下資本）。本表の百万円スケールは使わない。
    static func yenCash(_ yen: Double?) -> String {
        guard let yen else { return "—" }
        return groupedNumber(yen, fractionDigits: 0) + "円"
    }

    /// 一株指標・取得単価。単位は円/株。
    static func yenPerShare(_ yen: Double?) -> String {
        guard let yen else { return "—" }
        let digits = yen.rounded() == yen ? 0 : 2
        return groupedNumber(yen, fractionDigits: digits) + "円/株"
    }

    static func shares(_ quantity: Double?) -> String {
        guard let quantity else { return "—" }
        let digits = quantity.rounded() == quantity ? 0 : 2
        return groupedNumber(quantity, fractionDigits: digits) + "株"
    }

    static func percent(_ value: Double?, digits: Int = 1, includeUnit: Bool = true) -> String {
        guard let value else { return "—" }
        let number = String(format: "%.\(digits)f", value)
        return includeUnit ? number + "%" : number
    }

    static func times(_ value: Double?, includeUnit: Bool = true) -> String {
        guard let value else { return "—" }
        let number = String(format: "%.2f", value)
        return includeUnit ? number + "倍" : number
    }

    static func percentPoints(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f", value) + "%"
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

    /// 純利益率 = 純利益 ÷ 売上高 × 100
    static func netProfitMargin(_ year: FinancialsYear) -> Double? {
        ratio(year.netProfit, dividedBy: year.sales)
    }

    /// フリーCF = 営業CF + 投資CF
    static func freeCashFlow(_ year: FinancialsYear) -> Double? {
        guard let cfo = year.cfo, let cfi = year.cfi else { return nil }
        return cfo + cfi
    }

    /// 検索結果・銘柄ヘッダ用。法人格の「株式会社」は出さない。
    /// 「ホールディングス」で言い切るときだけ HD。直前の「・」は残さない。
    /// 途中の「ホールディングス・アンド…」は触らない。
    static func displayName(_ name: String, fallback: String = "") -> String {
        var stripped = name
            .replacingOccurrences(of: "株式会社", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasSuffix("・ホールディングス") || stripped.hasSuffix("･ホールディングス") {
            stripped.removeLast("・ホールディングス".count)
            stripped += "HD"
        } else if stripped.hasSuffix("ホールディングス") {
            stripped.removeLast("ホールディングス".count)
            stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            stripped += "HD"
        }
        if stripped.isEmpty {
            return fallback.isEmpty ? name : fallback
        }
        return stripped
    }

    /// Feed の提出日時（JST の `YYYY-MM-DD HH:mm`。RSS の `pubDate` から作る）を公開日として出す。
    static func submittedDate(_ raw: String) -> String {
        let prefix = String(raw.prefix(10))
        guard prefix.count == 10 else { return raw }
        return prefix.replacingOccurrences(of: "-", with: "/")
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

    private static func yenScale(_ absAmount: Double, currency: String? = nil) -> YenScale {
        // 判定は百万単位で行う（百万・億・十億・兆）。API は基本単位なので先に百万で割る。
        let absMillion = absAmount / 1_000_000
        let name = currencyName(currency)
        let units: [(divisor: Double, name: String)] = [
            (1, "百万" + name),
            (100, "億" + name),
            (1_000, "十億" + name),
            (1_000_000, "兆" + name),
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
            divisor: chosen.divisor * 1_000_000,
            unit: chosen.name,
            fractionDigits: scaled < 100 ? 1 : 0
        )
    }
}
