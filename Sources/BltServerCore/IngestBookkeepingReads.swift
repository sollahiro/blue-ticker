// ingest 分類・件数集計の SQL 寄せ。候補集合と servable 件数は従来の in-memory 走査と
// 同じ結果になること（転送行だけ減らす。cache_version は触らない）。
// SQLite / Postgres はどちらも SQLDatabase。非 SQL ドライバは使わない
// （hydrate フォールバックは全表転送に戻る）。

import BlueTickerCore
import Fluent
import SQLKit

/// 発行体（sec_code × edinet_code の組）単位の集約行。`highWater` は
/// `docTypes` ∩ 会社開示府令(010) の doc だけの `MAX(submit_date_time)`（無ければ nil）。
/// `newestAnnual` は会社開示府令の有報(120) のうち period_end 最大の 1 件（`period_end|doc_id`、無ければ nil）。
typealias IssuerHighWater = (
    secCode: String?, edinetCode: String, highWater: String?, newestAnnual: String?
)

/// 数値 fact 取り込みの分類結果。`missing` / `stale` は提出日時降順（従来の一覧走査と同じ）。
/// `skipped` は現行 cache_version の格納済み書類数。
struct FactsIngestClassifyWorklist: Equatable, Sendable {
    var missing: [String]
    var stale: [String]
    var skipped: Int
}

/// 書類一覧の分類に使う列。テストのオラクルが DB 全表 `.all()` せずに同じ畳み込みを踏むため。
struct DocumentListingFields: Equatable, Sendable {
    var id: String?
    var edinetCode: String
    var secCode: String?
    var docTypeCode: String?
    var ordinanceCode: String?
    var submitDateTime: String
    var periodEnd: String?
}

/// `source` / `cache_version` / グループ列の `COUNT(*)`。servable 判定は Swift 側の既存関数に渡す。
struct IngestSourceVersionGroupCount: Equatable, Sendable {
    var source: String
    var cacheVersion: String
    var group: String
    var n: Int
}

enum IngestBookkeepingReadError: Error {
    /// Fluent の Database が SQLDatabase ではない（Postgres / SQLite 以外）。
    case sqlDatabaseRequired
}

func requireSQLDatabase(_ db: Database) throws -> SQLDatabase {
    guard let sql = db as? SQLDatabase else {
        throw IngestBookkeepingReadError.sqlDatabaseRequired
    }
    return sql
}

func sqlDecodeCount(_ row: SQLRow, column: String = "n") throws -> Int {
    if let n = try? row.decode(column: column, as: Int64.self) {
        return Int(n)
    }
    return try row.decode(column: column, as: Int.self)
}

func listingFields(from doc: EdinetDocumentListing) -> DocumentListingFields {
    DocumentListingFields(
        id: doc.id, edinetCode: doc.edinetCode, secCode: doc.secCode,
        docTypeCode: doc.docTypeCode, ordinanceCode: doc.ordinanceCode,
        submitDateTime: doc.submitDateTime, periodEnd: doc.periodEnd)
}

func isAnnualReportDisclosure(_ doc: DocumentListingFields) -> Bool {
    doc.docTypeCode == Api.docTypeAnnualReport
        && Api.isCompanyDisclosureOrdinance(doc.ordinanceCode)
}

func annualReportDisclosureDocsFromFields(
    _ docs: [DocumentListingFields]
) -> [DocumentListingFields] {
    docs.filter(isAnnualReportDisclosure)
}

/// 従来の「全書類を新しい順に走査して missing / stale / skipped に分ける」と同じ結果。
func factsIngestClassifyWorklistFromFields(
    _ documents: [DocumentListingFields],
    factsByID: [String: String],
    currentVersion: String
) -> FactsIngestClassifyWorklist {
    let ordered = documents.sorted { $0.submitDateTime > $1.submitDateTime }
    var missing: [String] = []
    var stale: [String] = []
    var skipped = 0
    for doc in ordered {
        guard let docID = doc.id else { continue }
        guard let version = factsByID[docID] else {
            missing.append(docID)
            continue
        }
        if version != currentVersion {
            stale.append(docID)
        } else {
            skipped += 1
        }
    }
    return FactsIngestClassifyWorklist(missing: missing, stale: stale, skipped: skipped)
}

