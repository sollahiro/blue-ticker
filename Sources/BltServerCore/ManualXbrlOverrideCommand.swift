// `blt-server overrides`。add / list / revoke。書き込みは WRITE URL 必須。--dry-run は検証と diff のみ。

import BlueTickerCore
import Fluent
import Foundation
import Vapor

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

enum ManualXbrlOverrideCommandError: Error, CustomStringConvertible {
    case writeDatabaseURLMissing
    case databaseUnavailable
    case fileNotFound(String)
    case invalidUsage(String)
    case activeExists(id: UUID?)
    case notFound
    case alreadyRevoked(id: UUID)

    var description: String {
        switch self {
        case .writeDatabaseURLMissing:
            return "\(manualXbrlOverrideWriteDatabaseURLEnv) が未設定です。overrides add / revoke の書き込みには本番 WRITE URL の明示が必要です。"
        case .databaseUnavailable:
            return "DATABASE_URL が未設定です。overrides list / --dry-run には DB 接続が必要です。"
        case .fileNotFound(let path):
            return "指定されたファイルが見つかりません: \(path)"
        case .invalidUsage(let message):
            return message
        case .activeExists(let id):
            let suffix = id.map { " (id=\($0.uuidString))" } ?? ""
            return "有効な上書きが既にあります\(suffix)。先に overrides revoke してください。"
        case .notFound:
            return "対象の上書きが見つかりません。"
        case .alreadyRevoked(let id):
            return "既に revoke 済みです (id=\(id.uuidString))。"
        }
    }
}

public struct ManualXbrlOverrideCLIArgs: Sendable {
    public var subcommand: String
    public var file: String?
    public var createdBy: String?
    public var dryRun: Bool
    public var edinetCode: String?
    public var item: String?
    public var includeRevoked: Bool
    public var id: String?
    public var periodEnd: String?

    public init(
        subcommand: String, file: String? = nil, createdBy: String? = nil, dryRun: Bool = false,
        edinetCode: String? = nil, item: String? = nil, includeRevoked: Bool = false,
        id: String? = nil, periodEnd: String? = nil
    ) {
        self.subcommand = subcommand
        self.file = file
        self.createdBy = createdBy
        self.dryRun = dryRun
        self.edinetCode = edinetCode
        self.item = item
        self.includeRevoked = includeRevoked
        self.id = id
        self.periodEnd = periodEnd
    }
}

public func runManualXbrlOverrideCommand(_ args: ManualXbrlOverrideCLIArgs) async throws {
    switch args.subcommand {
    case "add":
        try await runManualXbrlOverrideAdd(args)
    case "list":
        try await runManualXbrlOverrideList(args)
    case "revoke":
        try await runManualXbrlOverrideRevoke(args)
    default:
        throw ManualXbrlOverrideCommandError.invalidUsage(
            "overrides のサブコマンドは add / list / revoke です")
    }
}

func runManualXbrlOverrideAdd(_ args: ManualXbrlOverrideCLIArgs) async throws {
    guard let path = args.file, !path.isEmpty else {
        throw ManualXbrlOverrideCommandError.invalidUsage(
            "overrides add には --file <path.json> が必要です")
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        throw ManualXbrlOverrideCommandError.fileNotFound(path)
    }
    let record = try parseManualXbrlOverrideAddFile(data, createdByOverride: args.createdBy)
    if args.dryRun {
        try await withOverrideDatabase(write: false) { db in
            let diff = try await manualXbrlOverrideDiff(record: record, on: db)
            print(prettyJSON(["dry_run": true, "record": recordJSON(record, id: nil), "diff": diff]))
        }
        return
    }
    try await withOverrideDatabase(write: true) { db in
        let row = try await insertManualXbrlOverride(record, on: db)
        print(prettyJSON(["written": true, "record": recordJSON(record, id: row.id)]))
    }
}

func runManualXbrlOverrideList(_ args: ManualXbrlOverrideCLIArgs) async throws {
    let item = try args.item.map { try parseManualXbrlOverrideItem($0) }
    try await withOverrideDatabase(write: false) { db in
        let rows = try await listManualXbrlOverrides(
            edinetCode: args.edinetCode, item: item, includeRevoked: args.includeRevoked, on: db)
        let listed = try rows.map { row -> [String: Any] in
            let record = try row.validatedRecord()
            return rowJSON(row, record: record)
        }
        print(prettyJSON(["overrides": listed]))
    }
}

