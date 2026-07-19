// geography（地域別情報）/ business（事業別・製品別情報）の html_table 結果を
// LLM で BreakdownSnapshot へ正規化する。docs/segment-normalization-concept.md 参照。
// SegmentNormalizer.swift（xbrl_facts 経路）とは別経路。会社ごとに表の向き・表数・
// 見出しキーワードの取り違えが不揃いなため、表全体（markdown）を LLM に渡して構造化させ、
// Swift 側は単位変換・分母整合性・ラベル妥当性のみ決定的に検証する（契約検証の増分。
// ingest/CLI/REST 配線は対象外）。
//
// business 軸は2種類の入力を想定する（今後の検討事項3）:
//   - segments キーが html_table のケース（例: キヤノンの US-GAAP 注23。事業名が列見出し、
//     行が指標という向きのため、LLM が「外部顧客向け」行を転置して1事業=1行にする）
//   - segments の axis が geography 判定になるケース（オークマ型）で、収益認識注記
//     （`SegmentExtractor.extractRevenueRecognitionInfo`）から拾う製品別内訳

import Foundation

/// LLM がどの表・どの期間列・どの単位を採用したかの監査情報（目視検証用）。
/// `BreakdownSnapshot` 自体（xbrl_facts 経路と共有する契約型）は汚さず、別チャネルで返す。
struct LLMBreakdownAudit {
    var sourceTableIndex: Int?
    var periodColumn: String?
    var unit: String
    /// 表がそもそも事業別/製品別の利益情報を含んでいたか（LLM の自己申告）。
    /// `BreakdownRow.profit == nil` だけでは「未開示（確認済み）」と「LLM が見落とした・非該当」を
    /// 区別できないため、この申告と実際の rows の整合性を決定的に検証する
    /// （`profit_disclosed_but_row_missing` / `profit_present_despite_not_disclosed` 警告）。
    var profitDisclosed: Bool
    var notes: String
}

enum SegmentBreakdownLLMNormalizer {

    private static let geographySystemPrompt = """
    あなたは日本の有価証券報告書の「地域ごとの情報」注記から、地域別の外部売上（または相当する主要指標）を構造化するアシスタントです。

    入力として、同一書類から抽出された地域別注記の候補テーブル（Markdown形式、見出し・期間ラベル・表インデックス付き）と、
    連結の外部売上高（円単位、比較の分母）が与えられます。

    ルール:
    - 候補テーブルが複数ある場合、連結売上高との整合性が最も高い表・列（多くは「当期」列）を選ぶこと。前期・当期の両方が1つの表に列として並んでいる場合は当期列を選ぶこと
    - **見出しが2段以上に分かれている表（例: 1段目が「アジア」「米州」等の広い区分、2段目が「タイ」「その他」「米国」「その他」等の細かい区分）では、必ず最も粒度の細かい行を採用すること。広い区分へ集約してはならない。行ラベルは2段目（最も内側）の区分名をそのまま使うこと（例: 「アジア」「タイ」の2段なら「タイ」、「アジア」「その他」の2段なら「アジアその他」のように、上位区分と下位区分をつなげた名前にすること）**
    - 行ラベルは「日本」「米国」「欧州」「アジア」等の地域名であるべきで、事業名・製品名ではないこと。地域別注記のはずが実際には事業別の表（見出しの取り違え）である場合は applicable=false を返すこと
    - 表の金額単位を判定し、unit フィールドに "yen"（円） / "million_yen"（百万円） / "other" のいずれかを申告すること。日本の有価証券報告書の注記は「（単位：百万円）」の表記が最も一般的
    - 合計・小計・連結合計を表す行は row_kind="subtotal" とし、除去・消去を表す行は row_kind="reconciling" とすること。純粋な地域区分の行は row_kind="segment" とすること
    - 該当する地域別データが候補テーブル群に存在しない場合は applicable=false を返すこと
    - profit フィールドは常に null、profit_disclosed は常に false にすること（地域別の比較では利益は対象外）
    - notes フィールドに、表選択・期間列選択の根拠を短く日本語で記すこと
    """

