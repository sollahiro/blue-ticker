// XBRL 抽出結果の型定義

struct XbrlFact {
    var tag: String
    var contextRef: String
    var value: Double
    var consolidation: String
    var unitRef: String?
    var decimals: String?
    var role: String?
    var section: String?
    var roles: [String]?
    var sections: [String]?
    var label: String?
    var sourceFile: String?
    /// role URI ごとの presentation linkbase 表示順（0始まり、role 内の深さ優先走査順）。
    /// role がこのタグを含まない場合は該当キー無し。
    var orderByRole: [String: Int]?
}

typealias XbrlTagElements = [String: [String: Double]]
typealias XbrlFactIndex = [String: [String: XbrlFact]]
