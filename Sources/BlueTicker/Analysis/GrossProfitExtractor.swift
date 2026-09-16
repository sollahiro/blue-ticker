import Foundation
import SwiftSoup

struct GrossProfitResult {
    var grossProfit: Double?
    var grossProfitPrior: Double?
    var grossProfitLabel: String?
    var method: String
    var accountingStandard: String
}

enum GrossProfitExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String, xbrlDir: URL? = nil) -> GrossProfitResult {
        // US-GAAP 企業: 連結損益計算書HTML(0105010)から直接解析
        if accountingStandard == "US-GAAP" {
            if let dir = xbrlDir, let fv = USGAAPHtml.extractGrossProfit(in: dir) {
                return GrossProfitResult(
                    grossProfit: fv.current,
                    grossProfitPrior: fv.prior,
                    grossProfitLabel: nil,
                    method: "usgaap_html",
                    accountingStandard: "US-GAAP"
                )
            }
            return GrossProfitResult(
                grossProfit: nil, grossProfitPrior: nil, grossProfitLabel: nil,
                method: "not_found", accountingStandard: "US-GAAP"
            )
        }

        // 保険は粗利益を全年 null にする。direct / 営業収益−営業費用+販管費 / 業務粗利益 /
        // 営業総利益 / TextBlock / 売上−原価（原価0）のいずれも採用しない。
        if Xbrl.isInsuranceFiling(fieldSet) {
            return GrossProfitResult(
                grossProfit: nil, grossProfitPrior: nil, grossProfitLabel: nil,
                method: "not_found", accountingStandard: accountingStandard
            )
        }

        // 直接法: GrossProfit タグ（売上高 − 売上原価）。イオン等は営業総利益
        // （営業収益合計 − 営業原価合計）も併記し、販管費はその直上から落ちる。
        // Waterfall 事業利益 = GP − 販管費 が営業利益と一致する方を採用する。
        let directItem = resolveItem(fieldSet, tags: Xbrl.grossProfitDirectTags)
        let opGpItem = resolveItem(fieldSet, tags: Xbrl.operatingGrossProfitDirectTags)
        if prefersOperatingGrossProfitOverMerchandise(
            merchandise: directItem, operating: opGpItem, fieldSet: fieldSet)
        {
            return GrossProfitResult(
                grossProfit: opGpItem.current,
                grossProfitPrior: opGpItem.prior,
                grossProfitLabel: "営業総利益",
                method: "operating_gross_profit",
                accountingStandard: accountingStandard
            )
        }
        if directItem.tag != nil {
            return GrossProfitResult(
                grossProfit: directItem.current,
                grossProfitPrior: directItem.prior,
                grossProfitLabel: nil,
                method: "direct",
                accountingStandard: accountingStandard
            )
        }

        // 営業総利益（倉庫・運輸等）。売上総利益行が無いとき。開示行を構成値・銀行部品より先に取る。
        if opGpItem.tag != nil {
            return GrossProfitResult(
                grossProfit: opGpItem.current,
                grossProfitPrior: opGpItem.prior,
                grossProfitLabel: "営業総利益",
                method: "operating_gross_profit",
                accountingStandard: accountingStandard
            )
        }

        // 営業収益 − 営業費用 + 販管費。販管費が営業費用の内数であるクレジット・割賦等向け。
        // 役務タグ1本で銀行の連結業務粗利益に落ちる誤爆（イオンFS）を、本表形状が揃っているときに避ける。
        if let opexGP = extractOperatingRevenueMinusOpexPlusSGA(
            fieldSet: fieldSet, accountingStandard: accountingStandard)
        {
            return opexGP
        }

        // 銀行業: 連結業務粗利益を構成要素から積み上げ
        if let bankGP = extractBankBusinessGrossProfit(fieldSet: fieldSet, accountingStandard: accountingStandard) {
            return bankGP
        }

        let salesItem = resolveItem(fieldSet, tags: Xbrl.grossProfitSalesTags)
        let costsItem = resolveItem(fieldSet, tags: Xbrl.grossProfitCostsTags)

        // IFRS Summary型: 売上原価タグが存在しない場合、TextBlockから粗利益を抽出する
        if accountingStandard == "IFRS", costsItem.tag == nil,
           let dir = xbrlDir,
           let textblockResult = extractIfrsGPFromTextblock(in: dir) {
            return textblockResult
        }

        // 計算法: 売上高 − 売上原価（売上原価タグがない場合は 0 扱い）
        if salesItem.tag != nil {
            let gpCurrent: Double? = salesItem.current.map { $0 - (costsItem.current ?? 0.0) }
            let gpPrior: Double? = salesItem.prior.map { $0 - (costsItem.prior ?? 0.0) }
            if gpCurrent != nil || gpPrior != nil {
                return GrossProfitResult(
                    grossProfit: gpCurrent,
                    grossProfitPrior: gpPrior,
                    grossProfitLabel: nil,
                    method: "computed",
                    accountingStandard: accountingStandard
                )
            }
        }

