// geography（地域別情報）の html_table 結果を LLM で BreakdownSnapshot へ正規化する。
// docs/breakdown-normalization-concept.md 参照。BreakdownNormalizer.swift（xbrl_facts 経路）とは
// 別経路。会社ごとに表の向き・表数・見出しキーワードの取り違えが不揃いなため、
// 表全体（markdown）を LLM に渡して構造化させ、Swift 側は単位変換・分母整合性・
// 地域ラベル妥当性のみ決定的に検証する（契約検証の増分。ingest/CLI/REST 配線は対象外）。
//
// segments（business）軸への適用は今回のスコープ外（smoke 11社中 0社が html_table のため）。
// オークマ型（segments キーの axis が geography 判定になるケース）の配線方針は
// docs/breakdown-normalization-concept.md「今後の検討事項3」に記載。ここでは扱わない。

import Foundation

/// LLM がどの表・どの期間列・どの単位を採用したかの監査情報（目視検証用）。
/// `BreakdownSnapshot` 自体（xbrl_facts 経路と共有する契約型）は汚さず、別チャネルで返す。
/// business 軸の正規化器（`RevenueRecognitionLLMNormalizer` 等）と共有する型。
struct LLMBreakdownAudit {
    var sourceTableIndex: Int?
    var periodColumn: String?
    var unit: String
    /// 表がそもそも事業別/製品別の利益情報を含んでいたか。`BreakdownRow.profit == nil` だけでは
    /// 「未開示（確認済み）」と「LLM の見落とし」を区別できないため独立して持つ。
    /// geography 軸（本ファイル）は利益比較の対象外のため常に false。
    var profitDisclosed: Bool
    var notes: String
    /// `applicable=false` のときの理由種別（`geography_only` | `other`）。business 軸の
    /// 正規化器（`RevenueRecognitionLLMNormalizer`/`SegmentInfoLLMNormalizer`）のみが設定する
    /// （issue #135: html_table経由でLLMが地域別のみと判定したケースをE判定として拾うため）。
    /// `applicable=true` のときは無視されるフィールドのため nil のままでよい。
    var notApplicableReason: String? = nil
}

enum GeographyBreakdownLLMNormalizer {

