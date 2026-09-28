// LLM 内訳正規化器が共有する金額スケール。
// 有報 HTML 表は百万円表示が最多だが、千円・円の表もある。連結売上の比較分母は円。
// 表ヘッダー／キャプションの「単位：…」をコードで読み、LLM の申告 unit はヘッダーが
// 取れないときのフォールバックにする。ヘッダーと LLM 申告が食い違うときは分母比で
// 候補を選ぶ（LLM が千円表を百万円へ直して申告したのにヘッダー ×1000 を再適用すると
// 1000 倍小さくなる）。LLM が unit=million_yen と申告しつつ行金額を既に円で返すと、
// 従来の一律 ×1e6 が分母を約 1e12（百万円表示比）に膨らませる。

import Foundation

enum BreakdownLLMAmountScale {
    /// 千円表示を円へ直す倍率。
    static let thousandYen: Double = 1_000

    /// ヘッダー単位が LLM 申告と食い違うときに立てる。公開 payload 形は変えない（warnings 配列の値）。
    static let headerLlmMismatchWarning = "unit_header_llm_mismatch"

    struct Resolution: Equatable {
        /// 行金額に掛ける円換算倍率。単位が一つも決まらないときは 1（推測スケールは掛けない）。
        var multiplier: Double
        /// ヘッダーにも LLM にも信頼できる単位が無い。格納してよいが trusted ではない。
        var unresolved: Bool
        /// ヘッダー単位と LLM 申告がどちらも決まり、倍率が食い違う。
        /// 分母が取れるときは候補から選ぶ。取れない／曖昧ならヘッダー倍率。
        var headerLlmMismatch: Bool
        /// `parseUnitCaption` が返した語（百万円 / 千円 / 円 等）。無ければ nil。
        var headerToken: String?
        /// ヘッダー語が対象表自身ではなく、候補表からの一意の兄弟借り。
        /// 食い違い時の `needs_review` ゲート（#447 公開面が needs_review 行を隠すため）。
        /// 直前表より後の `detectUnitFromPreceding` は対象表自身として扱う。
        var headerBorrowed: Bool
    }

    /// 対象表自身の単位語（キャプション行・markdown・見出し・スタブ引き継ぎ・
    /// 直前表より後に付いた preceding caption）。
    static func ownHeaderUnitToken(from table: BreakdownTable) -> String? {
        headerUnitToken(from: table)
    }

    struct HeaderUnitLookup: Equatable {
        var token: String?
        var borrowed: Bool
    }

