// 有報「事業の内容」から短い会社説明を生成する。50〜80字は目安。
// 公開 REST / Filing `texts` には載せない。空入力はモデルを呼ばない。

import Foundation

enum CompanyOverviewGenerator {
    static let systemPrompt = """
    あなたは日本の有価証券報告書「企業の概況」の「事業の内容」だけを材料に、銘柄ヘッダ用の短い会社説明を書く。
    ルール:
    - 入力テキストに書かれている主力事業・主な製品・サービスだけを使う。社名や業種欄から補わない。一般知識で足さない。
    - 会計基準の前置き、子会社数、セグメント注記への参照、沿革、関係会社一覧、事業系統図の会社名羅列は使わない。
    - 複数事業があるときは主要なものを2〜3個までに絞る。
    - 入力が空、または事業内容が全く読めないときは applicable を false にし overview を空文字にする。
    - 日本語。1〜2文。長さの目安は50〜80字（句読点・空白を含む）。必要な主力の製品・サービスが揃っていれば、情報量が少ないときに無理に足して長くしない。80字を超えたら失敗。
    - 「何をしている会社か」だけ。金額・件数・比率・成長率・目標・年度を書かない。
    - 買い推奨・投資判断・銘柄コードを書かない。
    - 社名は必要なら一度だけ。株式会社は付けない。
    - 文体はだ・である調。です・ます・でした・ましたは使わない。
    - 終止は「する」「行う」「手がける」「である」のほか、「を提供。」「を手がける。」のような言い切りでよい。どちらも可。
    出力は JSON のみ。
    """

    nonisolated(unsafe) private static let jsonSchemaObject: [String: Any] = [
        "type": "object",
        "properties": [
            "applicable": ["type": "boolean"],
            "overview": ["type": "string"],
            "char_count": ["type": "integer"],
            "reason": ["type": "string"],
        ],
        "required": ["applicable", "overview", "char_count", "reason"],
        "additionalProperties": false,
    ]

    static func generate(
        input: CompanyOverviewInput, client: ChatCompleting, model: String
    ) async -> CompanyOverviewDraft {
        let raw = input.sourceText
        let text = String(raw.prefix(companyOverviewMaxInputChars))
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return emptyDraft(input: input, raw: raw, model: model, reason: "入力が空")
        }

        guard let schema = try? JSONSerialization.data(withJSONObject: jsonSchemaObject) else {
            return failedDraft(input: input, raw: raw, used: text, model: model, reason: "json schema")
        }

        var attempts = 0
        let parsedFirst: LLMOverviewReply
        do {
            parsedFirst = try await complete(
                client: client, schema: schema, user: userPrompt(input: input, text: text, repair: nil))
            attempts = 1
        } catch {
            printError("CompanyOverviewGenerator: LLM呼び出し失敗: \(error)\n")
            return failedDraft(
                input: input, raw: raw, used: text, model: model, reason: String(describing: error),
                attempts: 1)
        }

        var parsed = parsedFirst
        var verdict = CompanyOverviewRules.evaluate(
            applicable: parsed.applicable, overview: parsed.overview)

        while case .invalid(let why) = verdict, attempts < companyOverviewMaxAttempts,
              parsed.applicable
        {
            attempts += 1
            let repair = repairPrompt(current: parsed.overview, source: text, detail: why)
            do {
                let candidate = try await complete(client: client, schema: schema, user: repair)
                if !candidate.applicable {
                    verdict = CompanyOverviewRules.evaluate(
                        applicable: parsed.applicable, overview: parsed.overview)
                    continue
                }
                parsed = candidate
                verdict = CompanyOverviewRules.evaluate(
                    applicable: parsed.applicable, overview: parsed.overview)
            } catch {
                printError("CompanyOverviewGenerator: repair LLM呼び出し失敗: \(error)\n")
                break
            }
        }

