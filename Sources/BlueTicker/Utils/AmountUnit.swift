// 金額・数量の単位の共通部品。単位語の表と XBRL `unitRef` の読み替えをここだけに置く。
//
// - 表・本文の単位語（「（単位：百万円）」「89,058百万円」）は `captionScale` で
//   開示通貨と基本単位への倍率に直す。どの語を探すか・既定値・優先順は呼び出し側の方針。
// - XBRL fact は `unitRef`（JPY / USD / JPYPerShares / shares / pure）から通貨と単位コードを読む。
//   桁は fact 自体が基本単位なので変えない。
// - LLM が申告する単位（yen / thousand_yen / million_yen）も同じ表で円倍率にする。
//
// 判定できないものは nil を返し、推測しない（文脈が要る判定は Jev に渡す）。

import Foundation

public enum AmountUnit {
    /// 公開契約の単位コード（応答の `units` マップの値）。金額は通貨に依らず `currency_amount`、
    /// 通貨は応答の `currency` が持つ。
    public enum Code: String, Sendable, CaseIterable {
        case currencyAmount = "currency_amount"
        case currencyPerShare = "currency_per_share"
        case shares
        case persons
        case percent
        case percentagePoints = "percentage_points"
        case times
        case days
    }

    /// 単位語1つ。`multiplier` は開示通貨の基本単位（円・ドル・ユーロ）への倍率。
    struct CaptionScale: Equatable, Sendable {
        var token: String
        var currency: String
        var multiplier: Double
    }

    public static let jpy = "JPY"

    /// 接頭辞付きの単位語。部分一致で探すときはこの順に当てる（外貨 → 十億円 → 百万円 → 千円 → 億円 → 兆円。
    /// 十億円を億円より先に当てる。兆円は本文の「1兆円」に当たりやすいので最後）。素の「円」は部分一致では使わない（「円/株」「円安」に当たる）。
    static let prefixedCaptionScales: [CaptionScale] = [
        CaptionScale(token: "百万ユーロ", currency: "EUR", multiplier: 1_000_000),
        CaptionScale(token: "百万米ドル", currency: "USD", multiplier: 1_000_000),
        CaptionScale(token: "千米ドル", currency: "USD", multiplier: 1_000),
        CaptionScale(token: "千ユーロ", currency: "EUR", multiplier: 1_000),
        CaptionScale(token: "十億円", currency: jpy, multiplier: 1_000_000_000),
        CaptionScale(token: "百万円", currency: jpy, multiplier: 1_000_000),
        CaptionScale(token: "千円", currency: jpy, multiplier: 1_000),
        CaptionScale(token: "億円", currency: jpy, multiplier: 100_000_000),
        CaptionScale(token: "兆円", currency: jpy, multiplier: 1_000_000_000_000),
    ]

    static let plainYen = CaptionScale(token: "円", currency: jpy, multiplier: 1)

    /// `prefixedCaptionScales` の語だけ（部分一致順）。
    static let prefixedCaptionTokens: [String] = prefixedCaptionScales.map(\.token)

    /// 単位語そのもの（完全一致）。「円」も含む。
    static func captionScale(forToken token: String) -> CaptionScale? {
        if token == plainYen.token { return plainYen }
        return prefixedCaptionScales.first { $0.token == token }
    }

    /// 単位語（完全一致）の円倍率。外貨と未知の語は nil。
    static func yenMultiplier(forToken token: String) -> Double? {
        guard let scale = captionScale(forToken: token), scale.currency == jpy else { return nil }
        return scale.multiplier
    }

    /// 単位語を含む文字列（`parseUnitCaption` の捕捉など）の円倍率。十億円を億円より先に見る。
    /// 素の「円」は文字列全体が「円」のときだけ。外貨と未知の語は nil。
    static func yenMultiplier(containedIn text: String) -> Double? {
        if text == plainYen.token { return 1 }
        return yenScale(containedIn: text)?.multiplier
    }

