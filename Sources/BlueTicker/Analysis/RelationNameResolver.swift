// 関係の相手の名前を上場企業の銘柄コードに結ぶ（すべて決定論。LLM は使わない）。
// 正規化は一般規則だけ（NFKC・大文字・法人格語・注記マーカー・「及びそのグループ会社」・空白と記号。
// 末尾の括弧書きは大株主の名義表記だけ外す）。
// 社名を直書きした辞書・別名表・例外は作らない。
// 解決の順（最初に一意に決まったところで止める）:
//   1. EDINET 提出者名の完全一致（上場 → name_exact）
//   2. 提出者名（英字）の完全一致（上場 → name_en_exact）
//   3. 上場会社の (連結子会社) 行の名称と一致し親が 1 社 → via_listed_parent（顧客・関連会社・親会社等の行だけ）
//      （1. で非上場の EDINET 提出者にだけ一致した名前もここを見る。決まらなければ edinet_unlisted）
//   4. 候補が 2 社以上 → ambiguous（needs_review）
//   5. どれにも当たらない → unresolved
// 自分自身（related_code == code）には結ばない。

import Crypto
import Foundation

public enum RelationNameNormalizer {
    /// 照合用の名前（`name_norm`）。空なら照合しない。
    /// 末尾の括弧書きを外すのは `stripsTrailingParenthesis` のときだけ（大株主の名義表記「（信託口）」
    /// 「（常任代理人 …）」）。それ以外では国名・地域名の括弧（「TOYOTA MOTOR (CHINA)」）を残し、
    /// 別の上場会社に結ばない。
    public static func normalize(_ name: String, stripsTrailingParenthesis: Bool = false) -> String {
        var s = name.precomposedStringWithCompatibilityMapping.uppercased()
        s = replacing(s, noteMarkerPatterns, with: " ")
        // 法人格語（と大株主の名義の括弧書き）は、どちらが外側でも外れるまで繰り返す。
        var previous = ""
        while previous != s {
            previous = s
            s = replacing(s, japaneseCorporateFormPatterns, with: "")
            s = trimmed(s)
            if stripsTrailingParenthesis { s = replacing(s, [trailingParenthesisPattern], with: "") }
            s = replacing(s, [formerNamePattern], with: "")
            s = replacing(s, [trailingGroupPhrasePattern, englishCorporateSuffixPattern], with: "")
            s = trimmed(s)
        }
        s = replacing(s, [separatorPattern], with: "")
        return s
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.、。")))
    }

