// company_financials に llm_audit 列を追加する。
// Summary `sga` の Jev 行選択監査。公開契約 `/financials` の response JSONB には載せない。

import Fluent

struct AddLlmAuditToCompanyFinancials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema)
            .field("llm_audit", .json)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema)
            .deleteField("llm_audit")
            .update()
    }
}
