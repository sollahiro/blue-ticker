// REST `/v1/skills` と MCP `tools/list` が共有する能力カタログ。
// エージェント向けの「いつ使うか / どう呼ぶか」説明の正本。
// MCP Tool 型は MCP SDK 依存のため、ここはプレーンな契約型のみを置く。

import Foundation

// MARK: - 契約型

/// REST skills 応答の `schema_version`。形を破壊的に変えたときのみ +1。
public let apiSkillsSchemaVersion = 1

/// パラメータの置き場所（REST パス変数 / クエリ）。
public enum ApiSkillParameterLocation: String, Sendable {
    case path
    case query
}

/// JSON Schema 相当の簡易型（MCP inputSchema へ写す）。
public enum ApiSkillParameterType: String, Sendable {
    case string
    case integer
    case stringArray = "array"
}

/// 省略時デフォルト（MCP schema の `default` と REST 説明用）。
public enum ApiSkillParameterDefault: Sendable, Equatable {
    case int(Int)
    case string(String)
}

/// 1 パラメータの説明。
/// `type` / `required` / `name` は REST（`GET /v1/skills`）の契約。
/// MCP 面だけ違う場合は `mcpName` / `mcpType` / `mcpRequired` で上書きする。
public struct ApiSkillParameter: Sendable {
    /// REST 上の名前（パス変数・クエリキー）。
    public let name: String
    public let location: ApiSkillParameterLocation
    /// REST ワイヤ上の型。
    public let type: ApiSkillParameterType
    public let description: String
    /// REST 上で必須か（サーバーが省略を受け入れるなら false）。
    public let required: Bool
    public let defaultValue: ApiSkillParameterDefault?
    /// MCP inputSchema 上の名前。nil なら MCP には出さない（REST 専用）。
    public let mcpName: String?
    /// MCP 上の型。nil なら `type` を使う。
    public let mcpType: ApiSkillParameterType?
    /// MCP 上で必須か。nil なら `required` を使う。
    public let mcpRequired: Bool?

    public init(
        name: String,
        location: ApiSkillParameterLocation,
        type: ApiSkillParameterType,
        description: String,
        required: Bool,
        defaultValue: ApiSkillParameterDefault? = nil,
        mcpName: String? = nil,
        mcpExposed: Bool = true,
        mcpType: ApiSkillParameterType? = nil,
        mcpRequired: Bool? = nil
    ) {
        self.name = name
        self.location = location
        self.type = type
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
        // mcpExposed=false で REST 専用。true かつ mcpName=nil なら REST 名をそのまま使う。
        self.mcpName = mcpExposed ? (mcpName ?? name) : nil
        self.mcpType = mcpExposed ? mcpType : nil
        self.mcpRequired = mcpExposed ? mcpRequired : nil
    }

    /// MCP 生成用の実効型。MCP 非公開なら nil。
    public var effectiveMcpType: ApiSkillParameterType? {
        guard mcpName != nil else { return nil }
        return mcpType ?? type
    }

    /// MCP 生成用の実効 required。MCP 非公開なら nil。
    public var effectiveMcpRequired: Bool? {
        guard mcpName != nil else { return nil }
        return mcpRequired ?? required
    }
}

/// 1 能力（REST エンドポイント相当）のスキル説明。
/// Agent Skills の name/description/instructions に相当する情報を持つ。
public struct ApiSkill: Sendable {
    /// 安定 ID（`GET /v1/skills/{id}` のキー。kebab-case）。
    public let id: String
    /// 短い表示名。
    public let name: String
    /// いつ使うか（エージェントが選択するための要約。MCP tool description と同一文面）。
    public let description: String
    /// HTTP メソッド。
    public let method: String
    /// REST パス（`{code}` 等のプレースホルダ付き）。
    public let path: String
    /// 対応 MCP ツール名。REST のみの能力は nil。
    public let mcpTool: String?
    /// `docs/feature-tiers.md` の機能枠。
    public let feature: String
    public let parameters: [ApiSkillParameter]
    /// 使い方の詳細（エラー意味・関連エンドポイント・単位など）。
    public let instructions: String
}

// MARK: - カタログ

