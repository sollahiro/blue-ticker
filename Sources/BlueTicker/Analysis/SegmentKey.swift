// segment-v3 の行キー。名前空間 URI（日付・タクソノミ版を含む）は使わない。
// "<EDINET code>:<ext|std|txt>:<local name>"
// ext = 提出者拡張 member（接頭辞 jpcrp030000-asr_Exxxxx-000）
// std = 標準 member（jpcrp_cor / jpigp_cor / jppfs_cor）
// txt = XBRL タグの無い行（本文・Jev。local name は正規化した日本語ラベル）

import Foundation

public enum SegmentKeyKind: String, Sendable, Equatable {
    case ext
    case std
    case txt
}

public struct SegmentKey: Hashable, Sendable {
    public var edinetCode: String
    public var kind: SegmentKeyKind
    public var localName: String

    public init(edinetCode: String, kind: SegmentKeyKind, localName: String) {
        self.edinetCode = edinetCode
        self.kind = kind
        self.localName = localName
    }

    public var description: String {
        "\(edinetCode):\(kind.rawValue):\(localName)"
    }

    public static func kind(forPrefix prefix: String?) -> SegmentKeyKind {
        guard let prefix, !prefix.isEmpty else { return .txt }
        let head = prefix.split(separator: ":").first.map(String.init) ?? prefix
        if head.hasPrefix("jpcrp_cor") || head.hasPrefix("jpigp_cor") || head.hasPrefix("jppfs_cor") {
            return .std
        }
        return .ext
    }

    public static func make(
        edinetCode: String, localName: String, prefix: String?
    ) -> SegmentKey {
        SegmentKey(
            edinetCode: edinetCode, kind: kind(forPrefix: prefix), localName: localName)
    }

    public static func text(edinetCode: String, label: String) -> SegmentKey {
        SegmentKey(
            edinetCode: edinetCode, kind: .txt, localName: SegmentLabelMatch.normalizeForKey(label))
    }

    public static func parse(_ raw: String) -> SegmentKey? {
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = SegmentKeyKind(rawValue: String(parts[1])) else {
            return nil
        }
        let code = String(parts[0])
        let local = String(parts[2])
        guard !code.isEmpty, !local.isEmpty else { return nil }
        return SegmentKey(edinetCode: code, kind: kind, localName: local)
    }
}

enum SegmentLabelMatch {
    static func nfkc(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping
    }

    static func compact(_ string: String) -> String {
        nfkc(string)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// 末尾の「事業」だけ落とす。部門・関連は落とさない（ANA 航空事業 vs 航空関連事業）。
    static func stripTrailingBusiness(_ string: String) -> String {
        let compact = compact(string)
        guard compact.hasSuffix("事業"), compact.count > 2 else { return compact }
        if compact.hasSuffix("関連事業") || compact.hasSuffix("部門事業") { return compact }
        return String(compact.dropLast(2))
    }

    static func normalizeForCompare(_ string: String) -> String {
        stripTrailingBusiness(string)
    }

    static func normalizeForKey(_ string: String) -> String {
        compact(string)
    }

    static func childOfParentSlash(_ child: String, parent: String) -> Bool {
        let compactedChild = compact(child)
        let compactedParent = compact(parent)
        guard !compactedParent.isEmpty, compactedChild != compactedParent else { return false }
        for separator in ["/", "／"] {
            if compactedChild.hasPrefix(compactedParent + separator) { return true }
        }
        return false
    }

    static func matches(_ overviewLabel: String, segmentLabel: String) -> Bool {
        let left = normalizeForCompare(overviewLabel)
        let right = normalizeForCompare(segmentLabel)
        if left == right { return true }
        if compact(overviewLabel) == compact(segmentLabel) { return true }
        if childOfParentSlash(overviewLabel, parent: segmentLabel) { return true }
        if childOfParentSlash(segmentLabel, parent: overviewLabel) { return true }
        return false
    }

    static func isCombinedOtherAndCorporate(_ label: String) -> Bool {
        let compact = compact(label)
        let hasOther = compact.contains("その他")
        let hasCorporate = compact.contains("全社") || compact.contains("調整") || compact.contains("消去")
        return hasOther && hasCorporate
    }

    static func isOverviewCorporateShared(_ label: String) -> Bool {
        let compact = compact(label)
        if isCombinedOtherAndCorporate(label) { return false }
        return compact == "全社" || compact == "全社(共通)" || compact == "全社（共通）"
            || compact == "全社共通"
    }
}
