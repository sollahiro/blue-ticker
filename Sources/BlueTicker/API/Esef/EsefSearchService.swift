import Foundation

enum EsefSearchError: Error, Equatable {
    case emptyIndex
}

/// EU/ESEF Meta Search（JP `CompanyInfoService.searchCompanies` の対）。
/// Icon 保留。REST preview は `GET /v1/eu/companies`（skills / MCP 未掲載）。
///
/// **entity index（`refreshIndex`）は ESAP 一般公開（目安 2027-07）まで本番運用しない。**
/// 当面の正は LEI / fxo_id / 名称の live 完全一致（`docs/eu-esef-roadmap.md`）。
actor EsefSearchService {
    private let client: EsefFilingsAPIClient
    private let index: EsefEntityIndexStore
    private let indexURL: URL

    init(
        client: EsefFilingsAPIClient = EsefFilingsAPIClient(),
        index: EsefEntityIndexStore = EsefEntityIndexStore(),
        cacheDir: URL = URL(fileURLWithPath: "tmp_cache/eu/esef", isDirectory: true)
    ) {
        self.client = client
        self.index = index
        self.indexURL = cacheDir.appendingPathComponent("entity_index.json")
    }

    /// filings.xbrl.org から entity 全件を引き、ローカル索引を更新する。
    /// **ESAP 公開まで本番ジョブ化しない**（テスト・将来用。roadmap 参照）。
    @discardableResult
    func refreshIndex(pageSize: Int = 200) async throws -> Int {
        let entities = try await client.fetchAllEntities(pageSize: pageSize)
        await index.replaceAll(entities)
        try await index.save(to: indexURL)
        return entities.count
    }

    /// ディスク索引を読む（無ければ何もしない）。
    func loadIndexIfPresent() async {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        try? await index.load(from: indexURL)
    }

    /// テスト用にメモリ索引だけ差し替える。
    func seedIndex(_ entities: [EsefEntity]) async {
        await index.replaceAll(entities)
    }

    func indexCount() async -> Int {
        await index.count()
    }

    /// 銘柄・書類の検索。
    /// - LEI / identifier: 索引 → 無ければ live `filter[identifier]`
    /// - fxo_id: live filings + include=entity
    /// - 名前: 索引の部分一致（要 `refreshIndex` / seed）
    func search(_ query: String, limit: Int = 50) async throws -> [EsefSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        if EsefSearchNormalization.looksLikeFxoId(trimmed) {
            if let hit = try await client.fetchFiling(fxoId: trimmed) {
                if let entity = hit.entity {
                    return [EsefSearchResult(entity: entity, matchedFiling: hit.filing)]
                }
                // entity 欠落時は fxo 先頭を identifier 候補に
                let leiGuess = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
                return [
                    EsefSearchResult(
                        identifier: leiGuess,
                        name: "",
                        matchedFiling: hit.filing
                    )
                ]
            }
            return []
        }

        await loadIndexIfPresent()

        if EsefSearchNormalization.looksLikeIdentifier(trimmed) {
            if let local = await index.entity(identifier: trimmed) {
                return [EsefSearchResult(entity: local)]
            }
            if let remote = try await client.fetchEntity(identifier: trimmed.uppercased()) {
                return [EsefSearchResult(entity: remote)]
            }
            // 大文字化前も試す（すでに upper）
            if let remote = try await client.fetchEntity(identifier: trimmed) {
                return [EsefSearchResult(entity: remote)]
            }
        }

        // 完全一致 name（索引が空でも live で当てる）
        if await index.count() == 0 {
            if let remote = try await client.fetchEntity(exactName: trimmed) {
                return [EsefSearchResult(entity: remote)]
            }
            if let remote = try await client.fetchEntity(exactName: trimmed.uppercased()) {
                return [EsefSearchResult(entity: remote)]
            }
        }

        let localHits = await index.search(trimmed, limit: limit)
        if localHits.isEmpty {
            let indexed = await index.count()
            if indexed == 0 {
                throw EsefSearchError.emptyIndex
            }
        }
        return localHits.map { EsefSearchResult(entity: $0) }
    }
}
