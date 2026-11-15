// company_filing_sections.r2_key: 本文を R2 に置いた行のオブジェクトキー。
// NULL（既存行）は従来どおり payload 列に本文を持つ。非 NULL の行は payload を空にし、本文は R2 から読む。
// nullable で追加するだけなので、旧版サーバーは列を無視して動く（先に migrate してよい）。

import BltStoreCore
import FluentKit

struct AddR2KeyToFilingSections: AsyncMigration {
    // マイグレーション名は一度適用したら変えない（MigrationNameStabilityTests）。
    var name: String { "BltServerCore.AddR2KeyToFilingSections" }

    func prepare(on database: Database) async throws {
        try await database.schema(CompanyFilingSections.schema)
            .field("r2_key", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyFilingSections.schema)
            .deleteField("r2_key")
            .update()
    }
}
