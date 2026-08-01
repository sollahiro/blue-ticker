// company_financials / company_half_financials に high_water 列を追加する（凍結済み・変更しない）。
// high-water 鮮度トリガー（issue #26）: 計算の基にした書類集合の max(submitDateTime) を記録し、
// 次回 ingest でこれより新しい提出があれば再計算する。nullable のため required は付けない
// （既存行は NULL のまま。次回 ingest で一度だけ再計算されることで自然に埋まる）。
// 半期分析機能は削除済み（company_half_financials は DropCompanyHalfFinancials で削除）。
// Model 型は削除済みのため、スキーマ名は当時と同じ値をリテラルで参照する。

import Fluent

struct AddHighWaterToCompanyFinancials: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema).field("high_water", .string).update()
        try await database.schema("company_half_financials").field("high_water", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyFinancials.schema).deleteField("high_water").update()
        try await database.schema("company_half_financials").deleteField("high_water").update()
    }
}
