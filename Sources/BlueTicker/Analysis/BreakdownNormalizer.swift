// 事業別・地域別売上の比較用コモンモデル（Stage 6, docs/breakdown-normalization-concept.md）
// BreakdownExtractor の xbrl_facts 結果を BreakdownSnapshot（比較可能な正規化スナップショット）へ写す。
//
// html_table 由来（method == "html_table"）は行パース未実装のため対象外（nil を返す）。
// 銀行等の金融機関は segmentExternalRevenueTags に一致するタグを持たないため、
// 自然に nil（対象外）になる。

import Foundation

struct BreakdownRow: Equatable {
    var labelRaw: String
    var amount: Double
    var share: Double?
    var profit: Double?  // 対応する利益タグが無ければ nil（任意フィールド）
    var rowKind: String  // "segment" | "subtotal" | "reconciling"
}

struct BreakdownSnapshot: Equatable {
    var axis: String  // "business" | "geography"
    var denominator: Double
    // 採用した分母の出所（監査・再現用）。xbrl_facts 経路は実際に使った XBRL タグ名
    // （例: "SalesToExternalCustomersIFRS"）、html_table 経路は XBRL タグが存在しないため
    // sentinel 文字列 "income_statement.sales" を使う（意図的な語彙の使い分け）。
    var denominatorTag: String
    var rows: [BreakdownRow]
    var sourceKind: String  // "xbrl_facts"（本ファイル） | "html_table"（GeographyBreakdownLLMNormalizer） | "revenue_recognition"（RevenueRecognitionLLMNormalizer） | "segment_info"（SegmentInfoLLMNormalizer）
    var needsReview: Bool
    var warnings: [String]
}

enum BreakdownNormalizer {

    /// ExtractedBreakdown（xbrl_facts）と連結外部売上から BreakdownSnapshot を組み立てる。
    /// 適用不可（html_table / not_found / 該当タグなし）の場合は nil。
    /// 銀行等、外部売上高に相当する概念を持たない金融機関は粗利益/営業純益基準へフォールバックする。
    /// Stage 4 の `sales` が欠損していても（保険の経常収益ラベルのみ・東宝など）、
    /// セグメント注記に外部顧客売上タグがあれば内部小計基準で解決する
    /// （実データ: SOMPO / MS&AD / 第一生命 / T&D / 東宝、2026-07-24）。
    static func normalize(_ result: ExtractedBreakdown, consolidatedSales: Double?) -> BreakdownSnapshot? {
        guard result.method == "xbrl_facts", !result.facts.isEmpty else { return nil }

        if let consolidatedSales, consolidatedSales != 0,
           let snapshot = normalizeSalesBasis(facts: result.facts, consolidatedSales: consolidatedSales)
        {
            return snapshot
        }
        // 連結売上が取れないときでも、セグメント側の外部顧客売上タグで分母を組む
        // （Stage 4 sales=null の保険・一部事業会社向け。LLM 経路に落とさない）。
        if let external = normalizeInternalSubtotalBasis(
            facts: result.facts, amountTags: Xbrl.segmentExternalRevenueTags,
            profitTags: Xbrl.segmentProfitTags, warningPrefix: "external_revenue")
        {
            return external
        }
        if let bank = normalizeInternalSubtotalBasis(
            facts: result.facts, amountTags: Xbrl.segmentBankGrossProfitTags,
            profitTags: Xbrl.segmentBankNetOperatingProfitTags, warningPrefix: "bank")
        {
            return bank
        }
        return normalizeInternalSubtotalBasis(
            facts: result.facts, amountTags: Xbrl.segmentInsuranceRevenueTags,
            profitTags: Xbrl.segmentInsuranceServiceResultTags, warningPrefix: "insurance")
    }

