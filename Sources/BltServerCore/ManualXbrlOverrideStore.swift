// 手動 XBRL 上書きの DB 読み書き。ingest は有効行だけを決定的に再適用する。

import BlueTickerCore
import Fluent
import FluentSQL
import Foundation
import SQLKit

func loadActiveManualXbrlOverrides(on db: Database) async throws -> [ManualXbrlOverrideRecord] {
    let rows = try await ManualXbrlOverrideRow.query(on: db)
        .filter(.sql(SQLRaw("revoked_at IS NULL")))
        .sort(\.$createdAt, .ascending)
        .all()
    return try rows.map { try $0.validatedRecord() }
}

func findActiveManualXbrlOverride(
    edinetCode: String, periodEnd: String, item: ManualXbrlOverrideItem, on db: Database
) async throws -> ManualXbrlOverrideRow? {
    try await ManualXbrlOverrideRow.query(on: db)
        .filter(\.$edinetCode == edinetCode)
        .filter(\.$periodEnd == periodEnd)
        .filter(\.$item == item.rawValue)
        .filter(.sql(SQLRaw("revoked_at IS NULL")))
        .first()
}

func insertManualXbrlOverride(
    _ record: ManualXbrlOverrideRecord, on db: Database
) async throws -> ManualXbrlOverrideRow {
    if let existing = try await findActiveManualXbrlOverride(
        edinetCode: record.edinetCode, periodEnd: record.periodEnd, item: record.item, on: db)
    {
        throw ManualXbrlOverrideCommandError.activeExists(id: existing.id)
    }
    let row = ManualXbrlOverrideRow(record: record)
    try await row.create(on: db)
    return row
}

func listManualXbrlOverrides(
    edinetCode: String?, item: ManualXbrlOverrideItem?, includeRevoked: Bool, on db: Database
) async throws -> [ManualXbrlOverrideRow] {
    var query = ManualXbrlOverrideRow.query(on: db)
    if let edinetCode {
        query = query.filter(\.$edinetCode == edinetCode)
    }
    if let item {
        query = query.filter(\.$item == item.rawValue)
    }
    if !includeRevoked {
        query = query.filter(.sql(SQLRaw("revoked_at IS NULL")))
    }
    return try await query.sort(\.$createdAt, .ascending).all()
}

func revokeManualXbrlOverride(
    id: UUID, on db: Database, now: Date = Date()
) async throws -> ManualXbrlOverrideRow {
    guard let row = try await ManualXbrlOverrideRow.find(id, on: db) else {
        throw ManualXbrlOverrideCommandError.notFound
    }
    if row.revokedAt != nil {
        throw ManualXbrlOverrideCommandError.alreadyRevoked(id: id)
    }
    row.revokedAt = now
    try await row.update(on: db)
    try await stampDerivedRowsStaleAfterOverrideRevoke(row: row, on: db)
    return row
}

func revokeActiveManualXbrlOverride(
    edinetCode: String, periodEnd: String, item: ManualXbrlOverrideItem, on db: Database,
    now: Date = Date()
) async throws -> ManualXbrlOverrideRow {
    guard let row = try await findActiveManualXbrlOverride(
        edinetCode: edinetCode, periodEnd: periodEnd, item: item, on: db)
    else {
        throw ManualXbrlOverrideCommandError.notFound
    }
    row.revokedAt = now
    try await row.update(on: db)
    try await stampDerivedRowsStaleAfterOverrideRevoke(row: row, on: db)
    return row
}

/// 次の ingest が filing へ戻すよう、上書き済み derived 行の skip を外す。
func stampDerivedRowsStaleAfterOverrideRevoke(
    row: ManualXbrlOverrideRow, on db: Database
) async throws {
    let docs = try await EdinetDocument.query(on: db)
        .filter(\.$edinetCode == row.edinetCode)
        .filter(\.$periodEnd == row.periodEnd)
        .filter(\.$docTypeCode == Api.docTypeAnnualReport)
        .all()
    let codes = Set(docs.compactMap { listedTickerCode(fromSecCode: $0.secCode) })
    let docIDs = Set(docs.compactMap(\.id))

    if row.item == ManualXbrlOverrideItem.capex.rawValue {
        for code in codes {
            guard let financials = try await CompanyFinancials.find(code, on: db) else { continue }
            financials.assemblyFingerprint = nil
            try await financials.update(on: db)
        }
    }
    if row.item == ManualXbrlOverrideItem.policyHoldingSecurities.rawValue {
        for docID in docIDs {
            let key = CompanyStatementNote.compositeID(
                docID: docID, noteType: statementNoteTypePolicyHoldingSecurities)
            guard let note = try await CompanyStatementNote.find(key, on: db),
                note.source == statementNoteSourceManualOverride
            else { continue }
            note.needsReview = true
            note.payload.needsReview = true
            try await note.update(on: db)
        }
    }
}

func manualXbrlOverrideForceTargets(
    overrides: [ManualXbrlOverrideRecord], on db: Database
) async throws -> (codes: Set<String>, docIDs: Set<String>) {
    var codes: Set<String> = []
    var docIDs: Set<String> = []
    for override in overrides {
        let docs = try await EdinetDocument.query(on: db)
            .filter(\.$edinetCode == override.edinetCode)
            .filter(\.$periodEnd == override.periodEnd)
            .filter(\.$docTypeCode == Api.docTypeAnnualReport)
            .all()
        for doc in docs {
            if let id = doc.id { docIDs.insert(id) }
            if let code = listedTickerCode(fromSecCode: doc.secCode) {
                codes.insert(code)
            }
        }
    }
    let staleNotes = try await CompanyStatementNote.query(on: db)
        .filter(\.$source == statementNoteSourceManualOverride)
        .filter(\.$noteType == statementNoteTypePolicyHoldingSecurities)
        .all()
    let activeKeys = Set(
        overrides.filter { $0.item == .policyHoldingSecurities }.map {
            "\($0.edinetCode)#\($0.periodEnd)"
        })
    for note in staleNotes {
        guard let doc = try await EdinetDocument.find(note.docID, on: db) else {
            docIDs.insert(note.docID)
            codes.insert(note.code)
            continue
        }
        let key = "\(doc.edinetCode)#\(doc.periodEnd ?? "")"
        if !activeKeys.contains(key) {
            docIDs.insert(note.docID)
            codes.insert(note.code)
        }
    }
    return (codes, docIDs)
}

func policyHoldingOverridesByOriginalDocID(
    overrides: [ManualXbrlOverrideRecord], on db: Database
) async throws -> [String: ManualXbrlOverrideRecord] {
    var mapped: [String: ManualXbrlOverrideRecord] = [:]
    for override in overrides where override.item == .policyHoldingSecurities {
        let docs = try await EdinetDocument.query(on: db)
            .filter(\.$edinetCode == override.edinetCode)
            .filter(\.$periodEnd == override.periodEnd)
            .filter(\.$docTypeCode == Api.docTypeAnnualReport)
            .all()
        for doc in docs {
            if let id = doc.id { mapped[id] = override }
        }
    }
    return mapped
}

func overrideMatching(
    docID: String, item: ManualXbrlOverrideItem, overrides: [ManualXbrlOverrideRecord],
    on db: Database
) async throws -> ManualXbrlOverrideRecord? {
    guard let doc = try await EdinetDocument.find(docID, on: db) else { return nil }
    let periodEnd = doc.periodEnd ?? ""
    return overrides.first {
        $0.item == item && $0.edinetCode == doc.edinetCode && $0.periodEnd == periodEnd
    }
}
