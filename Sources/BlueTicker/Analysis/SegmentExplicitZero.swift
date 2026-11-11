// 設備投資セルの 0 と欠測の区別。0 は明示証拠があるときだけ。
// ホワイトリスト: (a) 当該カテゴリの 0百万円/0千円 (b) 設備投資額セルが －/―
// (c) セグメント見出し直下の無修飾「設備投資を実施しておりません」
// それ以外（重要な…ありません、特記すべき、僅少、沈黙、売却・撤去の該当事項）は none。

import Foundation

enum SegmentExplicitZero {
    static let dashTokens: Set<String> = ["－", "-", "—", "―"]

    static func isDashCell(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: " ", with: "")
        return dashTokens.contains(trimmed)
    }

    /// 「0百万円」等、当該カテゴリに付いた明示 0。
    static func isExplicitZeroAmountText(_ text: String) -> Bool {
        let compact = SegmentLabelMatch.compact(text)
        let patterns = [
            "0百万円", "0千円", "0円", "0億", "０百万円", "０千円", "０円",
        ]
        return patterns.contains { compact.contains($0) }
    }

    /// 見出し直下の無修飾「設備投資を実施しておりません」。重要な／特記すべき／僅少は除外。
    static func isUnqualifiedNoCapex(underHeading heading: String, in prose: String) -> Bool {
        let headingIndex = prose.range(of: heading)
        let window: String
        if let headingIndex {
            let start = headingIndex.upperBound
            let end = prose.index(start, offsetBy: min(400, prose.distance(from: start, to: prose.endIndex)))
            window = String(prose[start..<end])
        } else {
            window = prose
        }
        let compact = SegmentLabelMatch.compact(window)
        let qualified = compact.contains("重要な") || compact.contains("特段")
            || compact.contains("特記すべき") || compact.contains("僅少")
        guard !qualified else { return false }
        return compact.contains("設備投資を実施しておりません")
            || compact.contains("投資を実施しておりません")
    }

    static func shouldEmitZero(
        factValue: Double?,
        htmlDash: Bool,
        amountText: String?,
        heading: String?,
        prose: String?
    ) -> Bool {
        if htmlDash { return true }
        if let amountText, isExplicitZeroAmountText(amountText) { return true }
        if let heading, let prose, isUnqualifiedNoCapex(underHeading: heading, in: prose) {
            return true
        }
        if let factValue, factValue == 0 {
            return true
        }
        return false
    }
}