        return GrossProfitResult(
            grossProfit: nil, grossProfitPrior: nil, grossProfitLabel: nil,
            method: "not_found", accountingStandard: accountingStandard
        )
    }

    /// IFRS連結損益計算書TextBlockから売上総利益を抽出する。
    private static func extractIfrsGPFromTextblock(in xbrlDir: URL) -> GrossProfitResult? {
        let table = XBRLUtils.extractIfrsTextblockTable(
            in: xbrlDir,
            textblockTag: "ConsolidatedStatementOfIncomeIFRSTextBlock"
        )
        guard let gp = table["売上総利益"], gp.current != nil || gp.prior != nil else { return nil }
        return GrossProfitResult(
            grossProfit: gp.current.map { $0 * Financial.millionYen },
            grossProfitPrior: gp.prior.map { $0 * Financial.millionYen },
            grossProfitLabel: nil,
            method: "ifrs_textblock",
            accountingStandard: "IFRS"
        )
    }

    /// 売上総利益と営業総利益が両方あるとき、販管費の直上（OP+SGA に近い行）を GP にする。
    /// イオン: 営業総利益 − 販管費 ＝ 営業利益。売上総利益 − 販管費は大幅赤字になる。
    /// 営業利益タグが無いときは切り替えない。OP 抽出器の `GrossProfit − SGA` と矛盾するため。
    private static func prefersOperatingGrossProfitOverMerchandise(
        merchandise: ResolvedItem, operating: ResolvedItem, fieldSet: FieldSet
    ) -> Bool {
        guard merchandise.tag != nil, operating.tag != nil else { return false }
        let sga = resolveItem(fieldSet, tags: Xbrl.sgaDirectTags)
        let op = resolveItem(fieldSet, tags: Xbrl.operatingProfitDirectTags)
        guard let gp = merchandise.current, let ogp = operating.current,
              let sgaCurrent = sga.current, let opCurrent = op.current
        else { return false }
        let implied = opCurrent + sgaCurrent
        return abs(ogp - implied) < abs(gp - implied)
    }

    /// 営業収益 − 営業費用 + 販管費。販管費が営業費用を超える年は構成しない。
    private static func extractOperatingRevenueMinusOpexPlusSGA(
        fieldSet: FieldSet, accountingStandard: String
    ) -> GrossProfitResult? {
        let revenue = resolveItem(fieldSet, tags: Xbrl.operatingRevenueForOpexSgaGrossProfitTags)
        let opex = resolveItem(fieldSet, tags: Xbrl.operatingExpenseTotalTags)
        let sga = resolveItem(fieldSet, tags: Xbrl.sgaDirectTags)
        guard revenue.tag != nil, opex.tag != nil, sga.tag != nil else { return nil }

        let current = constructedGrossProfit(
            revenue: revenue.current, opex: opex.current, sga: sga.current)
        let prior = constructedGrossProfit(
            revenue: revenue.prior, opex: opex.prior, sga: sga.prior)
        guard current != nil || prior != nil else { return nil }

        return GrossProfitResult(
            grossProfit: current,
            grossProfitPrior: prior,
            grossProfitLabel: "販管費控除前営業利益",
            method: "operating_revenue_minus_opex_plus_sga",
            accountingStandard: accountingStandard
        )
    }

    private static func constructedGrossProfit(revenue: Double?, opex: Double?, sga: Double?) -> Double? {
        guard let revenue, let opex, let sga, sga <= opex else { return nil }
        return revenue - opex + sga
    }

    private static func extractBankBusinessGrossProfit(fieldSet: FieldSet, accountingStandard: String) -> GrossProfitResult? {
        var currentTotal = 0.0
        var priorTotal = 0.0
        var hasCurrentAny = false
        var hasPriorAny = false

        for comp in Xbrl.businessGrossProfitComponents {
            let item = resolveItem(fieldSet, tags: comp.tags)
            if let c = item.current {
                currentTotal += Double(comp.sign) * c
                hasCurrentAny = true
            }
            if let p = item.prior {
                priorTotal += Double(comp.sign) * p
                hasPriorAny = true
            }
        }

        guard hasCurrentAny || hasPriorAny else { return nil }

        return GrossProfitResult(
            grossProfit: hasCurrentAny ? currentTotal : nil,
            grossProfitPrior: hasPriorAny ? priorTotal : nil,
            grossProfitLabel: "連結業務粗利益",
            method: "business_gross_profit",
            accountingStandard: accountingStandard
        )
    }
}
