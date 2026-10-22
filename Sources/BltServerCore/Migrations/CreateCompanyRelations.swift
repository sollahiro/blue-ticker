// company_relations テーブルの作成（関係取り込み。1 行 = 書類 1 件の相手 1 件）。
// 索引は (code)・(related_code, kind)・(name_norm)、一意制約は (code, section, position)。逆引き（仕入先・親会社・大株主になっている会社）は
// (related_code, kind) で引く。子会社索引の名前照合は (name_norm)。
// 表は `.ignoreExisting()`、索引は `CREATE INDEX IF NOT EXISTS`（AddCodeSubmitDateTimeIndexes と同じ理由。
// autoMigrate の再試行で、表の作成だけ済んだ途中失敗から復帰できるようにする）。

import Fluent
import SQLKit

struct CreateCompanyRelations: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyRelation.schema)
            .id()
            .field("code", .string, .required)
            .field("doc_id", .string, .required)
            .field("submit_date_time", .string, .required)
            .field("fy_end", .string)
            .field("section", .string, .required)
            .field("kind", .string, .required)
            .field("position", .int, .required)
            .field("name_raw", .string, .required)
            .field("name_norm", .string, .required)
            .field("amount_yen", .double)
            .field("segment_label", .string)
            .field("voting_ratio", .double)
            .field("related_code", .string)
            .field("resolution", .string)
            .field("resolver_key", .string)
            .field("needs_review", .bool, .required)
            .field("decided_by", .string, .required)
            .field("shares", .double)
            .field("book_value_yen", .double)
            .field("purpose", .string)
            .field("is_deemed", .bool)
            .field("holder", .string)
            .field("ratio", .double)
            .field("rank", .int)
            .field("address", .string)
            .field("section_status", .string)
            .field("warning", .string)
            .field("cache_version", .string, .required)
            .field("updated_at", .datetime)
            // 同じ会社を並行して差し替えても行が重複しない（後から来た挿入は一意制約で失敗し再試行される）。
            .unique(on: "code", "section", "position", name: "uq_company_relations_code_section_position")
            .ignoreExisting()
            .create()
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_company_relations_code ON company_relations (code)"
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_company_relations_related_code_kind
            ON company_relations (related_code, kind)
            """
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_company_relations_name_norm ON company_relations (name_norm)"
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyRelation.schema).delete()
    }
}
