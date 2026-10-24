// 関係の公開 REST（`GET /v1/companies/{code}/relations`）の読み取り。company_relations の格納行だけを返す。
// 自社の有報の行（顧客・関係会社・出資先・大株主）と、他社の有報からの逆引き（仕入先・親会社・大株主になっている会社）。
// 逆引きは上場企業どうしだけ（`related_code` が付いた行）。出資先（investee）の逆引きはしない。
// 公開可否は `isPubliclyServableRelation`。`needs_review` は応答に載せない。住所も載せない。

import BlueTickerCore
import Fluent
import Foundation

/// 逆引きで読む行数の上限（1 社が他社の有報に載る件数としては十分大きい）。
let relationsReverseRowLimit = 5000

/// 公開応答の材料。DB 行から写したもの（テストでも組み立てやすいよう Fluent から切り離す）。
struct RelationServeRow: Sendable, Equatable {
    var code: String
    var docID: String
    var fyEnd: String?
    var section: String
    var kind: String
    var position: Int
    var nameRaw: String
    var nameNorm: String
    var amountYen: Double?
    var segmentLabel: String?
    var votingRatio: Double?
    var votingRatioIndirect: Double?
    var votingRatioCloseParties: Double?
    var relatedCode: String?
    var resolution: String?
    var needsReview: Bool
    var decidedBy: String
    var shares: Double?
    var bookValueYen: Double?
    var purpose: String?
    var isDeemed: Bool?
    var holder: String?
    var ratio: Double?
    var rank: Int?
    var sectionStatus: String?
    var warning: String?

    init(_ model: CompanyRelation) {
        code = model.code
        docID = model.docID
        fyEnd = model.fyEnd
        section = model.section
        kind = model.kind
        position = model.position
        nameRaw = model.nameRaw
        nameNorm = model.nameNorm
        amountYen = model.amountYen
        segmentLabel = model.segmentLabel
        votingRatio = model.votingRatio
        votingRatioIndirect = model.votingRatioIndirect
        votingRatioCloseParties = model.votingRatioCloseParties
        relatedCode = model.relatedCode
        resolution = model.resolution
        needsReview = model.needsReview
        decidedBy = model.decidedBy
        shares = model.shares
        bookValueYen = model.bookValueYen
        purpose = model.purpose
        isDeemed = model.isDeemed
        holder = model.holder
        ratio = model.ratio
        rank = model.rank
        sectionStatus = model.sectionStatus
        warning = model.warning
    }

    var isServable: Bool {
        kind != relationKindNone
            && isPubliclyServableRelation(
                kind: kind, decidedBy: decidedBy, needsReview: needsReview, resolution: resolution,
                warning: warning)
    }
}

/// `relations` の読み取り結果。
enum RelationsServeResult {
    case ok([String: Any])
    case badRequest(String)
    case notFound
    case dbUnavailable
}

/// `relations` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveStoredRelations(
    code: String, types typeQuery: String?, limit: Int?, cursor: String?, db: Database?,
    logger: Logger
) async -> RelationsServeResult {
    guard isValidRelationsCompanyCode(code) else {
        return .badRequest("銘柄コードが不正です: \(code)")
    }
    let types: Set<CompanyRelationQueryType>
    switch parseCompanyRelationTypes(typeQuery) {
    case .success(let parsed): types = parsed
    case .failure(let error): return .badRequest(error.message)
    }
    let offset: Int
    if let cursor, !cursor.isEmpty {
        guard let parsed = parseRelationsCursor(cursor, types: types) else {
            return .badRequest("cursor が不正です（別の type の cursor は使えません）")
        }
        offset = parsed
    } else {
        offset = 0
    }
    let pageSize = min(max(limit ?? companyRelationsDefaultLimit, 1), companyRelationsMaxLimit)
    let result = await serveStored(db: db, logger: logger) { db in
        let (own, reverse) = try await loadRelationRows(code: code, db: db)
        let names = await relationCompanyNames(own: own, reverse: reverse)
        guard
            let response = buildCompanyRelationsResponse(
                code: code, own: own, reverse: reverse, types: types, offset: offset,
                limit: pageSize, companyName: { names[$0] })
        else { return nil }
        return try relationsJSONObject(response)
    }
    switch result {
    case .ok(let value): return .ok(value)
    case .notFound: return .notFound
    case .dbUnavailable: return .dbUnavailable
    }
}