func runManualXbrlOverrideRevoke(_ args: ManualXbrlOverrideCLIArgs) async throws {
    if args.dryRun {
        try await withOverrideDatabase(write: false) { db in
            let row = try await resolveRevokeTarget(args, on: db)
            let record = try row.validatedRecord()
            print(prettyJSON(["dry_run": true, "would_revoke": rowJSON(row, record: record)]))
        }
        return
    }
    try await withOverrideDatabase(write: true) { db in
        let row: ManualXbrlOverrideRow
        if let idRaw = args.id {
            guard let id = UUID(uuidString: idRaw) else {
                throw ManualXbrlOverrideCommandError.invalidUsage("--id は UUID で指定してください")
            }
            row = try await revokeManualXbrlOverride(id: id, on: db)
        } else {
            let item = try parseManualXbrlOverrideItem(
                try requireCLI(args.item, flag: "--item"))
            row = try await revokeActiveManualXbrlOverride(
                edinetCode: try requireCLI(args.edinetCode, flag: "--edinet-code"),
                periodEnd: try requireCLI(args.periodEnd, flag: "--period-end"),
                item: item, on: db)
        }
        let record = try row.validatedRecord()
        print(prettyJSON(["revoked": true, "record": rowJSON(row, record: record)]))
    }
}

private func resolveRevokeTarget(
    _ args: ManualXbrlOverrideCLIArgs, on db: Database
) async throws -> ManualXbrlOverrideRow {
    if let idRaw = args.id {
        guard let id = UUID(uuidString: idRaw) else {
            throw ManualXbrlOverrideCommandError.invalidUsage("--id は UUID で指定してください")
        }
        guard let row = try await ManualXbrlOverrideRow.find(id, on: db) else {
            throw ManualXbrlOverrideCommandError.notFound
        }
        return row
    }
    let item = try parseManualXbrlOverrideItem(try requireCLI(args.item, flag: "--item"))
    guard let row = try await findActiveManualXbrlOverride(
        edinetCode: try requireCLI(args.edinetCode, flag: "--edinet-code"),
        periodEnd: try requireCLI(args.periodEnd, flag: "--period-end"),
        item: item, on: db)
    else {
        throw ManualXbrlOverrideCommandError.notFound
    }
    return row
}

private func requireCLI(_ value: String?, flag: String) throws -> String {
    guard let value, !value.isEmpty else {
        throw ManualXbrlOverrideCommandError.invalidUsage("\(flag) が必要です")
    }
    return value
}

private func withOverrideDatabase(
    write: Bool, _ body: (Database) async throws -> Void
) async throws {
    if write {
        guard let writeURL = Environment.get(manualXbrlOverrideWriteDatabaseURLEnv),
            !writeURL.isEmpty
        else {
            throw ManualXbrlOverrideCommandError.writeDatabaseURLMissing
        }
        setenv("DATABASE_URL", writeURL, 1)
    } else {
        guard let url = Environment.get("DATABASE_URL"), !url.isEmpty else {
            throw ManualXbrlOverrideCommandError.databaseUnavailable
        }
    }
    var env = Environment(name: "production", arguments: ["blt-server"])
    try bootstrapBltLogging(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app)
        try await body(app.db)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

func manualXbrlOverrideDiff(
    record: ManualXbrlOverrideRecord, on db: Database
) async throws -> [String: Any] {
    let docs = try await EdinetDocument.query(on: db)
        .filter(\.$edinetCode == record.edinetCode)
        .filter(\.$periodEnd == record.periodEnd)
        .filter(\.$docTypeCode == Api.docTypeAnnualReport)
        .all()
    let codes = docs.compactMap { listedTickerCode(fromSecCode: $0.secCode) }
    switch record.payload {
    case .capex(let payload):
        var current: Double? = nil
        if let code = codes.first, let row = try await CompanyFinancials.find(code, on: db) {
            current = row.response.capexMillionYen(periodEnd: record.periodEnd)
        }
        return [
            "item": record.item.rawValue,
            "current_capex_million_yen": current as Any? ?? NSNull(),
            "override_capex_million_yen": payload.millionYen,
            "override_yen": payload.yen,
        ]
    }
}

private func recordJSON(_ record: ManualXbrlOverrideRecord, id: UUID?) -> [String: Any] {
    var json: [String: Any] = [
        "edinet_code": record.edinetCode,
        "period_end": record.periodEnd,
        "item": record.item.rawValue,
        "payload": manualXbrlOverridePayloadJSONObject(record.payload),
        "source_doc_id": record.sourceDocID,
        "source_page": record.sourcePage,
        "reason": record.reason,
        "created_by": record.createdBy,
    ]
    if let id {
        json["id"] = id.uuidString
    }
    return json
}

private func rowJSON(_ row: ManualXbrlOverrideRow, record: ManualXbrlOverrideRecord) -> [String: Any] {
    var json = recordJSON(record, id: row.id)
    json["created_at"] = row.createdAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
    json["revoked_at"] = row.revokedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
    return json
}

private func prettyJSON(_ value: [String: Any]) -> String {
    let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
}
