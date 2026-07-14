// MCP ツールカタログ（スキーマ定義のみ）。
// 各ツールの実処理（ディスパッチ）は BltServerCore が持つ。ここはビジネスロジック・DB を持たない。

import BlueTickerCore
import MCP

/// blt-mcp が公開するツール一覧。REST `/v1/` の各エンドポイントに対応する
/// （`docs/blt-server-roadmap.md` の MCP ツール ↔ REST エンドポイント対応表を参照）。
public func mcpToolCatalog() -> [Tool] {
    [
        Tool(
            name: "search_companies",
            description: "銘柄コードまたは名称で企業を検索します。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("検索クエリ（銘柄コードまたは企業名）"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        Tool(
            name: "search_by_sector",
            description: "東証33業種で銘柄を検索します。業種名の部分一致で絞り込めます。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sector": .object([
                        "type": .string("string"),
                        "description": .string("業種名（部分一致）"),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("返却件数上限"),
                        "default": .int(Api.sectorCompaniesLimitDefault),
                    ]),
                ]),
                "required": .array([.string("sector")]),
            ])
        ),
        Tool(
            name: "get_filings",
            description: "銘柄コードに紐づく EDINET 書類一覧を取得します。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "max_years": .object([
                        "type": .string("integer"),
                        "description": .string("取得年数"),
                        "default": .int(Api.filingsMaxYearsDefault),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
        Tool(
            name: "get_financial_summary",
            description: """
                銘柄コードの財務サマリーを年度別に返します（格納済みデータのみ。未集計の場合は空を返します）。
                損益・CF・バランスシート・収益性指標（水準値）を含みます。
                前年差・要因分解（増減分析）は get_analysis を使ってください。
                金額単位は百万円（JPY）、比率は%、株主指標は円。
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "years": .object([
                        "type": .string("integer"),
                        "description": .string("取得年数"),
                        "default": .int(Api.financialsYearsDefault),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
        Tool(
            name: "get_half_financial_summary",
            description: """
                銘柄コードの半期財務サマリーを返します（格納済みデータのみ。未集計の場合は空を返します）。
                損益・CF・バランスシート・収益性指標（水準値）を含みます。
                前年差・要因分解（増減分析）は get_half_analysis を使ってください。
                years は最大 \(Api.halfMaxYears) 年にクランプされます。
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "years": .object([
                        "type": .string("integer"),
                        "description": .string("取得年数（最大 \(Api.halfMaxYears)）"),
                        "default": .int(Api.halfFinancialsYearsDefault),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
        Tool(
            name: "get_analysis",
            description: """
                銘柄コードの増減分析（前年差分解）を年度別に返します（格納済みデータのみ。未集計の場合は空を返します）。
                get_financial_summary と同じ水準値に加え、事業利益ウォーターフォール（売上差/粗利率差/販管費差影響）、
                ROIC・ROE前年差の要因分解、ネットキャッシュ前年差（現金差/負債差影響）、
                運転資本・CCC前年差（売掛金/棚卸資産/買掛金差影響、DSO/DIO/DPO差影響）を含みます。
                金額単位は百万円（JPY）、比率は%、日数は日。
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "years": .object([
                        "type": .string("integer"),
                        "description": .string("取得年数"),
                        "default": .int(Api.financialsYearsDefault),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
        Tool(
            name: "get_half_analysis",
            description: """
                銘柄コードの半期増減分析（前年差分解）を返します（格納済みデータのみ。未集計の場合は空を返します）。
                get_half_financial_summary と同じ水準値に加え、get_analysis と同じ増減分解フィールドを含みます
                （前期は「同じ半期の直近過去期」）。
                years は最大 \(Api.halfMaxYears) 年にクランプされます。
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "years": .object([
                        "type": .string("integer"),
                        "description": .string("取得年数（最大 \(Api.halfMaxYears)）"),
                        "default": .int(Api.halfFinancialsYearsDefault),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
        Tool(
            name: "get_filing_content",
            description: """
                EDINET 書類からセクションテキストを抽出します（格納済みデータのみ）。
                doc_id を省略すると最新の有価証券報告書を使用します。
                sections を省略すると全セクションを返します。
                利用可能なセクション: business_risks, mda, capex_overview, major_facilities, facility_plans, research_and_development, segments, geography
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "doc_id": .object([
                        "type": .string("string"),
                        "description": .string("書類ID（省略時は最新の有価証券報告書）"),
                    ]),
                    "sections": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("抽出セクションのリスト（省略時は全セクション）"),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
    ]
}