/// 自社の行と逆引きの行を読む。逆引きは他社の行のうち `related_code = code` の顧客・子会社・親会社・大株主。
func loadRelationRows(code: String, db: Database) async throws -> (own: [RelationServeRow], reverse: [RelationServeRow]) {
    let own = try await CompanyRelation.query(on: db)
        .filter(\.$code == code)
        .sort(\.$section).sort(\.$position)
        .all()
        .map(RelationServeRow.init)
    let reverse = try await CompanyRelation.query(on: db)
        .filter(\.$relatedCode == code)
        .filter(\.$code != code)
        .filter(\.$kind ~~ reverseRelationKinds)
        .sort(\.$code).sort(\.$position)
        .limit(relationsReverseRowLimit)
        .all()
        .map(RelationServeRow.init)
    return (own, reverse)
}

/// 逆引きに使う相手側の `kind`。
let reverseRelationKinds = [
    relationKindCustomer, relationKindSubsidiary, relationKindParent, relationKindMajorShareholder,
]

/// 応答に出す上場企業コード → 社名（マスタ）。
func relationCompanyNames(own: [RelationServeRow], reverse: [RelationServeRow]) async -> [String: String] {
    var codes = Set(own.compactMap(\.relatedCode))
    codes.formUnion(reverse.map(\.code))
    var names: [String: String] = [:]
    for code in codes {
        if let name = await listedCompanyName(forCode: code) { names[code] = name }
    }
    return names
}

/// 格納行から公開応答を組み立てる（純粋関数）。公開できる行が自社にも逆引きにも無ければ nil（404）。
func buildCompanyRelationsResponse(
    code: String, own: [RelationServeRow], reverse: [RelationServeRow],
    types: Set<CompanyRelationQueryType>, offset: Int, limit: Int,
    companyName: (String) -> String?
) -> CompanyRelationsResponse? {
    let servableOwn = own.filter(\.isServable)
    let servableReverse = reverse.filter { $0.isServable && $0.relatedCode == code }
    guard !servableOwn.isEmpty || !servableReverse.isEmpty else { return nil }

    func ref(_ relatedCode: String?) -> CompanyRelationCompanyRef? {
        guard let relatedCode else { return nil }
        return CompanyRelationCompanyRef(code: relatedCode, name: companyName(relatedCode) ?? relatedCode)
    }
    func evidence(_ row: RelationServeRow) -> CompanyRelationEvidence {
        CompanyRelationEvidence(docID: row.docID, section: row.section, fyEnd: row.fyEnd, fromCode: row.code)
    }
    /// 自社の行: Jev が区分を決めたか＋名前解決の結果（`via_listed_parent` / `ambiguous` 等）。
    func ownReasons(_ row: RelationServeRow) -> [String] {
        (row.decidedBy == relationDecidedByJev ? [relationReasonJevClassified] : [])
            + (row.resolution.map { [$0] } ?? [])
    }
    /// 逆引きの行: 相手の有報に載っている＋相手側の行の名前解決の結果。
    func reverseReasons(_ row: RelationServeRow) -> [String] {
        [relationReasonDisclosedByCounterparty] + (row.resolution.map { [$0] } ?? [])
    }

    var items: [CompanyRelationItem] = []

    if types.contains(.customer) {
        for row in servableOwn where row.kind == relationKindCustomer {
            items.append(
                CompanyRelationItem(
                    type: relationTypeCustomer, kind: row.kind, company: ref(row.relatedCode),
                    nameRaw: row.nameRaw, reasons: ownReasons(row), amountYen: row.amountYen,
                    segmentLabel: row.segmentLabel, evidence: evidence(row)))
        }
    }
    if types.contains(.supplier) {
        // 相手が自社と自社の子会社を両方顧客欄に載せていても、相手 1 社 1 件にまとめる（金額の大きい行を残す）。
        let suppliers = servableReverse.filter { $0.kind == relationKindCustomer }
            .sorted { ($0.amountYen ?? -1, $1.code) > ($1.amountYen ?? -1, $0.code) }
        items.append(
            contentsOf: mergedByCounterparty(suppliers, reasons: reverseReasons) { row, reasons in
                CompanyRelationItem(
                    type: relationTypeSupplier, kind: relationTypeSupplier, company: ref(row.code),
                    nameRaw: companyName(row.code) ?? row.code, reasons: reasons,
                    amountYen: row.amountYen, segmentLabel: row.segmentLabel, evidence: evidence(row))
            })
    }
    let groupKinds = requestedGroupKinds(types)
    if !groupKinds.isEmpty {
        items.append(
            contentsOf: groupRelationItems(
                own: servableOwn, reverse: servableReverse, kinds: groupKinds, ref: ref,
                companyName: companyName, evidence: evidence, ownReasons: ownReasons,
                reverseReasons: reverseReasons))
    }
    if types.contains(.investee) {
        for row in servableOwn where row.kind == relationKindInvestee {
            items.append(
                CompanyRelationItem(
                    type: relationTypeInvestee, kind: row.kind, company: ref(row.relatedCode),
                    nameRaw: row.nameRaw, reasons: ownReasons(row),
                    investee: CompanyRelationInvestee(
                        shares: row.shares, bookValueYen: row.bookValueYen, purpose: row.purpose,
                        isDeemed: row.isDeemed ?? false, holder: row.holder),
                    evidence: evidence(row)))
        }
    }
    if types.contains(.majorShareholder) {
        let holders = servableOwn.filter { $0.kind == relationKindMajorShareholder }
            .sorted { ($0.rank ?? Int.max, $0.position) < ($1.rank ?? Int.max, $1.position) }
        for row in holders {
            items.append(
                CompanyRelationItem(
                    type: relationTypeMajorShareholder, kind: row.kind, company: ref(row.relatedCode),
                    nameRaw: row.nameRaw, reasons: ownReasons(row),
                    majorShareholder: CompanyRelationMajorShareholder(
                        rank: row.rank, shares: row.shares, ratio: row.ratio),
                    evidence: evidence(row)))
        }
    }
    if types.contains(.majorShareholderOf) {
        let held = servableReverse.filter { $0.kind == relationKindMajorShareholder }
            .sorted { ($0.ratio ?? -1, $1.code) > ($1.ratio ?? -1, $0.code) }
        items.append(
            contentsOf: mergedByCounterparty(held, reasons: reverseReasons) { row, reasons in
                CompanyRelationItem(
                    type: relationTypeMajorShareholderOf, kind: relationTypeMajorShareholderOf,
                    company: ref(row.code), nameRaw: companyName(row.code) ?? row.code,
                    reasons: reasons,
                    majorShareholder: CompanyRelationMajorShareholder(
                        rank: row.rank, shares: row.shares, ratio: row.ratio),
                    evidence: evidence(row))
            })
    }

    let page = Array(items.dropFirst(offset).prefix(limit))
    let nextOffset = offset + page.count
    return CompanyRelationsResponse(
        code: code, relations: page,
        omitted: omittedRelationTypes(own: own, types: types),
        nextCursor: nextOffset < items.count ? relationsCursor(offset: nextOffset, types: types) : nil)
}

