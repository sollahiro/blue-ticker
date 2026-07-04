// company_financials / company_half_financials に high_water 列を追加する。
// high-water 鮮度トリガー（issue #26）: 計算の基にした書類集合の max(submitDateTime) を記録し、
// 次回 ingest でこれより新しい提出があれば再計算する。nullable のため required は付けない
// （既存行は NULL のまま。次回 ingest で一度だけ再計算されることで自然に埋まる）。

import Fluent

struct AddHighWaterToCompanyFinancials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema).field("high_water", .string).update()
        try await database.schema(CompanyHalfFinancials.schema).field("high_water", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema).deleteField("high_water").update()
        try await database.schema(CompanyHalfFinancials.schema).deleteField("high_water").update()
    }
}
