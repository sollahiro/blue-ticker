// Statement 取り込み（Statement 本体）: 単一書類の XBRL から BS/PL/CF/SS を抽出する。
// docs/statement-normalization-concept.md 参照。IndividualAnalyzer（財務取り込み）と異なり、
// 複数年度の履歴集約（EdinetDiscovery 走査）は行わない。1書類＝1年度分の抽出のみ
// （複数年対応は StatementIngest 実装時に追加）。

import Foundation

struct StatementAnalyzer {
    let edinetClient: EdinetAPIClient

    /// 指定 docID の XBRL をダウンロードし、要求された statement type だけを抽出する。
    /// ダウンロード失敗は `.failed`。US-GAAP は連結に数値 fact が無いため `.notApplicable`
    /// （個別 BS への silent fallback はしない。notes と同方針、2026-08-09）。
    func extract(
        docID: String, statementTypes: Set<StatementSectionType>
    ) async -> StatementDocResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        let tagElements = XBRLUtils.factIndexToNumericElements(facts)
        if detectAccountingStandard(tagElements) == "US-GAAP" {
            return .notApplicable(reason: statementNotApplicableUSGAAP)
        }

        let parentTagsByRoleTag = XBRLUtils.loadPresentationParents(in: xbrlDir)
        let preferredLabelByRoleTag = XBRLUtils.loadPreferredLabelRoles(in: xbrlDir)
        let labelRoleVariantsByTag = XBRLUtils.loadLabelRoleVariants(in: xbrlDir)
        let calculationComponentsByRoleTag = XBRLUtils.loadCalculationComponents(in: xbrlDir)

        var balanceSheet: [StatementLineItem] = []
        var incomeStatement: [StatementLineItem] = []
        var cashFlow: [StatementLineItem] = []
        var changesInEquity: [StatementLineItem] = []

        if statementTypes.contains(.balanceSheet) {
            balanceSheet = StatementClassifier.extractLineItems(
                from: facts, sectionType: .balanceSheet, parentTagsByRoleTag: parentTagsByRoleTag,
                preferredLabelByRoleTag: preferredLabelByRoleTag,
                labelRoleVariantsByTag: labelRoleVariantsByTag,
                calculationComponentsByRoleTag: calculationComponentsByRoleTag)
        }
        if statementTypes.contains(.incomeStatement) {
            incomeStatement = StatementClassifier.extractLineItems(
                from: facts, sectionType: .incomeStatement,
                preferredLabelByRoleTag: preferredLabelByRoleTag,
                labelRoleVariantsByTag: labelRoleVariantsByTag,
                calculationComponentsByRoleTag: calculationComponentsByRoleTag)
        }
        if statementTypes.contains(.cashFlow) {
            cashFlow = StatementClassifier.extractLineItems(
                from: facts, sectionType: .cashFlow, parentTagsByRoleTag: parentTagsByRoleTag,
                preferredLabelByRoleTag: preferredLabelByRoleTag,
                labelRoleVariantsByTag: labelRoleVariantsByTag,
                calculationComponentsByRoleTag: calculationComponentsByRoleTag)
        }
        if statementTypes.contains(.changesInEquity) {
            changesInEquity = StatementClassifier.extractLineItems(
                from: facts, sectionType: .changesInEquity, parentTagsByRoleTag: parentTagsByRoleTag,
                preferredLabelByRoleTag: preferredLabelByRoleTag,
                labelRoleVariantsByTag: labelRoleVariantsByTag,
                calculationComponentsByRoleTag: calculationComponentsByRoleTag)
        }

        return .resolved(
            StatementYear(
                fyEnd: nil, financialPeriod: nil, docId: docID,
                balanceSheet: balanceSheet, incomeStatement: incomeStatement, cashFlow: cashFlow,
                changesInEquity: changesInEquity))
    }
}
