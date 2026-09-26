// 数値 fact 取り込み: edinet_documents の各書類について XBRL を取得（XBRL 取得キャッシュ）・パースし、
// 数値 fact インデックスを edinet_xbrl_facts へ upsert する。
// 取得・パースは BlueTickerCore のファサード（parseXbrlFactIndex）に委譲し、
// ここでは候補選定・staleness 判定・DB upsert のみを担う（ネットワーク非依存でテスト可能）。

import BlueTickerCore
import Fluent
import Foundation
import Vapor

/// 取り込み結果のサマリ。
public struct FactsIngestSummary: Sendable, Equatable {
    /// 取り込みを試みた書類数（skip を除く）。
    public let attempted: Int
    /// パース・格納に成功した書類数。
    public let stored: Int
    /// 取得・パース失敗（XBRL 無し等）でスキップした書類数。
    public let failed: Int
    /// 既に最新版でパース済みのためスキップした書類数。
    public let skipped: Int
}

/// docID を受けて fact インデックスを返すパーサ（成功で payload、失敗で nil）。
/// 本番は `context.parseXbrlFactIndex`、テストはフェイクを注入する。
public typealias XbrlFactParser = @Sendable (String) async -> XbrlFactIndexPayload?

/// edinet_documents の書類を新しい順に走査し、未パース or バージョン不一致のものを取り込む。
/// `limit` は新規取り込み件数の上限（XBRL ダウンロードが重いためバッチ実行用）。
/// `cachedDocIDs` はローカル XBRL 展開済み。欠測→版ずれの連結のうえ、キャッシュ済みを先頭へ寄せる。
func runFactsIngest(
    db: Database, limit: Int?, cachedDocIDs: Set<String> = [], logger: Logger? = nil,
    parse: XbrlFactParser
) async throws -> FactsIngestSummary {
    let documents = try await withDbRetry(logger: logger, context: "全書類一覧") {
        try await EdinetDocumentListing.query(on: db)
            .sort(\.$submitDateTime, .descending)
            .all()
    }

    var attempted = 0
    var stored = 0
    var failed = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [String] = []
    var stale: [String] = []

    let classifyRows = try await withDbRetry(
        logger: logger, context: "数値 fact 取り込み 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await EdinetXbrlFactsCacheVersionOnly.query(on: db).all()
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for doc in documents {
        guard let docID = doc.id else { continue }
        guard let existing = classifyIndex[docID] else {
            missing.append(docID)
            continue
        }
        if existing.cacheVersion != xbrlFactsCacheVersion {
            stale.append(docID)
        } else {
            skipped += 1
        }
    }

    let candidates = prioritized(missing + stale, codeOf: { $0 }, priorityCodes: cachedDocIDs)
    // 分類フェーズと実処理フェーズでリトライ予算を分ける。
    // 分類中の一過性リトライで処理フェーズが即中断しないようにする。
    unhealthyRetries = 0

    for cand in candidates {
        let docID = cand
        // continue（skip/failed）で下の判定を素通りされないよう、各項目の先頭で判定する。
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため数値 fact 取り込みを中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await EdinetXbrlFacts.find(docID, on: db)
        }
        if let row = existing, row.cacheVersion == xbrlFactsCacheVersion {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        guard let payload = await parse(docID) else {
            failed += 1
            logger?.warning("数値 fact 取り込み失敗: docID=\(docID)")
            continue
        }
        try await withDbRetry(
            logger: logger, context: "docID=\(docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await storeXbrlFacts(
                existing: try await EdinetXbrlFacts.find(docID, on: db), docID: docID, facts: payload,
                db: db)
        }
        stored += 1
    }

    return FactsIngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped)
}