    /// 外部売上高を分母とする通常経路（ホワイトリスト → カバレッジ発見フォールバック）。
    private static func normalizeSalesBasis(
        facts: [BreakdownFact], consolidatedSales: Double
    ) -> BreakdownSnapshot? {
        var denominatorNeedsReview = false
        let denominatorTag: String
        if let whitelisted = Xbrl.segmentExternalRevenueTags.first(where: { tag in
            facts.contains(where: { $0.tag == tag })
        }) {
            denominatorTag = whitelisted
        } else if let discovered = discoverDenominatorTagByCoverage(
            facts: facts, consolidatedSales: consolidatedSales)
        {
            denominatorTag = discovered.tag
            denominatorNeedsReview = discovered.needsReview
        } else {
            return nil
        }

        let perMember = resolvePerMember(facts: facts, tag: denominatorTag)
        guard !perMember.isEmpty else { return nil }

        // 利益は任意フィールド（対応する利益タグが無い/取れない member は profit=nil のまま）。
        let profitTag = Xbrl.segmentProfitTags.first(where: { tag in
            facts.contains(where: { $0.tag == tag })
        })
        let profitByMember = profitTag.map { resolvePerMember(facts: facts, tag: $0) } ?? [:]

        // 1次判定: タクソノミ標準の小計・調整 member を名称で分類する。
        var kinds: [String: String] = [:]
        for member in perMember.keys {
            if Xbrl.segmentReconcilingMemberNames.contains(member) {
                kinds[member] = "reconciling"
            } else if Xbrl.segmentSubtotalMemberNames.contains(member) {
                kinds[member] = "subtotal"
            } else {
                kinds[member] = "segment"
            }
        }
        // 2次判定（数値の安全網）: 名称未収載の合計行を分母一致で補足する。
        // ただし segment 候補が1件しかない場合は適用しない
        // （単一セグメント企業では amount ≈ denominator が正しい姿であり、小計ではない）。
        let segmentCandidates = perMember.keys.filter { kinds[$0] == "segment" }
        if segmentCandidates.count > 1 {
            for member in segmentCandidates {
                let amount = perMember[member]!.value
                if abs(amount - consolidatedSales) / abs(consolidatedSales) < 0.01 {
                    kinds[member] = "subtotal"
                }
            }
        }

        // 高島屋型: Stage 4 が NetSales（売上高）を取る一方、セグメント注記の
        // RevenuesFromExternalCustomers は営業収益ベース。Stage 4 売上を分母にしたままだと
        // amount/denominator が 1 を大きく超え比較不能になる（実データ: S100Y4X5、2026-07-25）。
        // 小計（または segment 合計）が Stage 4 売上と ±5% 超乖離するときは注記側に揃える。
        // segmentSum は 2 次判定後の kinds で再集計する（小計へ昇格した行を含めない）。
        let segmentSum = perMember.keys.filter { kinds[$0] == "segment" }
            .reduce(0.0) { $0 + perMember[$1]!.value }
        let subtotalCandidates = perMember.keys.filter { kinds[$0] == "subtotal" }
        let segmentConsistentDenominator: Double? = {
            if let closest = subtotalCandidates.min(by: {
                abs(perMember[$0]!.value - segmentSum) < abs(perMember[$1]!.value - segmentSum)
            }) {
                let subtotalValue = perMember[closest]!.value
                if abs(subtotalValue) > 0,
                   abs(subtotalValue - segmentSum) / abs(subtotalValue) <= 0.05
                {
                    return subtotalValue
                }
            }
            return segmentSum != 0 ? segmentSum : nil
        }()

        var denominator = consolidatedSales
        var warnings: [String] = []
        if let aligned = segmentConsistentDenominator, aligned != 0,
           abs(consolidatedSales - aligned) / abs(aligned) > 0.05
        {
            denominator = aligned
            warnings.append("sales_denominator_aligned_to_segment_total")
        }

        let rows = perMember.keys.sorted().map { member -> BreakdownRow in
            let fact = perMember[member]!
            return BreakdownRow(
                labelRaw: member,
                amount: fact.value,
                share: fact.value / denominator,
                profit: profitByMember[member]?.value,
                rowKind: kinds[member]!
            )
        }

        let (axis, axisNeedsReview) = classifyAxis(rows: rows)
        if axisNeedsReview { warnings.append("axis_ambiguous") }
        if denominatorNeedsReview { warnings.append("denominator_tag_ambiguous") }

        return BreakdownSnapshot(
            axis: axis,
            denominator: denominator,
            denominatorTag: denominatorTag,
            rows: rows,
            sourceKind: "xbrl_facts",
            needsReview: axisNeedsReview || denominatorNeedsReview,
            warnings: warnings
        )
    }

