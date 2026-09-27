// edinet_documents に訂正対象（EDINET parentDocID）を追加する。
// 公開 filings の形は変えない。statement notes / financials が同一 FY の 130 XBRL を
// 選ぶための内部列。既存行は null のまま残り、次回 sync の upsert で埋まる。

import Fluent
import SQLKit

struct AddParentDocIDToEdinetDocuments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(EdinetDocument.schema)
            .field("parent_doc_id", .string)
            .update()
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_edinet_documents_parent_doc_id
            ON edinet_documents (parent_doc_id)
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.drop(index: "idx_edinet_documents_parent_doc_id").ifExists().run()
        }
        try await database.schema(EdinetDocument.schema).deleteField("parent_doc_id").update()
    }
}
