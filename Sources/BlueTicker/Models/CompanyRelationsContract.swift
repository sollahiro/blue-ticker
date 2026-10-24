// 関係（顧客・仕入先・グループ会社・出資先・大株主）の格納契約。
// 材料は最新の有報（120）1 件の「主要な顧客ごとの情報」「関係会社の状況」「提出会社の親会社等の情報」
// 「株式の保有状況（特定投資株式・みなし保有株式）」「大株主の状況」。
// 格納は `company_relations`（1 行 = 書類 1 件の相手 1 件）。ingest stage は `relations`。
// 公開 REST は `GET /v1/companies/{code}/relations`（MCP には出さない）。

import Foundation

/// `company_relations.cache_version`。抽出・格納の意味を破壊的に変えたときだけ上げる
/// （`.agents/rules/versioning.md`）。名前解決の結果（`related_code` / `resolution`）は版に含めない。
public let companyRelationsCacheVersion = "relations-v2"

// MARK: - section（材料の節）

public let relationSectionMainCustomers = "main_customers"
public let relationSectionAffiliatedEntities = "affiliated_entities"
public let relationSectionParentCompanyInfo = "parent_company_info"
public let relationSectionPolicyHoldings = "policy_holdings"
public let relationSectionMajorShareholders = "major_shareholders"

// MARK: - kind（相手の役割）

public let relationKindCustomer = "customer"
public let relationKindParent = "parent"
public let relationKindSubsidiary = "subsidiary"
/// 持分法適用関連会社・持分法適用非連結子会社・非連結子会社。
public let relationKindAffiliate = "affiliate"
public let relationKindOtherRelated = "other_related"
/// 政策保有株式（特定投資株式・みなし保有株式）の銘柄。
public let relationKindInvestee = "investee"
public let relationKindMajorShareholder = "major_shareholder"
/// 表はあるが区分が決まらない行（Jev が 0.9 未満・未採用、または Jev キーなし）。公開しない。
public let relationKindUnclassified = "unclassified"
/// 節の状態だけを持つ行（`section_status`。相手は無い）。「省略」と「未抽出」を区別する。
public let relationKindNone = "none"

/// 関係会社表の区分（Jev の選択肢と同じ並び）。
public let relationGroupKinds = [
    relationKindParent, relationKindSubsidiary, relationKindAffiliate, relationKindOtherRelated,
]

// MARK: - section_status（kind = none の行）

/// 提出会社が記載を省略した（例「売上高の 10% 以上を占める相手先がないため記載を省略」）。
public let relationSectionStatusOmitted = "omitted"
/// 要素はあるが表が無く文だけ（省略文ではない）。
public let relationSectionStatusNoTable = "no_table"
/// 要素自体が無い。
public let relationSectionStatusNotFound = "not_found"
/// 構造化タグが無い（大株主・政策保有株式）。
public let relationSectionStatusNoTags = "no_tags"
/// 政策保有株式の上場銘柄数が 1 以上なのに銘柄名タグが無い（HTML 表だけ。Jev 列選択の候補）。
public let relationSectionStatusUntaggedTable = "untagged_table"

// MARK: - decided_by

public let relationDecidedByRule = "rule"
public let relationDecidedByJev = "jev"

// MARK: - holder（政策保有株式の保有主体）

public let relationHolderReportingCompany = "reporting_company"
public let relationHolderLargestHoldingCompany = "largest_holding_company"
public let relationHolderSecondLargestHoldingCompany = "second_largest_holding_company"

// MARK: - resolution（名前解決。すべて決定論）

/// EDINET 提出者名（正規化後）の完全一致で上場企業に一意。
public let relationResolutionNameExact = "name_exact"
/// EDINET 提出者名（英字）の完全一致で上場企業に一意。
public let relationResolutionNameEnExact = "name_en_exact"
/// 上場会社の (連結子会社) 行と一致し、親が 1 社に決まる。`related_code` は親。
public let relationResolutionViaListedParent = "via_listed_parent"
/// 上場していない EDINET 提出者に一致（`related_code` は null）。
public let relationResolutionEdinetUnlisted = "edinet_unlisted"
/// 候補が 2 社以上（黙って選ばない。`needs_review`）。
public let relationResolutionAmbiguous = "ambiguous"
/// どれにも当たらない。
public let relationResolutionUnresolved = "unresolved"

