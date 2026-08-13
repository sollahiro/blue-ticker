// 収益認識関係注記（「顧客との契約から生じる収益を分解した情報」）の html_table 結果を
// LLM で BreakdownSnapshot（axis:"business"）へ正規化する。
// docs/breakdown.md 参照。GeographyBreakdownLLMNormalizer.swift（geography 用）
// と同型だが、対象は次の会社で収益認識関係注記から本当の事業別（製品・部門別）データを拾う:
// - オークマ型: 報告セグメントが地域別のため、製品別が収益認識注記にある
// - ファナック型: 単一セグメントで報告セグメント開示省略。部門が列・地域が行のマトリクス表
//
// 呼び出し側の責務: この正規化器は「収益認識注記に事業別breakdownが存在するか」だけを判定する。
// segments キーの axis が実際に geography かどうかの判定（BreakdownNormalizer.classifyAxis /
// BreakdownExtractor の axis-aware swap）とは別レイヤーで、呼び出し側が組み合わせて使う。
//
// ライブ read 経路（REST/MCP）や ingest には配線しない（concept doc で確定済み: LLM は
// financials/filing-sections と同じ ingest バッチ経路に置く方針だが、永続化スキーマは未確定のため現時点では
// dev ツールでの手動検証のみ）。

import Foundation

enum RevenueRecognitionLLMNormalizer {

