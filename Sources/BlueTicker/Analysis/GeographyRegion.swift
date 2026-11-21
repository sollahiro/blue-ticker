// 地域別売上の地域ラベルを、年をまたいで比べられるコードへ寄せる。
// 決定論の辞書だけ（Jev も LLM も使わない）。辞書に無いラベルは region を nil にして、
// 開示のラベルをそのまま返す。複合ラベル（「アジア・オセアニア」など）は成分に分けて
// 成分コードを正規順に `+` でつなぐ。

import Foundation

public enum GeographyRegion {
    /// 成分の正規順。複合コードの並びと表示順に使う。
    public static let order: [String] = [
        "japan", "united_states", "north_america", "americas", "latin_america",
        "europe", "asia", "china", "oceania", "middle_east", "africa", "overseas", "other",
    ]

    /// 粗い区分への持ち上げ。段 1 は国・大国を地域へ（米国→北米、中国→アジア）、
    /// 段 2 は北米・中南米も米州へ。段 0 は何もしない。表に無いコードはそのまま。
    static let liftTables: [[String: String]] = [
        [:],
        ["united_states": "north_america", "china": "asia"],
        [
            "united_states": "americas", "north_america": "americas",
            "latin_america": "americas", "china": "asia",
        ],
    ]

    /// 先に当たったものを採る。長い語・具体的な語を前に置く。
    private static let dictionary: [(code: String, words: [String])] = [
        ("united_states", ["アメリカ合衆国", "米国", "合衆国", "USA"]),
        ("latin_america", ["中南米", "ラテンアメリカ", "南米", "中米"]),
        ("north_america", ["北米", "北アメリカ", "カナダ"]),
        ("americas", ["米州", "米洲", "米大陸", "アメリカ", "米"]),
        ("europe", ["欧州", "ヨーロッパ", "EMEA", "欧"]),
        ("china", ["中国", "中華人民共和国"]),
        ("asia", ["アジア"]),
        ("oceania", ["オセアニア", "豪州", "大洋州", "オーストラリア"]),
        ("middle_east", ["中東"]),
        ("africa", ["アフリカ"]),
        ("japan", ["日本", "国内", "本邦"]),
        ("overseas", ["海外", "国外", "外国", "在外"]),
        ("other", ["その他", "そのほか", "他"]),
    ]

    private static let separators = ["・", "･", "／", "/", "、", "，", ",", "＆", "&", "及び", "および"]

    public struct Normalized: Equatable, Sendable {
        /// 成分コードを正規順に `+` でつないだもの。辞書に無い成分が 1 つでもあれば nil。
        public var region: String?
        public var components: [String]
    }

    public static func normalize(label: String) -> Normalized {
        var text = label
        // 脚注・括弧書き（「（注）2」「（中国を除く）」「（うち米国）」）は成分に数えない。
        for pattern in [#"[（(][^）)]*[）)]"#, #"[※＊*]\s*[0-9０-９]*"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
        guard !text.isEmpty else { return Normalized(region: nil, components: []) }
        var tokens = [text]
        for separator in separators {
            tokens = tokens.flatMap { $0.components(separatedBy: separator) }
        }
        tokens = tokens.filter { !$0.isEmpty }
        var codes: [String] = []
        for token in tokens {
            // 「欧州他」「アジア他」は成分 + その他。
            if token.count >= 2, token.hasSuffix("他"), token != "その他",
                let head = code(of: String(token.dropLast()))
            {
                codes.append(head)
                codes.append("other")
                continue
            }
            guard let found = code(of: token) else {
                return Normalized(region: nil, components: [])
            }
            codes.append(found)
        }
        let unique = Array(Set(codes)).sorted { rank($0) < rank($1) }
        return Normalized(region: unique.joined(separator: "+"), components: unique)
    }

    private static func code(of token: String) -> String? {
        // 「その他の地域」「その他海外」は other。「その他の米州」「その他アジア」のように、
        // 「その他」のあとに地域名が続くときは、その地域（米国を除いた米州、など）として扱う。
        if token.hasPrefix("その他") {
            var rest = String(token.dropFirst("その他".count))
            if rest.hasPrefix("の") { rest.removeFirst() }
            let regional = Set(["japan", "overseas", "other"])
            if !rest.isEmpty,
                let entry = dictionary.first(where: { entry in
                    !regional.contains(entry.code) && entry.words.contains(where: { rest.contains($0) })
                })
            {
                return entry.code
            }
            return "other"
        }
        if token == "他" || token == "そのほか" { return "other" }
        for entry in dictionary where entry.words.contains(where: { token.contains($0) }) {
            return entry.code
        }
        return nil
    }

    private static func rank(_ code: String) -> Int {
        order.firstIndex(of: code) ?? order.count
    }

    /// 成分を `level` 段の持ち上げ表で粗い区分へ寄せる。
    static func lift(_ code: String, level: Int) -> String {
        let table = liftTables[min(max(level, 0), liftTables.count - 1)]
        return table[code] ?? code
    }
}
