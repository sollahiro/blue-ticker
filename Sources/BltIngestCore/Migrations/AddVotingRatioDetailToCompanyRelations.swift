// company_relations に議決権の内訳の列を追加する（凍結済み・変更しない）。
// voting_ratio_indirect は間接所有の内数、voting_ratio_close_parties は緊密な者・同意している者の外数。
// nullable のため既存行は NULL のまま。relations-v2 の再取り込みで埋まる。

import BltStoreCore
import FluentKit

struct AddVotingRatioDetailToCompanyRelations: AsyncMigration {
    // 適用済みの記録（_fluent_migrations）と一致させるため、移動前のモジュール名で固定する。
    var name: String { "BltServerCore.AddVotingRatioDetailToCompanyRelations" }

    func prepare(on database: Database) async throws {
        // SQLite（テスト）は 1 文で 1 列しか足せない。
        try await database.schema(CompanyRelation.schema).field("voting_ratio_indirect", .double).update()
        try await database.schema(CompanyRelation.schema).field("voting_ratio_close_parties", .double).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CompanyRelation.schema).deleteField("voting_ratio_close_parties").update()
        try await database.schema(CompanyRelation.schema).deleteField("voting_ratio_indirect").update()
    }
}
