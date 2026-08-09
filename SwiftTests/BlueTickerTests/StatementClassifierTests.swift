import Foundation
import Testing

@testable import BlueTickerCore

/// Statement 取り込み（Statement 本体）の BS/PL/CF/SS 判定・抽出の仕様を検証する。
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
        #expect(
            StatementClassifier.classify(role: role("StatementOfChangesInEquity"))
                == .changesInEquity)
        #expect(
            StatementClassifier.classify(role: role("ConsolidatedStatementOfChangesInEquity"))
                == .changesInEquity)
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
        #expect(
            StatementClassifier.classify(
                role: role("ConsolidatedStatementOfChangesInEquityIFRS")) == .changesInEquity)
    }

    @Test func excludesNotesPrefixedRolesEvenWhenKeywordMatches() {
        // NotesConsolidatedBalanceSheet は "BalanceSheet" を含むが、注記なので対象外。
        #expect(StatementClassifier.classify(role: role("NotesConsolidatedBalanceSheet")) == nil)
        #expect(StatementClassifier.classify(role: role("NotesStatementOfIncome")) == nil)
        #expect(
            StatementClassifier.classify(role: role("NotesStatementOfChangesInEquity")) == nil)
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
        // 子会社を持たない小規模企業（学び: Breakdown 内訳取り込み と同型）。
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

    @Test func changesInEquityUsesTotalColumnAndExcludesEquityMemberDimensions() {
        // SS は合計列のみ。資本金・親会社持分などの構成員次元は拾わない。
        let ssRole = role("ConsolidatedStatementOfChangesInEquityIFRS")
        let facts: XbrlFactIndex = [
            "PurchaseOfTreasurySharesSSIFRS": [
                "CurrentYearDuration": XbrlFact(
                    tag: "PurchaseOfTreasurySharesSSIFRS", contextRef: "CurrentYearDuration",
                    value: -1_179_043_000_000, consolidation: "", role: ssRole),
                "CurrentYearDuration_TreasurySharesIFRSMember": XbrlFact(
                    tag: "PurchaseOfTreasurySharesSSIFRS",
                    contextRef: "CurrentYearDuration_TreasurySharesIFRSMember",
                    value: -1_179_043_000_000, consolidation: "", role: ssRole),
                "CurrentYearDuration_EquityAttributableToOwnersOfParentIFRSMember": XbrlFact(
                    tag: "PurchaseOfTreasurySharesSSIFRS",
                    contextRef: "CurrentYearDuration_EquityAttributableToOwnersOfParentIFRSMember",
                    value: -1_179_043_000_000, consolidation: "", role: ssRole),
            ]
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .changesInEquity)
        #expect(items.map(\.value) == [-1_179_043_000_000])
        #expect(items.map(\.section) == [nil])
    }

    @Test func changesInEquityIncludesOpeningAndClosingEquityBalancesLikeCashFlow() {
        // SS の純資産/資本の期首・期末残高は Instant（前期末=当期首 / 当期末）。CF と同型。
        let ssRole = role("ConsolidatedStatementOfChangesInEquityIFRS")
        let facts: XbrlFactIndex = [
            "EquityIFRS": [
                "Prior1YearInstant": XbrlFact(
                    tag: "EquityIFRS", contextRef: "Prior1YearInstant", value: 35_239_338_000_000,
                    consolidation: "", role: ssRole,
                    orderByRole: [ssRole: 14]),
                "CurrentYearInstant": XbrlFact(
                    tag: "EquityIFRS", contextRef: "CurrentYearInstant", value: 36_878_913_000_000,
                    consolidation: "", role: ssRole,
                    orderByRole: [ssRole: 14]),
                "CurrentYearInstant_ShareCapitalIFRSMember": XbrlFact(
                    tag: "EquityIFRS", contextRef: "CurrentYearInstant_ShareCapitalIFRSMember",
                    value: 397_050_000_000, consolidation: "", role: ssRole),
            ],
            "DividendsSSIFRS": [
                "CurrentYearDuration": XbrlFact(
                    tag: "DividendsSSIFRS", contextRef: "CurrentYearDuration",
                    value: -1_200_000_000_000, consolidation: "", role: ssRole,
                    orderByRole: [ssRole: 20]),
            ],
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .changesInEquity)
        // 同一 order の EquityIFRS は期首→期末。配当はその後。
        #expect(items.map(\.tag) == ["EquityIFRS", "EquityIFRS", "DividendsSSIFRS"])
        #expect(
            items.map(\.value)
                == [35_239_338_000_000, 36_878_913_000_000, -1_200_000_000_000])
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

    @Test func classifiesLiabilitiesTotalAsLiabilitiesDespiteAmbiguousCombinedAncestorHeader() {
        // 回帰テスト（実データ検証: デンソー6902 IFRS）。負債合計 `LiabilitiesIFRS` の直接の親が
        // 負債・純資産を束ねる見出し `LiabilitiesAndEquityIFRSAbstract`（Liabilit と Equity 両方の
        // キーワードに一致）であるため、優先順位で確定させると誤って純資産へ分類されていた。
        // 祖先が曖昧な場合はタグ自身の名前（"Liabilit" のみに一致）へフォールバックして解決する。
        let bsRole = role("ConsolidatedStatementOfFinancialPositionIFRS")
        let facts: XbrlFactIndex = [
            "LiabilitiesIFRS": [
                "CurrentYearInstant": XbrlFact(
                    tag: "LiabilitiesIFRS", contextRef: "CurrentYearInstant", value: 2_936_082,
                    consolidation: "", role: bsRole)
            ]
        ]
        let parentTagsByRoleTag: [String: [String: Set<String>]] = [
            bsRole: ["LiabilitiesIFRS": ["LiabilitiesAndEquityIFRSAbstract"]]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet, parentTagsByRoleTag: parentTagsByRoleTag)
        #expect(items.first?.section == .liabilities)
    }

    @Test func equityMethodInvestmentUnderAssetsAncestorIsNotMisclassifiedByOwnNameFallback() {
        // 回帰テスト: `classifyIfUnambiguous` の祖先曖昧時フォールバックはタグ自身の名前も見るが、
        // 祖先が単一区分に確定できる場合はそちらが優先され、タグ名に含まれる無関係な部分文字列
        // （"EquityMethod" の "Equity"）に惑わされてはならない。
        let bsRole = role("ConsolidatedStatementOfFinancialPositionIFRS")
        let facts: XbrlFactIndex = [
            "InvestmentsAccountedForUsingEquityMethodIFRS": [
                "CurrentYearInstant": XbrlFact(
                    tag: "InvestmentsAccountedForUsingEquityMethodIFRS",
                    contextRef: "CurrentYearInstant", value: 123_901, consolidation: "", role: bsRole)
            ]
        ]
        let parentTagsByRoleTag: [String: [String: Set<String>]] = [
            bsRole: [
                "InvestmentsAccountedForUsingEquityMethodIFRS": ["NonCurrentAssetsIFRSAbstract"]
            ]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet, parentTagsByRoleTag: parentTagsByRoleTag)
        #expect(items.first?.section == .assets)
    }

    // MARK: - CF の現金同等物 期首/期末残高（Instant fact の受理）

    @Test func includesCashReconciliationInstantFactsWithinCashFlowSection() {
        // 回帰テスト（実データ検証: トヨタ7203 IFRS）。CF は大半が Duration だが、現金及び現金同等物の
        // 期首/期末残高調整行は Instant 型 fact のまま CF の presentation role に現れる。
        // Duration のみで判定すると黙って欠落していた。
        let cfRole = role("ConsolidatedStatementOfCashFlowsIFRS")
        let facts: XbrlFactIndex = [
            "CashAndCashEquivalentsIFRS": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndCashEquivalentsIFRS", contextRef: "CurrentYearInstant",
                    value: 8_982_404, consolidation: "", role: cfRole),
                "Prior1YearInstant": XbrlFact(
                    tag: "CashAndCashEquivalentsIFRS", contextRef: "Prior1YearInstant",
                    value: 9_412_060, consolidation: "", role: cfRole),
            ],
            "NetCashProvidedByUsedInOperatingActivitiesIFRS": [
                "CurrentYearDuration": XbrlFact(
                    tag: "NetCashProvidedByUsedInOperatingActivitiesIFRS",
                    contextRef: "CurrentYearDuration", value: 3_696_934, consolidation: "", role: cfRole)
            ],
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .cashFlow)
        let cashValues = Set(
            items.filter { $0.tag == "CashAndCashEquivalentsIFRS" }.map(\.value))
        #expect(cashValues == [8_982_404, 9_412_060])
        #expect(items.contains { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })
    }

    @Test func excludesDeeperPriorYearInstantFactsFromCashFlowSection() {
        // 前期首残高（Prior2YearInstant）は「当期」の CF には属さないため、CF 用に緩和した
        // Instant 受理が前期分まで巻き込まないことを確認する。
        let cfRole = role("ConsolidatedStatementOfCashFlowsIFRS")
        let facts: XbrlFactIndex = [
            "CashAndCashEquivalentsIFRS": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndCashEquivalentsIFRS", contextRef: "CurrentYearInstant",
                    value: 8_982_404, consolidation: "", role: cfRole),
                "Prior2YearInstant": XbrlFact(
                    tag: "CashAndCashEquivalentsIFRS", contextRef: "Prior2YearInstant",
                    value: 7_516_966, consolidation: "", role: cfRole),
            ]
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .cashFlow)
        #expect(items.map(\.value) == [8_982_404])
    }

    // MARK: - preferredLabel に応じたラベル選択

    @Test func usesTotalLabelVariantWhenPresentationArcPrefersIt() {
        // 回帰テスト（実データ検証: 任天堂7974 J-GAAP）。`ValuationAndTranslationAdjustments` は
        // presentationArc の `preferredLabel=totalLabel` により、通常ラベル「評価・換算差額等」
        // ではなく合計ラベル「評価・換算差額等合計」を使うべき小計行。
        let bsRole = role("BalanceSheet")
        let tag = "ValuationAndTranslationAdjustments"
        let totalLabelRole = "http://www.xbrl.org/2003/role/totalLabel"
        let facts: XbrlFactIndex = [
            tag: [
                "CurrentYearInstant": XbrlFact(
                    tag: tag, contextRef: "CurrentYearInstant", value: 237_581, consolidation: "",
                    role: bsRole, label: "評価・換算差額等")
            ]
        ]
        let preferredLabelByRoleTag: [String: [String: String]] = [bsRole: [tag: totalLabelRole]]
        let labelRoleVariantsByTag: [String: [String: String]] = [
            tag: [totalLabelRole: "評価・換算差額等合計"]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet, preferredLabelByRoleTag: preferredLabelByRoleTag,
            labelRoleVariantsByTag: labelRoleVariantsByTag)
        #expect(items.first?.label == "評価・換算差額等合計")
    }

    @Test func fallsBackToPlainLabelWhenPreferredVariantIsMissing() {
        let bsRole = role("BalanceSheet")
        let facts: XbrlFactIndex = [
            "CashAndDeposits": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndDeposits", contextRef: "CurrentYearInstant", value: 100,
                    consolidation: "", role: bsRole, label: "現金及び預金")
            ]
        ]
        let preferredLabelByRoleTag: [String: [String: String]] = [
            bsRole: ["CashAndDeposits": "http://www.xbrl.org/2003/role/totalLabel"]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet, preferredLabelByRoleTag: preferredLabelByRoleTag)
        #expect(items.first?.label == "現金及び預金")
    }

    @Test func doesNotOverridePreferredLabelWithPeriodEndVariantOutsideCashFlow() {
        // 回帰テスト（Opus 監査で発見・修正、2026-07-31）: BS の合計行タグが標準タクソノミの
        // periodEndLabel（多くの JPFS/IFRS の資産・負債・純資産系タグに存在）を持つ場合、
        // 期首/期末残高の区別は CF 専用のはずが sectionType を問わず先に評価されており、
        // `preferredLabel=totalLabel`（例: トヨタ7203 の `EquityIFRS` → 「資本合計」）が
        // 無視されて常に periodEndLabel（「期末残高」）になっていた
        // （キャッシュ済み実XBRL 140件中136件で発生）。
        let bsRole = role("ConsolidatedStatementOfFinancialPositionIFRS")
        let tag = "EquityIFRS"
        let totalLabelRole = "http://www.xbrl.org/2003/role/totalLabel"
        let periodEndLabelRole = "http://www.xbrl.org/2003/role/periodEndLabel"
        let facts: XbrlFactIndex = [
            tag: [
                "CurrentYearInstant": XbrlFact(
                    tag: tag, contextRef: "CurrentYearInstant", value: 36_878_913, consolidation: "",
                    role: bsRole, label: "資本")
            ]
        ]
        let preferredLabelByRoleTag: [String: [String: String]] = [bsRole: [tag: totalLabelRole]]
        let labelRoleVariantsByTag: [String: [String: String]] = [
            tag: [totalLabelRole: "資本合計", periodEndLabelRole: "期末残高"]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet, preferredLabelByRoleTag: preferredLabelByRoleTag,
            labelRoleVariantsByTag: labelRoleVariantsByTag)
        #expect(items.first?.label == "資本合計")
    }

    @Test func stillAppliesPeriodEndVariantWithinCashFlow() {
        // 上のテストの対（回帰確認）: CF では引き続き期末残高バリアントが優先されること。
        let cfRole = role("ConsolidatedStatementOfCashFlowsIFRS")
        let tag = "CashAndCashEquivalentsIFRS"
        let periodEndLabelRole = "http://www.xbrl.org/2003/role/periodEndLabel"
        let facts: XbrlFactIndex = [
            tag: [
                "CurrentYearInstant": XbrlFact(
                    tag: tag, contextRef: "CurrentYearInstant", value: 8_982_404, consolidation: "",
                    role: cfRole, label: "現金及び現金同等物")
            ]
        ]
        let labelRoleVariantsByTag: [String: [String: String]] = [
            tag: [periodEndLabelRole: "現金及び現金同等物の期末残高"]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .cashFlow, labelRoleVariantsByTag: labelRoleVariantsByTag)
        #expect(items.first?.label == "現金及び現金同等物の期末残高")
    }

    @Test func prefersStandardPeriodLabelRoleOverEdinetInterimVariantDeterministically() {
        // 回帰テスト（Opus 監査で発見・修正、2026-07-31）: 標準ロール
        // （`http://www.xbrl.org/2003/role/periodEndLabel`）と EDINET 独自の中間報告書用ロール
        // （`.../ConsolidatedInterim/role/periodEndLabel`、文言は「中間期末残高」）が両方存在する
        // 場合、以前は `Dictionary.first(where:)` で走査順（プロセスごとに非決定的）に選んでいた。
        // 標準ロールを優先し、決定的に選ぶこと。
        let cfRole = role("ConsolidatedStatementOfCashFlowsIFRS")
        let tag = "CashAndCashEquivalentsIFRS"
        let standardRole = "http://www.xbrl.org/2003/role/periodEndLabel"
        let interimRole = "http://disclosure.edinet-fsa.go.jp/jppfs/ConsolidatedInterim/role/periodEndLabel"
        let facts: XbrlFactIndex = [
            tag: [
                "CurrentYearInstant": XbrlFact(
                    tag: tag, contextRef: "CurrentYearInstant", value: 8_982_404, consolidation: "",
                    role: cfRole, label: "現金及び現金同等物")
            ]
        ]
        let labelRoleVariantsByTag: [String: [String: String]] = [
            tag: [standardRole: "現金及び現金同等物の期末残高", interimRole: "現金及び現金同等物の中間期末残高"]
        ]
        for _ in 0..<20 {
            let items = StatementClassifier.extractLineItems(
                from: facts, sectionType: .cashFlow, labelRoleVariantsByTag: labelRoleVariantsByTag)
            #expect(items.first?.label == "現金及び現金同等物の期末残高")
        }
    }

    // MARK: - 計算リンクベース由来の is_total/components

    @Test func marksTotalTagAndExposesWeightedComponentsFromCalculationLinkbase() {
        // 実データ検証（任天堂7974 J-GAAP）: presentation の親子関係は表示上のネストでしかなく
        // 二重計上を防げないが、計算リンクベース（`_cal.xml`、summation-item arc）は
        // 「この行が何の合計か」を weight（+1/−1）付きで決定的に示す。
        let bsRole = role("BalanceSheet")
        let facts: XbrlFactIndex = [
            "CurrentAssets": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CurrentAssets", contextRef: "CurrentYearInstant", value: 2_752_352,
                    consolidation: "", role: bsRole)
            ],
            "CashAndDeposits": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndDeposits", contextRef: "CurrentYearInstant", value: 1_586_275,
                    consolidation: "", role: bsRole)
            ],
        ]
        let calculationComponentsByRoleTag: [String: [String: [CalcComponent]]] = [
            bsRole: [
                "CurrentAssets": [
                    CalcComponent(tag: "CashAndDeposits", weight: 1),
                    CalcComponent(tag: "Inventories", weight: 1),
                ]
            ]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .balanceSheet,
            calculationComponentsByRoleTag: calculationComponentsByRoleTag)
        let byTag = Dictionary(uniqueKeysWithValues: items.map { ($0.tag, $0) })
        #expect(byTag["CurrentAssets"]?.isTotal == true)
        #expect(byTag["CurrentAssets"]?.components?.map(\.tag) == ["CashAndDeposits", "Inventories"])
        #expect(byTag["CurrentAssets"]?.components?.map(\.weight) == [1, 1])
        #expect(byTag["CashAndDeposits"]?.isTotal == false)
        #expect(byTag["CashAndDeposits"]?.components == nil)
    }

    @Test func expressesSubtractiveComponentsWithNegativeWeight() {
        // 実データ検証: `GrossProfitIFRS = RevenueIFRS − CostOfSalesIFRS`（控除項目は weight=-1）。
        let plRole = role("StatementOfProfitOrLossIFRS")
        let facts: XbrlFactIndex = [
            "GrossProfitIFRS": [
                "CurrentYearDuration": XbrlFact(
                    tag: "GrossProfitIFRS", contextRef: "CurrentYearDuration", value: 1_102_867,
                    consolidation: "", role: plRole)
            ]
        ]
        let calculationComponentsByRoleTag: [String: [String: [CalcComponent]]] = [
            plRole: [
                "GrossProfitIFRS": [
                    CalcComponent(tag: "RevenueIFRS", weight: 1),
                    CalcComponent(tag: "CostOfSalesIFRS", weight: -1),
                ]
            ]
        ]
        let items = StatementClassifier.extractLineItems(
            from: facts, sectionType: .incomeStatement,
            calculationComponentsByRoleTag: calculationComponentsByRoleTag)
        #expect(items.first?.isTotal == true)
        #expect(items.first?.components?.map(\.weight) == [1, -1])
    }

    @Test func isTotalIsFalseByDefaultWhenCalculationComponentsNotProvided() {
        let bsRole = role("BalanceSheet")
        let facts: XbrlFactIndex = [
            "CashAndDeposits": [
                "CurrentYearInstant": XbrlFact(
                    tag: "CashAndDeposits", contextRef: "CurrentYearInstant", value: 100,
                    consolidation: "", role: bsRole)
            ]
        ]
        let items = StatementClassifier.extractLineItems(from: facts, sectionType: .balanceSheet)
        #expect(items.first?.isTotal == false)
        #expect(items.first?.components == nil)
    }
}