    private static func replacing(
        _ s: String, _ patterns: [NSRegularExpression], with template: String
    ) -> String {
        var out = s
        for pattern in patterns {
            let ns = out as NSString
            out = pattern.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: ns.length), withTemplate: template)
        }
        return out
    }

    /// NFKC 後（「㈱」→「(株)」、全角括弧 → 半角）。
    private static let noteMarkerPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\(\s*注\s*[0-9]*\s*\)[\s0-9,、.・]*"#),
        try! NSRegularExpression(pattern: #"※\s*[0-9]*[\s,、]*"#),
        try! NSRegularExpression(pattern: #"\*\s*[0-9]+[\s,、]*"#),
    ]

    private static let japaneseCorporateFormPatterns: [NSRegularExpression] = [
        "株式会社", "有限会社", "合同会社", "合資会社", "合名会社", "相互会社",
        "一般社団法人", "公益社団法人", "一般財団法人", "公益財団法人",
        "独立行政法人", "国立研究開発法人", "地方独立行政法人",
        #"\(\s*(?:株|有|同|相|資|名|社|財|独)\s*\)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let trailingParenthesisPattern = try! NSRegularExpression(
        pattern: #"\s*\([^()]*\)\s*$"#)

    /// 末尾の旧社名の括弧書き（「（旧 東日本電信電話㈱）」）。どの kind でも外す。
    private static let formerNamePattern = try! NSRegularExpression(
        pattern: #"\s*\(\s*旧[^()]*(?:\([^()]*\)[^()]*)*\)\s*$"#)

    /// 末尾の「及びそのグループ会社」等（相手先をグループ単位で書いた顧客欄）。
    private static let trailingGroupPhrasePattern = try! NSRegularExpression(
        pattern: #"\s*(?:及び|および|並びに|ならびに|と)?\s*その(?:グループ会社|グループ各社|子会社|関係会社|連結子会社)(?:等)?\s*$"#)

    /// 末尾の英語の法人格語（連続していてもまとめて外す）。語の途中は外さない。
    private static let englishCorporateSuffixPattern = try! NSRegularExpression(
        pattern: #"(?:(?:(?<=[\s,.])|^)(?:CO|COMPANY|CORP|CORPORATION|INC|INCORPORATED|LTD|LIMITED|PLC|AG|SA|S\.A|GMBH|LLC|L\.L\.C|N\.V|B\.V|PTE|PTY|K\.K|KK)\.?[\s,]*)+$"#)

    /// 空白・中点・句読点・ハイフン類（長音「ー」は残す）。
    private static let separatorPattern = try! NSRegularExpression(
        pattern: #"[\s・･,，、。.．\-‐‑–—―−'’&＆]"#)
}

/// 正規化・解決規則の版。規則を変えたら上げる（全行の `resolver_key` がずれ、name_norm を作り直して解き直される）。
public let relationNameResolverVersion = "resolver-v3"

/// EDINET 提出者名の照合索引（正規化した名前 → 提出者）。
public struct RelationNameDirectory: Sendable {
    public struct Entry: Sendable, Equatable {
        public var edinetCode: String
        public var listedCode: String?
    }

    private(set) var byName: [String: [Entry]] = [:]
    private(set) var byEnglishName: [String: [Entry]] = [:]
    /// 名簿の中身（提出者コード・名前・英字名・上場コード）と正規化の版のハッシュ。
    /// 格納行の `resolver_key` と違えば、その行を解き直す（コードリストの更新・新規上場・上場廃止・社名変更）。
    public let fingerprint: String

    public init(filers: [EdinetFilerName]) {
        let canonical = filers
            .map { "\($0.edinetCode)\t\($0.name)\t\($0.nameEn)\t\($0.listedCode ?? "")" }
            .sorted()
            .joined(separator: "\n")
        fingerprint = SHA256.hash(data: Data((relationNameResolverVersion + "\n" + canonical).utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        for filer in filers {
            let entry = Entry(edinetCode: filer.edinetCode, listedCode: filer.listedCode)
            let ja = RelationNameNormalizer.normalize(filer.name)
            if !ja.isEmpty { byName[ja, default: []].append(entry) }
            let en = RelationNameNormalizer.normalize(filer.nameEn)
            if !en.isEmpty { byEnglishName[en, default: []].append(entry) }
        }
    }
}

/// 名前解決の結果。
public struct RelationNameResolution: Sendable, Equatable {
    public var relatedCode: String?
    public var resolution: String
    public var needsReview: Bool
}

public enum RelationNameResolver {
    /// 子会社索引（3.）を見る kind。取引の相手（顧客・関連会社）だけ。
    /// 連結子会社の行そのものは親経由に結ばない（上場子会社は 1. で結ぶ）。親会社等の行も結ばない
    /// （結ぶと祖父母会社が親会社になり、逆引きで孫会社が子会社に見える）。出資先・大株主も結ばない
    /// （子会社の株を持つ・子会社が株主であることは、親会社が出資先・大株主であることにならない。
    /// 例: 信託口の名義人である信託銀行を、その親会社の「大株主になっている会社」にしない）。
    public static func usesSubsidiaryIndex(kind: String) -> Bool {
        kind == relationKindCustomer || kind == relationKindAffiliate
    }

    /// - Parameters:
    ///   - subsidiaryParents: `name_norm` → その名前を (連結子会社) 行に載せている上場会社のコード集合。
    public static func resolve(
        nameNorm: String, kind: String, ownCode: String, directory: RelationNameDirectory,
        subsidiaryParents: (String) -> Set<String>
    ) -> RelationNameResolution {
        guard !nameNorm.isEmpty else { return unresolved }
        var unlistedEdinetMatch = false
        let jaEntries = directory.byName[nameNorm] ?? []
        if !jaEntries.isEmpty {
            switch listedCandidates(jaEntries, ownCode: ownCode) {
            case .one(let code):
                return RelationNameResolution(
                    relatedCode: code, resolution: relationResolutionNameExact, needsReview: false)
            case .many:
                return ambiguous
            case .selfOnly:
                return unresolved
            case .none:
                unlistedEdinetMatch = true
            }
        } else {
            let enEntries = directory.byEnglishName[nameNorm] ?? []
            switch listedCandidates(enEntries, ownCode: ownCode) {
            case .one(let code):
                return RelationNameResolution(
                    relatedCode: code, resolution: relationResolutionNameEnExact, needsReview: false)
            case .many:
                return ambiguous
            case .selfOnly:
                return unresolved
            case .none:
                unlistedEdinetMatch = !enEntries.isEmpty
            }
        }
        if usesSubsidiaryIndex(kind: kind) {
            let parents = subsidiaryParents(nameNorm).subtracting([ownCode])
            if parents.count == 1, let parent = parents.first {
                return RelationNameResolution(
                    relatedCode: parent, resolution: relationResolutionViaListedParent, needsReview: false)
            }
            if parents.count >= 2 { return ambiguous }
        }
        if unlistedEdinetMatch {
            return RelationNameResolution(
                relatedCode: nil, resolution: relationResolutionEdinetUnlisted, needsReview: false)
        }
        return unresolved
    }

    private enum ListedCandidates {
        case one(String)
        case many
        /// 上場の候補が自分自身だけ。
        case selfOnly
        case none
    }

    private static func listedCandidates(_ entries: [RelationNameDirectory.Entry], ownCode: String)
        -> ListedCandidates
    {
        let listed = Set(entries.compactMap(\.listedCode))
        let others = listed.subtracting([ownCode])
        if others.count == 1, let code = others.first { return .one(code) }
        if others.count >= 2 { return .many }
        return listed.isEmpty ? .none : .selfOnly
    }

    public static let unresolved = RelationNameResolution(
        relatedCode: nil, resolution: relationResolutionUnresolved, needsReview: false)
    public static let ambiguous = RelationNameResolution(
        relatedCode: nil, resolution: relationResolutionAmbiguous, needsReview: true)
}