/// 公開能力の完全一覧（順序はクライアント向けの推奨探索順）。
public func apiSkillsCatalog() -> [ApiSkill] {
    [
        ApiSkill(
            id: "search-companies",
            name: "企業検索",
            description: "銘柄コードまたは名称で企業を検索します。",
            method: "GET",
            path: "/v1/companies",
            mcpTool: "search_companies",
            feature: "discovery",
            parameters: [
                ApiSkillParameter(
                    name: "q",
                    location: .query,
                    type: .string,
                    description: "検索クエリ（銘柄コードまたは企業名）",
                    // REST は省略時空文字で受け付ける（400 にはしない）。MCP は required。
                    required: false,
                    mcpName: "query",
                    mcpRequired: true
                ),
            ],
            instructions: """
                銘柄コードが未知のときに最初に使う。ヒットした `code` を以降の financials / filings 等に渡す。
                REST の `q` 省略は空検索になる（必須ではない）。実質的な検索には `q` を付ける。
                例: GET /v1/companies?q=トヨタ
                """
        ),
        ApiSkill(
            id: "get-filings",
            name: "提出書類一覧",
            description: "銘柄コードに紐づく EDINET 書類一覧を取得します。",
            method: "GET",
            path: "/v1/companies/{code}/filings",
            mcpTool: "get_filings",
            feature: "filing",
            parameters: [
                ApiSkillParameter(
                    name: "code",
                    location: .path,
                    type: .string,
                    description: "銘柄コード（例: 6103）",
                    required: true
                ),
                ApiSkillParameter(
                    name: "max_years",
                    location: .query,
                    type: .integer,
                    description: "取得年数",
                    required: false,
                    defaultValue: .int(Api.filingsMaxYearsDefault)
                ),
            ],
            instructions: """
                有報・半期などの doc_id を知るときに使う。filing-content / breakdown の doc_id 指定の前段。
                DB 同期済みなら DB から返し、未同期銘柄のみライブ EDINET 探索へフォールバックする。
                例: GET /v1/companies/6103/filings?max_years=5
                """
        ),
        ApiSkill(
            id: "get-financials",
            name: "通期財務サマリー",
            description: """
                銘柄コードの財務サマリーを年度別に返します（格納済みデータのみ。未集計の場合は空を返します）。
                損益・CF・バランスシート・収益性指標（水準値）を含みます。直近\(Api.financialsYearsDefault)年分を返します。
                前年差・要因分解（増減分析）は get_waterfall を使ってください。
                金額単位は百万円（JPY）、比率は%、株主指標は円。
                """,
            method: "GET",
            path: "/v1/companies/{code}/financials",
            mcpTool: "get_financial_summary",
            feature: "summary",
            parameters: [
                ApiSkillParameter(
                    name: "code",
                    location: .path,
                    type: .string,
                    description: "銘柄コード（例: 6103）",
                    required: true
                ),
                ApiSkillParameter(
                    name: "years",
                    location: .query,
                    type: .integer,
                    description: "取得年数",
                    required: false,
                    defaultValue: .int(Api.financialsYearsDefault),
                    mcpExposed: false
                ),
            ],
            instructions: """
                Summary（水準値）。増減分解が必要なら get-waterfall。
                格納済みデータのみ。未集計は 404、DB 非接続は 503。ライブ計算へはフォールバックしない。
                金額単位は百万円（JPY）、比率は%、株主指標は円。
                MCP は years 固定（既定年数）。REST のみ years クエリで調整可。
                例: GET /v1/companies/6103/financials?years=5
                """
        ),
        ApiSkill(
            id: "get-waterfall",
            name: "通期増減分析",
            description: """
                銘柄コードの増減分析（前年差分解）を年度別に返します（格納済みデータのみ。未集計の場合は空を返します）。
                get_financial_summary と同じ水準値に加え、事業利益ウォーターフォール（売上差/粗利率差/販管費差影響）、
                ROIC・ROE前年差の要因分解、ネットキャッシュ前年差（現金差/負債差影響）、
                運転資本・CCC前年差（売掛金/棚卸資産/買掛金差影響、DSO/DIO/DPO差影響）を含みます。直近\(Api.financialsYearsDefault)年分を返します。
                金額単位は百万円（JPY）、比率は%、日数は日。
                """,
            method: "GET",
            path: "/v1/companies/{code}/waterfall",
            mcpTool: "get_waterfall",
            feature: "waterfall",
            parameters: [
                ApiSkillParameter(
                    name: "code",
                    location: .path,
                    type: .string,
                    description: "銘柄コード（例: 6103）",
                    required: true
                ),
                ApiSkillParameter(
                    name: "years",
                    location: .query,
                    type: .integer,
                    description: "取得年数",
                    required: false,
                    defaultValue: .int(Api.financialsYearsDefault),
                    mcpExposed: false
                ),
            ],
            instructions: """
                Waterfall（Summary + 前年差・要因分解）。水準値だけなら get-financials で足りる。
                格納済みデータのみ。未集計は 404、DB 非接続は 503。
                MCP は years 固定（既定年数）。REST のみ years クエリで調整可。
                例: GET /v1/companies/6103/waterfall?years=5
                """
        ),
        ApiSkill(
            id: "get-filing-content",
            name: "有報セクション本文",
            description: """
                EDINET 書類からセクションテキストを抽出します（格納済みデータのみ）。
                doc_id を省略すると最新の有価証券報告書を使用します。
                sections を省略すると全セクションを返します。
                利用可能なセクション: business_risks, mda, capex_overview, major_facilities, facility_plans, research_and_development, segments, geography
                """,
            method: "GET",
            path: "/v1/companies/{code}/filing-content",
            mcpTool: "get_filing_content",
            feature: "filing",
            parameters: [
                ApiSkillParameter(
                    name: "code",
                    location: .path,
                    type: .string,
                    description: "銘柄コード（例: 6103）",
                    required: true
                ),
                ApiSkillParameter(
                    name: "doc_id",
                    location: .query,
                    type: .string,
                    description: "書類ID（省略時は最新の有価証券報告書）",
                    required: false
                ),
                ApiSkillParameter(
                    name: "sections",
                    location: .query,
                    type: .string,
                    description: "抽出セクション（カンマ区切り。省略時は全セクション）",
                    required: false,
                    // MCP は文字列配列。REST ワイヤはクエリ1文字列。
                    mcpType: .stringArray
                ),
            ],
            instructions: """
                有報のテキスト抽出（Filing）。事業別売上の構造化数値は get-breakdown。
                格納済みデータのみ。未抽出は 404、DB 非接続は 503。
                REST: ?sections=mda,business_risks（カンマ区切り文字列）。MCP: 文字列配列。
                例: GET /v1/companies/6103/filing-content?sections=mda,business_risks
                """
        ),
        ApiSkill(
            id: "get-breakdown",
            name: "事業別・地域別売上内訳",
            description: """
                有価証券報告書から事業別/地域別売上高・従業員数・研究開発費の内訳を取得します（格納済みデータのみ）。
                対象は日経225構成銘柄に限ります。doc_id を省略すると最新の有価証券報告書を使用します。
                axis は business（既定）/ geography / employees / research_and_development に対応。
                employees・research_and_development は決定論のみ（LLMフォールバックなし）で、
                報告セグメント別の内訳が開示されている企業のみ値が入ります。
                """,
            method: "GET",
            path: "/v1/companies/{code}/breakdown",
            mcpTool: "get_breakdown",
            feature: "breakdown",
            parameters: [
                ApiSkillParameter(
                    name: "code",
                    location: .path,
                    type: .string,
                    description: "銘柄コード（例: 6758）",
                    required: true
                ),
                ApiSkillParameter(
                    name: "doc_id",
                    location: .query,
                    type: .string,
                    description: "書類ID（省略時は最新の有価証券報告書）",
                    required: false
                ),
                ApiSkillParameter(
                    name: "axis",
                    location: .query,
                    type: .string,
                    description: "内訳の軸（business / geography / employees / research_and_development。省略時 business）",
                    required: false,
                    defaultValue: .string("business")
                ),
            ],
            instructions: """
                Breakdown（事業別/地域別売上・従業員数・研究開発費の構造化）。
                自由テキストのセグメント記述は get-filing-content の segments。
                日経225構成銘柄のみ。格納済みデータのみ。未算出は 404、DB 非接続は 503。
                例: GET /v1/companies/6758/breakdown?axis=business
                例: GET /v1/companies/6758/breakdown?axis=geography
                例: GET /v1/companies/6758/breakdown?axis=employees
                """
        ),
        ApiSkill(
            id: "get-statement",
            name: "財務諸表（BS/PL/CF）完全正規化",
            description: """
                有価証券報告書から貸借対照表・損益計算書・キャッシュ・フロー計算書を、企業間の科目統一を
                試みずそのまま構造化して返します（格納済みデータのみ）。Summary/Waterfall の絞り込んだ
                ~20指標とは異なり、開示された全項目（企業拡張タグ含む）を返します。
                対象は日経225構成銘柄に限ります。doc_id を省略すると最新の有価証券報告書を使用します。
                注記（statement-notes）は別ツール get-statement-notes の対象。
                """,
            method: "GET",
            path: "/v1/companies/{code}/statement",
            mcpTool: "get_statement",
            feature: "statement",
            parameters: [
                ApiSkillParameter(
                    name: "code",
                    location: .path,
                    type: .string,
                    description: "銘柄コード（例: 7203）",
                    required: true
                ),
                ApiSkillParameter(
                    name: "doc_id",
                    location: .query,
                    type: .string,
                    description: "書類ID（省略時は直近 years 件の有価証券報告書）",
                    required: false
                ),
                ApiSkillParameter(
                    name: "years",
                    location: .query,
                    type: .integer,
                    description: "取得年数",
                    required: false,
                    defaultValue: .int(Api.statementYearsDefault)
                ),
            ],
            instructions: """
                Statement（BS/PL/CF の全項目正規化）。絞り込んだ主要指標だけなら get-financials。
                日経225構成銘柄のみ。格納済みデータのみ。未抽出は 404、DB 非接続は 503。
                表示順（order）は有価証券報告書の presentation linkbase 通り（取得できないタグはタグ名
                アルファベット順へフォールバック）。BS/CF の各行には区分（section: assets/liabilities/
                net_assets、operating/investing/financing）が付く場合がある（複数区分にまたがる合計行は
                null）。PL の行には section を付けない。各行の is_total は計算リンクベース由来で、true の
                場合 components（構成タグと weight。+1=加算、-1=控除）から二重計上せず合計を検算・
                再構成できる（複数区分にまたがるグランドトータル行も components は取得できる）。
                例: GET /v1/companies/7203/statement?years=3
                """
        ),
        ApiSkill(
            id: "get-statement-notes",
            name: "財務諸表注記",
            description: """
                貸借対照表・損益計算書・キャッシュ・フロー計算書（get-statement）の外にある注記
                （EPS・発行済株式数・研究開発費・設備投資概要・配当金・
                借入金等明細表・政策保有株式・有形固定資産等明細表・のれん及び無形資産明細）を
                note_type 単位で取得します（格納済みデータのみ）。
                対象は日経225構成銘柄に限ります。doc_id を省略すると最新の有価証券報告書を使用します。
                """,
            method: "GET",
            path: "/v1/companies/{code}/statement/notes",
            mcpTool: "get_statement_notes",
            feature: "statement_notes",
            parameters: [
                ApiSkillParameter(
                    name: "code",
                    location: .path,
                    type: .string,
                    description: "銘柄コード（例: 7203）",
                    required: true
                ),
                ApiSkillParameter(
                    name: "note_type",
                    location: .query,
                    type: .string,
                    description: """
                        注記種別: per_share_information / issued_shares / research_and_development / \
                        capital_expenditures_overview / dividends / \
                        borrowings_schedule / policy_holding_securities / \
                        property_plant_equipment_schedule / goodwill_and_intangibles
                        """,
                    required: true
                ),
                ApiSkillParameter(
                    name: "doc_id",
                    location: .query,
                    type: .string,
                    description: "書類ID（省略時は最新の有価証券報告書）",
                    required: false
                ),
            ],
            instructions: """
                Statement Notes（get-statement 本体の外にある財務諸表注記、note_type 単位）。
                日経225構成銘柄のみ。格納済みデータのみ。未算出は 404、DB 非接続は 503。
                property_plant_equipment_schedule / goodwill_and_intangibles は IFRS連結企業限定
                （J-GAAP単体の附属明細表は未対応）。
                例: GET /v1/companies/7203/statement/notes?note_type=policy_holding_securities
                """
        ),
    ]
}

