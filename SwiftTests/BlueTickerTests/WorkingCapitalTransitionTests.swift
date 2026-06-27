// 会計基準移行年の運転資本抽出の回帰テスト。
//
// 収益認識会計基準の移行年（例: 4042 東ソー 2022/03）では BS の前期列が
// 旧科目（NotesAndAccountsReceivableTrade, prior のみ）、当期列が新科目
// （AccountsReceivableTrade, current のみ）になる。current を持つタグを優先する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct WorkingCapitalTransitionTests {

    @Test func accountsReceivablePrefersCurrentTagOverPriorOnlyShadow() {
        // 旧科目は前期列のみ、新科目が当期列。先頭候補（旧科目）に引きずられないこと。
        var fs: FieldSet = [:]
        fs["NotesAndAccountsReceivableTrade"] = FieldValue(current: nil, prior: 225_459)
        fs["AccountsReceivableTrade"] = FieldValue(current: 217_073, prior: nil)

        let res = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(res.current == 217_073)
        #expect(res.method == "direct")
    }

    @Test func accountsPayablePrefersCurrentTagOverPriorOnlyShadow() {
        var fs: FieldSet = [:]
        fs["NotesAndAccountsPayableTrade"] = FieldValue(current: nil, prior: 91_377)
        fs["AccountsPayableTrade"] = FieldValue(current: 113_441, prior: nil)

        let res = AccountsPayableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(res.current == 113_441)
        #expect(res.method == "direct")
    }

    @Test func accountsReceivableExtractsContractAssetsStandardTag() {
        // 収益認識基準導入後の標準科目「受取手形、売掛金及び契約資産」
        // （例: 3778 さくらインターネット 2024/03 以降）を売掛金として抽出する。
        var fs: FieldSet = [:]
        fs["NotesAndAccountsReceivableTradeAndContractAssets"] = FieldValue(current: 3_241_165, prior: 2_392_419)

        let res = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(res.current == 3_241_165)
        #expect(res.method == "direct")
    }

    @Test func accountsReceivableReturnsNotFoundWhenNoCurrentAnywhere() {
        // 当期値がどのタグにも無い場合は not_found（prior のみで direct を返さない）。
        var fs: FieldSet = [:]
        fs["NotesAndAccountsReceivableTrade"] = FieldValue(current: nil, prior: 225_459)

        let res = AccountsReceivableExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(res.current == nil)
        #expect(res.method == "not_found")
    }
}
