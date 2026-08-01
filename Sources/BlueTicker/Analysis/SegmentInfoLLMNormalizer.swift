// `segments` キー自体が html_table を返すケース（例: キヤノンの US-GAAP 連結注記23。事業名が
// 列見出しで指標が行という向きの表が、巨大注記内に直接内包されている）の html_table 結果を
// LLM で BreakdownSnapshot（axis:"business"）へ正規化する。
// docs/breakdown-normalization-concept.md 参照。GeographyBreakdownLLMNormalizer.swift（geography 用）・
// RevenueRecognitionLLMNormalizer.swift（オークマ型、収益認識注記由来）と同型だが、対象は
// `segments` キー自体（オークマ型のような axis-aware swap を経ていない、素の segments 結果）
// が html_table になっているケース。
//
// ライブ read 経路（REST/MCP）や ingest には配線しない（他の LLM 正規化器と同じ理由。
// concept doc で確定済み: LLM は financials/filing-sections と同じ ingest バッチ経路に置く方針だが、
// 永続化スキーマ配線自体は今後の検討事項1で未着手）。

import Foundation

enum SegmentInfoLLMNormalizer {

    private static let systemPrompt = """
    あなたは日本の有価証券報告書の「セグメント情報」注記（US-GAAP連結注記に内包されている場合を含む）および
    「製品・サービス別情報」（サービス毎の情報を含む）から、
    事業別・製品別の外部売上（または相当する主要指標）を構造化するアシスタントです。

    入力として、同一書類から抽出された候補テーブル（Markdown形式、見出し・期間ラベル・表インデックス付き）と、
    連結の外部売上高（円単位、比較の分母）が与えられます。候補テーブルには無関係な表
    （債権残高・契約負債の期首期末残高など）が混ざっていることもある。
    分母は一般事業会社では売上高、銀行等では経常収益など売上に代わる指標のことがある。

    ルール:
    - 候補テーブルが複数ある場合、連結売上高（または分母として与えられた経常収益等）との整合性が最も高い表・期間列（多くは「当期」列）を選ぶこと。売上に関係しない表は無視すること
    - 「製品及びサービスごとの情報」「製品・サービス別情報」「サービス毎の情報」など製品名・サービス名が行または列にある表がある場合は、地域別の報告セグメント表よりそちらを優先すること
    - 銀行・信託では次を売上相当として採用してよい: 「外部顧客に対する経常収益」「経常収益」「実質業務粗利益」「連結粗利益」「業務粗利益」。売上総利益だけの表や地域別経常収益表より、事業・サービス別のこれらの指標を優先すること
    - 事業名・製品名が表の列見出しになっている場合（各列が1事業に対応し、行が売上高・利益等の指標になっている表）は、外部顧客向け売上高（または上記の売上相当行）を選び、各列見出しを行ラベルとして1事業=1行になるよう転置して出力すること
    - 事業名・製品名が表の行になっている場合（1行=1事業/製品の単純な表）はそのまま行として使うこと。地域名の行（日本／北米等）は製品別表の中にあっても row_kind="segment" の製品行としては使わず、製品行だけを出力すること
    - 売上と同じ表内に事業別・製品別の営業利益（またはセグメント利益に相当する指標。例:「営業利益」「税引前当期純利益」「実質業務純益」）が並んで開示されている場合は、売上行と同じ転置ルールで対応する profit フィールドに設定し、profit_disclosed を true にすること。該当する利益指標がその表に存在しない場合は profit を null のままにし、profit_disclosed を false にすること。無関係な指標（総資産・減価償却費・固定資産等）を流用してはならない
    - profit_disclosed は「この表に利益情報が存在するか」の申告であり、rows の profit 値と矛盾させないこと（true なら最低1行は profit を埋めること、false なら全行 null のままにすること）
    - 前期・当期の両方が1つの表に列として並んでいる場合は当期列を選ぶこと
    - 行ラベルは事業名・製品名・サービス名であるべきで、地域名ではないこと。事業別のはずが実際には地域別の表（見出しの取り違え）である場合は applicable=false を返すこと
    - 表の金額単位を判定し、unit フィールドに "yen"（円） / "million_yen"（百万円） / "other" のいずれかを申告すること
    - 合計・小計・連結合計を表す行は row_kind="subtotal" とし、純粋な除去・消去・調整だけの行（例:「消去」「調整額」「連結消去」）は row_kind="reconciling" とすること。純粋な事業・製品区分の行は row_kind="segment" とすること
    - 「その他（消去分を含む）」のように、残りの事業・本社勘定等と消去が一体になった列・行は row_kind="segment" とすること（ラベルに「消去」とあっても、単独の消去行ではない。野村HD等。ユーザー確認 2026-07-25）
    - 該当する事業別データが候補テーブル群に存在しない場合は applicable=false を返すこと
    - applicable=false の場合、not_applicable_reason に理由種別を設定すること: 候補が地域別の表のみで
      事業別・製品別データが存在しないことが理由なら geography_only、それ以外の理由なら other。
      applicable=true の場合は other のままでよい
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
            "not_applicable_reason": ["type": "string", "enum": ["geography_only", "other"]],
            "notes": ["type": "string"],
        ],
        "required": [
            "applicable", "unit", "source_table_index", "period_column", "profit_disclosed", "rows",
            "not_applicable_reason", "notes",
        ],
        "additionalProperties": false,
    ]

    /// 分母整合性チェックの許容範囲。他の LLM 正規化器と同じ許容幅を使う。
    private static let denominatorTolerance = 0.90...1.10

    /// segments の ExtractedBreakdown（html_table）と連結外部売上から BreakdownSnapshot を組み立てる。
    /// LLM 呼び出し失敗・非該当・パース不能の場合は snapshot=nil。
    static func normalize(
        _ result: ExtractedBreakdown, consolidatedSales: Double?, client: ChatCompleting
    ) async -> (snapshot: BreakdownSnapshot?, audit: LLMBreakdownAudit?) {
        // `method == "xbrl_facts"` でも tables が非空なら試す（facts 優先で method が変わっても
        // 表フォールバックの手段を残すため。issue調査 2026-07-21、Grok 4.5 レビュー指摘）。
        guard !result.tables.isEmpty,
              let consolidatedSales, consolidatedSales != 0 else { return (nil, nil) }

        let userPrompt = buildUserPrompt(tables: result.tables, consolidatedSales: consolidatedSales)

        guard let jsonSchemaData = try? JSONSerialization.data(withJSONObject: jsonSchema) else { return (nil, nil) }

        let response: [String: Any]
        do {
            let responseData = try await client.complete(
                system: systemPrompt,
                user: userPrompt,
                jsonSchema: jsonSchemaData,
                schemaName: "segment_info_breakdown"
            )
            guard let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return (nil, nil)
            }
            response = parsed
        } catch {
            printError("SegmentInfoLLMNormalizer: LLM呼び出し失敗: \(error)\n")
            return (nil, nil)
        }

        let unit = response["unit"] as? String ?? "other"
        // キー欠落・型不正は「未開示（確認済み）」ではなく「不明」なので、silent に false 扱いせず
        // llm_profit_disclosed_unresolved を立てる（unit の "other" フラグ付けと同じ考え方）。
        let profitDisclosedRaw = response["profit_disclosed"] as? Bool
        let profitDisclosed = profitDisclosedRaw ?? false
        // strict JSON schema では not_applicable_reason が applicable=true の応答でも常に埋まって
        // 返ってくる（プロンプトの「other のままでよい」は forcing ではない）。applicable=false の
        // ときだけ採用することで、成功応答からの理由を誤って「該当なし」判定に混入させない
        // （Opus監査 2026-07-26）。
        let applicable = response["applicable"] as? Bool ?? false
        let audit = LLMBreakdownAudit(
            sourceTableIndex: (response["source_table_index"] as? NSNumber)?.intValue,
            periodColumn: response["period_column"] as? String,
            unit: unit,
            profitDisclosed: profitDisclosed,
            notes: response["notes"] as? String ?? "",
            notApplicableReason: applicable ? nil : response["not_applicable_reason"] as? String
        )

        guard applicable,
              let rawRows = response["rows"] as? [[String: Any]], !rawRows.isEmpty
        else { return (nil, audit) }
        var warnings: [String] = []
        var needsReview = false

        if profitDisclosedRaw == nil {
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
            let rawProfit = (raw["profit"] as? NSNumber)?.doubleValue
            rows.append(BreakdownRow(
                labelRaw: label, amount: rawAmount * unitMultiplier, share: nil,
                profit: rawProfit.map { $0 * unitMultiplier },
                rowKind: resolvedRowKind(label: label, rowKind: rowKind)
            ))
        }
        guard !rows.isEmpty else { return (nil, audit) }

        // profit_disclosed の自己申告と実際の rows の整合性チェック（決定的）。
        let hasAnySegmentProfit = rows.contains { $0.rowKind == "segment" && $0.profit != nil }
        if profitDisclosed && !hasAnySegmentProfit {
            needsReview = true
            warnings.append("profit_disclosed_but_row_missing")
        } else if !profitDisclosed && hasAnySegmentProfit {
            needsReview = true
            warnings.append("profit_present_despite_not_disclosed")
        }

        // ラベル妥当性チェック（決定的、追加ガード）。全行が地域名に一致するなら、地域別の表を
        // 誤って business として採用した疑いがある。「その他」「その他の地域」を含むラベルは
        // 判定から除外する — 事業別表にも「その他及び全社」等の形でほぼ必ず出現するため
        // （固有の地域名が最低1つ一致することを要求する設計を骨抜きにしないため）。
        // さらに「国内」「海外」のみの一致では立てない（実データ検証: キッコーマン、
        // issue調査 2026-07-21。「国内食料品製造・販売」等の事業区分×国内海外クロス集計を
        // 誤って地域別と誤認していた）。特定の国・地域名が最低1つ一致することを要求する。
        let segmentLabels = rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        let labelsExcludingOther = segmentLabels.filter { !$0.contains("その他") }
        let allLabelsLookLikeGeography = !labelsExcludingOther.isEmpty && labelsExcludingOther.allSatisfy { label in
            Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
        }
        let hasSpecificGeographyLabel = labelsExcludingOther.contains { label in
            Xbrl.segmentSpecificGeographyLabelKeywordsJa.contains { label.contains($0) }
        }
        if allLabelsLookLikeGeography, hasSpecificGeographyLabel {
            needsReview = true
            warnings.append("business_label_looks_like_geography")
        }

        // 分母整合性チェック。証券会社等（例: 野村HD, issue #105）は資金調達費用が大きく、
        // セグメント表の「収益合計（金融費用控除後）」が連結売上高（総額）の半分以下になり、
        // consolidatedSales基準では必ず乖離する。この場合、表自身のsubtotal行（「計」等。
        // segment+reconciling合計と一致するのが通例）を分母として使えないか試す
        // （xbrl_facts経路の銀行・保険向けnormalizeInternalSubtotalBasisと同型の考え方）。
        // ガード（5%。xbrl_facts経路と同じ閾値）を通らない場合は表取り違えの疑いが残るため
        // フォールバックせず、従来どおりneeds_reviewを立てる。
        let segmentSum = rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + $1.amount }
        let reconcilingSum = rows.filter { $0.rowKind == "reconciling" }.reduce(0.0) { $0 + $1.amount }
        let segmentShare = segmentSum / consolidatedSales

        var denominator = consolidatedSales
        var denominatorTag = "income_statement.sales"

        if !denominatorTolerance.contains(segmentShare) {
            let internalSum = segmentSum + reconcilingSum
            let subtotalCandidates = rows.filter { $0.rowKind == "subtotal" }
            if let closest = subtotalCandidates.min(by: {
                abs($0.amount - internalSum) < abs($1.amount - internalSum)
            }), closest.amount != 0, abs(closest.amount - internalSum) / abs(closest.amount) <= 0.05 {
                denominator = closest.amount
                denominatorTag = "llm_table_subtotal"
                warnings.append("llm_denominator_from_internal_subtotal")
            } else {
                needsReview = true
                warnings.append("llm_row_sum_mismatch")
            }
        }

        let rowsWithShare = rows.map { row -> BreakdownRow in
            var r = row
            r.share = r.amount / denominator
            return r
        }

        let snapshot = BreakdownSnapshot(
            axis: "business",
            denominator: denominator,
            denominatorTag: denominatorTag,
            rows: rowsWithShare,
            sourceKind: "segment_info",
            needsReview: needsReview,
            warnings: warnings
        )
        return (snapshot, audit)
    }

    /// LLM が「その他（消去分を含む）」を reconciling に誤分類しても、残事業バケットとして
    /// segment に直す（野村HD、ユーザー確認 2026-07-25）。
    /// 「その他の調整額」「その他の消去」のように消去・調整が本体の行は reconciling のまま
    /// （Opus 監査 2026-07-25）。
    private static func resolvedRowKind(label: String, rowKind: String) -> String {
        guard rowKind == "reconciling", label.contains("その他") else { return rowKind }
        if label.contains("消去分を含む") || label.contains("全社") { return "segment" }
        if label.contains("消去") || label.contains("調整") { return rowKind }
        return "segment"
    }

    private static func buildUserPrompt(tables: [BreakdownTable], consolidatedSales: Double) -> String {
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
