// geography（地域別情報）の html_table 結果を LLM で BreakdownSnapshot へ正規化する。
// docs/segment-normalization-concept.md 参照。SegmentNormalizer.swift（xbrl_facts 経路）とは
// 別経路。会社ごとに表の向き・表数・見出しキーワードの取り違えが不揃いなため、
// 表全体（markdown）を LLM に渡して構造化させ、Swift 側は単位変換・分母整合性・
// 地域ラベル妥当性のみ決定的に検証する（契約検証の増分。ingest/CLI/REST 配線は対象外）。
//
// segments（business）軸への適用は今回のスコープ外（smoke 11社中 0社が html_table のため）。
// オークマ型（segments キーの axis が geography 判定になるケース）の配線方針は
// docs/segment-normalization-concept.md「今後の検討事項3」に記載。ここでは扱わない。

import Foundation

/// LLM がどの表・どの期間列・どの単位を採用したかの監査情報（目視検証用）。
/// `BreakdownSnapshot` 自体（xbrl_facts 経路と共有する契約型）は汚さず、別チャネルで返す。
struct LLMBreakdownAudit {
    var sourceTableIndex: Int?
    var periodColumn: String?
    var unit: String
    var notes: String
}

enum SegmentBreakdownLLMNormalizer {

    private static let systemPrompt = """
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
    - notes フィールドに、表選択・期間列選択の根拠を短く日本語で記すこと
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
            "rows": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "label": ["type": "string"],
                        "amount": ["type": "number"],
                        "row_kind": ["type": "string", "enum": ["segment", "subtotal", "reconciling"]],
                    ],
                    "required": ["label", "amount", "row_kind"],
                    "additionalProperties": false,
                ],
            ],
            "notes": ["type": "string"],
        ],
        "required": ["applicable", "unit", "source_table_index", "period_column", "rows", "notes"],
        "additionalProperties": false,
    ]

    /// 分母整合性チェックの許容範囲。xbrl_facts 経路（0.95...1.05）より広め。
    /// html_table は「注記の仕向地合計」と「損益計算書の売上」が数%ずれることがある
    /// （実データ: キヤノン地域別注記の計 4,509,821 百万円 vs 連結売上 4,624,727 百万円 ≈ 2.5%差）。
    private static let denominatorTolerance = 0.90...1.10

    /// geography の SegmentResult（html_table）と連結外部売上から BreakdownSnapshot を組み立てる。
    /// LLM 呼び出し失敗・非該当・パース不能の場合は snapshot=nil。
    /// audit は LLM が実際に選んだ表・期間列・単位・判断根拠（目視検証用。呼び出し失敗時のみ nil）。
    static func normalize(
        _ result: SegmentResult, consolidatedSales: Double?, client: ChatCompleting
    ) async -> (snapshot: BreakdownSnapshot?, audit: LLMBreakdownAudit?) {
        guard result.method == "html_table", !result.tables.isEmpty,
              let consolidatedSales, consolidatedSales != 0 else { return (nil, nil) }

        let userPrompt = buildUserPrompt(tables: result.tables, consolidatedSales: consolidatedSales)

        guard let jsonSchemaData = try? JSONSerialization.data(withJSONObject: jsonSchema) else { return (nil, nil) }

        let response: [String: Any]
        do {
            let responseData = try await client.complete(
                system: systemPrompt,
                user: userPrompt,
                jsonSchema: jsonSchemaData,
                schemaName: "geography_breakdown"
            )
            guard let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return (nil, nil)
            }
            response = parsed
        } catch {
            return (nil, nil)
        }

        let unit = response["unit"] as? String ?? "other"
        let audit = LLMBreakdownAudit(
            sourceTableIndex: (response["source_table_index"] as? NSNumber)?.intValue,
            periodColumn: response["period_column"] as? String,
            unit: unit,
            notes: response["notes"] as? String ?? ""
        )

        guard let applicable = response["applicable"] as? Bool, applicable,
              let rawRows = response["rows"] as? [[String: Any]], !rawRows.isEmpty
        else { return (nil, audit) }
        var warnings: [String] = []
        var needsReview = false

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
            rows.append(BreakdownRow(labelRaw: label, amount: rawAmount * unitMultiplier, share: nil, profit: nil, rowKind: rowKind))
        }
        guard !rows.isEmpty else { return (nil, audit) }

        // ラベル妥当性チェック（決定的、追加ガード）。分母一致だけでは表の取り違えを検知できないため
        // （例: 誤って選ばれた事業別表の合計が、地域別表の合計とたまたま一致するケース）。
        // 「その他」はキーワードに含めない — 事業別表にも「その他及び全社」等の形でほぼ必ず
        // 出現するため、これを含めると事業別表の取り違えをすり抜けさせてしまう
        // （固有の地域名が最低1つ一致することを要求する設計を骨抜きにする）。
        let segmentLabels = rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        let hasGeographyLikeLabel = segmentLabels.contains { label in
            Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
        }
        if !hasGeographyLikeLabel {
            needsReview = true
            warnings.append("geography_label_mismatch")
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
            axis: "geography",
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