    /// 銀行・保険等、外部売上高に相当する概念を持たない業種向けの共通フォールバック経路
    /// （実データ検証: 三菱UFJ「NetRevenue」＝粗利益／「OperatingProfit」＝営業純益、
    /// 三井住友「ConsolidatedGrossProfit」／「ConsolidatedNetBusinessProfit」、
    /// 東京海上「InsuranceRevenueIFRS」＝保険収益／「InsuranceServiceResultIFRS」＝
    /// 保険サービス損益、issue調査 2026-07-21）。分母は外部から渡される連結売上高ではなく、
    /// `segmentSubtotalMemberNames` に名称一致する小計 member 自身の値を使う。複数の
    /// 小計候補がある場合（三菱UFJ: 全社合計と顧客部門のみの部分合計の2種）は、segment 行の
    /// 合計に最も近い値（＝真の全社合計）を採用する。単純な最大値採用だと、市場部門が赤字の期に
    /// 部分合計の方が全社合計より大きくなり誤って選ばれることがあるため（golden データ検証）。
    /// 名称一致する小計が無い場合は segment 行の合計にフォールバックし needsReview を立てる
    /// （裏取りが名称一致より弱いため）。軸は常に business 固定（`classifyAxis` は
    /// 「Japanese...」のような事業本部名を地域名の部分一致で誤検知するため、この経路では
    /// 地域別開示が来る想定が無く再利用しない）。
    private static func normalizeInternalSubtotalBasis(
        facts: [BreakdownFact], amountTags: [String], profitTags: [String], warningPrefix: String
    ) -> BreakdownSnapshot? {
        guard let amountTag = amountTags.first(where: { tag in
            facts.contains(where: { $0.tag == tag })
        }) else { return nil }

        let perMember = resolvePerMember(facts: facts, tag: amountTag)
        guard !perMember.isEmpty else { return nil }

        var kinds: [String: String] = [:]
        for member in perMember.keys {
            if Xbrl.segmentReconcilingMemberNames.contains(member) {
                kinds[member] = "reconciling"
            } else if Xbrl.segmentSubtotalMemberNames.contains(member) {
                kinds[member] = "subtotal"
            } else {
                kinds[member] = "segment"
            }
        }

        let subtotalCandidates = perMember.keys.filter { kinds[$0] == "subtotal" }
        let segmentSum = perMember.keys.filter { kinds[$0] == "segment" }
            .reduce(0.0) { $0 + perMember[$1]!.value }
        let denominator: Double
        var denominatorWarning: String?
        if let closestToSegmentSum = subtotalCandidates.min(by: {
            abs(perMember[$0]!.value - segmentSum) < abs(perMember[$1]!.value - segmentSum)
        }) {
            denominator = perMember[closestToSegmentSum]!.value
            // Grok 4.5 レビュー指摘: 小計候補が1件しかない場合（例: 全社合計タグが名称未収載で
            // 部分合計しか無い）、距離チェックそのものがスキップされ needsReview が立たない穴が
            // あった。segment 行合計と大きく乖離する小計を採用したときは要確認とする。
            if abs(denominator) > 0, abs(denominator - segmentSum) / abs(denominator) > 0.05 {
                denominatorWarning = "\(warningPrefix)_denominator_far_from_segment_sum"
            }
        } else {
            denominator = segmentSum
            denominatorWarning = "\(warningPrefix)_denominator_derived_from_segment_sum"
        }
        guard denominator != 0 else { return nil }

        let profitTag = profitTags.first(where: { tag in
            facts.contains(where: { $0.tag == tag })
        })
        let profitByMember = profitTag.map { resolvePerMember(facts: facts, tag: $0) } ?? [:]

        let rows = perMember.keys.sorted().map { member -> BreakdownRow in
            let fact = perMember[member]!
            return BreakdownRow(
                labelRaw: member,
                amount: fact.value,
                share: fact.value / denominator,
                profit: profitByMember[member]?.value,
                rowKind: kinds[member]!
            )
        }

        var warnings: [String] = []
        if let denominatorWarning { warnings.append(denominatorWarning) }

        return BreakdownSnapshot(
            axis: "business",
            denominator: denominator,
            denominatorTag: amountTag,
            rows: rows,
            sourceKind: "xbrl_facts",
            needsReview: denominatorWarning != nil,
            warnings: warnings
        )
    }

    // MARK: - 内部ロジック

