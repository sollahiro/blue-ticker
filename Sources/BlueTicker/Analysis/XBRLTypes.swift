// XBRL 抽出結果の型定義
// Python の XbrlFact TypedDict と XbrlFactIndex の Swift 対応

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
}

typealias XbrlTagElements = [String: [String: Double]]
typealias XbrlFactIndex = [String: [String: XbrlFact]]