/// 逆引きの行を相手（提出会社）ごとに 1 件へまとめる。先頭（並べ替え済みの最上位）の行を残し、reasons を合わせる。
private func mergedByCounterparty(
    _ rows: [RelationServeRow], reasons: (RelationServeRow) -> [String],
    make: (RelationServeRow, [String]) -> CompanyRelationItem
) -> [CompanyRelationItem] {
    var order: [String] = []
    var first: [String: RelationServeRow] = [:]
    var merged: [String: [String]] = [:]
    for row in rows {
        if first[row.code] == nil {
            order.append(row.code)
            first[row.code] = row
        }
        for reason in reasons(row) where !(merged[row.code] ?? []).contains(reason) {
            merged[row.code, default: []].append(reason)
        }
    }
    return order.compactMap { code in first[code].map { make($0, merged[code] ?? []) } }
}

/// `next_cursor`。要求の type の組と結び付ける（別の type の要求に使うと 400）。中身は不透明として扱う。
func relationsCursor(offset: Int, types: Set<CompanyRelationQueryType>) -> String {
    let key = types.map(\.rawValue).sorted().joined(separator: ",")
    return Data("v1|\(key)|\(offset)".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// `cursor` を読む。版・type の組が違う、または壊れていれば nil（400）。
func parseRelationsCursor(_ cursor: String, types: Set<CompanyRelationQueryType>) -> Int? {
    var base64 = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) else {
        return nil
    }
    let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    let key = types.map(\.rawValue).sorted().joined(separator: ",")
    guard parts.count == 3, parts[0] == "v1", parts[1] == key, let offset = Int(parts[2]), offset >= 0 else {
        return nil
    }
    return offset
}

/// 絞り込みに対応する関係会社の `kind`。`group` は全区分。
func requestedGroupKinds(_ types: Set<CompanyRelationQueryType>) -> Set<String> {
    if types.contains(.group) {
        return [relationKindParent, relationKindSubsidiary, relationKindAffiliate, relationKindOtherRelated]
    }
    var kinds = Set<String>()
    if types.contains(.parent) { kinds.insert(relationKindParent) }
    if types.contains(.subsidiary) { kinds.insert(relationKindSubsidiary) }
    if types.contains(.affiliate) { kinds.insert(relationKindAffiliate) }
    return kinds
}

/// 関係会社（type = group）。自社の行と逆引き（相手の子会社表に載る → 親会社、相手の親会社欄に載る → 子会社）を
/// 同じ相手（上場はコード、非上場は正規化名）でまとめ、reasons を合わせる。上場（company あり）を先に並べる。
private func groupRelationItems(
    own: [RelationServeRow], reverse: [RelationServeRow], kinds: Set<String>,
    ref: (String?) -> CompanyRelationCompanyRef?, companyName: (String) -> String?,
    evidence: (RelationServeRow) -> CompanyRelationEvidence,
    ownReasons: (RelationServeRow) -> [String], reverseReasons: (RelationServeRow) -> [String]
) -> [CompanyRelationItem] {
    var order: [String] = []
    var merged: [String: CompanyRelationItem] = [:]
    func add(key: String, item: CompanyRelationItem) {
        guard var existing = merged[key] else {
            order.append(key)
            merged[key] = item
            return
        }
        for reason in item.reasons where !existing.reasons.contains(reason) {
            existing.reasons.append(reason)
        }
        if existing.votingRatio == nil, existing.votingRatioIndirect == nil, existing.votingRatioCloseParties == nil {
            existing.votingRatio = item.votingRatio
            existing.votingRatioIndirect = item.votingRatioIndirect
            existing.votingRatioCloseParties = item.votingRatioCloseParties
        }
        merged[key] = existing
    }
    let ownGroup = own.filter {
        $0.section == relationSectionAffiliatedEntities || $0.section == relationSectionParentCompanyInfo
    }
    // 関係会社の状況を先に（議決権の割合を持つ）、親会社等の状況はその後に足す。
    for row in ownGroup.sorted(by: { ($0.section, $0.position) < ($1.section, $1.position) })
    where kinds.contains(row.kind) {
        let key = "\(row.kind)|" + (row.relatedCode.map { "code:\($0)" } ?? "name:\(row.nameNorm)")
        add(
            key: key,
            item: CompanyRelationItem(
                type: relationTypeGroup, kind: row.kind, company: ref(row.relatedCode),
                nameRaw: row.nameRaw, reasons: ownReasons(row), votingRatio: row.votingRatio,
                votingRatioIndirect: row.votingRatioIndirect, votingRatioCloseParties: row.votingRatioCloseParties,
                evidence: evidence(row)))
    }
    for row in reverse {
        let kind: String
        switch row.kind {
        case relationKindSubsidiary: kind = relationKindParent
        case relationKindParent: kind = relationKindSubsidiary
        default: continue
        }
        guard kinds.contains(kind) else { continue }
        add(
            key: "\(kind)|code:\(row.code)",
            item: CompanyRelationItem(
                type: relationTypeGroup, kind: kind, company: ref(row.code),
                nameRaw: companyName(row.code) ?? row.code,
                reasons: reverseReasons(row), evidence: evidence(row)))
    }
    let items = order.compactMap { merged[$0] }
    return items.filter { $0.company != nil } + items.filter { $0.company == nil }
}

/// 自社の有報が記載を省略した type（要求された type のうち）。overlay 回帰の書類は数えない。
func omittedRelationTypes(own: [RelationServeRow], types: Set<CompanyRelationQueryType>) -> [String] {
    var omitted: [String] = []
    for row in own
    where row.kind == relationKindNone && row.sectionStatus == relationSectionStatusOmitted
        && !(row.warning.map { hasOverlayRegressionWarning([$0]) } ?? false)
    {
        let type: (String, Bool)?
        switch row.section {
        case relationSectionMainCustomers: type = (relationTypeCustomer, types.contains(.customer))
        case relationSectionAffiliatedEntities:
            type = (relationTypeGroup, !requestedGroupKinds(types).isEmpty)
        case relationSectionPolicyHoldings: type = (relationTypeInvestee, types.contains(.investee))
        case relationSectionMajorShareholders:
            type = (relationTypeMajorShareholder, types.contains(.majorShareholder))
        default: type = nil
        }
        if let (name, requested) = type, requested, !omitted.contains(name) { omitted.append(name) }
    }
    return omitted
}

/// Codable の応答を `jsonResponse` に渡せる JSON オブジェクトへ。
func relationsJSONObject(_ response: CompanyRelationsResponse) throws -> [String: Any] {
    let data = try JSONEncoder().encode(response)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RelationsEncodingError()
    }
    return object
}

struct RelationsEncodingError: Error {}