// MARK: - 抽出結果（Core → ingest）

/// 関係 1 行（書類 1 件の相手 1 件）。`kind == none` の行は節の状態だけを持つ。
public struct CompanyRelationDraft: Sendable, Equatable {
    public var section: String
    public var kind: String
    /// 節内の出現順（0 始まり）。応答の並びに使う。
    public var position: Int
    public var nameRaw: String
    public var amountYen: Double?
    /// 顧客表の「関連するセグメント名」、関係会社表の「主要な事業の内容」。
    public var segmentLabel: String?
    /// 関係会社表の議決権の所有（親会社・その他の関係会社は被所有）割合（％、記載どおり）。間接所有を含む合計。
    public var votingRatio: Double?
    /// 議決権の割合のうち間接所有の内数（「100.0(66.5)」の括弧）。
    public var votingRatioIndirect: Double?
    /// 緊密な者・同意している者の議決権の外数（「100.0[30.0]」の［ ］）。
    public var votingRatioCloseParties: Double?
    public var decidedBy: String
    public var needsReview: Bool
    public var shares: Double?
    public var bookValueYen: Double?
    public var purpose: String?
    public var isDeemed: Bool?
    public var holder: String?
    /// 大株主の「発行済株式の総数に対する所有株式数の割合」（XBRL の値。0.128 = 12.8%）。
    public var ratio: Double?
    /// 大株主の順位（1 始まり）。
    public var rank: Int?
    /// 大株主の住所（保存のみ。応答には載せない）。
    public var address: String?
    /// `kind == none` の行だけ（`relationSectionStatus*`）。
    public var sectionStatus: String?

    public init(
        section: String, kind: String, position: Int, nameRaw: String,
        amountYen: Double? = nil, segmentLabel: String? = nil, votingRatio: Double? = nil,
        votingRatioIndirect: Double? = nil, votingRatioCloseParties: Double? = nil,
        decidedBy: String = relationDecidedByRule, needsReview: Bool = false,
        shares: Double? = nil, bookValueYen: Double? = nil, purpose: String? = nil,
        isDeemed: Bool? = nil, holder: String? = nil, ratio: Double? = nil, rank: Int? = nil,
        address: String? = nil, sectionStatus: String? = nil
    ) {
        self.section = section
        self.kind = kind
        self.position = position
        self.nameRaw = nameRaw
        self.amountYen = amountYen
        self.segmentLabel = segmentLabel
        self.votingRatio = votingRatio
        self.votingRatioIndirect = votingRatioIndirect
        self.votingRatioCloseParties = votingRatioCloseParties
        self.decidedBy = decidedBy
        self.needsReview = needsReview
        self.shares = shares
        self.bookValueYen = bookValueYen
        self.purpose = purpose
        self.isDeemed = isDeemed
        self.holder = holder
        self.ratio = ratio
        self.rank = rank
        self.address = address
        self.sectionStatus = sectionStatus
    }

    /// 節の状態だけの行。
    public static func status(section: String, _ status: String) -> CompanyRelationDraft {
        CompanyRelationDraft(
            section: section, kind: relationKindNone, position: 0, nameRaw: "",
            sectionStatus: status)
    }
}

/// 書類 1 件分の抽出結果。どの節も行か `kind == none` の状態行を必ず 1 つ以上持つ。
public struct CompanyRelationsExtraction: Sendable, Equatable {
    public var rows: [CompanyRelationDraft]
    /// 当期末（`CurrentFiscalYearEndDateDEI`、`YYYY-MM-DD`）。取れなければ nil。
    public var fyEnd: String?
    /// 訂正 overlay 回帰の warning（`overlay_regression:…`）。付いた書類の行は公開しない。
    public var warnings: [String]

    public init(rows: [CompanyRelationDraft], fyEnd: String?, warnings: [String] = []) {
        self.rows = rows
        self.fyEnd = fyEnd
        self.warnings = warnings
    }
}

/// ingest の抽出関数の結果。
public enum CompanyRelationsResolveResult: Sendable {
    case extracted(CompanyRelationsExtraction)
    /// 書類取得・展開の失敗。行は作らない（次回再試行）。
    case failed
}

// MARK: - 公開可否（serve 時の純関数）

