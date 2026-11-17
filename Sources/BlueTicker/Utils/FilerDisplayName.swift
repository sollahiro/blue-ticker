import Foundation

/// EDINET 提出者名（コードリスト CSV の「提出者名」/ API の `filerName`）の表示用整形。
///
/// 提出者名は常用外の漢字や全角英数を含む商号に、末尾の括弧で実際の商号を補う。
/// 例: 「パーク二四株式会社（定款上の商号　パーク２４株式会社）」→「パーク24株式会社」。
/// 括弧内を使うのは次の 2 形だけで、それ以外（社名の途中の括弧など）は触らない。
/// - 末尾の括弧が「定款上の商号」「商号」「称号」で始まる（ラベルを除いた商号を NFKC 正規化して使う）。
/// - 末尾の括弧が英数字だけ（外国法人の英字名。例: 「テックポイント・インク（Ｔｅｃｈｐｏｉｎｔ，Ｉｎｃ．）」）。
///
/// 保存データは書き換えず、読む側で毎回適用する。コードリスト差し替えや再取り込みの後も同じ結果になり、
/// 銘柄ごとの上書き表を持たないので、新しく括弧付きになった社名にも同じ規則が効く。
/// Feed RSS Worker の `displayFilerName`（workers/feed-rss/src/query.js）と同じ結果を返すこと
/// （fixture: workers/feed-rss/test-fixtures/feed-parity.json の `filerDisplayNames`）。
func displayFilerName(_ raw: String) -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.hasSuffix("）"), let open = name.lastIndex(of: "（") else { return name }
    let outer = name[..<open]
    let inner = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
    guard !outer.isEmpty else { return name }

    var candidate: String?
    for label in filerNameBracketLabels where inner.hasPrefix(label) {
        candidate = nfkc(String(inner.dropFirst(label.count)))
            .trimmingCharacters(in: .whitespaces)
        break
    }
    if candidate == nil {
        let folded = nfkc(inner).trimmingCharacters(in: .whitespaces)
        if !folded.isEmpty, folded.unicodeScalars.allSatisfy(isLatinNameScalar) {
            // 全角コンマは NFKC で "," になりスペースが落ちるため、直後に 1 つ補う。
            candidate = folded.replacingOccurrences(
                of: ",(?=[^ ])", with: ", ", options: .regularExpression)
        }
    }
    guard var result = candidate, !result.isEmpty else { return name }
    // 「株式会社　ＪＭＳ」のように法人格と社名の間に空白が入る場合は詰める。
    for form in ["株式会社", "有限会社", "合同会社"] {
        result = result
            .replacingOccurrences(of: "\(form) ", with: form)
            .replacingOccurrences(of: " \(form)", with: form)
    }
    return result.isEmpty ? name : result
}

private let filerNameBracketLabels = ["定款上の商号", "商号", "称号"]

private func nfkc(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping
}

private func isLatinNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true  // 0-9 A-Z a-z
    case 0x20, 0x26, 0x27, 0x2C, 0x2D, 0x2E: return true  // 空白 & ' , - .
    default: return false
    }
}
