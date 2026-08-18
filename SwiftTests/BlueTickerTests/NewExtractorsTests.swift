// 今回追加した6エクストラクターのユニットテスト
// CfTreasuryStock / DividendSS / DividendPaid / AccountsReceivable / Inventory / AccountsPayable

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct NewExtractorsTests {

    // MARK: - CfTreasuryStockExtractor

    @Test func testCfTreasuryStockJgaap() {
        // CF 値は負値（アウトフロー） → 正値に変換
        let fs = makeFieldSet(("PurchaseOfTreasuryStockFinCF", -5_000_000.0, nil))
        let result = CfTreasuryStockExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 5_000_000.0)
        #expect(result.method == "cf_financing")
    }

    @Test func testCfTreasuryStockIfrs() {
        let fs = makeFieldSet(("PaymentsForPurchaseOfTreasurySharesFinCFIFRS", -3_000_000.0, nil))
        let result = CfTreasuryStockExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 3_000_000.0)
        #expect(result.method == "cf_financing")
    }

    @Test func testCfTreasuryStockIfrsFallbackTag() {
        let fs = makeFieldSet(("AcquisitionOfTreasurySharesFinCFIFRS", -2_000_000.0, nil))
        let result = CfTreasuryStockExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 2_000_000.0)
    }

    @Test func testCfTreasuryStockUsgaapReturnsNil() {
        let fs = makeFieldSet(("PurchaseOfTreasuryStockFinCF", -1_000_000.0, nil))
        let result = CfTreasuryStockExtractor.extract(fieldSet: fs, accountingStandard: "US-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    @Test func testCfTreasuryStockUsgaapAbsNegativeHtml() {
        // CF HTML の △ は負値。financials はキャッシュアウト正。
        let fs = makeFieldSet(("USGAAP_HTML_CFTreasuryStock", -16_000_000.0, nil))
        let result = CfTreasuryStockExtractor.extract(fieldSet: fs, accountingStandard: "US-GAAP")
        #expect(result.current == 16_000_000.0)
        #expect(result.method == "usgaap_html")
    }

    @Test func testCfTreasuryStockNotFound() {
        let result = CfTreasuryStockExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    // MARK: - ShareBuybackExtractor

    @Test func testShareBuybackUsgaapAbsNegativeHtml() {
        let fs = makeFieldSet(("USGAAP_HTML_CFTreasuryStock", -300_019_000_000.0, nil))
        let result = ShareBuybackExtractor.extract(
            fieldSet: fs, ncFieldSet: [:], equityAttributableFieldSet: [:],
            accountingStandard: "US-GAAP")
        #expect(result.current == 300_019_000_000.0)
        #expect(result.method == "usgaap_html")
    }

    @Test func testShareBuybackJgaapNegatesSS() {
        let fs = makeFieldSet(("PurchaseOfTreasuryStock", -1_227_000_000.0, nil))
        let result = ShareBuybackExtractor.extract(
            fieldSet: fs, ncFieldSet: [:], equityAttributableFieldSet: [:],
            accountingStandard: "J-GAAP")
        #expect(result.current == 1_227_000_000.0)
        #expect(result.method == "ss_consolidated")
    }

    // MARK: - DividendSSExtractor

    @Test func testDividendSSJgaap() {
        // SS 値は負値（純資産の減少） → 正値に変換
        let fs = makeFieldSet(("DividendsFromSurplus", -2_000_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, ncFieldSet: [:], equityAttributableFieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == 2_000_000.0)
        #expect(result.method == "ss_equity")
    }

    @Test func testDividendSSIfrs() {
        // equityAttributableFieldSet が空の場合は fieldSet にフォールバック
        let fs = makeFieldSet(("DividendsToOwnersOfParentSSIFRS", -4_000_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, ncFieldSet: [:], equityAttributableFieldSet: [:], accountingStandard: "IFRS")
        #expect(result.current == 4_000_000.0)
        #expect(result.method == "ss_equity")
    }

    @Test func testDividendSSIfrsEquityAttributable() {
        // IFRS: equityAttributableFieldSet の値を優先して返す
        let eaFs = makeFieldSet(("DividendsToOwnersOfParentSSIFRS", -3_900_000.0, nil))
        let fs   = makeFieldSet(("DividendsSSIFRS", -9_900_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, ncFieldSet: [:], equityAttributableFieldSet: eaFs, accountingStandard: "IFRS")
        #expect(result.current == 3_900_000.0)
        #expect(result.method == "ss_equity_parent")
    }

    @Test func testDividendSSIfrsFallbackTag() {
        // equityAttributableFieldSet が空の場合は fieldSet にフォールバック
        let fs = makeFieldSet(("DividendsSSIFRS", -3_500_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, ncFieldSet: [:], equityAttributableFieldSet: [:], accountingStandard: "IFRS")
        #expect(result.current == 3_500_000.0)
    }

    @Test func testDividendSSUsgaapReturnsNil() {
        let fs = makeFieldSet(("DividendsCS", -1_000_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, ncFieldSet: [:], equityAttributableFieldSet: [:], accountingStandard: "US-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    @Test func testDividendSSNotFound() {
        let result = DividendSSExtractor.extract(fieldSet: [:], ncFieldSet: [:], equityAttributableFieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    @Test func testDividendSSNonConsolidated() {
        // 非連結企業: ncFieldSet からフォールバック取得
        let ncFs = makeFieldSet(("DividendsFromSurplus", -5_000_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: [:], ncFieldSet: ncFs, equityAttributableFieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == 5_000_000.0)
        #expect(result.method == "ss_nonconsolidated")
    }

    // MARK: - DividendPaidExtractor

    @Test func testDividendPaidJgaap() {
        let fs = makeFieldSet(("CashDividendsPaidFinCF", -2_500_000.0, nil))
        let result = DividendPaidExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 2_500_000.0)
        #expect(result.method == "cf_financing")
    }

    @Test func testDividendPaidIfrsOwners() {
        let fs = makeFieldSet(("DividendsPaidToOwnersOfParentFinCFIFRS", -3_000_000.0, nil))
        let result = DividendPaidExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 3_000_000.0)
        #expect(result.method == "cf_financing")
    }

    @Test func testDividendPaidIfrsFallback() {
        let fs = makeFieldSet(("DividendsPaidFinCFIFRS", -2_000_000.0, nil))
        let result = DividendPaidExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 2_000_000.0)
    }

    @Test func testDividendPaidUsgaapReturnsNil() {
        let fs = makeFieldSet(("DividendsPaidFinCF", -1_000_000.0, nil))
        let result = DividendPaidExtractor.extract(fieldSet: fs, accountingStandard: "US-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    @Test func testDividendPaidNotFound() {
        let result = DividendPaidExtractor.extract(fieldSet: [:], accountingStandard: "IFRS")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    // MARK: - AccountsReceivableExtractor

    @Test func testAccountsReceivableJgaapCombined() {
        // 受取手形及び売掛金（合算タグ優先）
        let fs = makeFieldSet(("NotesAndAccountsReceivableTrade", 100_000_000.0, 90_000_000.0))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 100_000_000.0)
        #expect(result.method == "direct")
    }

    @Test func testAccountsReceivableJgaapFallback() {
        // 合算タグなし → 売掛金単独タグにフォールバック
        let fs = makeFieldSet(("AccountsReceivableTrade", 80_000_000.0, nil))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 80_000_000.0)
    }

    @Test func testAccountsReceivableIfrs() {
        let fs = makeFieldSet(("TradeAndOtherReceivablesCAIFRS", 150_000_000.0, 140_000_000.0))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 150_000_000.0)
        #expect(result.method == "direct")
    }

    @Test func testAccountsReceivableIfrsFallbackTag() {
        let fs = makeFieldSet(("TradeAndOtherReceivables2CAIFRS", 120_000_000.0, nil))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 120_000_000.0)
    }

    @Test func testAccountsReceivableIfrsTradeOnly() {
        let fs = makeFieldSet(("TradeReceivablesCAIFRS", 100_000_000.0, nil))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 100_000_000.0)
    }

    @Test func testAccountsReceivableIfrsTradeAndContractAssetsExtension() {
        // 売上債権＋契約資産の企業拡張タグ（日立 6501、2025-03 期: 3,496,340 百万）。
        // 拡張タグを取りこぼすと売掛金が nil になり運転資本・DSO・CCC が連鎖欠損する。
        let fs = makeFieldSet(("TradeReceivablesAndContractAssetsCAIFRSIFRS", 3_496_340.0, 2_991_316.0))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 3_496_340.0)
        #expect(result.method == "direct")
    }

    @Test func testAccountsReceivableJgaapReceivablesFromContractsWithCustomersExtension() {
        // 収益認識基準移行期の企業拡張タグ（ぷらっとホーム 6836、2023-03 期: 168,055 千円）。
        // 拡張タグを取りこぼすと FY22〜FY25 の売掛金だけ連続で nil になる。
        let fs = makeFieldSet(("AccountsReceivableTradeReceivablesFromContractsWithCustomersCA", 168_055_000.0, 155_124_000.0))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 168_055_000.0)
        #expect(result.method == "direct")
    }

    @Test func testAccountsReceivableJgaapTradeAndContractAssetsExtension() {
        // 同上の別名義タグ（ぷらっとホーム 6836、2025-03 期: 105,474 千円）。
        let fs = makeFieldSet(("AccountsReceivableTradeAndContractAssetsCA", 105_474_000.0, 152_851_000.0))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 105_474_000.0)
        #expect(result.method == "direct")
    }

    @Test func testAccountsReceivableNotFound() {
        let result = AccountsReceivableExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    // MARK: - InventoryExtractor

    @Test func testInventoryJgaap() {
        let fs = makeFieldSet(("Inventories", 50_000_000.0, 45_000_000.0))
        let result = InventoryExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 50_000_000.0)
        #expect(result.method == "direct")
    }

    @Test func testInventoryIfrs() {
        let fs = makeFieldSet(("InventoriesCAIFRS", 60_000_000.0, nil))
        let result = InventoryExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 60_000_000.0)
    }

    @Test func testInventoryJgaapAggregated() {
        // Inventories 合算タグなし → 内訳タグの積み上げ
        let fs: FieldSet = [
            "MerchandiseAndFinishedGoods": FieldValue(current: 39_637_000_000.0, prior: nil),
            "WorkInProcess":               FieldValue(current:  2_582_000_000.0, prior: nil),
            "RawMaterialsAndSupplies":     FieldValue(current: 12_774_000_000.0, prior: nil),
        ]
        let result = InventoryExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 54_993_000_000.0)
        #expect(result.method == "aggregated")
    }

    @Test func testInventoryNotFound() {
        let result = InventoryExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    // MARK: - AccountsPayableExtractor

    @Test func testAccountsPayableJgaapCombined() {
        // 支払手形及び買掛金（合算タグ優先）
        let fs = makeFieldSet(("NotesAndAccountsPayableTrade", 70_000_000.0, 65_000_000.0))
        let result = AccountsPayableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 70_000_000.0)
        #expect(result.method == "direct")
    }

    @Test func testAccountsPayableJgaapFallback() {
        let fs = makeFieldSet(("AccountsPayableTrade", 65_000_000.0, nil))
        let result = AccountsPayableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 65_000_000.0)
    }

    @Test func testAccountsPayableIfrs() {
        let fs = makeFieldSet(("TradeAndOtherPayablesCLIFRS", 80_000_000.0, 75_000_000.0))
        let result = AccountsPayableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 80_000_000.0)
        #expect(result.method == "direct")
    }

    @Test func testAccountsPayableIfrsFallback() {
        let fs = makeFieldSet(("TradeAndOtherPayables2CLIFRS", 78_000_000.0, nil))
        let result = AccountsPayableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 78_000_000.0)
    }

    @Test func testAccountsPayableIfrsTradeOnly() {
        let fs = makeFieldSet(("TradePayablesCLIFRS", 75_000_000.0, nil))
        let result = AccountsPayableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 75_000_000.0)
    }

    @Test func testAccountsPayableNotFound() {
        let result = AccountsPayableExtractor.extract(fieldSet: [:], accountingStandard: "IFRS")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }
}