/// ID で 1 件取得。未知 ID は nil。
public func apiSkill(id: String) -> ApiSkill? {
    apiSkillsCatalog().first { $0.id == id }
}

// MARK: - JSON 投影（REST）

/// `GET /v1/skills` 一覧応答。
public func apiSkillsListJSON() -> [String: Any] {
    [
        "schema_version": apiSkillsSchemaVersion,
        "overview": """
            Blue Ticker REST API の能力カタログ。各 skill は MCP ツール説明に相当する「いつ使うか／どう呼ぶか」の案内。\
            詳細は GET /v1/skills/{id}。契約の正は REST。MCP は追従面。格納系は未集計 404・DB 非接続 503。
            """,
        "skills": apiSkillsCatalog().map { apiSkillSummaryJSON($0) },
    ]
}

/// `GET /v1/skills/{id}` 詳細応答。
public func apiSkillDetailJSON(_ skill: ApiSkill) -> [String: Any] {
    var json = apiSkillSummaryJSON(skill)
    json["schema_version"] = apiSkillsSchemaVersion
    json["parameters"] = skill.parameters.map { apiSkillParameterJSON($0) }
    json["instructions"] = skill.instructions
    return json
}

private func apiSkillSummaryJSON(_ skill: ApiSkill) -> [String: Any] {
    var json: [String: Any] = [
        "id": skill.id,
        "name": skill.name,
        "description": skill.description,
        "method": skill.method,
        "path": skill.path,
        "feature": skill.feature,
    ]
    if let mcpTool = skill.mcpTool {
        json["mcp_tool"] = mcpTool
    }
    return json
}

private func apiSkillParameterJSON(_ parameter: ApiSkillParameter) -> [String: Any] {
    var json: [String: Any] = [
        "name": parameter.name,
        "in": parameter.location.rawValue,
        "type": parameter.type.rawValue,
        "description": parameter.description,
        "required": parameter.required,
    ]
    switch parameter.defaultValue {
    case .int(let value):
        json["default"] = value
    case .string(let value):
        json["default"] = value
    case nil:
        break
    }
    return json
}