    private static let businessSystemPrompt = """
    あなたは日本の有価証券報告書の注記から、事業別・製品別の外部売上（または相当する主要指標）を構造化するアシスタントです。

    入力として、同一書類から抽出された候補テーブル（Markdown形式、見出し・期間ラベル・表インデックス付き）と、
    連結の外部売上高（円単位、比較の分母）が与えられます。候補テーブルの出所は「事業別セグメント情報」（US-GAAP注記等、
    事業名が列見出しになっている場合がある）や「収益認識注記の製品別内訳」など書類によって様々で、無関係な表
    （債権残高・契約負債の期首期末残高など）が混ざっていることもある。

    ルール:
    - 候補テーブルが複数ある場合、連結売上高との整合性が最も高い表・期間列（多くは「当期」列）を選ぶこと。売上に関係しない表（債権・契約負債の残高等）は無視すること
    - 事業名・製品名が表の列見出しになっている場合（各列が1事業に対応し、行が売上高・利益等の指標になっている表）は、外部顧客向け売上高の行を選び、各列見出しを行ラベルとして1事業=1行になるよう転置して出力すること
    - 事業名・製品名が表の行になっている場合（1行=1事業/製品の単純な表）はそのまま行として使うこと。「顧客との契約から生じる収益」「外部顧客への売上高」等の集計行は row_kind="subtotal" とすること
    - 売上と同じ表内に事業別・製品別の営業利益（またはセグメント利益に相当する指標。例:「営業利益」「税引前当期純利益」）が並んで開示されている場合は、売上行と同じ転置ルールで対応する profit フィールドに設定し、profit_disclosed を true にすること。該当する利益指標がその表に存在しない場合（収益認識注記の製品別売上高表など、利益が開示されていない表が多い）は profit を null のままにし、profit_disclosed を false にすること。無関係な指標（総資産・減価償却費等）を流用してはならない
    - profit_disclosed は「この表に利益情報が存在するか」の申告であり、rows の profit 値と矛盾させないこと（true なら最低1行は profit を埋めること、false なら全行 null のままにすること）
    - 前期・当期の両方が1つの表に列として並んでいる場合は当期列を選ぶこと
    - 行ラベルは事業名・製品名であるべきで、地域名ではないこと。事業別のはずが実際には地域別の表（見出しの取り違え）である場合は applicable=false を返すこと
    - 表の金額単位を判定し、unit フィールドに "yen"（円） / "million_yen"（百万円） / "other" のいずれかを申告すること
    - 合計・小計・連結合計を表す行は row_kind="subtotal" とし、除去・消去を表す行は row_kind="reconciling" とすること。純粋な事業・製品区分の行は row_kind="segment" とすること
    - 該当する事業別データが候補テーブル群に存在しない場合は applicable=false を返すこと
    - notes フィールドに、表選択・期間列選択・転置有無の根拠を短く日本語で記すこと
    """

