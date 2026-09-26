// 有報(120)に対する訂正(130) XBRL 候補の引き当て。
// 公開行の doc_id は原本のまま。パースできる訂正の fact / TextBlock を提出順に overlay する。

import BlueTickerCore
import Fluent
import Foundation
import Logging

extension EdinetDocument {
    var xbrlSourceDocument: XbrlSourceDocument {
        XbrlSourceDocument(
            docID: id ?? "",
            docTypeCode: docTypeCode,
            parentDocID: parentDocID,
            edinetCode: edinetCode,
            periodStart: periodStart,
            periodEnd: periodEnd,
            submitDateTime: submitDateTime,
            docDescription: docDescription)
    }
}

/// 会社開示府令の 120/130 から、原本 docID → 訂正 docID（新しい順）を作る。
func loadAnnualXbrlCorrectionIDsByOriginal(
    db: Database, logger: Logger? = nil
) async throws -> [String: [String]] {
    let rows = try await withDbRetry(logger: logger, context: "訂正有報 XBRL 候補") {
        try await EdinetDocument.query(on: db)
            .filter(\.$ordinanceCode == Api.ordinanceCompanyDisclosure)
            .filter(\.$docTypeCode ~~ [Api.docTypeAnnualReport, Api.docTypeAmendment])
            .all()
    }
    let originals = rows.filter { $0.docTypeCode == Api.docTypeAnnualReport }.map(\.xbrlSourceDocument)
    let corrections = rows.filter { $0.docTypeCode == Api.docTypeAmendment }.map(\.xbrlSourceDocument)
    return preferredCorrectionDocIDsByOriginal(originals: originals, corrections: corrections)
}