func factsIngestClassifyWorklist(
    db: Database, currentVersion: String = xbrlFactsCacheVersion
) async throws -> FactsIngestClassifyWorklist {
    let sql = try requireSQLDatabase(db)
    let workRows = try await sql.raw("""
        SELECT \(ident: EdinetDocument.schema).\(ident: "doc_id") AS doc_id,
            CASE WHEN \(ident: EdinetXbrlFacts.schema).\(ident: "doc_id") IS NULL THEN 0 ELSE 1 END AS is_stale
        FROM \(ident: EdinetDocument.schema)
        LEFT JOIN \(ident: EdinetXbrlFacts.schema)
            ON \(ident: EdinetXbrlFacts.schema).\(ident: "doc_id")
                = \(ident: EdinetDocument.schema).\(ident: "doc_id")
        WHERE \(ident: EdinetXbrlFacts.schema).\(ident: "doc_id") IS NULL
            OR \(ident: EdinetXbrlFacts.schema).\(ident: "cache_version") <> \(bind: currentVersion)
        ORDER BY \(ident: EdinetDocument.schema).\(ident: "submit_date_time") DESC
        """).all()
    var missing: [String] = []
    var stale: [String] = []
    missing.reserveCapacity(workRows.count)
    stale.reserveCapacity(workRows.count)
    for row in workRows {
        let docID = try row.decode(column: "doc_id", as: String.self)
        if try sqlDecodeCount(row, column: "is_stale") == 0 {
            missing.append(docID)
        } else {
            stale.append(docID)
        }
    }
    let skippedRows = try await sql.raw("""
        SELECT COUNT(*) AS n
        FROM \(ident: EdinetDocument.schema)
        INNER JOIN \(ident: EdinetXbrlFacts.schema)
            ON \(ident: EdinetXbrlFacts.schema).\(ident: "doc_id")
                = \(ident: EdinetDocument.schema).\(ident: "doc_id")
        WHERE \(ident: EdinetXbrlFacts.schema).\(ident: "cache_version") = \(bind: currentVersion)
        """).all()
    let skipped = try skippedRows.first.map { try sqlDecodeCount($0) } ?? 0
    return FactsIngestClassifyWorklist(missing: missing, stale: stale, skipped: skipped)
}

/// 従来の発行体集約（全 listing を畳む）と同じ結果。SQL `GROUP BY` のオラクル。
func foldIssuerHighWaterRows(
    _ documents: [DocumentListingFields], docTypes: Set<String>
) -> [IssuerHighWater] {
    var order: [String] = []
    var byIssuer: [String: IssuerHighWater] = [:]
    for doc in documents {
        let key = "\(doc.secCode ?? "")\u{1F}\(doc.edinetCode)"
        var row = byIssuer[key]
            ?? (secCode: doc.secCode, edinetCode: doc.edinetCode, highWater: nil, newestAnnual: nil)
        if byIssuer[key] == nil { order.append(key) }
        if let docType = doc.docTypeCode, docTypes.contains(docType),
            Api.isCompanyDisclosureOrdinance(doc.ordinanceCode),
            doc.submitDateTime > (row.highWater ?? "")
        {
            row.highWater = doc.submitDateTime
        }
        if doc.docTypeCode == Api.docTypeAnnualReport,
            Api.isCompanyDisclosureOrdinance(doc.ordinanceCode),
            let periodEnd = doc.periodEnd, !periodEnd.isEmpty, let docID = doc.id
        {
            let candidate = "\(periodEnd.prefix(10))|\(docID)"
            if candidate > (row.newestAnnual ?? "") { row.newestAnnual = candidate }
        }
        byIssuer[key] = row
    }
    return order.compactMap { byIssuer[$0] }
}