    private static let systemPrompt = """
    あなたは日本の有価証券報告書の「地域ごとの情報」注記から、地域別の外部売上（または相当する主要指標）を構造化するアシスタントです。

    入力として、同一書類から抽出された地域別注記の候補テーブル（Markdown形式、見出し・期間ラベル・表インデックス付き）と、
    連結の外部売上高（円単位、比較の分母）が与えられます。

    ルール:
    - 候補テーブルが複数ある場合、連結売上高との整合性が最も高い表・列（多くは「当期」列）を選ぶこと。前期・当期の両方が1つの表に列として並んでいる場合は当期列を選ぶこと
    - **見出しが2段以上に分かれている表（例: 1段目が「アジア」「米州」等の広い区分、2段目が「タイ」「その他」「米国」「その他」等の細かい区分）では、必ず最も粒度の細かい行を採用すること。広い区分へ集約してはならない。行ラベルは2段目（最も内側）の区分名をそのまま使うこと（例: 「アジア」「タイ」の2段なら「タイ」、「アジア」「その他」の2段なら「アジアその他」のように、上位区分と下位区分をつなげた名前にすること）**
    - **親地域に金額があり、その下に「うち」「（うち〜）」等の内数行がある表では、内数行は出力しないこと（親地域の金額のみを segment にする）。内数を別 segment に含めると親と二重計上になり分母合計が崩れる**
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

    /// geography の ExtractedBreakdown（html_table）と連結外部売上から BreakdownSnapshot を組み立てる。
    /// LLM 呼び出し失敗・非該当・パース不能の場合は snapshot=nil。
    /// audit は LLM が実際に選んだ表・期間列・単位・判断根拠（目視検証用。呼び出し失敗時のみ nil）。
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
            profitDisclosed: false,
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

        // 「うち」内数の二重計上を決定的に除去する（プロンプト指示の保険）。
        // 親地域（北米等）と内数（米国等）が両方 segment だと分母合計が 1 を超える。
        rows = dropOfWhichSubsetSegments(rows)

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

        // 分母整合性チェック。金融・カード等（例: クレディセゾン・野村HD）は地域注記の
        // 「営業収益」「収益合計（金融費用控除後）」が損益計算書の売上高（総額）と乖離する。
        // 表自身の subtotal（合計/連結）が segment(+reconciling) 合計と一致するなら注記側に揃える
        // （business 軸 `SegmentInfoLLMNormalizer` / xbrl_facts の高島屋型と同型）。
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
            axis: "geography",
            denominator: denominator,
            denominatorTag: denominatorTag,
            rows: rowsWithShare,
            sourceKind: "html_table",
            needsReview: needsReview,
            warnings: warnings
        )
        return (snapshot, audit)
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

    /// 親地域の内数（「うち」）として重複計上されている segment 行を除く。
    /// 親を残し内数を落とす（注記の加算構造に合わせる。内数は親金額の内訳開示）。
    static func dropOfWhichSubsetSegments(_ rows: [BreakdownRow]) -> [BreakdownRow] {
        let segmentIndices = rows.indices.filter { rows[$0].rowKind == "segment" }
        guard segmentIndices.count >= 2 else { return rows }
        var drop = Set<Int>()
        for childIdx in segmentIndices {
            let child = rows[childIdx]
            for parentIdx in segmentIndices where parentIdx != childIdx && !drop.contains(parentIdx) {
                let parent = rows[parentIdx]
                if isLikelyOfWhichChild(parent: parent, child: child) {
                    drop.insert(childIdx)
                    break
                }
            }
        }
        guard !drop.isEmpty else { return rows }
        return rows.enumerated().compactMap { drop.contains($0.offset) ? nil : $0.element }
    }

    /// 親・子のラベル組と金額関係から、「うち」内数行かを判定する。
    /// 独立した並列地域（例: 「中国」と「アジア他」、「中国」と「その他」）を誤って落とさないよう、
    /// 内数らしい高い金額比率（親の概ね 80% 以上）を要求する。
    private static func isLikelyOfWhichChild(parent: BreakdownRow, child: BreakdownRow) -> Bool {
        guard child.amount > 0, parent.amount > 0 else { return false }
        // 内数は親以下（丸め誤差のみ許容）。
        guard child.amount <= parent.amount * 1.001 else { return false }
        // 兄弟地域の取りこぼし防止: 真の「うち」は親の大部分を占めることが多い
        // （北米のうち米国 ≈ 95%+）。中国が「アジア他」「その他」と並列な表では比率が低い。
        guard child.amount >= parent.amount * 0.80 else { return false }
        return matchesOfWhichLabelPair(parent: parent.labelRaw, child: child.labelRaw)
    }

    /// 高確度の親地域 ↔ 内数地域ラベル組のみ（並列バケット「その他」「アジア他」は扱わない）。
    /// 「その他のうち中国」等はプロンプト指示に委ね、決定的フィルタでは触らない。
    private static func matchesOfWhichLabelPair(parent: String, child: String) -> Bool {
        let pairs: [(parents: [String], children: [String])] = [
            (["北米", "米州", "米大陸", "アメリカ"], ["米国", "アメリカ合衆国"]),
            (["欧州", "ヨーロッパ"], ["フランス", "ドイツ", "英国", "イギリス", "イタリア", "スペイン"]),
        ]
        for pair in pairs {
            let parentHit = pair.parents.contains { parent.contains($0) }
            let childHit = pair.children.contains { child.contains($0) }
            // 親ラベル自体が子キーワードだけ、または子が親キーワードを含む場合は組としない
            // （例: 親「米国」と子「北米」の取り違えを防ぐ）。
            let parentIsChildOnly = pair.children.contains { parent == $0 || parent.contains($0) }
                && !pair.parents.contains { parent.contains($0) }
            if parentHit && childHit && !parentIsChildOnly { return true }
        }
        return false
    }
}
