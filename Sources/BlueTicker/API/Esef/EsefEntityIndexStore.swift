import Foundation

/// EU/ESEF 発行体マスターの試作（JP `MasterDataManager` + EDINET CSV の対）。
/// **本番の全件索引運用は ESAP（目安 2027-07）まで保留**（`docs/eu-esef-roadmap.md`）。
actor EsefEntityIndexStore {
    private var entities: [EsefEntity] = []
    private var byIdentifier: [String: EsefEntity] = [:]
    private(set) var isLoaded = false

    struct Snapshot: Codable, Sendable {
        var fetchedAt: String
        var entities: [EsefEntity]
    }

    func replaceAll(_ entities: [EsefEntity], fetchedAt: Date = Date()) {
        var unique: [String: EsefEntity] = [:]
        for e in entities {
            unique[e.identifier.uppercased()] = e
        }
        let list = Array(unique.values).sorted { $0.identifier < $1.identifier }
        self.entities = list
        self.byIdentifier = unique
        self.isLoaded = true
        _ = fetchedAt
    }

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let snap = try JSONDecoder().decode(Snapshot.self, from: data)
        replaceAll(snap.entities)
    }

    func save(to url: URL, fetchedAt: Date = Date()) throws {
        let formatter = ISO8601DateFormatter()
        let snap = Snapshot(fetchedAt: formatter.string(from: fetchedAt), entities: entities)
        let data = try JSONEncoder().encode(snap)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    func count() -> Int { entities.count }

    func entity(identifier: String) -> EsefEntity? {
        byIdentifier[identifier.uppercased()]
    }

    /// identifier 完全一致、または name の正規化部分一致 / 生部分一致。
    func search(_ query: String, limit: Int = 50) -> [EsefEntity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let qNorm = EsefSearchNormalization.normalize(trimmed)
        var results: [EsefEntity] = []
        for entity in entities {
            let idUpper = entity.identifier.uppercased()
            if idUpper == trimmed.uppercased()
                || entity.nameNormalized.contains(qNorm)
                || entity.name.localizedCaseInsensitiveContains(trimmed)
            {
                results.append(entity)
                if results.count >= limit { break }
            }
        }
        return results
    }
}
