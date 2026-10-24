// company_breakdowns に not_applicable_reason 列を追加する（issue #132）。
// product_service 軸が解決できなかった理由（E: geography_only / F: single_segment_disclosed / unknown）を
// 永続化し、REST/MCP の 404 応答へ反映するために使う。nullable のため required は付けない
// （実データ行は常に NULL。source == breakdownSourceNotApplicable の行にのみ設定される）。

import BltStoreCore
import FluentKit

struct AddNotApplicableReasonToCompanyBreakdowns: AsyncMigration {
    // 適用済みの記録（_fluent_migrations）と一致させるため、移動前のモジュール名で固定する。
    var name: String { "BltServerCore.AddNotApplicableReasonToCompanyBreakdowns" }

    func prepare(on database: Database) async throws {
        try await database.schema(CompanyBreakdown.schema)
            .field("not_applicable_reason", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyBreakdown.schema)
            .deleteField("not_applicable_reason")
            .update()
    }
}