func issuerHighWaterRows(
    db: Database, docTypes: Set<String>
) async throws -> [IssuerHighWater] {
    let sql = try requireSQLDatabase(db)
    let rows = try await sql.raw("""
        SELECT \(ident: "sec_code") AS sec_code,
            \(ident: "edinet_code") AS edinet_code,
            MAX(CASE WHEN \(ident: "doc_type_code") IN (\(binds: Array(docTypes)))
                    AND \(ident: "ordinance_code") = \(bind: Api.ordinanceCompanyDisclosure)
                THEN \(ident: "submit_date_time") END) AS high_water,
            MAX(CASE WHEN \(ident: "doc_type_code") = \(bind: Api.docTypeAnnualReport)
                    AND \(ident: "ordinance_code") = \(bind: Api.ordinanceCompanyDisclosure)
                    AND \(ident: "period_end") IS NOT NULL AND \(ident: "period_end") <> ''
                THEN SUBSTR(\(ident: "period_end"), 1, 10) || '|' || \(ident: "doc_id") END) AS newest_annual
        FROM \(ident: EdinetDocument.schema)
        GROUP BY \(ident: "sec_code"), \(ident: "edinet_code")
        ORDER BY \(ident: "edinet_code"), \(ident: "sec_code")
        """).all()
    return try rows.map { row in
        (
            try row.decode(column: "sec_code", as: String?.self),
            try row.decode(column: "edinet_code", as: String.self),
            try row.decode(column: "high_water", as: String?.self),
            try row.decode(column: "newest_annual", as: String?.self)
        )
    }
}

func sqlGroupedSourceVersionCounts(
    db: Database, schema: String, groupColumn: String
) async throws -> [IngestSourceVersionGroupCount] {
    let sql = try requireSQLDatabase(db)
    let rows = try await sql.raw("""
        SELECT \(ident: "source") AS source,
            \(ident: "cache_version") AS cache_version,
            \(ident: groupColumn) AS grp,
            COUNT(*) AS n
        FROM \(ident: schema)
        GROUP BY \(ident: "source"), \(ident: "cache_version"), \(ident: groupColumn)
        """).all()
    return try rows.map { row in
        IngestSourceVersionGroupCount(
            source: try row.decode(column: "source", as: String.self),
            cacheVersion: try row.decode(column: "cache_version", as: String.self),
            group: try row.decode(column: "grp", as: String.self),
            n: try sqlDecodeCount(row)
        )
    }
}

func servableCounts(
    from groups: [IngestSourceVersionGroupCount],
    isServable: (String, String, String) -> Bool
) -> (servable: Int, unservable: Int) {
    var servable = 0
    var total = 0
    for group in groups {
        total += group.n
        if isServable(group.source, group.cacheVersion, group.group) {
            servable += group.n
        }
    }
    return (servable, total - servable)
}

func servableCountsFromRows<T>(
    _ rows: [T],
    source: (T) -> String,
    cacheVersion: (T) -> String,
    group: (T) -> String,
    isServable: (String, String, String) -> Bool
) -> (servable: Int, unservable: Int) {
    var groups: [String: IngestSourceVersionGroupCount] = [:]
    var order: [String] = []
    for row in rows {
        let src = source(row)
        let version = cacheVersion(row)
        let keyGroup = group(row)
        let key = "\(src)\u{1F}\(version)\u{1F}\(keyGroup)"
        if groups[key] == nil {
            order.append(key)
            groups[key] = IngestSourceVersionGroupCount(
                source: src, cacheVersion: version, group: keyGroup, n: 0)
        }
        groups[key]?.n += 1
    }
    return servableCounts(from: order.compactMap { groups[$0] }, isServable: isServable)
}
