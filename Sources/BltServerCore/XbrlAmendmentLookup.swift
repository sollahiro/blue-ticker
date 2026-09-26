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
/// `originalDocIDs` / `listedCodes` は今回 ingest 中の原本・証券コード。どちらか必須。
/// 空のときは空 map を返し、全件 120/130 は読まない。
func loadAnnualXbrlCorrectionIDsByOriginal(
    db: Database,
    originalDocIDs: Set<String> = [],
    listedCodes: Set<String> = [],
    logger: Logger? = nil
) async throws -> [String: [String]] {
    if originalDocIDs.isEmpty && listedCodes.isEmpty { return [:] }

    let originalRows = try await withDbRetry(logger: logger, context: "訂正有報 XBRL 原本") {
        try await annualXbrlOriginalsInFlight(
            db: db, originalDocIDs: originalDocIDs, listedCodes: listedCodes)
    }
    if originalRows.isEmpty { return [:] }

    let edinetCodes = Array(Set(originalRows.map(\.edinetCode).filter { !$0.isEmpty }))
    // 照合は edinet_code + 期末だけ。parent_doc_id では絞らない（ほぼ null。全件 130 も読まない）。
    if edinetCodes.isEmpty { return [:] }
    let correctionRows = try await withDbRetry(logger: logger, context: "訂正有報 XBRL 候補") {
        try await EdinetDocument.query(on: db)
            .filter(\.$ordinanceCode == Api.ordinanceCompanyDisclosure)
            .filter(\.$docTypeCode == Api.docTypeAmendment)
            .filter(\.$edinetCode ~~ edinetCodes)
            .all()
    }
    return preferredCorrectionDocIDsByOriginal(
        originals: originalRows.map(\.xbrlSourceDocument),
        corrections: correctionRows.map(\.xbrlSourceDocument))
}

/// 今回 ingest 対象の有報(120)だけを読む。`originalDocIDs` があればその主キーに限定し、
/// 無ければ `listedCodes` の 5 桁 secCode 集合へ落とす。
private func annualXbrlOriginalsInFlight(
    db: Database, originalDocIDs: Set<String>, listedCodes: Set<String>
) async throws -> [EdinetDocument] {
    let query = EdinetDocument.query(on: db)
        .filter(\.$ordinanceCode == Api.ordinanceCompanyDisclosure)
        .filter(\.$docTypeCode == Api.docTypeAnnualReport)
    if !originalDocIDs.isEmpty {
        return try await query.filter(\.$id ~~ Array(originalDocIDs)).all()
    }
    let secCodes = Array(Set(listedCodes.flatMap(edinetSecCodes(forIssuerCode:))))
    guard !secCodes.isEmpty else { return [] }
    return try await query.filter(\.$secCode ~~ secCodes).all()
}