/// 公開 REST が格納行を出してよいか。格納行・`cache_version` は触らない（breakdown と同じ形）。
/// - Jev 由来（`decided_by = jev`）の `needs_review` は出さない（fail closed）。ただし `needs_review` が
///   名前解決の `ambiguous` だけによるとき（Jev が区分を採用した行）は出す。
/// - 決定論の `needs_review`（名前解決の `ambiguous`）は出す（呼び出し側が `company: null`）。
/// - 訂正 overlay 回帰の warning が付いた書類の行は出さない。
/// - 区分の決まらない行（`unclassified`）は出さない。
public func isPubliclyServableRelation(
    kind: String, decidedBy: String, needsReview: Bool, resolution: String?, warning: String?
) -> Bool {
    if let warning, hasOverlayRegressionWarning([warning]) { return false }
    if kind == relationKindUnclassified { return false }
    if decidedBy == relationDecidedByJev, needsReview, resolution != relationResolutionAmbiguous {
        return false
    }
    return true
}

// MARK: - 名前解決の材料

/// EDINET コードリスト（`assets/EdinetcodeDlInfo.csv`）の 1 行。証券コードの無い提出者も含む。
public struct EdinetFilerName: Sendable, Equatable {
    public var edinetCode: String
    /// 提出者名。
    public var name: String
    /// 提出者名（英字）。無ければ空。
    public var nameEn: String
    /// 上場（「上場区分」= 上場）かつ証券コードがあるときの 4 桁コード。それ以外は nil。
    public var listedCode: String?

    public init(edinetCode: String, name: String, nameEn: String, listedCode: String?) {
        self.edinetCode = edinetCode
        self.name = name
        self.nameEn = nameEn
        self.listedCode = listedCode
    }
}

// MARK: - 公開 REST（GET /v1/companies/{code}/relations）

/// `type` クエリの値。`group` は parent + subsidiary + affiliate + other_related のまとめ。
/// `supplier` / `major_shareholder_of` は他社の有報からの逆引き（上場企業どうしだけ）。
public enum CompanyRelationQueryType: String, CaseIterable, Sendable {
    case customer
    case supplier
    case group
    case parent
    case subsidiary
    case affiliate
    case investee
    case majorShareholder = "major_shareholder"
    case majorShareholderOf = "major_shareholder_of"
}

/// 応答要素の `type`（関係の向き・まとまり）。`parent` / `subsidiary` / `affiliate` の絞り込みも `group`。
public let relationTypeCustomer = "customer"
public let relationTypeSupplier = "supplier"
public let relationTypeGroup = "group"
public let relationTypeInvestee = "investee"
public let relationTypeMajorShareholder = "major_shareholder"
public let relationTypeMajorShareholderOf = "major_shareholder_of"

/// 応答の `basis`。この API では常に有報の記載（推定は入れない）。
public let relationBasisDisclosed = "disclosed"
/// `reasons`: Jev が関係会社表の区分を決めた行。
public let relationReasonJevClassified = "jev_classified"
/// `reasons`: 相手側の有報に載っている行（仕入先・親会社の逆引き・大株主になっている会社）。
public let relationReasonDisclosedByCounterparty = "disclosed_by_counterparty"

/// `voting_ratio_basis`: 提出会社が相手の議決権を持つ割合（子会社・関連会社の行）。
public let relationVotingRatioBasisOwned = "owned"
/// `voting_ratio_basis`: 相手が提出会社の議決権を持つ割合（被所有。親会社・その他の関係会社の行）。
public let relationVotingRatioBasisOwnedBy = "owned_by"

/// `limit` の既定と上限。
public let companyRelationsDefaultLimit = 200
public let companyRelationsMaxLimit = 1000

/// `type` の CSV を解釈する。省略・空は全種類。未知の値（`competitor` など）があれば `.failure`（400）。
public func parseCompanyRelationTypes(_ csv: String?) -> Result<Set<CompanyRelationQueryType>, CompanyRelationQueryError> {
    guard let csv, !csv.trimmingCharacters(in: .whitespaces).isEmpty else {
        return .success(Set(CompanyRelationQueryType.allCases))
    }
    var result = Set<CompanyRelationQueryType>()
    var unknown: [String] = []
    for token in csv.split(separator: ",") {
        let value = token.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { continue }
        if let type = CompanyRelationQueryType(rawValue: value) {
            result.insert(type)
        } else {
            unknown.append(value)
        }
    }
    if !unknown.isEmpty { return .failure(CompanyRelationQueryError(unknownTypes: unknown)) }
    return result.isEmpty ? .success(Set(CompanyRelationQueryType.allCases)) : .success(result)
}