    /// ConsolidatedOrNonConsolidatedAxis が明示的に非連結を指していないこと。
    private static func isConsolidated(_ fact: BreakdownFact) -> Bool {
        fact.dimensions["ConsolidatedOrNonConsolidatedAxis"] != "NonConsolidatedMember"
    }

    /// 指定タグの当期 fact を member ごとに解決する。連結を優先し、連結コンテキストが
    /// 1件もなければ非連結（子会社を持たない小規模企業）にフォールバックする
    /// （resolveItemPreferCurrent と同じ「優先→フォールバック」の非対称ルール）。
    /// facts は tag+contextRef でソート済みのため、member 内の採用順は決定的。
    private static func resolvePerMember(facts: [BreakdownFact], tag: String) -> [String: BreakdownFact] {
        let candidateFacts = facts.filter { $0.tag == tag && isCurrentPeriod($0.contextRef) }
        let consolidatedFacts = candidateFacts.filter(isConsolidated)
        let source = consolidatedFacts.isEmpty ? candidateFacts : consolidatedFacts

        var perMember: [String: BreakdownFact] = [:]
        for fact in source {
            guard let member = primaryMember(fact.dimensions), perMember[member] == nil else { continue }
            perMember[member] = fact
        }
        return perMember
    }

    /// `Xbrl.segmentExternalRevenueTags` ホワイトリストに一致するタグが無い場合の候補発見。
    /// 個別タグを都度ホワイトリストへ追加する Whac-A-Mole を避けるための一般化ルール
    /// （実データ検証: NTT の `TransactionsWithExternalCustomersIFRS`、
    /// ファーストリテイリングの `RevenueIFRS` はいずれも本ロジックで発見できることを確認済みだが、
    /// 両者は確認済みのためホワイトリストにも追加済み。本関数は将来の未知タグ向け）。
    ///
    /// 判定: `segmentNonRevenueTagKeywords` に一致しないタグのうち、segment 行（小計・調整を除く）の
    /// 合計が連結外部売上高の ±5% に収まるものを候補とする。複数候補が残った場合は
    /// タグ名に External/Customers を含むものを優先し、次に分母比率が 1.0 に近い順、
    /// 最後にタグ名の辞書順で決定的にタイブレークする（複数候補が残った事実自体は needsReview で示す）。
    private static func discoverDenominatorTagByCoverage(
        facts: [BreakdownFact], consolidatedSales: Double
    ) -> (tag: String, needsReview: Bool)? {
        let candidateTags = Set(facts.map(\.tag))
            .subtracting(Xbrl.segmentExternalRevenueTags)
            .subtracting(Xbrl.segmentProfitTags)
            .filter { tag in !Xbrl.segmentNonRevenueTagKeywords.contains { tag.contains($0) } }

        let passing: [(tag: String, ratio: Double)] = candidateTags.compactMap { tag in
            let perMember = resolvePerMember(facts: facts, tag: tag)
            guard !perMember.isEmpty else { return nil }

            var excluded = Set(perMember.keys.filter { member in
                Xbrl.segmentSubtotalMemberNames.contains(member)
                    || Xbrl.segmentReconcilingMemberNames.contains(member)
            })
            // 数値による小計除外の安全網（本処理と同じ非対称ルール、学び7）: 企業独自の合計行名が
            // 上記の標準語彙に無くても、候補が複数あるときは金額が連結売上高に一致する member を
            // 小計とみなして除外する（Grok 4.5 レビュー指摘: 除外しないと合計が概ね2倍になり、
            // 正しい売上タグが ±5% 判定で誤って弾かれる）。
            let unnamedCandidates = perMember.keys.filter { !excluded.contains($0) }
            if unnamedCandidates.count > 1 {
                for member in unnamedCandidates {
                    let amount = perMember[member]!.value
                    if abs(amount - consolidatedSales) / abs(consolidatedSales) < 0.01 {
                        excluded.insert(member)
                    }
                }
            }

            let segmentSum = perMember.reduce(0.0) { total, entry in
                let (member, fact) = entry
                return excluded.contains(member) ? total : total + fact.value
            }
            guard segmentSum > 0 else { return nil }
            let ratio = segmentSum / consolidatedSales
            guard (0.95...1.05).contains(ratio) else { return nil }
            return (tag, ratio)
        }
        guard !passing.isEmpty else { return nil }

        let sorted = passing.sorted { a, b in
            let aKeyword = a.tag.contains("External") || a.tag.contains("Customers")
            let bKeyword = b.tag.contains("External") || b.tag.contains("Customers")
            if aKeyword != bKeyword { return aKeyword }
            let aDistance = abs(a.ratio - 1.0)
            let bDistance = abs(b.ratio - 1.0)
            if aDistance != bDistance { return aDistance < bDistance }
            return a.tag < b.tag
        }
        return (sorted[0].tag, passing.count > 1)
    }

