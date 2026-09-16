import Foundation
import SwiftSoup

struct CashFlowResult {
    var cfo: Double?
    var cfoPrior: Double?
    var cfi: Double?
    var cfiPrior: Double?
    var accountingStandard: String
}

enum CashFlowExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> CashFlowResult {
        let cfoItem = resolveItem(fieldSet, tags: Xbrl.cfOperatingTags)
        let cfiItem = resolveItem(fieldSet, tags: Xbrl.cfInvestingTags)
        return CashFlowResult(
            cfo: cfoItem.current, cfoPrior: cfoItem.prior,
            cfi: cfiItem.current, cfiPrior: cfiItem.prior,
            accountingStandard: accountingStandard
        )
    }
}

struct CapexResult {
    var current: Double?
    var method: String
    var tag: String?
}

enum CapexExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> CapexResult {
        // 設備投資等の概要タグを優先（正値）
        let overview = resolveItem(fieldSet, tags: Xbrl.capexOverviewTags)
        if let v = overview.current {
            return CapexResult(current: v, method: "overview", tag: overview.tag)
        }
        // CF計算書フォールバック（負値を正値へ変換）
        let cfTags = accountingStandard == "IFRS" ? Xbrl.capexCFIFRSTags : Xbrl.capexCFJGAAPTags
        let item = resolveItem(fieldSet, tags: cfTags)
        if let v = item.current {
            return CapexResult(current: abs(v), method: "cf_investing", tag: item.tag)
        }
        let fallbackTags = accountingStandard == "IFRS" ? Xbrl.capexCFJGAAPTags : Xbrl.capexCFIFRSTags
        let fallback = resolveItem(fieldSet, tags: fallbackTags)
        if let v = fallback.current {
            return CapexResult(current: abs(v), method: "cf_investing_fallback", tag: fallback.tag)
        }
        return CapexResult(current: nil, method: "not_found", tag: nil)
    }
}

struct ShareBuybackResult {
    var current: Double?
    var method: String
}

enum ShareBuybackExtractor {

    /// 自己株式取得額（正値、円単位）を抽出する。
    ///
    /// XBRL の SS・CF 値は負値（キャッシュアウトフロー）で報告されるため符号反転して返す。
    /// US-GAAP HTML 仮想タグも CF 上は △ の負値なので絶対値にする。
    static func extract(
        fieldSet: FieldSet,
        ncFieldSet: FieldSet,
        equityAttributableFieldSet: FieldSet,
        accountingStandard: String
    ) -> ShareBuybackResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_CFTreasuryStock"])
            if let v = item.current {
                // CF HTML は △ の負値。financials / smoke はキャッシュアウト正。
                return ShareBuybackResult(current: abs(v), method: "usgaap_html")
            }
            let ncItem = resolveItem(ncFieldSet, tags: Xbrl.shareBuybackSSJGAAPTags)
            if ncItem.tag != nil, let v = ncItem.current {
                return ShareBuybackResult(current: -v, method: "ss_nonconsolidated")
            }
            return ShareBuybackResult(current: nil, method: "not_found")
        }

        let ssTags = accountingStandard == "J-GAAP" ? Xbrl.shareBuybackSSJGAAPTags : Xbrl.shareBuybackSSIFRSTags
        let cfTags = accountingStandard == "J-GAAP" ? Xbrl.shareBuybackCFJGAAPTags : Xbrl.shareBuybackCFIFRSTags

        // 1. 株主資本等変動計算書（IFRS は親会社帰属持分コンテキストを優先）
        let ssFieldSet = accountingStandard == "IFRS" ? equityAttributableFieldSet : fieldSet
        let ssItem = resolveItem(ssFieldSet, tags: ssTags)
        if ssItem.tag != nil, let v = ssItem.current {
            return ShareBuybackResult(current: -v, method: accountingStandard == "IFRS" ? "ss_equity_parent" : "ss_consolidated")
        }

        // 2. CF計算書・財務活動
        let cfItem = resolveItem(fieldSet, tags: cfTags)
        if cfItem.tag != nil {
            return ShareBuybackResult(current: cfItem.current.map { -$0 }, method: "cf_financing")
        }

        // 3. 株主資本等変動計算書・非連結（単独決算企業のフォールバック）
        let ncItem = resolveItem(ncFieldSet, tags: ssTags)
        if ncItem.tag != nil, let v = ncItem.current {
            return ShareBuybackResult(current: -v, method: "ss_nonconsolidated")
        }

        return ShareBuybackResult(current: nil, method: "not_found")
    }
}

