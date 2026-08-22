// Feed Update の提出日時索引。
// `GET /v1/feed/updates` が doc_type + submit_date_time 降順で読む。

import Fluent
import SQLKit

struct AddFeedQueryIndexesToEdinetDocuments: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.create(index: "idx_edinet_documents_doc_type_submit")
            .on(EdinetDocument.schema)
            .column("doc_type_code")
            .column("submit_date_time")
            .run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.drop(index: "idx_edinet_documents_doc_type_submit").ifExists().run()
    }
}
