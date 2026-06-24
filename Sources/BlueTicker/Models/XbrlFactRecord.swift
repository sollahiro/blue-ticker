import Foundation

/// Stage 3（XBRL 数値 RAW）の格納用レコード。内部型 `XbrlFact` の Codable 版で、
/// tag・contextRef は格納時のマップキー（[tag: [contextRef: XbrlFactRecord]]）になるため持たない。
/// パース結果を欠落なく保持する（RAW スキーマ）。公開契約ではなくサーバー内部スキーマ。
public struct XbrlFactRecord: Codable, Sendable, Equatable {
    public let value: Double
    public let consolidation: String
    public let unitRef: String?
    public let decimals: String?
    public let role: String?
    public let section: String?
    public let roles: [String]?
    public let sections: [String]?
    public let label: String?
    public let sourceFile: String?

    public init(
        value: Double,
        consolidation: String,
        unitRef: String? = nil,
        decimals: String? = nil,
        role: String? = nil,
        section: String? = nil,
        roles: [String]? = nil,
        sections: [String]? = nil,
        label: String? = nil,
        sourceFile: String? = nil
    ) {
        self.value = value
        self.consolidation = consolidation
        self.unitRef = unitRef
        self.decimals = decimals
        self.role = role
        self.section = section
        self.roles = roles
        self.sections = sections
        self.label = label
        self.sourceFile = sourceFile
    }
}

/// 書類1件分の数値 fact インデックス（tag → contextRef → fact）。JSONB 1 セルに格納する。
public typealias XbrlFactIndexPayload = [String: [String: XbrlFactRecord]]