    /// 当期コンテキストかどうか（セグメント軸は Member 修飾があるため ContextHelpers は使わず判定する）。
    private static func isCurrentPeriod(_ contextRef: String) -> Bool {
        Xbrl.durationContextPatterns.contains(where: contextRef.contains)
            || Xbrl.instantContextPatterns.contains(where: contextRef.contains)
    }

    /// dimensions のうち ConsolidatedOrNonConsolidatedAxis 以外の member を行ラベルとする。
    /// 複数該当する場合は dimension キー名の辞書順で先頭を採用し、Dictionary の走査順不定に依存しない
    /// （smoke 実データでは OperatingSegmentsAxis 系1本のみだが、将来複数軸が絡む書類のための決定的化）。
    private static func primaryMember(_ dimensions: [String: String]) -> String? {
        dimensions
            .filter { $0.key != "ConsolidatedOrNonConsolidatedAxis" }
            .sorted { $0.key < $1.key }
            .first?.value
    }

    /// segment 行の member ラベルが地域名キーワードと全一致すれば geography、
    /// 一致なしなら business、一部一致（混在）は business + needs_review（ただし下記の例外あり）。
    /// `segmentOtherBusinessMemberNames`（rowKind は segment だが事業/地域いずれの軸にも
    /// 断定できない「その他」）は候補から除外する。`BreakdownExtractor.isGeographyAxis` と同じ理由
    /// （軸判定への影響を避ける）。除外しないと、地域別報告企業にこの member が同居する場合に
    /// 全一致判定が崩れ、本来 geography のスナップショットが business + needs_review へ誤分類される。
    ///
    /// 一部一致の needs_review 判定は `segmentGeographyMemberKeywords` 全体ではなく
    /// `segmentSpecificGeographyMemberKeywords`（Domestic/Overseas を除いた特定地域名）で行う
    /// （学び11、実データ検証: 1802大林組・1812鹿島建設・1808長谷工・2413エムスリー）。
    /// 「国内◯◯事業」「海外◯◯事業」という事業区分名や「海外事業」という単独カテゴリは
    /// Domestic/Overseas のみで一致するが、これらは事業軸の一部であって地域軸との真の混在ではない
    /// （sum(segment) ≈ denominator で axis=business の正しさを別途確認済み）。
    ///
    /// 特定地域名（Japan 等）が事業・プロジェクト名に埋め込まれているだけの行
    /// （例: INPEX `OilAndGasJapanReportableSegmentMember`＝国内O&G）も、除去後に**固有の**
    /// 事業語幹が残るなら混在シグナルに使わない（実データ検証 2026-07-24）。
    /// ただし `JapanBusinessMember` / `AmericasBusiness…` のように地域名＋汎用の Business
    /// ラッパだけのラベルは、学び11どおり特定地域名混在として needs_review を立てる
    /// （INPEX 免除を Business ラッパまで広げない。Sonnet レビュー 2026-07-25）。
    /// 既知のトレードオフ: 「DomesticMember」「OverseasMember」「JapanMember」のように
    /// member ラベルが地域語だけ（他の事業語を伴わない）で、かつ他の segment が事業名という
    /// 真に軸混在のケースも、本ルールでは needs_review を立てず見逃すことがある。
    private static func classifyAxis(rows: [BreakdownRow]) -> (axis: String, needsReview: Bool) {
        let segmentMembers = rows
            .filter { $0.rowKind == "segment" && !Xbrl.segmentOtherBusinessMemberNames.contains($0.labelRaw) }
            .map(\.labelRaw)
        guard !segmentMembers.isEmpty else { return ("business", false) }

        if allMembersAreGeography(segmentMembers) { return ("geography", false) }

        let geoMatches = segmentMembers.filter { member in
            Xbrl.segmentGeographyMemberKeywords.contains(where: member.contains)
        }
        if geoMatches.isEmpty { return ("business", false) }

        // TOTO型: 報告セグメントが「日本住設」＋海外住設の地域内訳（米州/アジア・オセアニア/欧州/
        // 中国大陸）＋「先進セラミック」。海外側 member は Americas / Europe 等の裸の地域名だが、
        // HousingEquipment 語幹を持つ行が同居するならマネジメント・アプローチ上の事業区分であり
        // 真の軸混在ではない（ユーザー確認 2026-07-25、S100YC72）。
        // 資生堂型の JapanBusiness のみの地域事業ユニット（製品別は記載省略）には HousingEquipment
        // が無いので、この免除は当たらない。
        if segmentMembers.contains(where: { $0.contains("HousingEquipment") }) {
            return ("business", false)
        }

        // 裸の特定地域名（＋汎用 Business ラッパのみ）を混在シグナルにする。
        // OilAndGasJapan 等、固有語幹が残る複合は除外。
        let bareSpecificGeoMatches = segmentMembers.filter { member in
            Xbrl.segmentSpecificGeographyMemberKeywords.contains(where: member.contains)
                && !hasSubstantiveNonGeographyContent(member)
        }
        return ("business", !bareSpecificGeoMatches.isEmpty)
    }