    // 中身は文字列・数値・配列・辞書のリテラルのみで実質不変（生成後に変更しない）。
    // `Any` を含むため Sendable 判定はできないが、共有可変状態は無い。
    nonisolated(unsafe) private static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "applicable": ["type": "boolean"],
            "unit": ["type": "string", "enum": ["yen", "million_yen", "other"]],
            "source_table_index": ["type": "integer"],
            "period_column": ["type": "string"],
            "profit_disclosed": ["type": "boolean"],
            "rows": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "label": ["type": "string"],
                        "amount": ["type": "number"],
                        "profit": ["type": ["number", "null"]],
                        "row_kind": ["type": "string", "enum": ["segment", "subtotal", "reconciling"]],
                    ],
                    "required": ["label", "amount", "profit", "row_kind"],
                    "additionalProperties": false,
                ],
            ],
            "notes": ["type": "string"],
        ],
        "required": ["applicable", "unit", "source_table_index", "period_column", "profit_disclosed", "rows", "notes"],
        "additionalProperties": false,
    ]

    /// 分母整合性チェックの許容範囲。xbrl_facts 経路（0.95...1.05）より広め。
    /// html_table は「注記の仕向地合計」と「損益計算書の売上」が数%ずれることがある
    /// （実データ: キヤノン地域別注記の計 4,509,821 百万円 vs 連結売上 4,624,727 百万円 ≈ 2.5%差）。
    private static let denominatorTolerance = 0.90...1.10

    /// geography/business の SegmentResult（html_table）と連結外部売上から BreakdownSnapshot を組み立てる。
    /// axis は "geography" | "business"。呼び出し側が「どの軸を期待しているか」を渡す
    /// （SegmentResult 自体は軸を持たないため。オークマ型の segments=geography 判定・
    /// 収益認識注記フォールバックの判断は呼び出し側の責務のまま変えない）。
    /// LLM 呼び出し失敗・非該当・パース不能の場合は snapshot=nil。
    /// audit は LLM が実際に選んだ表・期間列・単位・判断根拠（目視検証用。呼び出し失敗時のみ nil）。
    static func normalize(
        _ result: SegmentResult, axis: String, consolidatedSales: Double?, client: ChatCompleting
    ) async -> (snapshot: BreakdownSnapshot?, audit: LLMBreakdownAudit?) {
        guard result.method == "html_table", !result.tables.isEmpty,
              let consolidatedSales, consolidatedSales != 0 else { return (nil, nil) }

        let userPrompt = buildUserPrompt(tables: result.tables, consolidatedSales: consolidatedSales)

        guard let jsonSchemaData = try? JSONSerialization.data(withJSONObject: jsonSchema) else { return (nil, nil) }

        let response: [String: Any]
        do {
            let responseData = try await client.complete(
                system: axis == "business" ? businessSystemPrompt : geographySystemPrompt,
                user: userPrompt,
                jsonSchema: jsonSchemaData,
                schemaName: axis == "business" ? "business_breakdown" : "geography_breakdown"
            )
            guard let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return (nil, nil)
            }
            response = parsed
        } catch {
            return (nil, nil)
        }

        let unit = response["unit"] as? String ?? "other"
        // geography 軸は profit 対象外（学び参照）。プロンプトでも指示するが、LLM の自己申告だけに
        // 頼らずここでも固定する（Fable監査指摘: プロンプト任せにしない決定的ガード）。
        // キー欠落・型不正は「未開示（確認済み）」ではなく「不明」なので、下で silent に false 扱い
        // せず llm_profit_disclosed_unresolved を立てる（unit の "other" フラグ付けと同じ考え方）。
        let profitDisclosedRaw = response["profit_disclosed"] as? Bool
        let profitDisclosed = axis == "business" && (profitDisclosedRaw ?? false)
        let audit = LLMBreakdownAudit(
            sourceTableIndex: (response["source_table_index"] as? NSNumber)?.intValue,
            periodColumn: response["period_column"] as? String,
            unit: unit,
            profitDisclosed: profitDisclosed,
            notes: response["notes"] as? String ?? ""
        )

        guard let applicable = response["applicable"] as? Bool, applicable,
              let rawRows = response["rows"] as? [[String: Any]], !rawRows.isEmpty
        else { return (nil, audit) }
        var warnings: [String] = []
        var needsReview = false

        if axis == "business" && profitDisclosedRaw == nil {
            needsReview = true
            warnings.append("llm_profit_disclosed_unresolved")
        }

        let unitMultiplier: Double
        switch unit {
        case "yen":
            unitMultiplier = 1
        case "million_yen":
            unitMultiplier = Financial.millionYen
        default:
            unitMultiplier = 1
            needsReview = true
            warnings.append("llm_unit_unresolved")
        }

        var rows: [BreakdownRow] = []
        for raw in rawRows {
            guard let label = raw["label"] as? String,
                  let rawAmount = (raw["amount"] as? NSNumber)?.doubleValue,
                  let rowKind = raw["row_kind"] as? String
            else { continue }
            // profit は任意（JSON null も許容。null なら raw["profit"] as? NSNumber が自然に nil になる）。
            // geography 軸は常に nil に固定する（プロンプト任せにしない。上の profitDisclosed 算出と同じ理由）。
            let rawProfit = axis == "business" ? (raw["profit"] as? NSNumber)?.doubleValue : nil
            rows.append(BreakdownRow(
                labelRaw: label, amount: rawAmount * unitMultiplier, share: nil,
                profit: rawProfit.map { $0 * unitMultiplier }, rowKind: rowKind
            ))
        }
        guard !rows.isEmpty else { return (nil, audit) }

        // profit_disclosed の自己申告と実際の rows の整合性チェック（決定的）。
        // 「未開示（確認済み）」と「LLM が見落としただけ」を区別する主目的のフィールドが
        // rows と矛盾していては意味がないため、矛盾自体を needs_review で拾う。
        let hasAnySegmentProfit = rows.contains { $0.rowKind == "segment" && $0.profit != nil }
        if profitDisclosed && !hasAnySegmentProfit {
            needsReview = true
            warnings.append("profit_disclosed_but_row_missing")
        } else if !profitDisclosed && hasAnySegmentProfit {
            needsReview = true
            warnings.append("profit_present_despite_not_disclosed")
        }

        // ラベル妥当性チェック（決定的、追加ガード）。分母一致だけでは表の取り違えを検知できないため
        // （例: 誤って選ばれた事業別表の合計が、地域別表の合計とたまたま一致するケース）。
        // 「その他」はキーワードに含めない — 事業別表にも「その他及び全社」等の形でほぼ必ず
        // 出現するため、これを含めると事業別表の取り違えをすり抜けさせてしまう
        // （固有の地域名が最低1つ一致することを要求する設計を骨抜きにする）。
        let segmentLabels = rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        if axis == "geography" {
            let hasGeographyLikeLabel = segmentLabels.contains { label in
                Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
            }
            if !hasGeographyLikeLabel {
                needsReview = true
                warnings.append("geography_label_mismatch")
            }
        } else {
            // business の裏返し: 全行が地域名に一致するなら、地域別の表を誤って business として
            // 採用した疑いがある（geography 側と対称のガード）。「その他」「その他の地域」を含む
            // ラベルは判定から除外する — 実在の地域別表にはほぼ必ず存在し、これを残したまま
            // allSatisfy すると地域名だけの表（例: 国内/米州/欧州/アジア/その他の地域）でも
            // 「その他の地域」1件の不一致でガードが素通りしてしまう（false negative）。
            let labelsExcludingOther = segmentLabels.filter { !$0.contains("その他") }
            let allLabelsLookLikeGeography = !labelsExcludingOther.isEmpty && labelsExcludingOther.allSatisfy { label in
                Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
            }
            if allLabelsLookLikeGeography {
                needsReview = true
                warnings.append("business_label_looks_like_geography")
            }
        }

        // 分母整合性チェック。
        let segmentShare = rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount } / consolidatedSales
        if !denominatorTolerance.contains(segmentShare) {
            needsReview = true
            warnings.append("llm_row_sum_mismatch")
        }

        let rowsWithShare = rows.map { row -> BreakdownRow in
            var r = row
            r.share = r.amount / consolidatedSales
            return r
        }

        let snapshot = BreakdownSnapshot(
            axis: axis,
            denominator: consolidatedSales,
            denominatorTag: "income_statement.sales",
            rows: rowsWithShare,
            sourceKind: "html_table",
            needsReview: needsReview,
            warnings: warnings
        )
        return (snapshot, audit)
    }

    private static func buildUserPrompt(tables: [SegmentTable], consolidatedSales: Double) -> String {
        var lines: [String] = []
        lines.append("連結外部売上高（円、比較の分母）: \(Int(consolidatedSales))")
        lines.append("")
        lines.append("候補テーブル:")
        for (index, table) in tables.enumerated() {
            lines.append("--- table_index=\(index) heading=\(table.heading) period=\(table.period ?? "不明") ---")
            lines.append(table.markdown)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