    private static let systemPrompt = """
    あなたは日本の有価証券報告書の「収益認識関係」注記および IFRS「売上収益」注記（顧客との契約から生じる収益を分解した情報。
    NotesRevenue / NotesRevenue2 等を含む）から、
    事業別・製品別・部門別の外部売上（または相当する主要指標）を構造化するアシスタントです。

    入力として、同一書類から抽出された収益認識関係注記の候補テーブル（Markdown形式、見出し・期間ラベル・表インデックス付き）と、
    連結の外部売上高（円単位、比較の分母）が与えられます。

    ルール:
    - 候補テーブルが複数ある場合、連結売上高との整合性が最も高い表（多くは当期の表）を選ぶこと。前期・当期の両方が1つの表に列として並んでいる場合は当期列を選ぶこと
    - 出力の行ラベルは製品名・事業区分名・部門名であるべきで、「日本」「国内」「米国」「米州」「欧州」「アジア」「中国」等の地域名ではないこと
    - **例外（パンパシHD型）**: 行が「（ディスカウントストア）」「（総合スーパー）」のような大枠見出し（金額なし）と、その下の品目明細（家電製品・日用雑貨品等、金額あり）、さらに品目分解の無い「（海外）」配下の北米/アジアになっている表は対象内。大枠見出し行は出さず、品目明細を segment にし、業態が分かるようラベルに親見出しを付すこと（例: 「家電製品（ディスカウントストア）」）。海外の北米/アジアは品目が無い残として segment に残すこと。「その他の収益」も外部顧客への売上高に加算されているなら segment とし、reconciling にしないこと（品目＋海外＋その他の収益の segment 合計が外部顧客への売上高と一致するようにする）
    - **単純な製品別・部門別表**（1行=1製品/部門）はそのまま行として使うこと
    - **事業・製品名が行、地域が列のマトリクス表**（例: 行がタイヤ／その他、列が日本／米州／欧州…／連結計）は対象内。金額は「連結計」（または連結合計）列を使うこと。地域列の内訳を行にしてはならない
    - **部門・製品名・事業グループ名が列見出しで、指標が行になっているマトリクス表**（例: 列が地球環境エネルギー／マテリアルソリューション／金属資源…、行が「顧客との契約から認識した収益」）は対象内。当該収益行の各事業列の金額を使い、列見出しを行ラベルとして1事業=1行に転置して出力すること。地域行・調整列の扱いに注意し、合計列は row_kind="subtotal"
    - **部門・製品名が列見出しで、地域名が行になっているマトリクス表**（例: 列がＦＡ／ロボット／ロボマシン／サービス、行が国内／米州／欧州／中国…）は対象内。この場合は「外部顧客への売上高」または「顧客との契約から生じる収益」の合計行にある各部門列の金額を使い、列見出しを行ラベルとして1部門=1行に転置して出力すること。地域行をそのまま行にしてはならない。合計列は row_kind="subtotal"
    - 同一 Markdown 内に「収益認識の時期別」（一時点／一定期間）の第2マトリクスが続く場合がある。部門別の外部売上は上側（地域×部門）の合計行から取ること
    - **報告セグメント（不動産／保険／ホテル等の事業区分）を列に、収益の種類（物件売却収入・その他等）を行に持つクロス集計表**は対象外。この形は既に別経路（segments キー）で事業別データが取得できているため、ここでは扱わない。applicable=false を返すこと
    - 「製商品の販売／知的財産権収入」など収益の種類だけに分解した表（製品・事業名が無い）しか無い場合は applicable=false を返すこと
    - 地域別にだけ分解した表（国内／海外のみ等）しか無い場合は applicable=false を返すこと
    - 売上と同じ表内に製品別・事業別の営業利益（またはセグメント利益に相当する指標）が並んで開示されている場合は、対応する profit フィールドに設定し、profit_disclosed を true にすること。該当する利益指標がその表に存在しない場合（収益認識注記の製品別売上高表は利益が開示されていないことが多い）は profit を null のままにし、profit_disclosed を false にすること
    - profit_disclosed は「この表に利益情報が存在するか」の申告であり、rows の profit 値と矛盾させないこと（true なら最低1行は profit を埋めること、false なら全行 null のままにすること）
    - 表の金額単位を判定し、unit フィールドに "yen"（円） / "million_yen"（百万円） / "other" のいずれかを申告すること。日本の有価証券報告書の注記は「（単位：百万円）」の表記が最も一般的
    - 合計・小計・連結合計を表す行（例: 「顧客との契約から生じる収益」「外部顧客への売上高」「合計」「外部収益合計」）は row_kind="subtotal" とし、除去・消去を表す行は row_kind="reconciling" とすること。純粋な製品・事業・部門区分の行は row_kind="segment" とすること
    - 表や注記に「タイヤ(注1)＝タイヤ＋ソリューション」「その他(注2)＝化工品・多角化」のような内訳説明がある場合、rows は注記が示す粗い区分（例: タイヤ／その他）のままにし、細目名（ソリューション、化工品・多角化 等）は notes に具体名で残すこと（「細目は省略」だけでは不十分）
    - 該当する事業別・製品別・部門別データが候補テーブル群に存在しない場合は applicable=false を返すこと
    - applicable=false の場合、not_applicable_reason に理由種別を設定すること: 候補が地域別（仕向地別）分解のみで
      事業別・製品別・部門別データが存在しないことが理由なら geography_only、それ以外の理由（収益の種類だけの
      分解・該当データ自体が存在しない等）なら other。applicable=true の場合は other のままでよい
    - notes フィールドに、表選択・転置有無・連結計列の採用・注記の細目説明（具体名）の根拠を短く日本語で記すこと
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

    /// 分母整合性チェックの許容範囲。GeographyBreakdownLLMNormalizer と同じ許容幅を使う。
    private static let denominatorTolerance = 0.90...1.10

    /// revenue_recognition の ExtractedBreakdown（html_table）と連結外部売上から BreakdownSnapshot を組み立てる。
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
                schemaName: "revenue_recognition_breakdown"
            )
            guard let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return (nil, nil)
            }
            response = parsed
        } catch {
            printError("RevenueRecognitionLLMNormalizer: LLM呼び出し失敗: \(error)\n")
            return (nil, nil)
        }

        let unit = response["unit"] as? String ?? "other"
        // キー欠落・型不正は「未開示（確認済み）」ではなく「不明」なので、下で silent に false 扱い
        // せず llm_profit_disclosed_unresolved を立てる（unit の "other" フラグ付けと同じ考え方）。
        let profitDisclosedRaw = response["profit_disclosed"] as? Bool
        let profitDisclosed = profitDisclosedRaw ?? false
        // strict JSON schema では not_applicable_reason が applicable=true の応答でも常に埋まって
        // 返ってくる（プロンプトの「other のままでよい」は forcing ではない）。applicable=false の
        // ときだけ採用することで、成功応答からの理由を誤って「該当なし」判定に混入させない
        // （Opus監査 2026-07-26: revenueRecognitionLLM の needsReview 破棄経路が audit を持ち帰る
        // ため、ここを絞らないと非決定的な低確信度結果が誤って geography_only 確定してしまう）。
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
                profit: rawProfit.map { $0 * unitMultiplier }, rowKind: rowKind
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

        // ラベル妥当性チェック（決定的、追加ガード）。geography 正規化器の逆方向チェック:
        // 地域別表を誤って拾っていないかを検知する（分母一致だけでは表の取り違えを検知できないため）。
        // 地域名らしい行が過半数のとき弾く（「その他」だけの非地域行が混ざる地域表も拾う）。
        // パンパシHD型（品目多数＋海外残わずか）は過半数に届かず弾かない（ユーザー確認 2026-07-25）。
        // 以前の「全行一致」だと地域表＋「その他」1行でガードが死ぬ（Opus 監査 2026-07-25）。
        let segmentLabels = rows.filter { $0.rowKind == "segment" }.map(\.labelRaw)
        let geographyLikeCount = segmentLabels.filter { label in
            Xbrl.segmentGeographyLabelKeywordsJa.contains { label.contains($0) }
        }.count
        if !segmentLabels.isEmpty, geographyLikeCount * 2 > segmentLabels.count {
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