public struct CompanyRelationQueryError: Error, Equatable, Sendable {
    public var unknownTypes: [String]
    public var message: String { "type に不明な値があります: \(unknownTypes.joined(separator: ", "))" }
}

/// 4 桁の銘柄コード（英数字コードを含む）か。
public func isValidRelationsCompanyCode(_ code: String) -> Bool {
    code.range(of: #"^[0-9]{3}[0-9A-Z]$"#, options: .regularExpression) != nil
}

public struct CompanyRelationCompanyRef: Codable, Sendable, Equatable {
    public var code: String
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public struct CompanyRelationInvestee: Codable, Sendable, Equatable {
    public var shares: Double?
    public var bookValueYen: Double?
    public var purpose: String?
    public var isDeemed: Bool
    public var holder: String?

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case shares
        case bookValueYen = "book_value_yen"
        case purpose
        case isDeemed = "is_deemed"
        case holder
    }

    public init(shares: Double?, bookValueYen: Double?, purpose: String?, isDeemed: Bool, holder: String?) {
        self.shares = shares
        self.bookValueYen = bookValueYen
        self.purpose = purpose
        self.isDeemed = isDeemed
        self.holder = holder
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shares, forKey: .shares)
        try c.encode(bookValueYen, forKey: .bookValueYen)
        try c.encode(purpose, forKey: .purpose)
        try c.encode(isDeemed, forKey: .isDeemed)
        try c.encode(holder, forKey: .holder)
    }
}

public struct CompanyRelationMajorShareholder: Codable, Sendable, Equatable {
    public var rank: Int?
    public var shares: Double?
    /// 発行済株式（自己株式を除く）の総数に対する所有株式数の割合（XBRL の値。0.128 = 12.8%）。
    public var ratio: Double?

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case rank, shares, ratio
    }

    public init(rank: Int?, shares: Double?, ratio: Double?) {
        self.rank = rank
        self.shares = shares
        self.ratio = ratio
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rank, forKey: .rank)
        try c.encode(shares, forKey: .shares)
        try c.encode(ratio, forKey: .ratio)
    }
}

public struct CompanyRelationEvidence: Codable, Sendable, Equatable {
    public var docID: String
    public var section: String
    public var fyEnd: String?
    /// その行を載せた有報の提出会社（逆引きでは相手側）。
    public var fromCode: String

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case docID = "doc_id"
        case section
        case fyEnd = "fy_end"
        case fromCode = "from_code"
    }

    public init(docID: String, section: String, fyEnd: String?, fromCode: String) {
        self.docID = docID
        self.section = section
        self.fyEnd = fyEnd
        self.fromCode = fromCode
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(docID, forKey: .docID)
        try c.encode(section, forKey: .section)
        try c.encode(fyEnd, forKey: .fyEnd)
        try c.encode(fromCode, forKey: .fromCode)
    }
}

/// 応答の 1 要素。nullable のキーも必ず出す（欠落と null を区別する）。住所・needs_review は載せない。
public struct CompanyRelationItem: Codable, Sendable, Equatable {
    public var type: String
    public var kind: String
    public var basis: String
    public var company: CompanyRelationCompanyRef?
    public var nameRaw: String
    public var reasons: [String]
    public var amountYen: Double?
    public var segmentLabel: String?
    public var votingRatio: Double?
    public var votingRatioIndirect: Double?
    public var votingRatioCloseParties: Double?
    public var investee: CompanyRelationInvestee?
    public var majorShareholder: CompanyRelationMajorShareholder?
    public var evidence: CompanyRelationEvidence

    /// `voting_ratio` の向き。関係会社表の議決権欄は区分で向きが決まる（親会社・その他の関係会社の行は被所有）。
    public var votingRatioBasis: String? {
        guard votingRatio != nil || votingRatioIndirect != nil || votingRatioCloseParties != nil else { return nil }
        switch kind {
        case relationKindParent, relationKindOtherRelated: return relationVotingRatioBasisOwnedBy
        case relationKindSubsidiary, relationKindAffiliate: return relationVotingRatioBasisOwned
        default: return nil
        }
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, kind, basis, company
        case nameRaw = "name_raw"
        case reasons
        case amountYen = "amount_yen"
        case segmentLabel = "segment_label"
        case votingRatio = "voting_ratio"
        case votingRatioBasis = "voting_ratio_basis"
        case votingRatioIndirect = "voting_ratio_indirect"
        case votingRatioCloseParties = "voting_ratio_close_parties"
        case investee
        case majorShareholder = "major_shareholder"
        case evidence
    }

