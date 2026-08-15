import Foundation

/// Region `EU` · Source `ESEF` の発行体（filings.xbrl.org entity）。
/// JP の証券コードに相当する主キーは `identifier`（多くは LEI）。
struct EsefEntity: Codable, Equatable, Sendable, Hashable {
    /// XBRL identifier（LEI または各国の会社識別子）
    var identifier: String
    var name: String

    var nameNormalized: String {
        EsefSearchNormalization.normalize(name)
    }
}

/// ESEF 書類の参照（検索ヒットに添付するとき用）。
struct EsefFilingRef: Codable, Equatable, Sendable {
    var fxoId: String
    var country: String
    var periodEnd: String
    var jsonURL: String?
    var packageURL: String?
    var reportURL: String?
}

/// Meta Search の1ヒット。JP `StockSearchResult` の EU/ESEF 対。
/// 配線前のため REST/MCP 契約には載せない。
struct EsefSearchResult: Codable, Equatable, Sendable {
    var identifier: String
    var name: String
    /// 常に `EU`（Region 軸）
    var region: String
    /// 常に `ESEF`（Source 軸）。UKSEF/UAIFRS も索引上は ESEF 系として扱う。
    var source: String
    /// クエリが `fxo_id` のときに付く
    var matchedFiling: EsefFilingRef?

    init(
        identifier: String,
        name: String,
        region: String = "EU",
        source: String = "ESEF",
        matchedFiling: EsefFilingRef? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.region = region
        self.source = source
        self.matchedFiling = matchedFiling
    }

    init(entity: EsefEntity, matchedFiling: EsefFilingRef? = nil) {
        self.init(
            identifier: entity.identifier,
            name: entity.name,
            matchedFiling: matchedFiling
        )
    }
}

enum EsefSearchNormalization {
    /// JP `MasterDataManager.normalizeForSearch` に近い正規化（欧米向けに中点除去は省略可だが統一）。
    static func normalize(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping.uppercased()
        return nfkc
            .replacingOccurrences(of: "・", with: "")
            .replacingOccurrences(of: "･", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    /// LEI は20桁英数。各国ローカル ID も identifier として使うため、厳密 LEI 以外も exact 照合する。
    static func looksLikeIdentifier(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard q.count >= 6, q.count <= 20 else { return false }
        return q.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    static func looksLikeFxoId(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard q.count > 20 else { return false }
        return q.contains("-ESEF-")
            || q.contains("-UKSEF-")
            || q.contains("-UAIFRS-")
            || q.contains("-ESEF")
    }
}
