import Foundation
import Testing

@testable import BlueTickerCore

/// Stage 7（Statement 本体）の BS/PL/CF 判定・抽出の仕様を検証する。
/// 実データ検証（キャッシュ済み実XBRL 158社）で確認した role 命名パターン
/// （J-GAAP/IFRS）を fixture として再現する。
@Suite struct StatementClassifierTests {
    private func role(_ name: String) -> String {
        "http://disclosure.edinet-fsa.go.jp/role/jppfs/rol_\(name)"
    }

    // MARK: - classify(role:)

    @Test func classifiesJGaapRoleNames() {
        #expect(StatementClassifier.classify(role: role("BalanceSheet")) == .balanceSheet)
        #expect(StatementClassifier.classify(role: role("ConsolidatedBalanceSheet")) == .balanceSheet)
        #expect(StatementClassifier.classify(role: role("StatementOfIncome")) == .incomeStatement)
        #expect(
            StatementClassifier.classify(role: role("ConsolidatedStatementOfIncome"))
                == .incomeStatement)
        #expect(
            StatementClassifier.classify(role: role("StatementOfCashFlows-indirect")) == .cashFlow)
        #expect(
            StatementClassifier.classify(role: role("ConsolidatedStatementOfCashFlows-indirect"))
                == .cashFlow)
    }

    @Test func classifiesIfrsRoleNames() {
        #expect(
            StatementClassifier.classify(role: role("ConsolidatedStatementOfFinancialPositionIFRS"))
                == .balanceSheet)
        #expect(
            StatementClassifier.classify(role: role("ConsolidatedStatementOfProfitOrLossIFRS"))
                == .incomeStatement)
        #expect(
            StatementClassifier.classify(role: role("ConsolidatedStatementOfCashFlowsIFRS"))
                == .cashFlow)
    }

    @Test func excludesNotesPrefixedRolesEvenWhenKeywordMatches() {
        // NotesConsolidatedBalanceSheet は "BalanceSheet" を含むが、注記なので対象外。
        #expect(StatementClassifier.classify(role: role("NotesConsolidatedBalanceSheet")) == nil)
        #expect(StatementClassifier.classify(role: role("NotesStatementOfIncome")) == nil)
    }

    @Test func returnsNilForUnrelatedRoles() {
        #expect(StatementClassifier.classify(role: role("BusinessResultsOfGroup")) == nil)
    }

    // MARK: - extractLineItems(from:sectionType:)

    @Test func prefersConsolidatedOverNonConsolidatedWhenBothPresent() {
        let facts: XbrlFactIndex = [
            "NetSales": [
                "CurrentYearDuration": XbrlFact(
                    tag: "NetSales", contextRef: "CurrentYearDuration", value: 100, consolidation: "",
                    role: role("ConsolidatedStatementOfIncome")),
                "CurrentYearDuration_NonConsolidated": XbrlFact(
                    tag: "NetSales", contextRef: "CurrentYearDuration_NonConsolidated", value: 80,
                    consolidation: "", role: role("StatementOfIncome")),
            ]
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .incomeStatement)
        #expect(items.map(\.value) == [100])
    }

    @Test func fallsBackToNonConsolidatedWhenNoConsolidatedContextExists() {
        // 子会社を持たない小規模企業（学び: Breakdown Stage 6 と同型）。
        let facts: XbrlFactIndex = [
            "NetSales": [
                "CurrentYearDuration_NonConsolidated": XbrlFact(
                    tag: "NetSales", contextRef: "CurrentYearDuration_NonConsolidated", value: 80,
                    consolidation: "", role: role("StatementOfIncome"))
            ]
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .incomeStatement)
        #expect(items.map(\.value) == [80])
    }

    @Test func nonConsolidatedFallbackExcludesSegmentDimensionedContexts() {
        // `_NonConsolidatedMember` に続けてセグメント軸メンバーが付いた dimensioned context は
        // 「非連結の当期合計」ではない（同一タグにセグメント別の値が複数紐づく）。フォールバックが
        // isNonConsolidatedInstant/Duration（`_NonConsolidated` 部分一致のみ）だとここが素通り
        // してしまうため、isPureNonConsolidatedContext（完全一致）を使うことを回帰させる。
        let facts: XbrlFactIndex = [
            "NetSales": [
                "CurrentYearDuration_NonConsolidatedMember_SegmentAMember": XbrlFact(
                    tag: "NetSales",
                    contextRef: "CurrentYearDuration_NonConsolidatedMember_SegmentAMember", value: 30,
                    consolidation: "", role: role("StatementOfIncome")),
                "CurrentYearDuration_NonConsolidatedMember_SegmentBMember": XbrlFact(
                    tag: "NetSales",
                    contextRef: "CurrentYearDuration_NonConsolidatedMember_SegmentBMember", value: 50,
                    consolidation: "", role: role("StatementOfIncome")),
            ]
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .incomeStatement)
        #expect(items.isEmpty)
    }

    @Test func excludesPriorYearContexts() {
        let facts: XbrlFactIndex = [
            "NetSales": [
                "CurrentYearDuration": XbrlFact(
                    tag: "NetSales", contextRef: "CurrentYearDuration", value: 100, consolidation: "",
                    role: role("ConsolidatedStatementOfIncome")),
                "Prior1YearDuration": XbrlFact(
                    tag: "NetSales", contextRef: "Prior1YearDuration", value: 90, consolidation: "",
                    role: role("ConsolidatedStatementOfIncome")),
            ]
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .incomeStatement)
        #expect(items.map(\.value) == [100])
    }

    @Test func excludesFactsFromOtherStatementSections() {
        let facts: XbrlFactIndex = [
            "CashAndDeposits": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndDeposits", contextRef: "CurrentYearInstant", value: 1_000,
                    consolidation: "", role: role("ConsolidatedBalanceSheet"))
            ],
            "NetSales": [
                "CurrentYearDuration": XbrlFact(
                    tag: "NetSales", contextRef: "CurrentYearDuration", value: 100, consolidation: "",
                    role: role("ConsolidatedStatementOfIncome"))
            ],
        ]
        let balanceSheet = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet)
        #expect(balanceSheet.map(\.tag) == ["CashAndDeposits"])
    }

    @Test func sortsResultsByTagAlphabeticallyForDeterministicOrder() {
        let facts: XbrlFactIndex = [
            "TotalAssets": [
                "CurrentYearInstant": XbrlFact(
                    tag: "TotalAssets", contextRef: "CurrentYearInstant", value: 500,
                    consolidation: "", role: role("ConsolidatedBalanceSheet"))
            ],
            "CashAndDeposits": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndDeposits", contextRef: "CurrentYearInstant", value: 1_000,
                    consolidation: "", role: role("ConsolidatedBalanceSheet"))
            ],
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .balanceSheet)
        #expect(items.map(\.tag) == ["CashAndDeposits", "TotalAssets"])
    }

    @Test func sortsResultsByPresentationOrderWhenAvailable() {
        // タグ名のアルファベット順（CashAndDeposits < TotalAssets）とは逆の presentation 順
        // （TotalAssets が先）を与え、order が優先されることを確認する。
        let bsRole = role("ConsolidatedBalanceSheet")
        let facts: XbrlFactIndex = [
            "TotalAssets": [
                "CurrentYearInstant": XbrlFact(
                    tag: "TotalAssets", contextRef: "CurrentYearInstant", value: 500,
                    consolidation: "", role: bsRole, orderByRole: [bsRole: 0])
            ],
            "CashAndDeposits": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndDeposits", contextRef: "CurrentYearInstant", value: 1_000,
                    consolidation: "", role: bsRole, orderByRole: [bsRole: 1])
            ],
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .balanceSheet)
        #expect(items.map(\.tag) == ["TotalAssets", "CashAndDeposits"])
        #expect(items.map(\.order) == [0, 1])
    }

    @Test func choosesRoleByCoverageOfChosenItemsNotByRawMentionFrequency() {
        // 実データ検証（ソニー/トヨタのIFRS BS、S100QZT6・S100VWVY）で発見したバグの回帰テスト。
        // 同じ sectionType に2つの role が対応する場合（IFRS企業の連結BS用roleと、同じ role名
        // キーワードにマッチするが実際は別の目的の role）、全タグがどちらの role にも言及していても、
        // 実際に採用されたタグ集合を1つもカバーしない「decoy」roleを選んではならない。カバレッジで
        // 選べば正しい role（realRole）が選ばれ、頻度だけで選ぶ実装に戻すとここで全 order が nil に
        // 落ちてタグ名アルファベット順（Assets, Cash, Liabilities）へサイレント劣化する。
        let decoyRole = role("BalanceSheet")
        let realRole = role("ConsolidatedStatementOfFinancialPositionIFRS")
        let facts: XbrlFactIndex = [
            "AssetsIFRS": [
                "CurrentYearInstant": XbrlFact(
                    tag: "AssetsIFRS", contextRef: "CurrentYearInstant", value: 500,
                    consolidation: "", roles: [decoyRole, realRole], orderByRole: [realRole: 0])
            ],
            "CashAndCashEquivalentsIFRS": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndCashEquivalentsIFRS", contextRef: "CurrentYearInstant", value: 100,
                    consolidation: "", roles: [decoyRole, realRole], orderByRole: [realRole: 1])
            ],
            "LiabilitiesIFRS": [
                "CurrentYearInstant": XbrlFact(
                    tag: "LiabilitiesIFRS", contextRef: "CurrentYearInstant", value: 200,
                    consolidation: "", roles: [decoyRole, realRole], orderByRole: [realRole: 2])
            ],
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .balanceSheet)
        #expect(items.map(\.tag) == ["AssetsIFRS", "CashAndCashEquivalentsIFRS", "LiabilitiesIFRS"])
        #expect(items.map(\.order) == [0, 1, 2])
    }

    @Test func placesTagsWithoutPresentationOrderAfterOrderedTagsFallingBackToAlphabetical() {
        // order を持つタグを優先し、order が無いタグは末尾でタグ名アルファベット順にする。
        let bsRole = role("ConsolidatedBalanceSheet")
        let facts: XbrlFactIndex = [
            "TotalAssets": [
                "CurrentYearInstant": XbrlFact(
                    tag: "TotalAssets", contextRef: "CurrentYearInstant", value: 500,
                    consolidation: "", role: bsRole, orderByRole: [bsRole: 5])
            ],
            "ZExtensionTag": [
                "CurrentYearInstant": XbrlFact(
                    tag: "ZExtensionTag", contextRef: "CurrentYearInstant", value: 10,
                    consolidation: "", role: bsRole)
            ],
            "AExtensionTag": [
                "CurrentYearInstant": XbrlFact(
                    tag: "AExtensionTag", contextRef: "CurrentYearInstant", value: 20,
                    consolidation: "", role: bsRole)
            ],
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .balanceSheet)
        #expect(items.map(\.tag) == ["TotalAssets", "AExtensionTag", "ZExtensionTag"])
    }
}
