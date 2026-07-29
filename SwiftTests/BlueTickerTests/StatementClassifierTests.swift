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

    // MARK: - section（資産/負債/純資産、営業/投資/財務）

    @Test func classifiesBalanceSheetLineIntoAssetsLiabilitiesNetAssetsViaPresentationAncestors() {
        // 実データ（トヨタ7203 J-GAAP）の presentation tree を再現:
        // AssetsAbstract > CurrentAssetsAbstract > CashAndDeposits（2階層上で "資産" 判定）。
        let bsRole = role("BalanceSheet")
        let facts: XbrlFactIndex = [
            "CashAndDeposits": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndDeposits", contextRef: "CurrentYearInstant", value: 100,
                    consolidation: "", role: bsRole)
            ],
            "AccountsPayableTrade": [
                "CurrentYearInstant": XbrlFact(
                    tag: "AccountsPayableTrade", contextRef: "CurrentYearInstant", value: 50,
                    consolidation: "", role: bsRole)
            ],
            "CapitalStock": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CapitalStock", contextRef: "CurrentYearInstant", value: 200,
                    consolidation: "", role: bsRole)
            ],
        ]
        let parentTagsByRoleTag: [String: [String: Set<String>]] = [
            bsRole: [
                "CashAndDeposits": ["CurrentAssetsAbstract"],
                "CurrentAssetsAbstract": ["AssetsAbstract"],
                "AccountsPayableTrade": ["CurrentLiabilitiesAbstract"],
                "CurrentLiabilitiesAbstract": ["LiabilitiesAbstract"],
                "CapitalStock": ["ShareholdersEquityAbstract"],
                "ShareholdersEquityAbstract": ["NetAssetsAbstract"],
            ]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet, parentTagsByRoleTag: parentTagsByRoleTag)
        let sectionByTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0.section) })
        #expect(sectionByTag["CashAndDeposits"] == .assets)
        #expect(sectionByTag["AccountsPayableTrade"] == .liabilities)
        #expect(sectionByTag["CapitalStock"] == .netAssets)
    }

    @Test func netAssetsAbstractIsNotMisclassifiedAsAssetsDespiteContainingAssetsSubstring() {
        // 回帰テスト: "NetAssetsAbstract" は "Assets" を部分文字列として含むため、資産キーワードを
        // 先に判定すると純資産科目が資産へ誤分類される（Constants/Xbrl.swift のコメント参照）。
        let bsRole = role("BalanceSheet")
        let facts: XbrlFactIndex = [
            "ValuationDifferenceOnAvailableForSaleSecurities": [
                "CurrentYearInstant": XbrlFact(
                    tag: "ValuationDifferenceOnAvailableForSaleSecurities",
                    contextRef: "CurrentYearInstant", value: 30, consolidation: "", role: bsRole)
            ]
        ]
        let parentTagsByRoleTag: [String: [String: Set<String>]] = [
            bsRole: [
                "ValuationDifferenceOnAvailableForSaleSecurities": [
                    "ValuationAndTranslationAdjustmentsAbstract"
                ],
                "ValuationAndTranslationAdjustmentsAbstract": ["NetAssetsAbstract"],
            ]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet, parentTagsByRoleTag: parentTagsByRoleTag)
        #expect(items.first?.section == .netAssets)
    }

    @Test func classifiesCashFlowLineIntoOperatingInvestingFinancingViaPresentationAncestors() {
        // 実データ（ソニー6758 IFRS）の presentation tree を再現:
        // CashFlowsFromOperatingActivitiesIFRSAbstract > AdjustmentsForOpeCFIFRSAbstract >
        // DepreciationAndAmortizationOpeCFIFRS（2階層上で "営業" 判定。"Ope" 略記だけでは
        // マッチしないことを確認する）。
        let cfRole = role("ConsolidatedStatementOfCashFlowsIFRS")
        let facts: XbrlFactIndex = [
            "DepreciationAndAmortizationOpeCFIFRS": [
                "CurrentYearDuration": XbrlFact(
                    tag: "DepreciationAndAmortizationOpeCFIFRS", contextRef: "CurrentYearDuration",
                    value: 10, consolidation: "", role: cfRole)
            ],
            "PurchaseOfPropertyPlantAndEquipmentInvCFIFRS": [
                "CurrentYearDuration": XbrlFact(
                    tag: "PurchaseOfPropertyPlantAndEquipmentInvCFIFRS",
                    contextRef: "CurrentYearDuration", value: 20, consolidation: "", role: cfRole)
            ],
            "DividendsPaidFinCFIFRS": [
                "CurrentYearDuration": XbrlFact(
                    tag: "DividendsPaidFinCFIFRS", contextRef: "CurrentYearDuration", value: 5,
                    consolidation: "", role: cfRole)
            ],
        ]
        let parentTagsByRoleTag: [String: [String: Set<String>]] = [
            cfRole: [
                "DepreciationAndAmortizationOpeCFIFRS": ["AdjustmentsForOpeCFIFRSAbstract"],
                "AdjustmentsForOpeCFIFRSAbstract": ["CashFlowsFromOperatingActivitiesIFRSAbstract"],
                "PurchaseOfPropertyPlantAndEquipmentInvCFIFRS": [
                    "CashFlowsFromInvestingActivitiesIFRSAbstract"
                ],
                "DividendsPaidFinCFIFRS": ["CashFlowsFromFinancingActivitiesIFRSAbstract"],
            ]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .cashFlow, parentTagsByRoleTag: parentTagsByRoleTag)
        let sectionByTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0.section) })
        #expect(sectionByTag["DepreciationAndAmortizationOpeCFIFRS"] == .operating)
        #expect(sectionByTag["PurchaseOfPropertyPlantAndEquipmentInvCFIFRS"] == .investing)
        #expect(sectionByTag["DividendsPaidFinCFIFRS"] == .financing)
    }

    @Test func resolvesSectionAcrossDuplicateLocOccurrencesOfTheSameAncestorTag() {
        // 実データ（ソニー6758 IFRS の ChangesInWorkingCapitalOpeCFIFRSAbstract）で発見した
        // presentation linkbase の癖の回帰テスト: 同一タグが役割内で2回 <loc> され、1回は
        // 明細の見出しとして親を持たない root（今回のケースの "from" 経路）、もう1回は上位ツリーの
        // 子として参照される（親を持つ）。タグ単位で親集合を持たせることで、root 側の出現から見ても
        // もう一方の出現の親を辿って正しく分類できることを確認する。
        let cfRole = role("ConsolidatedStatementOfCashFlowsIFRS")
        let facts: XbrlFactIndex = [
            "IncreaseDecreaseInTradeReceivablesAndContractAssetsOpeCFIFRS": [
                "CurrentYearDuration": XbrlFact(
                    tag: "IncreaseDecreaseInTradeReceivablesAndContractAssetsOpeCFIFRS",
                    contextRef: "CurrentYearDuration", value: 15, consolidation: "", role: cfRole)
            ]
        ]
        let parentTagsByRoleTag: [String: [String: Set<String>]] = [
            cfRole: [
                "IncreaseDecreaseInTradeReceivablesAndContractAssetsOpeCFIFRS": [
                    "ChangesInWorkingCapitalOpeCFIFRSAbstract"
                ],
                // ChangesInWorkingCapitalOpeCFIFRSAbstract 自身も別出現で
                // AdjustmentsForOpeCFIFRSAbstract の子として参照されている。
                "ChangesInWorkingCapitalOpeCFIFRSAbstract": ["AdjustmentsForOpeCFIFRSAbstract"],
                "AdjustmentsForOpeCFIFRSAbstract": ["CashFlowsFromOperatingActivitiesIFRSAbstract"],
            ]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .cashFlow, parentTagsByRoleTag: parentTagsByRoleTag)
        #expect(items.first?.section == .operating)
    }

    @Test func leavesSectionNilWhenNoAncestorMatchesAnyKeyword() {
        // グランドトータル行（例: LiabilitiesAndNetAssets）は資産/負債/純資産いずれの祖先も
        // 持たないため section は nil のまま（配列構造は維持し行自体は残る）。
        let bsRole = role("BalanceSheet")
        let facts: XbrlFactIndex = [
            "LiabilitiesAndNetAssets": [
                "CurrentYearInstant": XbrlFact(
                    tag: "LiabilitiesAndNetAssets", contextRef: "CurrentYearInstant", value: 1_000,
                    consolidation: "", role: bsRole)
            ]
        ]
        let parentTagsByRoleTag: [String: [String: Set<String>]] = [
            bsRole: ["LiabilitiesAndNetAssets": ["BalanceSheetLineItems"]]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet, parentTagsByRoleTag: parentTagsByRoleTag)
        #expect(items.first?.section == nil)
    }

    @Test func incomeStatementLinesNeverGetASectionEvenWithMatchingAncestors() {
        // PL利益段階ラベリングはスコープ外（2026-07-30合意）。section は BS/CF のみに適用する。
        let plRole = role("StatementOfIncome")
        let facts: XbrlFactIndex = [
            "NetSales": [
                "CurrentYearDuration": XbrlFact(
                    tag: "NetSales", contextRef: "CurrentYearDuration", value: 100, consolidation: "",
                    role: plRole)
            ]
        ]
        let parentTagsByRoleTag: [String: [String: Set<String>]] = [
            plRole: ["NetSales": ["AssetsAbstract"]]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .incomeStatement, parentTagsByRoleTag: parentTagsByRoleTag)
        #expect(items.first?.section == nil)
    }

    @Test func sectionIsNilByDefaultWhenParentTagsNotProvided() {
        let bsRole = role("BalanceSheet")
        let facts: XbrlFactIndex = [
            "CashAndDeposits": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndDeposits", contextRef: "CurrentYearInstant", value: 100,
                    consolidation: "", role: bsRole)
            ]
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .balanceSheet)
        #expect(items.first?.section == nil)
    }
}
