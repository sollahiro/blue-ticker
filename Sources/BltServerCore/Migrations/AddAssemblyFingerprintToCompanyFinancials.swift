// company_financials に assembly_fingerprint 列を追加する（タスク #11）。
// 組立が読む正本 cache_version の指紋を記録し、statement / notes / breakdown の抽出世代が
// 変わったら fin-vN を上げなくても再組立する。nullable（required は付けない）。
// 既存行は現行指紋で埋める。NULL のままにすると次回 ingest が全件再組立になるため。

import BlueTickerCore
import Fluent
import SQLKit

struct AddAssemblyFingerprintToCompanyFinancials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema)
            .field("assembly_fingerprint", .string)
            .update()
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            UPDATE company_financials
            SET assembly_fingerprint = \(bind: financialsAssemblyFingerprint())
            WHERE assembly_fingerprint IS NULL
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema)
            .deleteField("assembly_fingerprint")
            .update()
    }
}
