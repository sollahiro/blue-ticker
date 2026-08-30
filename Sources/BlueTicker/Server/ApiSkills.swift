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
    /// REST 能力カタログの機能枠（`docs/architecture.md`）。
    public let feature: String
    public let parameters: [ApiSkillParameter]
    /// 使い方の詳細（エラー意味・関連エンドポイント・単位など）。
    public let instructions: String
    /// MCP `tools/list` の outputSchema 用 JSON Schema 文字列。REST `/v1/skills` には出さない。
    public let mcpOutputSchema: String?
}

// MARK: - カタログ

/// get_financial_summary / get_waterfall の MCP outputSchema（同一 envelope）。
private let mcpOutputSchemaFinancialEnvelope =
    """
    {"type":"object","required":["schema_version","code","name","sector","market","currency","unit","years"],\
    "properties":{"schema_version":{"type":"integer"},"code":{"type":"string"},"name":{"type":"string"},\
    "sector":{"type":"string"},"market":{"type":"string"},"currency":{"type":"string"},"unit":{"type":"string"},\
    "years":{"type":"array","items":{"type":"object"}}}}
    """

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
                """,
            mcpOutputSchema:
                """
                {"type":"object","required":["results"],"properties":{"results":{"type":"array","items":\
                {"type":"object","required":["code","name"],"properties":{"code":{"type":"string"},\
                "name":{"type":"string"},"sector":{"type":"string"},"market":{"type":"string"},\
                "location":{"type":"string"}}}}}}
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
                """,
            mcpOutputSchema:
                """
                {"type":"object","required":["code","name","filings"],"properties":{"code":{"type":"string"},\
                "name":{"type":"string"},"filings":{"type":"array","items":{"type":"object",\
                "required":["doc_id","doc_type","doc_type_label","fy_end","submitted_at"],\
                "properties":{"doc_id":{"type":"string"},"doc_type":{"type":"string"},\
                "doc_type_label":{"type":"string"},"fy_end":{"type":"string"},\
                "submitted_at":{"type":"string"}}}}}}
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
                """,
            mcpOutputSchema: mcpOutputSchemaFinancialEnvelope
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
                """,
            mcpOutputSchema: mcpOutputSchemaFinancialEnvelope
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
                """,
            mcpOutputSchema:
                """
                {"type":"object","required":["code","doc_id","sections"],"properties":{"code":{"type":"string"},\
                "doc_id":{"type":"string"},"sections":{"type":"object"}}}
                """
        ),
        ApiSkill(
            id: "get-breakdown",
            name: "事業別・地域別売上内訳",
            description: """
                有価証券報告書から事業別/地域別売上高、従業員数、研究開発費、のれん、
                報告セグメント別の資産・減価償却費及び償却費・のれんの償却額・減損損失・
                持分法会計処理される投資・資本的支出・非流動性資産への追加額を取得します（格納済みデータのみ）。
                対象は取り込み済みの上場企業です。doc_id を省略すると最新の有価証券報告書を使用します。
                axis は business（既定）/ geography / employees / research_and_development / goodwill /
                segment_assets / depreciation_and_amortization / goodwill_amortization / impairment_loss /
                equity_method_investments / capital_expenditures /
                capital_expenditures_overview / noncurrent_asset_additions に対応。
                これらの決定論軸は LLM フォールバックなしで、
                報告セグメント別の内訳が開示されている企業のみ値が入ります。
                内訳が取得できない場合は 404 とともに reason が返ることがあります（reason 無しの 404 は単に未取り込み）。
                axis=business: geography_only（報告セグメントが地域別のみで事業別への変換不可）、
                single_segment_disclosed（単一セグメントのため報告セグメント開示自体を省略）、
                unknown（原因未特定・要再調査）。
                axis=geography: not_found（地域別情報の注記自体が存在しない）、unknown（抽出失敗・要再調査）。
                決定論軸: not_found（セグメント別内訳が非開示）。
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
                    description: "内訳の軸（business / geography / employees / research_and_development / goodwill / segment_assets / depreciation_and_amortization / goodwill_amortization / impairment_loss / equity_method_investments / capital_expenditures / capital_expenditures_overview / noncurrent_asset_additions。省略時 business）",
                    required: false,
                    defaultValue: .string("business")
                ),
            ],
            instructions: """
                Breakdown（事業別/地域別売上、従業員数、研究開発費、のれん、報告セグメント別指標の構造化）。
                自由テキストのセグメント記述は get-filing-content の segments。
                格納済みデータのみ。未算出は 404、DB 非接続は 503。
                例: GET /v1/companies/6758/breakdown?axis=business
                例: GET /v1/companies/6758/breakdown?axis=geography
                例: GET /v1/companies/6758/breakdown?axis=employees
                """,
            mcpOutputSchema:
                """
                {"type":"object","required":["code","doc_id","axis","breakdown"],"properties":{"code":\
                {"type":"string"},"doc_id":{"type":"string"},"axis":{"type":"string"},\
                "breakdown":{"type":"object"},"llm_audit":{"type":"object"}}}
                """
        ),
        ApiSkill(
            id: "get-statement",
            name: "財務諸表（BS/PL/CF/SS）完全正規化",
            description: """
                有価証券報告書から貸借対照表・損益計算書・キャッシュ・フロー計算書・持分変動計算書
                （株主資本等変動計算書）を、企業間の科目統一を試みずそのまま構造化して返します
                （格納済みデータのみ）。Summary/Waterfall の絞り込んだ ~20指標とは異なり、開示された
                全項目（企業拡張タグ含む）を返します。持分変動計算書は合計列のみ（資本構成員別の
                行列展開はしない）。対象は日経225構成銘柄に限ります。doc_id を省略すると最新の
                有価証券報告書を使用します。注記（statement-notes）は別ツール get-statement-notes の対象。
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
                Statement（BS/PL/CF/SS の全項目正規化）。絞り込んだ主要指標だけなら get-financials。
                日経225構成銘柄のみ。格納済みデータのみ。未抽出は 404、DB 非接続は 503。
                表示順（order）は有価証券報告書の presentation linkbase 通り（取得できないタグはタグ名
                アルファベット順へフォールバック）。BS/CF の各行には区分（section: assets/liabilities/
                net_assets、operating/investing/financing）が付く場合がある（複数区分にまたがる合計行は
                null）。PL/SS の行には section を付けない。SS（changes_in_equity）は合計列のみ。
                各行の is_total は計算リンクベース由来で、true の場合 components（構成タグと weight。
                +1=加算、-1=控除）から二重計上せず合計を検算・再構成できる（複数区分にまたがる
                グランドトータル行も components は取得できる）。US-GAAP 連結は HTML 経路のため
                is_total はラベル規則、components はキヤノン型（合計直後の内訳が親と一致）のみ。
                例: GET /v1/companies/7203/statement?years=3
                """,
            mcpOutputSchema:
                """
                {"type":"object","required":["schema_version","code","name","sector","market","years"],\
                "properties":{"schema_version":{"type":"integer"},"code":{"type":"string"},\
                "name":{"type":["string","null"]},"sector":{"type":["string","null"]},\
                "market":{"type":["string","null"]},"years":{"type":"array","items":{"type":"object"}}}}
                """
        ),
        ApiSkill(
            id: "get-statement-notes",
            name: "財務諸表注記",
            description: """
                貸借対照表・損益計算書・キャッシュ・フロー計算書（get-statement）の外にある注記
                （EPS・発行済株式数・配当金・
                借入金等明細表・政策保有株式・有形固定資産等明細表・のれん及び無形資産明細・
                リース負債・販売費及び一般管理費の費目内訳）を
                note_type 単位で取得します（格納済みデータのみ）。
                対象は日経225構成銘柄に限ります。doc_id を省略すると最新の有価証券報告書を使用します。
                注記が取得できない場合はエラー応答とともに reason が返ることがあります
                （reason 無しは単に未取り込み。REST では 404、MCP では isError）。
                not_found（当該 note_type の開示・XBRLタグが見つからない＝正当な欠測）、
                available_via_statement（本 note_type の対象外だが同等の値は get-statement から取得可能。
                例: property_plant_equipment_schedule / lease_liabilities で BS に区分・負債の
                構造化タグ当期値がある場合。goodwill_and_intangibles は IFRS 注記限定のため非対象時も同様）、
                available_via_notes（本 note_type の対象外だが同等の値は他の note_type から取得可能。
                例: lease_liabilities のリース債務が borrowings_schedule＝借入金等明細表側にある場合）、
                us_gaap_unsupported（US-GAAP 連結で本 note_type の構造化タグ判定ができない場合）。
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
                        注記種別: per_share_information / issued_shares_and_capital / \
                        dividends / \
                        borrowings_schedule / policy_holding_securities / \
                        property_plant_equipment_schedule / goodwill_and_intangibles / \
                        lease_liabilities
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
                日経225構成銘柄のみ。格納済みデータのみ。未算出は 404（reason 無し）、
                対象外・非開示は 404 + reason（not_found / available_via_statement /
                available_via_notes / us_gaap_unsupported）、DB 非接続は 503。
                property_plant_equipment_schedule / lease_liabilities は IFRS 注記（または TextBlock）を
                優先し、それ以外は BS 構造化タグ当期値で available_via_statement（lease は借入金等明細表の
                リース債務なら available_via_notes。US-GAAP は us_gaap_unsupported）。
                goodwill_and_intangibles は IFRS 注記限定。
                例: GET /v1/companies/7203/statement/notes?note_type=policy_holding_securities
                """,
            mcpOutputSchema:
                """
                {"type":"object","required":["code","doc_id","note_type","note"],"properties":{"code":\
                {"type":"string"},"doc_id":{"type":"string"},"note_type":{"type":"string"},\
                "note":{"type":"object"}}}
                """
        ),
        ApiSkill(
            id: "get-feed-updates",
            name: "開示更新フィード",
            description: """
                直近に提出された上場企業の有報などの書類を、提出日時の新しい順で返します（既定は直近7日）。
                件数は当日（total.day）と直近1週間（total.week）。銘柄横断の更新情報です。
                1 社の書類一覧は get_filings を使ってください。
                """,
            method: "GET",
            path: "/v1/feed/updates",
            mcpTool: "get_feed_updates",
            feature: "feed",
            parameters: [
                ApiSkillParameter(
                    name: "limit",
                    location: .query,
                    type: .integer,
                    description: "返却件数（最大 \(Api.feedLimitMax)）",
                    required: false,
                    defaultValue: .int(Api.feedLimitDefault)
                ),
                ApiSkillParameter(
                    name: "days",
                    location: .query,
                    type: .integer,
                    description: "items の窓（日。最大 \(Api.feedTrendDaysMax)。total.week は常に直近7日）",
                    required: false,
                    defaultValue: .int(Api.feedTrendDaysDefault)
                ),
                ApiSkillParameter(
                    name: "doc_type",
                    location: .query,
                    type: .string,
                    description: "書類種別（カンマ区切り。120 有報 / 130 訂正有報 / 140 四半期 / 160 半期。省略時 120）",
                    required: false,
                    defaultValue: .string(Api.docTypeAnnualReport)
                ),
            ],
            instructions: """
                Feed Update。sync 済み `edinet_documents` の上場提出（証券コード末尾 0）のみ。
                items はクエリ days 窓の提出日時降順（既定 7 日）。
                `date` は集計した UTC 暦日。`total.day` はその日、`total.week` は直近7日の上場提出件数（limit で切る前。days とは独立）。
                空でも 200（items=[]）。DB 非接続は 503。ライブ EDINET へはフォールバックしない。
                RSS は未提供（REST が契約の正。MCP は追従）。
                例: GET /v1/feed/updates?days=7&limit=20
                例: GET /v1/feed/updates?doc_type=120,160
                """,
            mcpOutputSchema:
                """
                {"type":"object","required":["schema_version","date","days","total","items"],"properties":\
                {"schema_version":{"type":"integer"},"date":{"type":"string"},"days":{"type":"integer"},\
                "total":{"type":"object","required":["day","week"],"properties":{"day":{"type":"integer"},\
                "week":{"type":"integer"}}},"doc_types":{"type":"array","items":{"type":"string"}},"items":\
                {"type":"array","items":{"type":"object","required":["code","name","doc_id","doc_type",\
                "doc_type_label","fy_end","submitted_at"],"properties":{"code":{"type":"string"},\
                "name":{"type":"string"},"doc_id":{"type":"string"},"doc_type":{"type":"string"},\
                "doc_type_label":{"type":"string"},"fy_end":{"type":"string"},\
                "submitted_at":{"type":"string"}}}}}}
                """
        ),
        ApiSkill(
            id: "get-feed-trend",
            name: "検索トレンド",
            description: """
                直近に検索・参照された銘柄を件数の多い順で返します（匿名のコマンド回数。提出書類の件数ではありません）。
                銘柄の直近提出は get_feed_updates、1社の書類一覧は get_filings を使ってください。
                """,
            method: "GET",
            path: "/v1/feed/trend",
            mcpTool: "get_feed_trend",
            feature: "feed",
            parameters: [
                ApiSkillParameter(
                    name: "limit",
                    location: .query,
                    type: .integer,
                    description: "返却件数（最大 \(Api.feedLimitMax)）",
                    required: false,
                    defaultValue: .int(Api.feedLimitDefault)
                ),
                ApiSkillParameter(
                    name: "days",
                    location: .query,
                    type: .integer,
                    description: "集計窓（日。直近 N×24h。最大 \(Api.feedTrendDaysMax)）",
                    required: false,
                    defaultValue: .int(Api.feedTrendDaysDefault)
                ),
                ApiSkillParameter(
                    name: "code",
                    location: .query,
                    type: .string,
                    description: "4桁コード。指定するとその銘柄のツール別・面別・検索クエリ内訳",
                    required: false
                ),
            ],
            instructions: """
                Feed Trend。匿名の search_companies および各ツールヒット回数（MCP と REST を区別）。
                顧客アカウントや IP は持たない。書き込みは origin からカウンターへ fire-and-forget（失敗しても本 API は 200/404/503 のまま）。
                items は code ごとの件数降順。空でも 200（items=[]）。カウンター未設定・取得失敗は 503。
                提出件数ランキングは出さない（それは get_feed_updates）。
                RSS は未提供（REST が契約の正。MCP は追従）。
                例: GET /v1/feed/trend?days=7&limit=20
                例: GET /v1/feed/trend?code=7203
                """,
            mcpOutputSchema:
                """
                {"type":"object","required":["schema_version","date","days","items"],"properties":\
                {"schema_version":{"type":"integer"},"date":{"type":"string"},"days":{"type":"integer"},\
                "code":{"type":"string"},"items":{"type":"array","items":{"type":"object","required":\
                ["code","name","count"],"properties":{"code":{"type":"string"},"name":{"type":"string"},\
                "count":{"type":"integer"}}}},"by_tool":{"type":"array","items":{"type":"object"}},\
                "by_surface":{"type":"array","items":{"type":"object"}},\
                "by_query":{"type":"array","items":{"type":"object"}}}}
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
