// Stage 7（Statement 本体）: 単一書類の XBRL から BS/PL/CF を抽出する。
// docs/statement-normalization-concept.md 参照。IndividualAnalyzer（Stage 4）と異なり、
// 複数年度の履歴集約（EdinetDiscovery 走査）は行わない。1書類＝1年度分の抽出のみ
// （複数年対応は Stage7Ingest 実装時に追加）。

import Foundation

struct StatementAnalyzer {
    let edinetClient: EdinetAPIClient

    /// 指定 docID の XBRL をダウンロードし、要求された statement type だけを抽出する。
    /// ダウンロード失敗時は nil（戻り値パターン、error-handling.md）。
    func extract(
        docID: String, statementTypes: Set<StatementSectionType>
    ) async -> StatementYear? {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return nil }
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)

        var balanceSheet: [StatementLineItem] = []
        var incomeStatement: [StatementLineItem] = []
        var cashFlow: [StatementLineItem] = []

        if statementTypes.contains(.balanceSheet) {
            balanceSheet = StatementClassifier.extractLineItems(from: facts, sectionType: .balanceSheet)
        }
        if statementTypes.contains(.incomeStatement) {
            incomeStatement = StatementClassifier.extractLineItems(
                from: facts, sectionType: .incomeStatement)
        }
        if statementTypes.contains(.cashFlow) {
            cashFlow = StatementClassifier.extractLineItems(from: facts, sectionType: .cashFlow)
        }

        return StatementYear(
            fyEnd: nil, financialPeriod: nil, docId: docID,
            balanceSheet: balanceSheet, incomeStatement: incomeStatement, cashFlow: cashFlow)
    }
}
