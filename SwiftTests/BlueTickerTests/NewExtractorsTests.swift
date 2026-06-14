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

    @Test func testCfTreasuryStockNotFound() {
        let result = CfTreasuryStockExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    // MARK: - DividendSSExtractor

    @Test func testDividendSSJgaap() {
        // SS 値は負値（純資産の減少） → 正値に変換
        let fs = makeFieldSet(("DividendsCS", -2_000_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 2_000_000.0)
        #expect(result.method == "ss_equity")
    }

    @Test func testDividendSSJgaapFallbackTag() {
        let fs = makeFieldSet(("DividendsFromRetainedEarnings", -1_500_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.current == 1_500_000.0)
    }

    @Test func testDividendSSIfrs() {
        let fs = makeFieldSet(("DividendsPaidToOwnersOfParentSSIFRS", -4_000_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 4_000_000.0)
        #expect(result.method == "ss_equity")
    }

    @Test func testDividendSSUsgaapReturnsNil() {
        let fs = makeFieldSet(("DividendsCS", -1_000_000.0, nil))
        let result = DividendSSExtractor.extract(fieldSet: fs, accountingStandard: "US-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    @Test func testDividendSSNotFound() {
        let result = DividendSSExtractor.extract(fieldSet: [:], accountingStandard: "J-GAAP")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }

    // MARK: - DividendPaidExtractor

    @Test func testDividendPaidJgaap() {
        let fs = makeFieldSet(("DividendsPaidFinCF", -2_500_000.0, nil))
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
        let fs = makeFieldSet(("TradeAndOtherReceivablesCurrentIFRS", 150_000_000.0, 140_000_000.0))
        let result = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 150_000_000.0)
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
        let fs = makeFieldSet(("InventoriesIFRS", 60_000_000.0, nil))
        let result = InventoryExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 60_000_000.0)
    }

    @Test func testInventoryIfrsFallback() {
        let fs = makeFieldSet(("InventoriesCurrentIFRS", 55_000_000.0, nil))
        let result = InventoryExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 55_000_000.0)
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
        let fs = makeFieldSet(("TradeAndOtherPayablesCurrentIFRS", 80_000_000.0, 75_000_000.0))
        let result = AccountsPayableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 80_000_000.0)
        #expect(result.method == "direct")
    }

    @Test func testAccountsPayableIfrsFallback() {
        let fs = makeFieldSet(("TradePayablesCurrentIFRS", 78_000_000.0, nil))
        let result = AccountsPayableExtractor.extract(fieldSet: fs, accountingStandard: "IFRS")
        #expect(result.current == 78_000_000.0)
    }

    @Test func testAccountsPayableNotFound() {
        let result = AccountsPayableExtractor.extract(fieldSet: [:], accountingStandard: "IFRS")
        #expect(result.current == nil)
        #expect(result.method == "not_found")
    }
}