    /// 文字列に含まれる円建ての接頭辞付き単位語のうち、倍率が最大のもの（十億円を含めば億円とは数えない）。
    static func yenScale(containedIn text: String) -> CaptionScale? {
        prefixedCaptionScales
            .filter { $0.currency == jpy && containsToken($0, in: text) }
            .max { $0.multiplier < $1.multiplier }
    }

    /// 文字列の中で最も後ろに現れる円建ての接頭辞付き単位語（表の直前の見出しで、表に最も近い単位）。
    static func lastYenScale(in text: String, among tokens: Set<String>? = nil) -> CaptionScale? {
        var best: (index: String.Index, scale: CaptionScale)?
        for scale in prefixedCaptionScales where scale.currency == jpy {
            if let tokens, !tokens.contains(scale.token) { continue }
            var searchEnd = text.endIndex
            while let r = text.range(of: scale.token, options: .backwards, range: text.startIndex..<searchEnd) {
                if scale.token == "億円", r.lowerBound > text.startIndex,
                    text[text.index(before: r.lowerBound)] == "十"
                {
                    searchEnd = r.lowerBound
                    continue
                }
                if best == nil || r.lowerBound > best!.index { best = (r.lowerBound, scale) }
                break
            }
        }
        return best?.scale
    }

    /// 「十億円」の中の「億円」は億円として数えない。
    private static func containsToken(_ scale: CaptionScale, in text: String) -> Bool {
        guard scale.token == "億円" else { return text.contains(scale.token) }
        return text.replacingOccurrences(of: "十億円", with: "").contains("億円")
    }

    // MARK: - LLM の申告単位

    /// LLM 正規化器が申告する `unit` の円倍率。未知は nil。
    static let llmDeclaredYenMultipliers: [String: Double] = [
        "yen": 1,
        "thousand_yen": 1_000,
        "million_yen": 1_000_000,
    ]

    /// 表合計と連結売上（円）の比が、円 / 千円 / 百万円のうちちょうど1つで分母帯に入るときだけ、その申告単位を返す。
    /// 複数・どれでもなければ `other`（推測しない）。
    static func inferredLlmDeclaredUnit(
        tableTotal: Double?,
        consolidatedSales: Double?,
        tolerance: ClosedRange<Double>
    ) -> String {
        guard let total = tableTotal, total != 0,
            let sales = consolidatedSales, sales != 0
        else { return "other" }
        let hits = ["yen", "thousand_yen", "million_yen"].filter { unit in
            tolerance.contains(abs(total * llmDeclaredYenMultipliers[unit]! / sales))
        }
        return hits.count == 1 ? hits[0] : "other"
    }

    // MARK: - XBRL unitRef

    /// `unitRef` が1株当たり金額か（`JPYPerShares` / `USDPerShares` など）。
    public static func isPerShare(unitRef: String?) -> Bool {
        guard let unitRef else { return false }
        return unitRef.hasSuffix("PerShares") || unitRef.hasSuffix("PerShare")
    }

    /// `unitRef` の通貨（ISO 4217）。`JPY` / `USD` / `JPYPerShares` など通貨建てだけ。株数・pure は nil。
    /// HTML 表から組んだ行の `yen` も JPY として読む。
    public static func currency(unitRef: String?) -> String? {
        guard var unit = unitRef?.trimmingCharacters(in: .whitespaces), !unit.isEmpty else { return nil }
        if unit == "yen" { return jpy }
        for suffix in ["PerShares", "PerShare"] where unit.hasSuffix(suffix) {
            unit = String(unit.dropLast(suffix.count))
        }
        guard unit.count == 3, unit.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return unit
    }

    /// `unitRef` の単位コード。pure（比率・人数など意味がタグで決まる）は nil。
    public static func code(unitRef: String?) -> Code? {
        guard let unitRef else { return nil }
        if unitRef == "shares" || unitRef == "Shares" { return .shares }
        if unitRef == "yen_per_share" { return .currencyPerShare }
        guard currency(unitRef: unitRef) != nil else { return nil }
        return isPerShare(unitRef: unitRef) ? .currencyPerShare : .currencyAmount
    }
}
