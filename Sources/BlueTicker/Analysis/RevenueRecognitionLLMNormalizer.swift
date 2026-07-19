// 収益認識関係注記（「顧客との契約から生じる収益を分解した情報」）の html_table 結果を
// LLM で BreakdownSnapshot（axis:"business"）へ正規化する。
// docs/segment-normalization-concept.md 参照。SegmentBreakdownLLMNormalizer.swift（geography 用）
// と同型だが、対象は「本来 segments キーが事業別のはずが地域別だった」オークマ型の会社で、
// 収益認識関係注記から本当の事業別（製品別）データを拾うためのもの。
//
// 呼び出し側の責務: この正規化器は「収益認識注記に事業別breakdownが存在するか」だけを判定する。
// segments キーの axis が実際に geography かどうかの判定（SegmentNormalizer.classifyAxis /
// SegmentExtractor の axis-aware swap）とは別レイヤーで、呼び出し側が組み合わせて使う。
//
// ライブ read 経路（REST/MCP）や ingest には配線しない（concept doc で確定済み: LLM は
// Stage 4/5 と同じ ingest バッチ経路に置く方針だが、永続化スキーマは未確定のため現時点では
// dev ツールでの手動検証のみ）。

import Foundation

enum RevenueRecognitionLLMNormalizer {

    private static let systemPrompt = """
    あなたは日本の有価証券報告書の「収益認識関係」注記（顧客との契約から生じる収益を分解した情報）から、
    事業別・製品別の外部売上（または相当する主要指標）を構造化するアシスタントです。

    入力として、同一書類から抽出された収益認識関係注記の候補テーブル（Markdown形式、見出し・期間ラベル・表インデックス付き）と、
    連結の外部売上高（円単位、比較の分母）が与えられます。

    ルール:
    - 候補テーブルが複数ある場合、連結売上高との整合性が最も高い表・列（多くは「当期」列）を選ぶこと。前期・当期の両方が1つの表に列として並んでいる場合は当期列を選ぶこと
    - 行ラベルは製品名・事業区分名であるべきで、「日本」「米国」「欧州」「アジア」等の地域名ではないこと。地域別に分解した表しか無い場合は applicable=false を返すこと
    - **報告セグメント（事業区分）を列に、収益区分（物件売却収入・その他等）を行に持つクロス集計表**（例: 不動産事業／保険事業／ホテル事業を列にした表）は対象外。この形は既に別経路（segments キー）で事業別データが取得できているため、ここでは扱わない。applicable=false を返すこと
    - 表の金額単位を判定し、unit フィールドに "yen"（円） / "million_yen"（百万円） / "other" のいずれかを申告すること。日本の有価証券報告書の注記は「（単位：百万円）」の表記が最も一般的
    - 合計・小計・連結合計を表す行（例: 「顧客との契約から生じる収益」「外部顧客への売上高」）は row_kind="subtotal" とし、除去・消去を表す行は row_kind="reconciling" とすること。純粋な製品・事業区分の行は row_kind="segment" とすること
    - 該当する事業別・製品別データが候補テーブル群に存在しない場合は applicable=false を返すこと
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

    /// 分母整合性チェックの許容範囲。SegmentBreakdownLLMNormalizer と同じ許容幅を使う。
    private static let denominatorTolerance = 0.90...1.10

    /// revenue_recognition の SegmentResult（html_table）と連結外部売上から BreakdownSnapshot を組み立てる。
    /// LLM 呼び出し失敗・非該当・パース不能の場合は snapshot=nil。
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
                schemaName: "revenue_recognition_breakdown"
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

        // ラベル妥当性チェック（決定的、追加ガード）。geography 正規化器の逆方向チェック:
        // 地域別表を誤って拾っていないかを検知する（分母一致だけでは表の取り違えを検知できないため）。
        let segmentLabels = rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        let hasGeographyLikeLabel = segmentLabels.contains { label in
            Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
        }
        if hasGeographyLikeLabel {
            needsReview = true
            warnings.append("business_label_mismatch")
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
            axis: "business",
            denominator: consolidatedSales,
            denominatorTag: "income_statement.sales",
            rows: rowsWithShare,
            sourceKind: "revenue_recognition",
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
