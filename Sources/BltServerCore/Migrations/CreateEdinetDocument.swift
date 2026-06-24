// edinet_documents テーブルの作成。
// 企業ごとの引き当て（edinet_code / sec_code）が読み取りのホットパスのため、両カラムに索引を張る。

import Fluent
import SQLKit

struct CreateEdinetDocument: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(EdinetDocument.schema)
            .field("doc_id", .string, .identifier(auto: false))
            .field("edinet_code", .string, .required)
            .field("sec_code", .string)
            .field("filer_name", .string, .required)
            .field("doc_type_code", .string)
            .field("ordinance_code", .string)
            .field("form_code", .string)
            .field("period_start", .string)
            .field("period_end", .string)
            .field("submit_date_time", .string, .required)
            .field("doc_description", .string)
            .field("updated_at", .datetime)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.create(index: "idx_edinet_documents_edinet_code")
                .on(EdinetDocument.schema).column("edinet_code").run()
            try await sql.create(index: "idx_edinet_documents_sec_code")
                .on(EdinetDocument.schema).column("sec_code").run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(EdinetDocument.schema).delete()
    }
}
