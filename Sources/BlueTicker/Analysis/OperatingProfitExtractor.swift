import Foundation
import SwiftSoup

struct OperatingProfitResult {
    var operatingProfit: Double?
    var operatingProfitPrior: Double?
    var sga: Double?
    var sgaPrior: Double?
    var label: String
    var method: String
    var accountingStandard: String
}

enum OperatingProfitExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> OperatingProfitResult {
        // US-GAAP 企業: HTML 仮想タグ（USGAAPHtml.parsePLFields が注入）を使用
        if accountingStandard == "US-GAAP" {
            let opItem = resolveItem(fieldSet, tags: ["USGAAP_HTML_OperatingIncome"])
            if opItem.current != nil || opItem.prior != nil {
                let sgaItem = resolveItem(fieldSet, tags: ["USGAAP_HTML_SGA"])
                return OperatingProfitResult(
                    operatingProfit: opItem.current,
                    operatingProfitPrior: opItem.prior,
                    sga: sgaItem.current,
                    sgaPrior: sgaItem.current != nil ? sgaItem.prior : nil,
                    label: "営業利益",
                    method: "usgaap_html",
                    accountingStandard: "US-GAAP"
                )
            }
            return OperatingProfitResult(
                operatingProfit: nil, operatingProfitPrior: nil,
                sga: nil, sgaPrior: nil,
                label: "営業利益", method: "not_found", accountingStandard: "US-GAAP"
            )
        }

        // 保険は営業利益を全年 null にする。経常利益・保険サービス損益・税引前は入れない。
        // 販管費は OP 成否と切り離して拾う（損保 J-GAAP 営業費、生保 J-GAAP 事業費、IFRS 一般管理費）。
        if Xbrl.isInsuranceFiling(fieldSet) {
            let sga = resolveSGA(fieldSet)
            return OperatingProfitResult(
                operatingProfit: nil, operatingProfitPrior: nil,
                sga: sga.current, sgaPrior: sga.prior,
                label: "営業利益", method: "not_found",
                accountingStandard: accountingStandard
            )
        }

        // 直接法: OPERATING_PROFIT_DIRECT_TAGS
        let opItem = resolveItem(fieldSet, tags: Xbrl.operatingProfitDirectTags)
        if opItem.tag != nil {
            let sga = resolveSGA(fieldSet)
            return OperatingProfitResult(
                operatingProfit: opItem.current,
                operatingProfitPrior: opItem.prior,
                sga: sga.current,
                sgaPrior: sga.prior,
                label: "営業利益",
                method: "direct",
                accountingStandard: accountingStandard
            )
        }

        // 計算法: GrossProfit − SGA（OperatingProfitLossIFRS が存在しない IFRS 企業向け）
        let computed = deriveSubtraction(
            fieldSet,
            minuendTags: Xbrl.grossProfitDirectTags,
            subtrahendTags: Xbrl.sgaDirectTags
        )
        if computed.current != nil || computed.prior != nil {
            let sga = resolveSGA(fieldSet)
            return OperatingProfitResult(
                operatingProfit: computed.current,
                operatingProfitPrior: computed.prior,
                sga: sga.current,
                sgaPrior: sga.prior,
                label: "営業利益",
                method: "computed",
                accountingStandard: accountingStandard
            )
        }

        // 経常利益フォールバック（J-GAAP 銀行等。保険は上で return 済み）。
        // IFRS企業では連結コンテキストに経常利益タグが残存しても使わない。
        if accountingStandard != "IFRS" {
            let oiItem = resolveItem(fieldSet, tags: Xbrl.ordinaryIncomeTags)
            if oiItem.tag != nil {
                return OperatingProfitResult(
                    operatingProfit: oiItem.current,
                    operatingProfitPrior: oiItem.prior,
                    sga: nil,
                    sgaPrior: nil,
                    label: "経常利益",
                    method: "ordinary_income",
                    accountingStandard: accountingStandard
                )
            }
        }

        return OperatingProfitResult(
            operatingProfit: nil, operatingProfitPrior: nil,
            sga: nil, sgaPrior: nil,
            label: "営業利益", method: "not_found", accountingStandard: accountingStandard
        )
    }

    /// SGA を解決する。結合タグ優先、なければ保険販管相当、なければ販売費＋一般管理費を合算。
    private static func resolveSGA(_ fieldSet: FieldSet) -> (current: Double?, prior: Double?) {
        let combined = resolveItem(fieldSet, tags: Xbrl.sgaDirectTags)
        if combined.tag != nil { return (combined.current, combined.prior) }

        let insurance = resolveItem(fieldSet, tags: Xbrl.insuranceSgaTags)
        if insurance.tag != nil { return (insurance.current, insurance.prior) }

        let selling = resolveItem(fieldSet, tags: Xbrl.sgaSellingIFRSTags)
        let ga = resolveItem(fieldSet, tags: Xbrl.sgaGaIFRSTags)
        guard selling.current != nil || ga.current != nil else { return (nil, nil) }
        let current = (selling.current ?? 0.0) + (ga.current ?? 0.0)
        let prior: Double? = (selling.prior != nil || ga.prior != nil)
            ? (selling.prior ?? 0.0) + (ga.prior ?? 0.0) : nil
        return (current, prior)
    }
}