struct CfTreasuryStockResult {
    var current: Double?
    var method: String
}

enum CfTreasuryStockExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> CfTreasuryStockResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_CFTreasuryStock"])
            if item.tag != nil {
                // CF HTML は △ の負値。financials / smoke はキャッシュアウト正。
                return CfTreasuryStockResult(current: item.current.map { abs($0) }, method: "usgaap_html")
            }
            return CfTreasuryStockResult(current: nil, method: "not_found")
        }
        let cfTags = accountingStandard == "J-GAAP"
            ? Xbrl.shareBuybackCFJGAAPTags
            : Xbrl.shareBuybackCFIFRSTags
        let item = resolveItem(fieldSet, tags: cfTags)
        guard item.tag != nil else {
            return CfTreasuryStockResult(current: nil, method: "not_found")
        }
        return CfTreasuryStockResult(current: item.current.map { -$0 }, method: "cf_financing")
    }
}

struct DividendResult {
    var current: Double?
    var method: String
}

enum DividendSSExtractor {

    static func extract(
        fieldSet: FieldSet,
        ncFieldSet: FieldSet,
        equityAttributableFieldSet: FieldSet,
        accountingStandard: String
    ) -> DividendResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_DividendSS"])
            if item.tag != nil {
                return DividendResult(current: item.current.map { -$0 }, method: "usgaap_html")
            }
            return DividendResult(current: nil, method: "not_found")
        }
        let ssTags = accountingStandard == "J-GAAP"
            ? Xbrl.dividendSSJGAAPTags
            : Xbrl.dividendSSIFRSTags

        // IFRS: 親会社帰属持分コンテキストを優先（NCI除外）
        if accountingStandard == "IFRS" {
            let item = resolveItem(equityAttributableFieldSet, tags: ssTags)
            if item.tag != nil {
                return DividendResult(current: item.current.map { -$0 }, method: "ss_equity_parent")
            }
        }

        let item = resolveItem(fieldSet, tags: ssTags)
        if item.tag != nil {
            return DividendResult(current: item.current.map { -$0 }, method: "ss_equity")
        }

        // 非連結フォールバック（単体決算企業用）
        let ncItem = resolveItem(ncFieldSet, tags: ssTags)
        if ncItem.tag != nil {
            return DividendResult(current: ncItem.current.map { -$0 }, method: "ss_nonconsolidated")
        }

        return DividendResult(current: nil, method: "not_found")
    }
}

enum DividendPaidExtractor {

    static func extract(fieldSet: FieldSet, accountingStandard: String) -> DividendResult {
        if accountingStandard == "US-GAAP" {
            let item = resolveItem(fieldSet, tags: ["USGAAP_HTML_DividendPaidCF"])
            if item.tag != nil {
                return DividendResult(current: item.current.map { -$0 }, method: "usgaap_html")
            }
            return DividendResult(current: nil, method: "not_found")
        }
        let cfTags = accountingStandard == "J-GAAP"
            ? Xbrl.dividendPaidCFJGAAPTags
            : Xbrl.dividendPaidCFIFRSTags
        let item = resolveItem(fieldSet, tags: cfTags)
        guard item.tag != nil else {
            return DividendResult(current: nil, method: "not_found")
        }
        return DividendResult(current: item.current.map { -$0 }, method: "cf_financing")
    }
}