    /// 申告 unit と行金額・連結売上（円）から、円へ直す倍率を決める。
    /// `million_yen` でも行金額が既に円スケールなら 1。未知 unit は unresolved。
    /// ヘッダー単位があるときは `resolve` を使う。
    static func yenMultiplier(
        declaredUnit: String,
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> (multiplier: Double, unresolved: Bool) {
        let resolved = resolve(
            headerToken: nil,
            declaredUnit: declaredUnit,
            rawAmounts: rawAmounts,
            consolidatedSales: consolidatedSales
        )
        return (resolved.multiplier, resolved.unresolved)
    }

    /// 表ヘッダーの単位を優先し、無ければ LLM 申告。食い違い時は
    /// {ヘッダー倍率, LLM 申告倍率, ×1} のうち分母比が 0.90...1.10 に入り 1 に最も近いものを選ぶ。
    /// 分母が無い・許容内に入らない・同距離ならヘッダー倍率。mismatch フラグは立てる。
    /// どちらからも円倍率が決まらなければ fail closed（unresolved、倍率 1）。
    static func resolve(
        headerToken: String?,
        declaredUnit: String,
        rawAmounts: [Double],
        consolidatedSales: Double?,
        headerBorrowed: Bool = false
    ) -> Resolution {
        let declared = declaredScale(
            declaredUnit: declaredUnit,
            rawAmounts: rawAmounts,
            consolidatedSales: consolidatedSales
        )
        if let headerToken {
            if let headerScale = yenScale(forHeaderToken: headerToken) {
                let mismatch = declared.nominal.map { $0 != headerScale } ?? false
                let applied: Double
                if mismatch {
                    applied = pickScaleAgainstDenominator(
                        candidates: [headerScale, declared.nominal ?? 1, 1],
                        defaultMultiplier: headerScale,
                        rawAmounts: rawAmounts,
                        consolidatedSales: consolidatedSales
                    )
                } else {
                    // 一致時はヘッダー倍率を正とするが、既に円スケールなら再乗算しない
                    // （geography が unit=yen で分母一致、ヘッダーは千円、の取り違え防止。Konami 型と同型）。
                    applied = scaleTowardYen(
                        proposed: headerScale,
                        rawAmounts: rawAmounts,
                        consolidatedSales: consolidatedSales)
                }
                return Resolution(
                    multiplier: applied,
                    unresolved: false,
                    headerLlmMismatch: mismatch,
                    headerToken: headerToken,
                    headerBorrowed: headerBorrowed
                )
            }
            // ヘッダー語はあるが円倍率に落ちない（百万ユーロ等）。LLM の百万円推定へ逃げない。
            return Resolution(
                multiplier: 1,
                unresolved: true,
                headerLlmMismatch: declared.nominal != nil,
                headerToken: headerToken,
                headerBorrowed: headerBorrowed
            )
        }
        if declared.known {
            return Resolution(
                multiplier: scaleTowardYen(
                    proposed: declared.nominal ?? declared.multiplier,
                    rawAmounts: rawAmounts,
                    consolidatedSales: consolidatedSales
                ),
                unresolved: false,
                headerLlmMismatch: false,
                headerToken: nil,
                headerBorrowed: false
            )
        }
        return Resolution(
            multiplier: 1,
            unresolved: true,
            headerLlmMismatch: false,
            headerToken: nil,
            headerBorrowed: false
        )
    }

    /// `source_table_index` の表を優先し、キャプション → markdown → 見出しの順で単位語を拾う。
    /// 対象表に単位が無く、候補表の単位語がすべて同じときだけ兄弟表から借りる（そのときだけ
    /// `borrowed`）。兄弟が食い違うときは借りない（LLM フォールバック／fail closed へ）。
    /// 直前表より後の preceding caption は対象表自身。
    static func headerUnitLookup(
        tables: [BreakdownTable],
        sourceTableIndex: Int?
    ) -> HeaderUnitLookup {
        if let index = sourceTableIndex, tables.indices.contains(index),
            let own = ownHeaderUnitToken(from: tables[index])
        {
            return HeaderUnitLookup(token: own, borrowed: false)
        }
        let tokens = tables.compactMap { headerUnitToken(from: $0) }
        if Set(tokens).count == 1 {
            return HeaderUnitLookup(token: tokens.first, borrowed: true)
        }
        return HeaderUnitLookup(token: nil, borrowed: false)
    }

    static func headerUnitToken(
        tables: [BreakdownTable],
        sourceTableIndex: Int?
    ) -> String? {
        headerUnitLookup(tables: tables, sourceTableIndex: sourceTableIndex).token
    }

    static func headerUnitToken(from table: BreakdownTable) -> String? {
        if let caption = table.unitCaption, let token = BreakdownExtractor.parseUnitCaption(caption) {
            return token
        }
        if let token = BreakdownExtractor.parseUnitCaption(table.markdown) {
            return token
        }
        return BreakdownExtractor.parseUnitCaption(table.heading)
    }

    /// `parseUnitCaption` の語を円倍率へ。十億円を億円より先に見る。未知語は nil（推測しない）。
    static func yenScale(forHeaderToken token: String) -> Double? {
        if token.contains("十億円") { return 1_000_000_000 }
        if token.contains("億円") { return 100_000_000 }
        if token.contains("百万円") { return Financial.millionYen }
        if token.contains("千円") { return thousandYen }
        if token == "円" { return 1 }
        return nil
    }

    /// 正規化器が共有するスケール適用。warnings は呼び出し側が既存配列へ append する。
    static func scaling(
        declaredUnit: String,
        tables: [BreakdownTable],
        sourceTableIndex: Int?,
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> Resolution {
        let lookup = headerUnitLookup(tables: tables, sourceTableIndex: sourceTableIndex)
        return resolve(
            headerToken: lookup.token,
            declaredUnit: declaredUnit,
            rawAmounts: rawAmounts,
            consolidatedSales: consolidatedSales,
            headerBorrowed: lookup.borrowed
        )
    }

    /// 公開面（#447）が隠す条件に合わせて flags を積む。対象表自身（直前表より後の
    /// preceding caption を含む）のヘッダー食い違いは `unit_header_llm_mismatch` 警告だけ。
    /// 兄弟表から借りたトークンの食い違いと unresolved だけ `needs_review`。
    static func applyPublicFlags(
        _ scale: Resolution,
        needsReview: inout Bool,
        warnings: inout [String]
    ) {
        if scale.unresolved {
            needsReview = true
            warnings.append("llm_unit_unresolved")
        }
        if scale.headerLlmMismatch {
            warnings.append(headerLlmMismatchWarning)
            if scale.headerBorrowed {
                needsReview = true
            }
        }
    }

    /// 旧ルール（LLM 申告のみ）の倍率。再 ingest スキャンの old vs new 比に使う。
    static func legacyYenMultiplier(
        declaredUnit: String,
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> (multiplier: Double, unresolved: Bool) {
        switch declaredUnit {
        case "yen":
            return (1, false)
        case "million_yen":
            return (
                millionYenMultiplier(rawAmounts: rawAmounts, consolidatedSales: consolidatedSales),
                false
            )
        default:
            return (1, true)
        }
    }

    /// LLM 行の `source` から filing specials / 抽出キーへ。スキャンと再抽出で共用。
    static func specialSectionKey(source: String) -> String? {
        switch source {
        case breakdownSourceRevenueRecognitionLLM: return "revenue_recognition"
        case breakdownSourceSegmentInfoLLM: return "segments"
        case breakdownSourceGeographyLLM: return "geography"
        default: return nil
        }
    }

    private struct DeclaredScale {
        var multiplier: Double
        var known: Bool
        /// LLM が主張する表示単位の円倍率。ヒューリスティック後の実効倍率とは別（mismatch 判定用）。
        var nominal: Double?
    }

    private static func declaredScale(
        declaredUnit: String,
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> DeclaredScale {
        switch declaredUnit {
        case "yen":
            return DeclaredScale(multiplier: 1, known: true, nominal: 1)
        case "million_yen":
            return DeclaredScale(
                multiplier: millionYenMultiplier(
                    rawAmounts: rawAmounts, consolidatedSales: consolidatedSales),
                known: true,
                nominal: Financial.millionYen
            )
        default:
            return DeclaredScale(multiplier: 1, known: false, nominal: nil)
        }
    }

    private static func millionYenMultiplier(
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> Double {
        scaleTowardYen(
            proposed: Financial.millionYen, rawAmounts: rawAmounts, consolidatedSales: consolidatedSales)
    }

    /// LLM 正規化器の分母許容と同じ。食い違い時の候補採否に使う。
    static let denominatorRatioTolerance = 0.90...1.10

    /// 分母比が `denominatorRatioTolerance` に入る候補のうち、1 に最も近い倍率。
    /// 分母なし・該当なし・同距離は `defaultMultiplier`（ヘッダー）。
    private static func pickScaleAgainstDenominator(
        candidates: [Double],
        defaultMultiplier: Double,
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> Double {
        guard let sales = consolidatedSales, sales != 0 else { return defaultMultiplier }
        let rawRef = rawAmounts.map { abs($0) }.max() ?? 0
        guard rawRef != 0 else { return defaultMultiplier }

        struct Scored {
            var multiplier: Double
            var distance: Double
        }
        var scored: [Scored] = []
        var seen = Set<Double>()
        for multiplier in candidates where seen.insert(multiplier).inserted {
            let ratio = rawRef * multiplier / abs(sales)
            guard denominatorRatioTolerance.contains(ratio) else { continue }
            scored.append(Scored(multiplier: multiplier, distance: logDistanceFromUnity(ratio)))
        }
        guard let bestDistance = scored.map(\.distance).min() else {
            return defaultMultiplier
        }
        let tied = scored.filter { abs($0.distance - bestDistance) < 1e-12 }
        if tied.count != 1 {
            return defaultMultiplier
        }
        return tied[0].multiplier
    }

    /// 提案倍率を掛けたほうが分母に近いか、既に円スケールか。
    private static func scaleTowardYen(
        proposed: Double,
        rawAmounts: [Double],
        consolidatedSales: Double?
    ) -> Double {
        if proposed == 1 { return 1 }
        guard let sales = consolidatedSales, sales != 0 else { return proposed }
        let rawRef = rawAmounts.map { abs($0) }.max() ?? 0
        guard rawRef != 0 else { return proposed }
        let asIs = rawRef / abs(sales)
        let asScaled = rawRef * proposed / abs(sales)
        if closerToUnity(asIs, than: asScaled) {
            return 1
        }
        return proposed
    }

    private static func closerToUnity(_ a: Double, than b: Double) -> Bool {
        logDistanceFromUnity(a) < logDistanceFromUnity(b)
    }

    private static func logDistanceFromUnity(_ ratio: Double) -> Double {
        abs(log10(max(ratio, Double.leastNonzeroMagnitude)))
    }
}
