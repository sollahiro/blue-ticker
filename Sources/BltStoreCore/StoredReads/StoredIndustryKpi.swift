import BlueTickerCore
import FluentKit
import Foundation

/// `GET /v1/benchmark/{group}` の応答スキーマ版。互換追加のときは上げない。
package let industryBenchmarkServeSchemaVersion = 1

/// 公開する業種グループ。ここに無いグループは 404（取り込み済みでも出さない）。
/// 業種を公開するときはここに足す（アプリ側の業種選択も同じ範囲だけを出す）。
package let industryBenchmarkPublicGroups: Set<String> = [industryKpiGroupBank]

/// 格納済みの業種 KPI を、業種グループ単位で全社分まとめて返す。
/// - 会社ごとに提出日時が最新の書類 1 件だけを使う。最新が対象外・要レビュー・値なしなら、その会社は出さない
///   （古い書類へはさかのぼらない。fail closed）。
/// - 現行の `cache_version` の行だけを使う。
/// - 各 KPI は連結（`consolidated`）を優先し、無ければ提出会社（`filer`）。子会社の値（`named_subsidiary`）は出さない。
/// - 社名・業種・アイコンはここでは付けない（呼び出し側で合成する）。
/// 公開できる会社が 1 社も無ければ nil（呼び出し側 404）。ライブ抽出へはフォールバックしない。
package func loadStoredIndustryBenchmark(group: String, db: Database) async throws -> [String: Any]? {
    guard industryBenchmarkPublicGroups.contains(group) else { return nil }
    let rows = try await IndustryKpiFact.query(on: db)
        .filter(\.$industryGroup == group)
        .filter(\.$cacheVersion == industryKpiCacheVersion)
        .sort(\.$submitDateTime, .descending)
        .all()
    guard !rows.isEmpty else { return nil }
    let companyDocIDs = try await companyDisclosureDocIDs(among: rows.map(\.docID), db: db)

    var latestByCode: [String: IndustryKpiFact] = [:]
    for row in rows where companyDocIDs.contains(row.docID) {
        if latestByCode[row.code] == nil { latestByCode[row.code] = row }
    }
    let usable = latestByCode.values.filter { row in
        !row.needsReview
            && row.notApplicableReason == nil
            && row.source != industryKpiSourceNotApplicable
            && !row.payload.needsReview
            && !row.payload.facts.isEmpty
    }
    guard !usable.isEmpty else { return nil }

    let metas = try await EdinetDocument.query(on: db)
        .filter(\.$id ~~ usable.map(\.docID))
        .all()
    var periodEndByDocID: [String: String] = [:]
    for meta in metas {
        if let id = meta.id, let end = meta.periodEnd { periodEndByDocID[id] = end }
    }

    let companies: [[String: Any]] = usable
        .sorted { $0.code < $1.code }
        .compactMap { row in
            let kpis = industryBenchmarkKpis(row.payload.facts)
            guard !kpis.isEmpty else { return nil }
            var item: [String: Any] = [
                "code": row.code,
                "doc_id": row.docID,
                "kpis": kpis,
                "warnings": row.payload.warnings,
            ]
            if let end = periodEndByDocID[row.docID] { item["fy_end"] = end }
            return item
        }
    guard !companies.isEmpty else { return nil }
    return [
        "schema_version": industryBenchmarkServeSchemaVersion,
        "industry_group": group,
        "companies": companies,
    ]
}

/// KPI キーごとに、連結 → 提出会社の順で 1 つ選ぶ。
func industryBenchmarkKpis(_ facts: [IndustryKpiFactValue]) -> [String: Any] {
    var out: [String: Any] = [:]
    for key in Set(facts.map(\.kpiKey)) {
        let fact =
            facts.first { $0.kpiKey == key && $0.scope == industryKpiScopeConsolidated }
            ?? facts.first { $0.kpiKey == key && $0.scope == industryKpiScopeFiler }
        guard let fact, fact.value.isFinite else { continue }
        out[key] = [
            "value": fact.value,
            "unit": fact.unit,
            "period_basis": fact.periodBasis,
            "scope": fact.scope,
        ]
    }
    return out
}
