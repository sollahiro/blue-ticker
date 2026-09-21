// LLM 内訳正規化器が共有する金額スケール。
// 有報 HTML 表は百万円表示、連結売上の比較分母は円。LLM が unit=million_yen と
// 申告しつつ行金額を既に円で返すと、従来の一律 ×1e6 が分母を約 1e12（百万円表示比）に膨らませる。

import Foundation

enum BreakdownLLMAmountScale {
    /// 申告 unit と行金額・連結売上（円）から、円へ直す倍率を決める。
    /// `million_yen` でも行金額が既に円スケールなら 1。未知 unit は unresolved。
    static func yenMultiplier(
        declaredUnit: String,
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> (multiplier: Double, unresolved: Bool) {
        switch declaredUnit {
        case "yen":
            return (1, false)
        case "million_yen":
            return (
                millionYenMultiplier(rawAmounts: rawAmounts, consolidatedSales: consolidatedSales),
                false
            )
        default:
            return (1, true)
        }
    }

    private static func millionYenMultiplier(
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> Double {
        let million = Financial.millionYen
        guard let sales = consolidatedSales, sales != 0 else { return million }
        let rawRef = rawAmounts.map { abs($0) }.max() ?? 0
        guard rawRef != 0 else { return million }
        let asIs = rawRef / abs(sales)
        let asMillion = rawRef * million / abs(sales)
        if closerToUnity(asIs, than: asMillion) {
            return 1
        }
        return million
    }

    private static func closerToUnity(_ a: Double, than b: Double) -> Bool {
        logDistanceFromUnity(a) < logDistanceFromUnity(b)
    }

    private static func logDistanceFromUnity(_ ratio: Double) -> Double {
        abs(log10(max(ratio, Double.leastNonzeroMagnitude)))
    }
}