    /// member ラベル集合が「全て地域軸相当」かを判定する共通ロジック。`classifyAxis` と
    /// `BreakdownExtractor` の axis-aware swap 判定（オークマ型検出）の双方が同じ基準を必要とする
    /// ため一本化した（重複ロジック回避。以前は各所に同型のチェックが独立して存在し、片方だけ
    /// 修正して食い違うバグがあった。issue調査 2026-07-21）。
    ///
    /// 全 member が地域キーワードにヒットしても、特定地域名（Japan 等）を1件も伴わず、かつ
    /// Domestic/Overseas を除去した後に事業名らしき語幹が残るなら「国内食品製造販売」
    /// 「海外食品製造販売」（キッコーマン型）のような事業区分×国内海外クロス集計であり、
    /// 真の地域軸ではない。「DomesticMember」「OverseasMember」のような裸の地域区分
    /// （除去後に何も残らない）はこの条件に当たらず地域軸のまま（既知のトレードオフ、学び11参照）。
    static func allMembersAreGeography(_ members: [String]) -> Bool {
        guard !members.isEmpty else { return false }
        let geoMatches = members.filter { member in
            Xbrl.segmentGeographyMemberKeywords.contains(where: member.contains)
        }
        guard geoMatches.count == members.count else { return false }

        let specificGeoMatches = members.filter { member in
            Xbrl.segmentSpecificGeographyMemberKeywords.contains(where: member.contains)
        }
        if specificGeoMatches.isEmpty, members.allSatisfy(hasSubstantiveNonGeographyContent) {
            return false
        }
        return true
    }

    /// member 名から地域キーワード・共通接尾辞・汎用 Business ラッパを除去した後、
    /// 実質的な語幹が残るか（＝固有の事業名・プロジェクト名等の修飾を伴う複合ラベルか）を判定する。
    /// Domestic/Overseas だけでなく Japan 等の特定地域名も除去する
    /// （INPEX `OilAndGasJapan…` → `OilAndGas` が残る、実データ検証 2026-07-24）。
    /// `JapanBusiness…` は Business 除去後に空になり「実質語幹なし」＝混在シグナル対象のまま
    /// （学び11。Business ラッパを事業語幹とみなすと資生堂型の要レビューが消える）。
    /// TOTO の海外住設（Americas 等）は `classifyAxis` 側の HousingEquipment 同居免除で扱う。
    private static func hasSubstantiveNonGeographyContent(_ member: String) -> Bool {
        var stripped = member
        // 長いキーワードから消す（NorthAmerica を America より先に、等）
        for keyword in Xbrl.segmentGeographyMemberKeywords.sorted(by: { $0.count > $1.count }) {
            stripped = stripped.replacingOccurrences(of: keyword, with: "")
        }
        for suffix in ["ReportableSegmentsMember", "ReportableSegmentMember", "Member"] {
            stripped = stripped.replacingOccurrences(of: suffix, with: "")
        }
        // 地域事業ユニットの汎用ラッパ。これだけ残っても固有の事業語幹とはみなさない。
        stripped = stripped.replacingOccurrences(of: "Business", with: "")
        return !stripped.isEmpty
    }
}