    public init(
        type: String, kind: String, company: CompanyRelationCompanyRef?, nameRaw: String,
        reasons: [String], amountYen: Double? = nil, segmentLabel: String? = nil,
        votingRatio: Double? = nil, votingRatioIndirect: Double? = nil, votingRatioCloseParties: Double? = nil,
        investee: CompanyRelationInvestee? = nil, majorShareholder: CompanyRelationMajorShareholder? = nil, evidence: CompanyRelationEvidence
    ) {
        self.type = type
        self.kind = kind
        self.basis = relationBasisDisclosed
        self.company = company
        self.nameRaw = nameRaw
        self.reasons = reasons
        self.amountYen = amountYen
        self.segmentLabel = segmentLabel
        self.votingRatio = votingRatio
        self.votingRatioIndirect = votingRatioIndirect
        self.votingRatioCloseParties = votingRatioCloseParties
        self.investee = investee
        self.majorShareholder = majorShareholder
        self.evidence = evidence
    }

    /// `voting_ratio_basis` は `kind` と `voting_ratio` から決まるので読まない。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        kind = try c.decode(String.self, forKey: .kind)
        basis = try c.decode(String.self, forKey: .basis)
        company = try c.decodeIfPresent(CompanyRelationCompanyRef.self, forKey: .company)
        nameRaw = try c.decode(String.self, forKey: .nameRaw)
        reasons = try c.decode([String].self, forKey: .reasons)
        amountYen = try c.decodeIfPresent(Double.self, forKey: .amountYen)
        segmentLabel = try c.decodeIfPresent(String.self, forKey: .segmentLabel)
        votingRatio = try c.decodeIfPresent(Double.self, forKey: .votingRatio)
        votingRatioIndirect = try c.decodeIfPresent(Double.self, forKey: .votingRatioIndirect)
        votingRatioCloseParties = try c.decodeIfPresent(Double.self, forKey: .votingRatioCloseParties)
        investee = try c.decodeIfPresent(CompanyRelationInvestee.self, forKey: .investee)
        majorShareholder = try c.decodeIfPresent(CompanyRelationMajorShareholder.self, forKey: .majorShareholder)
        evidence = try c.decode(CompanyRelationEvidence.self, forKey: .evidence)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(kind, forKey: .kind)
        try c.encode(basis, forKey: .basis)
        try c.encode(company, forKey: .company)
        try c.encode(nameRaw, forKey: .nameRaw)
        try c.encode(reasons, forKey: .reasons)
        try c.encode(amountYen, forKey: .amountYen)
        try c.encode(segmentLabel, forKey: .segmentLabel)
        try c.encode(votingRatio, forKey: .votingRatio)
        try c.encode(votingRatioBasis, forKey: .votingRatioBasis)
        try c.encode(votingRatioIndirect, forKey: .votingRatioIndirect)
        try c.encode(votingRatioCloseParties, forKey: .votingRatioCloseParties)
        try c.encode(investee, forKey: .investee)
        try c.encode(majorShareholder, forKey: .majorShareholder)
        try c.encode(evidence, forKey: .evidence)
    }
}

public struct CompanyRelationsResponse: Codable, Sendable, Equatable {
    public var code: String
    public var relations: [CompanyRelationItem]
    /// 提出会社が記載を省略した type（例: 売上高 10% 以上の顧客なし → `customer`）。
    public var omitted: [String]
    /// 続きがあるときの `cursor`。無ければ null。
    public var nextCursor: String?

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case code, relations, omitted
        case nextCursor = "next_cursor"
    }

    public init(code: String, relations: [CompanyRelationItem], omitted: [String], nextCursor: String?) {
        self.code = code
        self.relations = relations
        self.omitted = omitted
        self.nextCursor = nextCursor
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(relations, forKey: .relations)
        try c.encode(omitted, forKey: .omitted)
        try c.encode(nextCursor, forKey: .nextCursor)
    }
}
