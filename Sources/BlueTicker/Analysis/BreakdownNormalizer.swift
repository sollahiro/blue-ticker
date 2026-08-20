// 事業別・地域別売上の比較用コモンモデル（内訳取り込み, docs/breakdown.md）
// BreakdownExtractor の xbrl_facts 結果を BreakdownSnapshot（比較可能な正規化スナップショット）へ写す。
//
// html_table 由来（method == "html_table"）は行パース未実装のため対象外（nil を返す）。
// 銀行等の金融機関は segmentExternalRevenueTags に一致するタグを持たないため、
// 自然に nil（対象外）になる。

import Foundation

struct BreakdownRow: Equatable {
    var labelRaw: String
    // XBRL ラベルリンクベースから解決した日本語ラベル（xbrl_facts 経路のみ。html_table/LLM 経路は
    // labelRaw が既に開示書類のテキストそのもの＝日本語のため nil のまま。公開層で
    // `label ?? labelRaw` にフォールバックする）。
    var label: String? = nil
    var amount: Double
    var share: Double?
    var profit: Double?  // 対応する利益タグが無ければ nil（任意フィールド）
    var rowKind: String  // "segment" | "subtotal" | "reconciling"
    /// notes「設備投資等の概要」の設備内容・目的。その他の軸は nil。
    var description: String? = nil
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
    /// 財務取り込み の `sales` が欠損していても（保険の経常収益ラベルのみ・東宝など）、
    /// セグメント注記に外部顧客売上タグがあれば内部小計基準で解決する
    /// （実データ: SOMPO / MS&AD / 第一生命 / T&D / 東宝、2026-07-24）。
    /// セグメント dimension が付かない全社合計 fact は `EntityTotal` 小計行として残す
    /// （第一生命: 計 11,373,330 ≠ 連結財務諸表計上額 9,873,251）。
    static func normalize(
        _ result: ExtractedBreakdown, consolidatedSales: Double?,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        guard result.method == "xbrl_facts", !result.facts.isEmpty else { return nil }

        if let consolidatedSales, consolidatedSales != 0,
           let snapshot = normalizeSalesBasis(
               facts: result.facts, consolidatedSales: consolidatedSales, labelsByTag: labelsByTag)
        {
            return snapshot
        }
        // 連結売上が取れないときでも、セグメント側の外部顧客売上タグで分母を組む
        // （財務取り込み sales=null の保険・一部事業会社向け。LLM 経路に落とさない）。
        if let external = normalizeInternalSubtotalBasis(
            facts: result.facts, amountTags: Xbrl.segmentExternalRevenueTags,
            profitTags: Xbrl.segmentProfitTags, warningPrefix: "external_revenue",
            labelsByTag: labelsByTag)
        {
            return external
        }
        if let bank = normalizeInternalSubtotalBasis(
            facts: result.facts, amountTags: Xbrl.segmentBankGrossProfitTags,
            profitTags: Xbrl.segmentBankNetOperatingProfitTags, warningPrefix: "bank",
            labelsByTag: labelsByTag)
        {
            return bank
        }
        return normalizeInternalSubtotalBasis(
            facts: result.facts, amountTags: Xbrl.segmentInsuranceRevenueTags,
            profitTags: Xbrl.segmentInsuranceServiceResultTags, warningPrefix: "insurance",
            labelsByTag: labelsByTag)
    }

