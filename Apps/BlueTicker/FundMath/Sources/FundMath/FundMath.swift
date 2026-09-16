import Foundation

/// マイファンドのルックスルー計算。入力は最新 FY の Summary 一株指標（`eps` / `bps`、円/株）。
/// Notes EPS は使わない。欠測は `nil`（UI は「—」）で、合計からも除外する。
enum FundMath {
    /// Summary 最新 FY の一株指標。単位は円/株（本表の百万円とは別）。
    struct PerShare: Equatable, Sendable {
        var fyEnd: String? = nil
        var epsYen: Double? = nil
        var bpsYen: Double? = nil
    }

    struct Position: Equatable, Sendable {
        var id: String
        var code: String
        var quantity: Double? = nil
        var acquisitionPriceYen: Double? = nil

        var isHolding: Bool {
            FundMath.isHolding(quantity: quantity, acquisitionPriceYen: acquisitionPriceYen)
        }
    }

    struct RowMetrics: Equatable, Sendable {
        var isHolding: Bool
        var lookThroughProfitYen: Double?
        var lookThroughBookYen: Double?
        var investedCapitalYen: Double?
    }

    struct TickerTotal: Equatable, Sendable {
        var code: String
        var quantity: Double
        var lookThroughProfitYen: Double?
        var lookThroughBookYen: Double?
        var investedCapitalYen: Double
    }

    struct Snapshot: Equatable, Sendable {
        var lookThroughProfitYen: Double?
        var lookThroughBookYen: Double?
        var investedCapitalYen: Double?
        /// 百分率（12.3 = 12.3%）。時価・純資産合計は分母にしない。
        var fundROEPercent: Double?
        var tickerTotals: [TickerTotal]
    }

    /// 株数と取得単価（円/株）の両方が有限値なら保有。片方だけ・欠測はウォッチ。
    static func isHolding(quantity: Double?, acquisitionPriceYen: Double?) -> Bool {
        guard let quantity, let acquisitionPriceYen else { return false }
        return quantity.isFinite && acquisitionPriceYen.isFinite
    }

    /// `fy_end` が空でない年度のうち、文字列最大（最新 FY）。
    static func latestYear<T>(_ years: [T], fyEnd: (T) -> String?) -> T? {
        years
            .filter { !(fyEnd($0) ?? "").isEmpty }
            .max { fyEnd($0)! < fyEnd($1)! }
    }

    static func rowMetrics(position: Position, perShare: PerShare) -> RowMetrics {
        guard position.isHolding, let quantity = position.quantity,
            let acquisition = position.acquisitionPriceYen
        else {
            return RowMetrics(
                isHolding: false,
                lookThroughProfitYen: nil,
                lookThroughBookYen: nil,
                investedCapitalYen: nil
            )
        }
        return RowMetrics(
            isHolding: true,
            lookThroughProfitYen: finiteProduct(perShare.epsYen, quantity),
            lookThroughBookYen: finiteProduct(perShare.bpsYen, quantity),
            investedCapitalYen: quantity * acquisition
        )
    }

    /// 公開合計は銘柄単位で合算（口座行は足してから EPS/BPS を掛ける）。ウォッチは除外。
    static func snapshot(
        positions: [Position],
        perShareByCode: [String: PerShare]
    ) -> Snapshot {
        var quantities: [String: Double] = [:]
        var invested: [String: Double] = [:]
        var order: [String] = []
        for position in positions where position.isHolding {
            guard let quantity = position.quantity,
                let acquisition = position.acquisitionPriceYen
            else { continue }
            if quantities[position.code] == nil {
                order.append(position.code)
            }
            quantities[position.code, default: 0] += quantity
            invested[position.code, default: 0] += quantity * acquisition
        }

        var tickerTotals: [TickerTotal] = []
        var profitSum = 0.0
        var profitSeen = false
        var bookSum = 0.0
        var bookSeen = false
        var investedSum = 0.0
        var investedSeen = false
        var roeProfit = 0.0
        var roeInvested = 0.0
        var roeSeen = false

        for code in order {
            let quantity = quantities[code] ?? 0
            let capital = invested[code] ?? 0
            let share = perShareByCode[code] ?? PerShare()
            let profit = finiteProduct(share.epsYen, quantity)
            let book = finiteProduct(share.bpsYen, quantity)
            tickerTotals.append(
                TickerTotal(
                    code: code,
                    quantity: quantity,
                    lookThroughProfitYen: profit,
                    lookThroughBookYen: book,
                    investedCapitalYen: capital
                ))
            investedSum += capital
            investedSeen = true
            if let profit {
                profitSum += profit
                profitSeen = true
            }
            if let book {
                bookSum += book
                bookSeen = true
            }
            if let profit {
                roeProfit += profit
                roeInvested += capital
                roeSeen = true
            }
        }

        let fundROE: Double?
        if roeSeen, roeInvested != 0 {
            fundROE = (roeProfit / roeInvested) * 100
        } else {
            fundROE = nil
        }

        return Snapshot(
            lookThroughProfitYen: profitSeen ? profitSum : nil,
            lookThroughBookYen: bookSeen ? bookSum : nil,
            investedCapitalYen: investedSeen ? investedSum : nil,
            fundROEPercent: fundROE,
            tickerTotals: tickerTotals
        )
    }

    private static func finiteProduct(_ perShareYen: Double?, _ quantity: Double) -> Double? {
        guard let perShareYen, perShareYen.isFinite else { return nil }
        return perShareYen * quantity
    }
}