/// fact インデックスを edinet_xbrl_facts へ書き込む（既存行があれば更新、無ければ作成）。
/// `existing` は当該リトライ試行内で find した行。試行をまたいでインスタンスを再利用しない。
func storeXbrlFacts(
    existing: EdinetXbrlFacts?, docID: String, facts: XbrlFactIndexPayload, db: Database
) async throws {
    let applyFields: (EdinetXbrlFacts) -> Void = { row in
        row.facts = facts
        row.cacheVersion = xbrlFactsCacheVersion
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = EdinetXbrlFacts()
        model.id = docID
        applyFields(model)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                guard let recovered = try await EdinetXbrlFacts.find(docID, on: db) else { return false }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

/// `cache_version` のみを対象にした軽量射影（`facts` の JSONB を転送しない。分類の N+1 find 回避用）。
final class EdinetXbrlFactsCacheVersionOnly: Model, @unchecked Sendable {
    static let schema = EdinetXbrlFacts.schema

    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    init() {}
}

// MARK: - CLI エントリ

/// 財務取り込みで格納する年数。要求が増えても再計算が走らないよう余裕を持たせる
/// （REST の financials は years 既定 5。read 時に要求年数へ縮める）。
let financialsIngestYears = 6

/// 報告セグメント別の決定論指標軸の1ジョブ上限。対象母集団は上場全体（日経225は処理順の先頭寄せ）。
/// business / geography の `--limit`（定期ジョブ既定 50）とは独立。`--codes` 時は無視して全件。
let unpublishedBreakdownIngestLimit = 30

/// `blt-server ingest` の本体。Application を一時起動して DB を配線し、
/// 財務取り込み（計算済み財務サマリ）→ 半期財務取り込み（半期）→ 有報セクション取り込み（有報セクション）→
/// 内訳取り込み（business/geography・決定論指標軸ともに上場全体。日経225は処理順の先頭寄せ）を取り込む。
///
/// 数値 fact 取り込み（`edinet_xbrl_facts`）は **閉じた**。生 XBRL の R2 L2 から
/// 再導出できるパース済み投影で、配信も他 stage も読まない。全件投影は Neon 512MB を超える。
/// `--with-facts`（`includeFacts`）は残存 CLI で製品経路ではない。財務取り込みの
/// `computeFinancials` は自前で生 XBRL を読むため、facts 行が無くても自足する。
///
/// `targets` は実行する financials/filing-sections/breakdowns/statements/statement-notes/icons/overviews の集合
/// （CLI: `--stages filing-sections` 等）。既定は全対象。icons は `BLT_R2_*` 環境変数未設定時は
/// スキップされる。overviews は `OPENROUTER_OVERVIEW_API_KEY` 未設定時はスキップされる。
/// 例えば有報セクション取り込みだけを先に流したいとき、重い financials の全件 drain を挟まずに済む。
/// 数値 fact 取り込みは `targets` に含めない。
/// `codes` は financials/filing-sections/breakdowns の対象を明示的な証券コード集合に絞る（CLI: `--codes 7203,6758`）。
/// `docIDs` は会社-FY（原本 120 の doc_id）単位の再 ingest（CLI: `--doc-ids S100W0S7`）。
/// 指定時は該当書類だけを keep し、skip を外して再計算する。financials は会社1行のため
/// その doc の発行体だけ再計算する（他 FY は原本 120 を再読。overlay は訂正がある FY だけ）。
/// バグ修正確認後などに特定銘柄だけを手動・単発で先に再計算したいケース向け（定期 launchd drain には
/// 使わない）。指定時は `limit` を無視して該当コードを全件処理する（対象自体が小さいため）。
/// 数値 fact 取り込みは `codes` の対象外（doc 単位のため、コードへの紐付けは別スコープ）。
/// 内訳取り込み: business/geography・決定論指標軸ともに `listed`（上場全体。日経225=`priority`は
/// 処理順の先頭寄せのみ）。`--codes` 指定時は全軸その集合。
/// DATABASE_URL 未設定なら databaseUnavailable、EDINET キー未設定なら apiKeyMissing を投げる。
public func runFactsIngestCommand(
    limit: Int?, includeFacts: Bool = false,
    targets: Set<IngestTarget> = Set(IngestTarget.allCases),
    codes: Set<String>? = nil,
    docIDs: Set<String>? = nil,
    noteTypes: Set<String>? = nil
) async throws {
    guard let context = await makeBltServerContext() else {
        throw DocumentSyncError.apiKeyMissing
    }
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        throw DocumentSyncError.databaseUnavailable
    }

    var env = Environment(name: "production", arguments: ["blt-server"])
    try bootstrapBltLogging(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app)
        // 上場・国内法人の対象ユニバース。financials/filing-sections 共通で候補を絞り込み、
        // 上場廃止・外国法人など二度と成功しない企業への無駄なリトライを避ける。
        let listed = await context.listedCompanyCodes()
        // ユーザーが用意した優先コード一覧（`assets/nikkei225.csv`）。対象選定ではなく
        // financials/filing-sections/breakdowns/statement-notes 共通の処理順序づけにのみ使う
        // （未配置なら空集合＝優先なし）。
        let priority = await context.priorityIngestCodes()
        if !priority.isEmpty {
            app.logger.notice(
                "Priority ingest codes loaded",
                metadata: ["event": "priority_codes_loaded", "count": "\(priority.count)"])
        }
        // `--codes` 指定時は financials/filing-sections の対象をその集合へ絞り、`limit` は無視して全件処理する
        // （手動・単発の対象は小さい前提。数値 fact 取り込みは doc 単位のためスコープ外）。
        let stageLimit = (codes == nil && docIDs == nil) ? limit : nil
        if let codes {
            app.logger.notice(
                "Explicit ingest codes specified",
                metadata: ["event": "explicit_codes_loaded", "count": "\(codes.count)"])
        }
        if let docIDs {
            app.logger.notice(
                "Explicit ingest doc IDs specified",
                metadata: ["event": "explicit_doc_ids_loaded", "count": "\(docIDs.count)"])
        }
        let cachedDocIDs = await context.cachedXbrlDocIDs()
        let publicBreakdownListed = codes ?? listed
        // 決定論指標軸（employees/rd/goodwill・報告セグメント別指標）・statement-notes の対象母集団。
        // 2026-09: 日経225限定を廃止し上場全体へ拡大（`priority` は処理順の先頭寄せとして残す）。
        let deterministicMetricsListed = codes ?? listed
        let needsListedFilings =
            targets.contains(.filingSections) || targets.contains(.breakdowns)
            || targets.contains(.statements)
        let needsDeterministicMetricsFilings =
            targets.contains(.notes) || targets.contains(.breakdowns)

        // 会社有報の一覧読みは全候補集合で 1 回だけにする（母集団ごとの再走査を避ける）。
        var annualDocs: [EdinetDocumentListing]?
        func loadCandidateSets(_ listedCodes: Set<String>) async throws -> FilingSectionCandidateSets {
            if listedCodes.isEmpty {
                return FilingSectionCandidateSets(keep: [], purge: [])
            }
            if annualDocs == nil {
                annualDocs = try await annualReportDisclosureDocs(db: app.db, logger: app.logger)
            }
            return await filingSectionCandidates(
                docs: annualDocs ?? [], listedCodes: listedCodes, explicitCodes: codes,
                years: filingSectionsIngestYears, explicitDocIDs: docIDs)
        }

        let listedFilingSets: FilingSectionCandidateSets
        if needsListedFilings {
            listedFilingSets = try await loadCandidateSets(listed)
        } else {
            listedFilingSets = FilingSectionCandidateSets(keep: [], purge: [])
        }

        let publicBreakdownSets: FilingSectionCandidateSets
        if targets.contains(.breakdowns) {
            if publicBreakdownListed == listed {
                publicBreakdownSets = listedFilingSets
            } else {
                publicBreakdownSets = try await loadCandidateSets(publicBreakdownListed)
            }
        } else {
            publicBreakdownSets = FilingSectionCandidateSets(keep: [], purge: [])
        }

        let deterministicMetricsFilingSets: FilingSectionCandidateSets
        if needsDeterministicMetricsFilings {
            if deterministicMetricsListed == listed && needsListedFilings {
                deterministicMetricsFilingSets = listedFilingSets
            } else if deterministicMetricsListed == publicBreakdownListed && targets.contains(.breakdowns) {
                deterministicMetricsFilingSets = publicBreakdownSets
            } else {
                deterministicMetricsFilingSets = try await loadCandidateSets(deterministicMetricsListed)
            }
        } else {
            deterministicMetricsFilingSets = FilingSectionCandidateSets(keep: [], purge: [])
        }

        let correctionIDsByOriginal = try await loadAnnualXbrlCorrectionIDsByOriginal(
            db: app.db, logger: app.logger)
        let forceDocIDs = docIDs ?? []
        let financialsExplicitCodes: Set<String>?
        if let docIDs {
            var fromDocs = Set(listedFilingSets.keep.map(\.code))
            fromDocs.formUnion(publicBreakdownSets.keep.map(\.code))
            fromDocs.formUnion(deterministicMetricsFilingSets.keep.map(\.code))
            if fromDocs.isEmpty {
                fromDocs = Set(try await loadCandidateSets(codes ?? listed).keep.map(\.code))
            }
            financialsExplicitCodes = codes.map { $0.intersection(fromDocs) } ?? fromDocs
        } else {
            financialsExplicitCodes = codes
        }

        if includeFacts {
            let s3 = try await runFactsIngest(
                db: app.db, limit: limit, cachedDocIDs: cachedDocIDs,
                logger: app.logger
            ) { docID in
                await context.parseXbrlFactIndex(
                    docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
            }
            logIngestSummary(
                app.logger, target: "facts", attempted: s3.attempted, stored: s3.stored,
                failed: s3.failed, skipped: s3.skipped)
        } else {
            app.logger.notice(
                "facts ingest disabled",
                metadata: ["event": "ingest_skipped", "target": "facts", "reason": "blt_23"])
        }
        if targets.contains(.financials) {
            let s4 = try await runFinancialsIngest(
                db: app.db, years: financialsIngestYears, limit: stageLimit, listedCodes: listed,
                explicitCodes: financialsExplicitCodes, priorityCodes: priority,
                forceCodes: docIDs == nil ? [] : (financialsExplicitCodes ?? []),
                logger: app.logger
            ) { code in
                await context.computeFinancials(code: code, years: financialsIngestYears)
            }
            let coverage = try? await withDbRetry(logger: app.logger, context: "company_financials 集計") {
                try await countServableCompanyFinancials(db: app.db)
            }
            logIngestSummary(
                app.logger, target: "financials", attempted: s4.attempted, stored: s4.stored,
                failed: s4.failed, skipped: s4.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable,
                notApplicable: s4.notApplicable)
        }
        if targets.contains(.filingSections) {
            // 有報セクション取り込み: 上場企業の有報セクション本文を抽出・格納（filing-content の read-only 化）。
            let s5 = try await runFilingSectionsIngest(
                db: app.db, listedCodes: listed, years: filingSectionsIngestYears,
                sectionKeys: currentFilingSectionKeys(), limit: stageLimit, explicitCodes: codes,
                priorityCodes: priority, cachedDocIDs: cachedDocIDs,
                candidateSets: listedFilingSets,
                forceDocIDs: forceDocIDs,
                logger: app.logger
            ) { docID in
                await context.extractFilingSections(
                    docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
            }
            let coverage = try? await withDbRetry(logger: app.logger, context: "company_filing_sections 集計") {
                try await countServableFilingSections(db: app.db)
            }
            logIngestSummary(
                app.logger, target: "filing-sections", attempted: s5.attempted, stored: s5.stored,
                failed: s5.failed, skipped: s5.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable, purged: s5.purged)
        }
        if targets.contains(.breakdowns) {
            // 内訳取り込み: business/geography・決定論指標軸ともに上場全体（`listed`。日経225=
            // `priority` は処理順の先頭寄せのみ）。`--codes` 時は全軸その集合。
            // `--limit` は business/geography に適用。決定論指標軸は `unpublishedBreakdownIngestLimit`。
            if publicBreakdownListed.isEmpty {
                app.logger.warning(
                    "内訳取り込み listed codes empty (listed universe empty and no --codes); skipping business/geography",
                    metadata: ["event": "ingest_skipped", "target": "breakdowns", "reason": "empty_listed_codes"])
            }
            if deterministicMetricsListed.isEmpty {
                app.logger.warning(
                    "内訳取り込み listed codes empty (listed universe empty and no --codes); skipping deterministic metric axes",
                    metadata: ["event": "ingest_skipped", "target": "breakdowns", "reason": "empty_listed_codes"])
            }
            let unpublishedLimit = (codes == nil && docIDs == nil) ? unpublishedBreakdownIngestLimit : nil
            let unpublishedSets =
                deterministicMetricsListed == publicBreakdownListed
                ? publicBreakdownSets : deterministicMetricsFilingSets

            /// 1 軸分の実行定義。`target` はログ用の ingest 対象名。
            struct BreakdownStage {
                let axis: String
                let target: String
                let listedCodes: Set<String>
                let limit: Int?
                let candidateSets: FilingSectionCandidateSets
                let resolve: BreakdownResolveFn
            }
            let stages: [BreakdownStage] = [
                BreakdownStage(
                    axis: breakdownAxisBusiness, target: "breakdowns",
                    listedCodes: publicBreakdownListed, limit: stageLimit,
                    candidateSets: publicBreakdownSets
                ) { docID in
                    await context.resolveBusinessBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisGeography, target: "breakdowns-geography",
                    listedCodes: publicBreakdownListed, limit: stageLimit,
                    candidateSets: publicBreakdownSets
                ) { docID in
                    await context.resolveGeographyBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisEmployees, target: "breakdowns-employees",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit,
                    candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveEmployeesBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisResearchAndDevelopment, target: "breakdowns-rd",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit,
                    candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveResearchAndDevelopmentBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisGoodwill, target: "breakdowns-goodwill",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit,
                    candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveGoodwillBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisSegmentAssets, target: "breakdowns-\(breakdownAxisSegmentAssets)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveSegmentAssetsBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisDepreciationAndAmortization,
                    target: "breakdowns-\(breakdownAxisDepreciationAndAmortization)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveDepreciationAndAmortizationBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisGoodwillAmortization,
                    target: "breakdowns-\(breakdownAxisGoodwillAmortization)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveGoodwillAmortizationBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisImpairmentLoss,
                    target: "breakdowns-\(breakdownAxisImpairmentLoss)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveImpairmentLossBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisEquityMethodInvestments,
                    target: "breakdowns-\(breakdownAxisEquityMethodInvestments)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveEquityMethodInvestmentsBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisCapitalExpenditures,
                    target: "breakdowns-\(breakdownAxisCapitalExpenditures)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveCapitalExpendituresBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisCapitalExpendituresOverview,
                    target: "breakdowns-\(breakdownAxisCapitalExpendituresOverview)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveCapitalExpendituresOverviewBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisNoncurrentAssetAdditions,
                    target: "breakdowns-\(breakdownAxisNoncurrentAssetAdditions)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveNoncurrentAssetAdditionsBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
            ]
            var summaries: [(stage: BreakdownStage, summary: BreakdownIngestSummary)] = []
            for stage in stages {
                let summary = try await runBreakdownIngest(
                    db: app.db, listedCodes: stage.listedCodes, years: filingSectionsIngestYears,
                    limit: stage.limit, explicitCodes: codes, priorityCodes: priority,
                    cachedDocIDs: cachedDocIDs, axis: stage.axis, candidateSets: stage.candidateSets,
                    forceDocIDs: forceDocIDs,
                    logger: app.logger, resolve: stage.resolve)
                summaries.append((stage, summary))
            }
            let coverage = try? await withDbRetry(
                logger: app.logger, context: "company_breakdowns 集計"
            ) {
                try await countServableBreakdowns(db: app.db)
            }
            for (stage, summary) in summaries {
                logIngestSummary(
                    app.logger, target: stage.target,
                    attempted: summary.attempted, stored: summary.stored,
                    failed: summary.failed, skipped: summary.skipped,
                    servable: coverage?.servable, unservable: coverage?.unservable,
                    notApplicable: summary.notApplicable,
                    notApplicableGeographyOnly: summary.notApplicableGeographyOnly,
                    notApplicableSingleSegmentDisclosed: summary.notApplicableSingleSegmentDisclosed,
                    notApplicableUnknown: summary.notApplicableUnknown,
                    purged: summary.purged)
            }
        }
        if targets.contains(.statements) {
            // Statement 取り込み: 既定は上場全体（`listed`）。日経225（`priority`）は処理順の先頭寄せのみ。
            // `--codes` 指定時はその集合を母集団にする（filing-sections / financials と同型）。
            let statementListed = codes ?? listed
            if statementListed.isEmpty {
                app.logger.warning(
                    "Statement 取り込み listed codes empty (listed universe empty and no --codes); skipping",
                    metadata: ["event": "ingest_skipped", "target": "statements", "reason": "empty_listed_codes"])
            }
            let s7 = try await runStatementIngest(
                db: app.db, listedCodes: statementListed, years: filingSectionsIngestYears, limit: stageLimit,
                explicitCodes: codes, priorityCodes: priority, cachedDocIDs: cachedDocIDs,
                candidateSets: listedFilingSets,
                forceDocIDs: forceDocIDs,
                logger: app.logger
            ) { docID in
                await context.extractStatement(
                    docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
            }
            let coverage = try? await withDbRetry(logger: app.logger, context: "company_statements 集計") {
                try await countServableStatements(db: app.db)
            }
            logIngestSummary(
                app.logger, target: "statements", attempted: s7.attempted, stored: s7.stored,
                failed: s7.failed, skipped: s7.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable,
                notApplicable: s7.notApplicable, purged: s7.purged)
        }
        if targets.contains(.notes) {
            // 財務諸表注記取り込み: 対象母集団は上場全体（`listed`。日経225=`priority`は処理順の
            // 先頭寄せのみ。2026-09: 日経225限定を廃止し statements と同じ上場全体へ拡大）。
            // EPS/発行済株式・資本金/配当金/borrowings_schedule/PPE・のれん/
            // lease_liabilities/policy_holding_securities は注記からXBRL直接抽出（決定論）。
            // `sga_expense_breakdown` は未公開のためここにも job-03 にも載せない（進捗は Linear Team `blue-ticker`）。
            let statementNotesListed = codes ?? listed
            if statementNotesListed.isEmpty {
                app.logger.warning(
                    "財務諸表注記取り込み listed codes empty (listed universe empty and no --codes); skipping",
                    metadata: ["event": "ingest_skipped", "target": "statement-notes", "reason": "empty_listed_codes"])
            }
            let statementNoteTypes:
                [(noteType: String, resolve: StatementNoteResolveFn)] = [
                    (
                        statementNoteTypePerShareInformation,
                        { docID, _ in
                            await context.resolvePerShareInformationNote(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                        }
                    ),
                    (
                        statementNoteTypeIssuedSharesAndCapital,
                        { docID, _ in
                            await context.resolveIssuedSharesAndCapitalNote(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                        }
                    ),
                    (
                        statementNoteTypeDividends,
                        { docID, _ in
                            await context.resolveDividendsNote(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                        }
                    ),
                    (
                        statementNoteTypeBorrowingsSchedule,
                        { docID, _ in
                            await context.resolveBorrowingsScheduleNote(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                        }
                    ),
                    (
                        statementNoteTypePropertyPlantEquipmentSchedule,
                        { docID, _ in
                            await context.resolvePropertyPlantEquipmentScheduleNote(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                        }
                    ),
                    (
                        statementNoteTypeGoodwillAndIntangibles,
                        { docID, _ in
                            await context.resolveGoodwillAndIntangiblesNote(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                        }
                    ),
                    (
                        statementNoteTypeLeaseLiabilities,
                        { docID, _ in
                            await context.resolveLeaseLiabilitiesNote(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                        }
                    ),
                    (
                        statementNoteTypePolicyHoldingSecurities,
                        { docID, _ in
                            await context.resolvePolicyHoldingSecuritiesNote(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                        }
                    ),
                ]
            let noteTypeFilter = noteTypes
            var notesSummaries: [(noteType: String, summary: StatementNotesIngestSummary)] = []
            for entry in statementNoteTypes {
                if let noteTypeFilter, !noteTypeFilter.contains(entry.noteType) { continue }
                let s8 = try await runStatementNotesIngest(
                    db: app.db, listedCodes: statementNotesListed, years: filingSectionsIngestYears,
                    limit: stageLimit, explicitCodes: codes, priorityCodes: priority,
                    cachedDocIDs: cachedDocIDs,
                    noteType: entry.noteType,
                    candidateSets: deterministicMetricsFilingSets,
                    forceDocIDs: forceDocIDs,
                    logger: app.logger, resolve: entry.resolve)
                notesSummaries.append((noteType: entry.noteType, summary: s8))
            }
            // カバレッジ集計は noteType 非依存のためループの外で 1 回だけ発行する。
            let notesCoverage = try? await withDbRetry(
                logger: app.logger, context: "company_statement_notes 集計"
            ) {
                try await countServableStatementNotes(db: app.db)
            }
            for entry in notesSummaries {
                let s8 = entry.summary
                logIngestSummary(
                    app.logger, target: "statement-notes-\(entry.noteType)", attempted: s8.attempted,
                    stored: s8.stored, failed: s8.failed, skipped: s8.skipped,
                    servable: notesCoverage?.servable, unservable: notesCoverage?.unservable,
                    notApplicable: s8.notApplicable, purged: s8.purged)
            }
        }
        if targets.contains(.icons) {
            // 会社アイコン取り込み: R2クレデンシャル（`BLT_R2_*`）が無い環境（ローカル未設定・Cursor Cloud等）
            // では対象に含めてもスキップし、他ステージの ingest を妨げない。
            if let r2Config = R2Config.resolveFromEnvironment() {
                let s9 = try await runIconsIngest(
                    db: app.db, listedCodes: listed, limit: stageLimit, explicitCodes: codes,
                    priorityCodes: priority, cachedDocIDs: cachedDocIDs,
                    logger: app.logger
                ) { docID, code in
                    await context.extractAndUploadCompanyIcon(
                        docID: docID, code: code, r2Config: r2Config,
                        correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                }
                logIngestSummary(
                    app.logger, target: "icons", attempted: s9.attempted, stored: s9.stored,
                    failed: s9.failed, skipped: s9.skipped)
            } else {
                app.logger.notice(
                    "会社アイコン取り込み skipped (BLT_R2_* 環境変数未設定)",
                    metadata: ["event": "ingest_skipped", "target": "icons", "reason": "r2_config_missing"])
            }
        }
        if targets.contains(.overviews) {
            // 銘柄 Overview 取り込み: OpenRouter キーが無い環境では対象に含めてもスキップし、
            // 他ステージの ingest を妨げない。
            let overviewKey = Environment.get(companyOverviewAPIKeyEnv)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if overviewKey.isEmpty {
                app.logger.notice(
                    "銘柄 Overview 取り込み skipped (\(companyOverviewAPIKeyEnv) 未設定)",
                    metadata: [
                        "event": "ingest_skipped", "target": "overviews",
                        "reason": "overview_api_key_missing",
                    ])
            } else {
                let s10 = try await runOverviewIngest(
                    db: app.db, listedCodes: listed, limit: stageLimit, explicitCodes: codes,
                    priorityCodes: priority, cachedDocIDs: cachedDocIDs,
                    forceDocIDs: forceDocIDs,
                    logger: app.logger
                ) { docID, code in
                    await context.generateCompanyOverview(
                        docID: docID, code: code,
                        correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                }
                logIngestSummary(
                    app.logger, target: "overviews", attempted: s10.attempted, stored: s10.stored,
                    failed: s10.failed, skipped: s10.skipped, notApplicable: s10.notApplicable)
            }
        }
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