    /// 外部売上高を分母とする通常経路（ホワイトリスト → カバレッジ発見フォールバック）。
    private static func normalizeSalesBasis(
        facts: [BreakdownFact], consolidatedSales: Double, labelsByTag: [String: String] = [:]
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

        let perMember = withEntityTotal(
            resolvePerMember(facts: facts, tag: denominatorTag), facts: facts, tag: denominatorTag)
        guard !perMember.isEmpty else { return nil }

        // 利益は任意フィールド（対応する利益タグが無い/取れない member は profit=nil のまま）。
        let profitTag = Xbrl.segmentProfitTags.first(where: { tag in
            facts.contains(where: { $0.tag == tag })
        })
        var profitByMember = profitTag.map { resolvePerMember(facts: facts, tag: $0) } ?? [:]
        if let profitTag {
            profitByMember = withEntityTotal(profitByMember, facts: facts, tag: profitTag)
        }

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

        // 高島屋型: 財務取り込み が NetSales（売上高）を取る一方、セグメント注記の
        // RevenuesFromExternalCustomers は営業収益ベース。財務取り込み 売上を分母にしたままだと
        // amount/denominator が 1 を大きく超え比較不能になる（実データ: S100Y4X5、2026-07-25）。
        // 小計（または segment 合計）が 財務取り込み 売上と ±5% 超乖離するときは注記側に揃える。
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
        // 名称一致小計で裏取りできた揃えは needs_review にしない（高島屋型）。
        // 小計が無く segmentSum だけに落ちる揃えは抽出不全の疑いがあるため要レビュー
        // （Opus 監査 2026-07-25）。
        var uncorroboratedDenominatorAlignment = false
        if let aligned = segmentConsistentDenominator, aligned != 0,
           abs(consolidatedSales - aligned) / abs(aligned) > 0.05
        {
            denominator = aligned
            warnings.append("sales_denominator_aligned_to_segment_total")
            let corroboratedBySubtotal = subtotalCandidates.contains { member in
                let value = perMember[member]!.value
                return abs(value) > 0 && abs(value - aligned) / abs(aligned) <= 0.05
            }
            if !corroboratedBySubtotal {
                uncorroboratedDenominatorAlignment = true
            }
        }

        let rows = perMember.keys.sorted().map { member -> BreakdownRow in
            let fact = perMember[member]!
            return BreakdownRow(
                labelRaw: member,
                label: labelsByTag[member],
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
            needsReview: axisNeedsReview || denominatorNeedsReview || uncorroboratedDenominatorAlignment,
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
        facts: [BreakdownFact], amountTags: [String], profitTags: [String], warningPrefix: String,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        guard let amountTag = amountTags.first(where: { tag in
            facts.contains(where: { $0.tag == tag })
        }) else { return nil }

        let perMember = withEntityTotal(
            resolvePerMember(facts: facts, tag: amountTag), facts: facts, tag: amountTag)
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
        var profitByMember = profitTag.map { resolvePerMember(facts: facts, tag: $0) } ?? [:]
        if let profitTag {
            profitByMember = withEntityTotal(profitByMember, facts: facts, tag: profitTag)
        }

        let rows = perMember.keys.sorted().map { member -> BreakdownRow in
            let fact = perMember[member]!
            return BreakdownRow(
                labelRaw: member,
                label: labelsByTag[member],
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

    /// 従業員数のセグメント別内訳（内訳取り込み employees 軸）。`normalizeCountBasis` 参照。
    static func normalizeEmployees(
        facts: [BreakdownFact], total: Double?, axis: String, labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        normalizeCountBasis(
            facts: facts, amountTags: Xbrl.employeeTags, total: total, axis: axis,
            warningPrefix: "employees", labelsByTag: labelsByTag)
    }

    /// 研究開発費の事業セグメント別内訳（内訳取り込み research_and_development 軸）。
    /// `normalizeCountBasis` 参照。金額（人数ではない）だが計算の形は同一のため共用する。
    ///
    /// セグメント dimension 付き fact が無くても、呼び出し側が渡す全社合計 `total` があれば
    /// `rows=[]`・denominator のみの snapshot を返す（2026-08-11: statement-notes の
    /// `research_and_development` note_type を廃止し本軸へ集約したため、合計のみ開示の会社
    /// （実データ: オークマ等）でも breakdown が正本として成立する必要がある）。`totalTag` は
    /// `total` を算出した実タグ名（呼び出し側が同一書類の非dimension factから解決して渡す。
    /// 未解決なら `"company_financials"` にフォールバックする）。
    static func normalizeResearchAndDevelopment(
        facts: [BreakdownFact], total: Double?, totalTag: String? = nil, axis: String,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        let amountTags = Xbrl.rdExpenseCommonTags + Xbrl.rdExpenseJGAAPTags + Xbrl.rdExpenseIFRSTags
        if let snapshot = normalizeCountBasis(
            facts: facts, amountTags: amountTags, total: total, axis: axis,
            warningPrefix: "research_and_development", labelsByTag: labelsByTag)
        {
            return snapshot
        }
        guard let total, total > 0 else { return nil }
        return BreakdownSnapshot(
            axis: axis, denominator: total, denominatorTag: totalTag ?? "company_financials",
            rows: [], sourceKind: "xbrl_facts", needsReview: false, warnings: [])
    }

    /// 従業員数・研究開発費など「セグメント dimension 付き fact ＋ 別途取得済みの全社合計値」から
    /// 内訳スナップショットを組み立てる共通処理（内訳取り込み employees / research_and_development 軸）。
    ///
    /// 当初 `normalizeInternalSubtotalBasis`（銀行・保険の売上/粗利益向け）をそのまま転用したが、
    /// 実データ検証（S100TSIJ・S100VXJA、2026-08-01）で誤りが発覚したため専用実装にした。
    /// `Xbrl.segmentSubtotalMemberNames` には `CorporateSharedMember`（全社共通）が含まれるが、
    /// これは売上文脈では「全社合計」を表す会社があるための登録であり、従業員数・研究開発費文脈では
    /// 「本社機能等の少額バケツ」でしかない。これを分母に採用すると常にシェアが100%を超える
    /// （実データ: S100TSIJ 従業員数で分母3,645人に対し1セグメントだけで39,450人＝1082%）。
    /// 全社合計は呼び出し側（`BreakdownIngest.swift` が `company_financials` から取得。財務取り込み と
    /// 同じ値を再利用し自前で XBRL から再抽出しない）が渡す前提とし、小計 member 名の
    /// マッチングには依存しない。
    ///
    /// `CorporateSharedMember`/`UnallocatedAmountsAndEliminationMember` は代替総合計ではなく
    /// 「本社機能等の少額バケツ」または消去行であり、売上文脈の subtotal とは別物。これを
    /// 「subtotal」（合計チェック対象外）に分類すると sum(segment) が常に total を下回り、
    /// 5%乖離チェックが恒常的に誤検知して needs_review=true が固定化する（監査指摘、2026-08-01、
    /// 実データ: S100TSIJ 従業員は segment + `CorporateSharedMember` が総数と一致）。
    /// count-basis 文脈では「reconciling」（合計チェックには算入するが代替分母としては採用しない）。
    /// `UnallocatedAmountsAndEliminationMember` は加算（味の素 R&D の未配賦）と減算
    /// （NTT R&D のセグメント間取引消去）の両方があり、符号は分母との一致で決める。
    private static let countBasisAdditiveBucketMemberNames: Set<String> = [
        "CorporateSharedMember",
        "UnallocatedAmountsAndEliminationMember",
    ]

    private static let countBasisEliminationMemberName = "UnallocatedAmountsAndEliminationMember"
    private static let countBasisReportableSegmentsMemberName = "ReportableSegmentsMember"

    private static func normalizeCountBasis(
        facts: [BreakdownFact], amountTags: [String], total: Double?, axis: String, warningPrefix: String,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        guard let amountTag = amountTags.first(where: { tag in
            facts.contains(where: { $0.tag == tag })
        }) else { return nil }

        let perMember = resolvePerMember(facts: facts, tag: amountTag)
        guard !perMember.isEmpty else { return nil }

        return buildCountBasisSnapshot(
            perMember: perMember, amountTag: amountTag, total: total, axis: axis,
            warningPrefix: warningPrefix, labelsByTag: labelsByTag)
    }

    /// のれんのセグメント別内訳（内訳取り込み goodwill 軸、2026-08-12追加）。
    /// `normalizeCountBasis` と異なり、候補タグ（`Xbrl.goodwillSegmentTags`）は「最初に現れたタグ」
    /// ではなく「セグメント dimension 付き fact を実際に持つ最初のタグ」を選ぶ。実データ検証
    /// （三井住友・三菱UFJ）: 全社合計は無dimensionの`Goodwill`タグにしか無く、セグメント別内訳は
    /// 別タグ`GoodwillBeforeOffsetting`にしかない（同一タグの中に両方が同居するオークマ型とは限らない）。
    /// `normalizeCountBasis`のタグ選択（"最初に現れる"）だと`Goodwill`が先に見つかった時点で確定し、
    /// dimension付きfactを1件も持たないまま`perMember`が空になり誤ってnilを返してしまう。
    static func normalizeGoodwill(
        facts: [BreakdownFact], total: Double?, totalTag: String? = nil, axis: String,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        var amountTag: String?
        var perMember: [String: BreakdownFact] = [:]
        for tag in Xbrl.goodwillSegmentTags {
            let candidate = resolvePerMember(facts: facts, tag: tag)
            if !candidate.isEmpty {
                amountTag = tag
                perMember = candidate
                break
            }
        }
        guard let amountTag, !perMember.isEmpty else { return nil }

        return buildCountBasisSnapshot(
            perMember: perMember, amountTag: totalTag ?? amountTag, total: total, axis: axis,
            warningPrefix: "goodwill", labelsByTag: labelsByTag)
    }

    /// 「報告セグメントごとの情報」に載る数値指標を、指標ごとの breakdown 軸へ正規化する。
    /// 全社合計 fact があればそれを分母に使い、無ければセグメント行＋調整行の合計を
    /// 決定論で分母にする。いずれも `denominatorTag` には実際に採用したタグ名を残す。
    private static func normalizeSegmentMetric(
        facts: [BreakdownFact], amountTags: [String], axis: String, warningPrefix: String,
        labelsByTag: [String: String]
    ) -> BreakdownSnapshot? {
        guard let amountTag = amountTags.first(where: { tag in
            !resolvePerMember(facts: facts, tag: tag).isEmpty
        }) else { return nil }
        let perMember = withEntityTotal(
            resolvePerMember(facts: facts, tag: amountTag), facts: facts, tag: amountTag)
        guard !perMember.isEmpty else { return nil }
        let total = resolveEntityTotal(facts: facts, tag: amountTag)?.value
        return buildCountBasisSnapshot(
            perMember: perMember, amountTag: amountTag, total: total, axis: axis,
            warningPrefix: warningPrefix, labelsByTag: labelsByTag,
            warnOnDerivedTotal: true, useEntityTotalAsDenominator: false,
            useTableSubtotalForDerivedTotal: true)
    }

    /// セグメント資産。
    static func normalizeSegmentAssets(
        facts: [BreakdownFact], axis: String = breakdownAxisSegmentAssets,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        normalizeSegmentMetric(
            facts: facts, amountTags: Xbrl.segmentAssetsTags, axis: axis,
            warningPrefix: "segment_assets", labelsByTag: labelsByTag)
    }

    /// 減価償却費及び償却費。
    static func normalizeDepreciationAndAmortization(
        facts: [BreakdownFact], axis: String = breakdownAxisDepreciationAndAmortization,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        normalizeSegmentMetric(
            facts: facts, amountTags: Xbrl.segmentDepreciationAndAmortizationTags, axis: axis,
            warningPrefix: "depreciation_and_amortization", labelsByTag: labelsByTag)
    }

    /// のれんの償却額。
    static func normalizeGoodwillAmortization(
        facts: [BreakdownFact], axis: String = breakdownAxisGoodwillAmortization,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        normalizeSegmentMetric(
            facts: facts, amountTags: Xbrl.segmentGoodwillAmortizationTags, axis: axis,
            warningPrefix: "goodwill_amortization", labelsByTag: labelsByTag)
    }

    /// 減損損失。
    static func normalizeImpairmentLoss(
        facts: [BreakdownFact], axis: String = breakdownAxisImpairmentLoss,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        normalizeSegmentMetric(
            facts: facts, amountTags: Xbrl.segmentImpairmentLossTags, axis: axis,
            warningPrefix: "impairment_loss", labelsByTag: labelsByTag)
    }

    /// 持分法会計処理される投資。
    static func normalizeEquityMethodInvestments(
        facts: [BreakdownFact], axis: String = breakdownAxisEquityMethodInvestments,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        normalizeSegmentMetric(
            facts: facts, amountTags: Xbrl.segmentEquityMethodInvestmentTags, axis: axis,
            warningPrefix: "equity_method_investments", labelsByTag: labelsByTag)
    }

    /// 資本的支出。
    static func normalizeCapitalExpenditures(
        facts: [BreakdownFact], axis: String = breakdownAxisCapitalExpenditures,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        normalizeSegmentMetric(
            facts: facts, amountTags: Xbrl.segmentCapitalExpenditureTags, axis: axis,
            warningPrefix: "capital_expenditures", labelsByTag: labelsByTag)
    }

    /// notes「設備投資等の概要」のCapex。報告セグメント表の資本的支出とは別軸。
    static func normalizeCapitalExpendituresOverview(
        facts: [BreakdownFact], axis: String = breakdownAxisCapitalExpendituresOverview,
        total: Double? = nil, totalTag: String? = nil, labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        if let snapshot = normalizeSegmentMetric(
            facts: facts, amountTags: Xbrl.capexOverviewTags, axis: axis,
            warningPrefix: "capital_expenditures_overview", labelsByTag: labelsByTag)
        {
            return snapshot
        }
        guard let total, total > 0 else { return nil }
        return BreakdownSnapshot(
            axis: axis, denominator: total, denominatorTag: totalTag ?? "company_financials",
            rows: [], sourceKind: "xbrl_facts", needsReview: false, warnings: [])
    }

    /// notes「設備投資等の概要」HTML表をbreakdown契約へ写す。
    /// 前年度比は移さず、設備内容・目的だけを description として保持する。
    static func normalizeCapitalExpendituresOverview(
        segments: [CapexSegmentPayload],
        axis: String = breakdownAxisCapitalExpendituresOverview
    ) -> BreakdownSnapshot? {
        guard !segments.isEmpty else { return nil }
        // segmentName=nil の単一総額fallbackは denominator-only とする。
        if segments.allSatisfy({ $0.segmentName == nil }) {
            guard let total = segments.compactMap(\.investmentAmount).first, total > 0 else {
                return nil
            }
            return BreakdownSnapshot(
                axis: axis, denominator: total,
                denominatorTag: "CapitalExpendituresOverviewOfCapitalExpendituresEtc",
                rows: [], sourceKind: "html_table", needsReview: false, warnings: [])
        }

        let rows = segments.compactMap { segment -> BreakdownRow? in
            guard let name = segment.segmentName, let amount = segment.investmentAmount else {
                return nil
            }
            let normalized = name.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
            let rowKind: String
            if segment.isTotal {
                rowKind = "subtotal"
            } else if normalized.contains("調整") || normalized == "全社" || normalized == "全社(共通)" {
                rowKind = "reconciling"
            } else {
                rowKind = "segment"
            }
            return BreakdownRow(
                labelRaw: name, label: name, amount: amount, share: nil, profit: nil,
                rowKind: rowKind, description: segment.description)
        }
        guard !rows.isEmpty else { return nil }
        let totalRow = rows.last { $0.rowKind == "subtotal" }
        let denominator: Double
        var warnings: [String] = []
        if let total = totalRow?.amount, total > 0 {
            denominator = total
        } else {
            denominator = rows
                .filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
                .map(\.amount).reduce(0, +)
            warnings.append("capital_expenditures_overview_denominator_derived_from_segment_sum")
        }
        guard denominator > 0 else { return nil }
        var resolvedRows = rows
        for index in resolvedRows.indices {
            resolvedRows[index].share = resolvedRows[index].amount / denominator
        }
        return BreakdownSnapshot(
            axis: axis, denominator: denominator,
            denominatorTag: "CapitalExpendituresOverviewOfCapitalExpendituresEtc",
            rows: resolvedRows, sourceKind: "html_table",
            needsReview: !warnings.isEmpty, warnings: warnings)
    }

    /// 非流動性資産への追加額。
    static func normalizeNoncurrentAssetAdditions(
        facts: [BreakdownFact], axis: String = breakdownAxisNoncurrentAssetAdditions,
        labelsByTag: [String: String] = [:]
    ) -> BreakdownSnapshot? {
        normalizeSegmentMetric(
            facts: facts, amountTags: Xbrl.segmentNoncurrentAssetAdditionTags, axis: axis,
            warningPrefix: "noncurrent_asset_additions", labelsByTag: labelsByTag)
    }

    /// `normalizeCountBasis`/`normalizeGoodwill` 共通の後処理（member 分類・分母解決・行組み立て）。
    /// `amountTag`（`denominatorTag`として使う）は呼び出し側がタグ選択方式ごとに解決済みの値を渡す
    /// （`normalizeGoodwill` は全社合計の実タグ名=`totalTag` を優先し、無ければセグメント側タグに
    /// フォールバックする——セグメント別内訳タグと全社合計タグが別物のケースがあるため）。
    private static func buildCountBasisSnapshot(
        perMember: [String: BreakdownFact], amountTag: String, total: Double?, axis: String,
        warningPrefix: String, labelsByTag: [String: String], warnOnDerivedTotal: Bool = true,
        useEntityTotalAsDenominator: Bool = true,
        useTableSubtotalForDerivedTotal: Bool = false
    ) -> BreakdownSnapshot? {
        var kinds: [String: String] = [:]
        for member in perMember.keys {
            if Xbrl.segmentReconcilingMemberNames.contains(member)
                || countBasisAdditiveBucketMemberNames.contains(member)
            {
                kinds[member] = "reconciling"
            } else if Xbrl.segmentSubtotalMemberNames.contains(member) {
                kinds[member] = "subtotal"
            } else {
                kinds[member] = "segment"
            }
        }
        promoteSoleReportableSegmentsMember(kinds: &kinds)
        var amounts: [String: Double] = [:]
        for (member, fact) in perMember {
            amounts[member] = fact.value
        }
        demoteRedundantParentSegments(kinds: &kinds, amounts: amounts, total: total)
        applyEliminationSign(amounts: &amounts, kinds: kinds, total: total)

        // 合計チェック・フォールバック分母は segment に加え reconciling（本社機能等の少額バケツ）も
        // 算入する。subtotal（代替総合計 member）だけは二重計上を避けるため除外する。
        let reconciledKinds: Set<String> = ["segment", "reconciling"]

        var warnings: [String] = []
        let denominator: Double
        if useEntityTotalAsDenominator, let total, total > 0 {
            denominator = total
            let segmentSum = amounts.keys.filter { reconciledKinds.contains(kinds[$0]!) }
                .reduce(0.0) { $0 + amounts[$1]! }
            if segmentSum > 0, abs(segmentSum - total) / total > 0.05 {
                warnings.append("\(warningPrefix)_segment_sum_far_from_total")
            }
        } else {
            let derived: (value: Double, corroborated: Bool)
            if useTableSubtotalForDerivedTotal {
                derived = deriveTableMetricDenominator(kinds: kinds, amounts: amounts)
            } else {
                let value = amounts.keys.filter { reconciledKinds.contains(kinds[$0]!) }
                    .reduce(0.0) { $0 + amounts[$1]! }
                derived = (value: value, corroborated: false)
            }
            denominator = derived.value
            if warnOnDerivedTotal && !derived.corroborated {
                warnings.append("\(warningPrefix)_denominator_derived_from_segment_sum")
            }
            if !useEntityTotalAsDenominator,
                let entityTotal = amounts[Xbrl.entityTotalMemberName],
                denominator > 0
            {
                let scale = max(1.0, abs(entityTotal), abs(denominator))
                if abs(entityTotal - denominator) / scale > 0.05 {
                    warnings.append("\(warningPrefix)_entity_total_differs_from_table_total")
                }
            }
        }
        guard denominator > 0 else { return nil }

        let rows = perMember.keys.sorted().map { member -> BreakdownRow in
            let amount = amounts[member]!
            return BreakdownRow(
                labelRaw: member, label: labelsByTag[member], amount: amount,
                share: amount / denominator, profit: nil, rowKind: kinds[member]!)
        }

        return BreakdownSnapshot(
            axis: axis, denominator: denominator, denominatorTag: amountTag, rows: rows,
            sourceKind: "xbrl_facts", needsReview: !warnings.isEmpty, warnings: warnings)
    }

    /// 「計/合計」と調整行から、表示用の連結計上額相当値を決定する。
    /// 抽出factを書き換えず、明示された subtotal/reconciling 行はそのまま保持する。
    private static func deriveTableMetricDenominator(
        kinds: [String: String], amounts: [String: Double]
    ) -> (value: Double, corroborated: Bool) {
        let segmentSum = amounts.keys
            .filter { kinds[$0] == "segment" }
            .reduce(0.0) { $0 + amounts[$1]! }
        let reconcilingSum = amounts.keys
            .filter { kinds[$0] == "reconciling" }
            .reduce(0.0) { $0 + amounts[$1]! }
        let reconciledSum = segmentSum + reconcilingSum
        let subtotalValues = amounts.keys
            .filter { kinds[$0] == "subtotal" }
            .map { amounts[$0]! }
        guard let subtotal = subtotalValues.min(by: {
            abs($0 - reconciledSum) < abs($1 - reconciledSum)
        }) else {
            return (reconciledSum, false)
        }

        let reconciledScale = max(1.0, abs(subtotal), abs(reconciledSum))
        if abs(subtotal - reconciledSum) / reconciledScale <= 0.05 {
            return (subtotal, true)
        }
        let segmentScale = max(1.0, abs(subtotal), abs(segmentSum))
        if abs(subtotal - segmentSum) / segmentScale <= 0.05 {
            return (subtotal + reconcilingSum, true)
        }
        return (reconciledSum, false)
    }

    /// 報告セグメント fact が `ReportableSegmentsMember` 親だけ（子 member の人数・費用が無く、
    /// 残る segment はその他事業のみ）のとき、親を segment 行に昇格する。
    /// 実データ: エーザイ S100YB05 従業員は医薬品事業 9,832 人が親 member に載り、
    /// `OperatingSegmentsNotIncluded…` 711 人だけが segment 扱いになって needs_review になっていた。
    private static func promoteSoleReportableSegmentsMember(kinds: inout [String: String]) {
        guard kinds[countBasisReportableSegmentsMemberName] == "subtotal" else { return }
        let segmentMembers = kinds.keys.filter { kinds[$0] == "segment" }
        guard segmentMembers.allSatisfy({ Xbrl.segmentOtherBusinessMemberNames.contains($0) }) else {
            return
        }
        kinds[countBasisReportableSegmentsMemberName] = "segment"
    }

    /// 子セグメントと同居する親小計を subtotal へ落とす。含めると分母から 5% 超ずれ、
    /// その1 member を除外すると ±5% に収まる場合のみ（候補が複数なら触らない）。
    /// 実データ: 花王 S100XT6G 従業員の `GlobalConsumerCareBusinessReportableSegmentMember`
    /// は化粧品・HBC・ハイジーンの親であり、除外すると全社 31,514 人と一致する。
    private static func demoteRedundantParentSegments(
        kinds: inout [String: String], amounts: [String: Double], total: Double?
    ) {
        guard let total, total > 0 else { return }
        let included = reconciledAmount(kinds: kinds, amounts: amounts)
        guard included > 0, abs(included - total) / total > 0.05 else { return }

        let candidates = amounts.keys.filter { kinds[$0] == "segment" }.filter { member in
            var trial = kinds
            trial[member] = "subtotal"
            let sum = reconciledAmount(kinds: trial, amounts: amounts)
            return sum > 0 && abs(sum - total) / total <= 0.05
        }
        guard candidates.count == 1, let parent = candidates.first else { return }
        kinds[parent] = "subtotal"
    }

    /// `UnallocatedAmountsAndEliminationMember` を足すと分母からずれ、引くと ±5% に収まるとき
    /// 符号を反転する（NTT S100YCP3 のセグメント間取引消去）。足す方が合う場合は正のまま
    /// （味の素 S100VXJA の未配賦 R&D）。
    private static func applyEliminationSign(
        amounts: inout [String: Double], kinds: [String: String], total: Double?
    ) {
        guard let total, total > 0 else { return }
        let member = countBasisEliminationMemberName
        guard kinds[member] == "reconciling", let value = amounts[member], value != 0 else { return }

        var without = kinds
        without[member] = "subtotal"
        let sumExcl = reconciledAmount(kinds: without, amounts: amounts)
        let addErr = abs(sumExcl + value - total) / total
        let subErr = abs(sumExcl - value - total) / total
        if subErr <= 0.05, addErr > 0.05 {
            amounts[member] = -abs(value)
        }
    }

    private static func reconciledAmount(kinds: [String: String], amounts: [String: Double]) -> Double {
        let reconciledKinds: Set<String> = ["segment", "reconciling"]
        return amounts.keys.filter { reconciledKinds.contains(kinds[$0] ?? "") }
            .reduce(0.0) { $0 + amounts[$1]! }
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

    /// セグメント dimension が付かない当期の全社合計 fact（表の「連結財務諸表計上額」列）。
    /// `resolvePerMember` は primaryMember 必須のため、ここでのみ拾う。
    /// employees / rd の人数・費用基準は呼ばない（既存の全社合計は呼び出し側の `total`）。
    private static func resolveEntityTotal(facts: [BreakdownFact], tag: String) -> BreakdownFact? {
        let candidateFacts = facts.filter {
            $0.tag == tag && isCurrentPeriod($0.contextRef) && primaryMember($0.dimensions) == nil
        }
        let consolidatedFacts = candidateFacts.filter(isConsolidated)
        let source = consolidatedFacts.isEmpty ? candidateFacts : consolidatedFacts
        return source.sorted { $0.contextRef < $1.contextRef }.first
    }

    private static func withEntityTotal(
        _ perMember: [String: BreakdownFact], facts: [BreakdownFact], tag: String
    ) -> [String: BreakdownFact] {
        guard perMember[Xbrl.entityTotalMemberName] == nil,
              let entity = resolveEntityTotal(facts: facts, tag: tag)
        else { return perMember }
        var result = perMember
        result[Xbrl.entityTotalMemberName] = entity
        return result
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
    /// 裸の地域行が1件だけ事業名と混在するケース（例: Foods + Japan）は従来どおり needs_review。
    /// 裸の地域が複数かつ非地域の専門事業が同居する NXHD 型は下記で免除する。
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
        if bareSpecificGeoMatches.isEmpty { return ("business", false) }

        // NXHD型: ロジスティクスを日本/米州/欧州/東アジア/南アジア・オセアニアに展開し、
        // 警備輸送・重量品建設・物流サポート等の専門事業と同居する。裸の地域行はロジスティクスの
        // 地域内訳であり、事業軸として採用する（ユーザー確認 2026-07-25、S100XTG8）。
        // 資生堂型の JapanBusiness / AmericasBusiness ラッパは「Business」を含むため除外する
        // （学び11。ラッパ付き裸地域を件数だけで免除すると資生堂型の要レビューが消える。
        // Opus 監査 2026-07-25）。
        // 地域が1件だけの混在（Foods + Japan 等）は表取り違えの疑いが残るため要レビューのまま。
        //
        // 非地域の実質事業の最低件数を1件から2件に厳格化する。旧条件（裸地域2件以上 かつ
        // 非地域事業1件以上）は、エーザイ旧filings（Americas/AsiaAndLatinAmerica/China/
        // EMEA/Japanの地域5member + 残余バケツ「OTCAndOthers」1件）にも誤って一致し、
        // 地域別データが axis=business, needs_review=false のまま確定していた（本番Neon実データ
        // 確認、Opus監査 finding #2、2026-07-25）。裸地域2件以上の要件は維持する（外すと
        // 「Foods + Chemicals + Japan」のような1地域だけの混在まで免除されてしまい、
        // 既存の表取り違え検知回帰が壊れる）。非地域事業を2件以上に上げると、NXHD
        // （DistributionSupport/HeavyHaulageAndConstruction/SecurityTransportationの3件）は
        // 免除が維持され、エーザイ旧filings（残余バケツ1件のみ）は免除が外れて
        // needs_review が正しく立つ。
        let nonGeographyBusinessMembers = segmentMembers.filter { member in
            !Xbrl.segmentGeographyMemberKeywords.contains(where: member.contains)
                && hasSubstantiveNonGeographyContent(member)
        }
        let bareGeoWithoutBusinessWrapper = bareSpecificGeoMatches.filter { !$0.contains("Business") }
        if bareGeoWithoutBusinessWrapper.count >= 2, nonGeographyBusinessMembers.count >= 2 {
            return ("business", false)
        }
        return ("business", true)
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