        var overview = parsed.overview
        var clipped = false
        if parsed.applicable, case .invalid(let why) = verdict {
            var clippedText: String?
            if overview.count > companyOverviewMaxChars {
                clippedText = CompanyOverviewRules.clip(overview)
            } else if why.contains("言い切りの句点") {
                clippedText = overview + "。"
            }
            if let clippedText {
                let clippedVerdict = CompanyOverviewRules.evaluate(
                    applicable: true, overview: clippedText)
                if case .ok = clippedVerdict {
                    overview = clippedText
                    parsed.overview = clippedText
                    clipped = true
                    verdict = .ok
                }
            }
        }

        let ok: Bool
        let okDetail: String
        switch verdict {
        case .ok:
            ok = true
            okDetail = ""
        case .invalid(let why):
            ok = false
            okDetail = why
        }
        return CompanyOverviewDraft(
            applicable: parsed.applicable, overview: overview, charCount: overview.count,
            reason: parsed.reason, ok: ok, okDetail: okDetail, clipped: clipped,
            attempts: attempts, model: model, inputCharsTotal: raw.count,
            inputCharsUsed: text.count,
            inputThin: raw.trimmingCharacters(in: .whitespacesAndNewlines).count
                < companyOverviewInputThinChars)
    }

    private struct LLMOverviewReply {
        var applicable: Bool
        var overview: String
        var reason: String
    }

    private static func complete(client: ChatCompleting, schema: Data, user: String) async throws
        -> LLMOverviewReply
    {
        let data = try await client.complete(
            system: systemPrompt, user: user, jsonSchema: schema,
            schemaName: companyOverviewJSONSchemaName)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatCompletionError.decodingFailed("overview json")
        }
        let applicable = obj["applicable"] as? Bool ?? false
        let overview = ((obj["overview"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = (obj["reason"] as? String) ?? ""
        return LLMOverviewReply(applicable: applicable, overview: overview, reason: reason)
    }

    static func userPrompt(input: CompanyOverviewInput, text: String, repair: String?) -> String {
        let extra = repair.map { "\n前回の出力は長さまたは内容が不適です。直し: \($0)\n" } ?? ""
        return """
            銘柄コード \(input.code) / 社名 \(input.name) / 業種 \(input.sector)
            入力キー: \(companyOverviewInputKey)
            見出し: 企業の概況 / \(companyOverviewSectionTitle)
            \(extra)----- 有報テキスト -----
            \(text)
            ----- ここまで -----
            """
    }

    private static func repairPrompt(current: String, source _: String, detail: String) -> String {
        let n = current.count
        let style = """
            文体はだ・である調。です・ます・でした・ましたは使わない。「を提供。」「を手がける。」の言い切りも可。applicable は true のまま。
            """
        if detail.contains("ですます") {
            return """
                \(style) 長さは変えず、新しい事実は足さない。情報量が少なければ無理に長くしない。
                \(current)
                """
        }
        if n > companyOverviewMaxChars {
            return """
                次の日本語は\(n)字。句読点込みで\(companyOverviewMaxChars)字以下に短縮する。\(style) 新しい事業を足さず、数字・年度・目標は残さない。情報量が少なければ無理に長くしない。
                \(current)
                """
        }
        return """
            内容が不適です。直し: \(detail)。\(style) 新しい事実は足さない。情報量が少なければ無理に長くしない。
            \(current)
            """
    }

    private static func emptyDraft(
        input: CompanyOverviewInput, raw: String, model: String, reason: String
    ) -> CompanyOverviewDraft {
        CompanyOverviewDraft(
            applicable: false, overview: "", charCount: 0, reason: reason, ok: true, okDetail: "",
            clipped: false, attempts: 0, model: model, inputCharsTotal: raw.count, inputCharsUsed: 0,
            inputThin: true)
    }

    private static func failedDraft(
        input: CompanyOverviewInput, raw: String, used: String, model: String, reason: String,
        attempts: Int = 0
    ) -> CompanyOverviewDraft {
        CompanyOverviewDraft(
            applicable: false, overview: "", charCount: 0, reason: reason, ok: false,
            okDetail: reason, clipped: false, attempts: attempts, model: model,
            inputCharsTotal: raw.count, inputCharsUsed: used.count,
            inputThin: raw.trimmingCharacters(in: .whitespacesAndNewlines).count
                < companyOverviewInputThinChars)
    }
}
