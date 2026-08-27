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
        try await EdinetDocument.query(on: db)
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
            try await storeXbrlFacts(existing: existing, docID: docID, facts: payload, db: db)
        }
        stored += 1
    }

    return FactsIngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped)
}

/// fact インデックスを edinet_xbrl_facts へ書き込む（既存行があれば更新、無ければ作成）。
/// `existing` は呼び出し側で取得済みの行（再 find を避ける）。cache_version に現行 xbrlFactsCacheVersion を埋め込む。
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

/// 報告セグメント別の決定論指標軸の1ジョブ上限。日経225限定。
/// business / geography の `--limit`（定期ジョブ既定 50）とは独立。`--codes` 時は無視して全件。
let unpublishedBreakdownIngestLimit = 30

/// `blt-server ingest` の本体。Application を一時起動して DB を配線し、
/// 財務取り込み（計算済み財務サマリ）→ 半期財務取り込み（半期）→ 有報セクション取り込み（有報セクション）→
/// 内訳取り込み（business/geography は上場全体、決定論指標軸は日経225限定）を取り込む。
///
/// 数値 fact 取り込み（`edinet_xbrl_facts`）は **閉じた**（BLT-23）。生 XBRL の R2 L2 から
/// 再導出できるパース済み投影で、配信も他 stage も読まない。全件投影は Neon 512MB を超える。
/// `--with-facts`（`includeFacts`）は残存 CLI で製品経路ではない。財務取り込みの
/// `computeFinancials` は自前で生 XBRL を読むため、facts 行が無くても自足する。
///
/// `targets` は実行する financials/filing-sections/breakdowns/statements/statement-notes/icons の集合
/// （CLI: `--stages filing-sections` 等）。既定は全対象。icons は `BLT_R2_*` 環境変数未設定時はスキップされる。
/// 例えば有報セクション取り込みだけを先に流したいとき、重い financials の全件 drain を挟まずに済む。
/// 数値 fact 取り込みは `targets` に含めない。
/// `codes` は financials/filing-sections/breakdowns の対象を明示的な証券コード集合に絞る（CLI: `--codes 7203,6758`）。
/// バグ修正確認後などに特定銘柄だけを手動・単発で先に再計算したいケース向け（定期 launchd drain には
/// 使わない）。指定時は `limit` を無視して該当コードを全件処理する（対象自体が小さいため）。
/// 数値 fact 取り込みは `codes` の対象外（doc 単位のため、コードへの紐付けは別スコープ）。
/// 内訳取り込み: business/geography は `listed`（上場全体。日経225は処理順の先頭寄せ）、
/// 決定論指標軸は `priority`（日経225）。`--codes` 指定時は全軸その集合。
/// DATABASE_URL 未設定なら databaseUnavailable、EDINET キー未設定なら apiKeyMissing を投げる。
public func runFactsIngestCommand(
    limit: Int?, includeFacts: Bool = false,
    targets: Set<IngestTarget> = Set(IngestTarget.allCases),
    codes: Set<String>? = nil,
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
        // financials/filing-sections 共通の処理順序づけにのみ使う（未配置なら空集合＝優先なし）。
        let priority = await context.priorityIngestCodes()
        if !priority.isEmpty {
            app.logger.notice(
                "Priority ingest codes loaded",
                metadata: ["event": "priority_codes_loaded", "count": "\(priority.count)"])
        }
        // `--codes` 指定時は financials/filing-sections の対象をその集合へ絞り、`limit` は無視して全件処理する
        // （手動・単発の対象は小さい前提。数値 fact 取り込みは doc 単位のためスコープ外）。
        let stageLimit = codes == nil ? limit : nil
        if let codes {
            app.logger.notice(
                "Explicit ingest codes specified",
                metadata: ["event": "explicit_codes_loaded", "count": "\(codes.count)"])
        }
        let cachedDocIDs = await context.cachedXbrlDocIDs()
        let publicBreakdownListed = codes ?? listed
        let nikkeiListed = codes ?? priority
        let needsListedFilings =
            targets.contains(.filingSections) || targets.contains(.breakdowns)
            || targets.contains(.statements)
        let needsNikkeiFilings =
            targets.contains(.notes) || targets.contains(.breakdowns)

        func loadCandidateSets(_ listedCodes: Set<String>) async throws -> FilingSectionCandidateSets {
            if listedCodes.isEmpty {
                return FilingSectionCandidateSets(keep: [], purge: [])
            }
            return try await filingSectionCandidates(
                db: app.db, listedCodes: listedCodes, explicitCodes: codes,
                years: filingSectionsIngestYears, logger: app.logger)
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

        let nikkeiFilingSets: FilingSectionCandidateSets
        if needsNikkeiFilings {
            if nikkeiListed == listed && needsListedFilings {
                nikkeiFilingSets = listedFilingSets
            } else if nikkeiListed == publicBreakdownListed && targets.contains(.breakdowns) {
                nikkeiFilingSets = publicBreakdownSets
            } else {
                nikkeiFilingSets = try await loadCandidateSets(nikkeiListed)
            }
        } else {
            nikkeiFilingSets = FilingSectionCandidateSets(keep: [], purge: [])
        }

        if includeFacts {
            let s3 = try await runFactsIngest(
                db: app.db, limit: limit, cachedDocIDs: cachedDocIDs,
                logger: app.logger
            ) { docID in
                await context.parseXbrlFactIndex(docID: docID)
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
                explicitCodes: codes, priorityCodes: priority, logger: app.logger
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
                logger: app.logger
            ) { docID in
                await context.extractFilingSections(docID: docID)
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
            // 内訳取り込み: business/geography は上場全体（`listed`。日経225は処理順の先頭寄せ）。
            // 決定論指標軸は日経225（`priority`）限定。`--codes` 時は全軸その集合。
            // `--limit` は business/geography に適用。決定論指標軸は `unpublishedBreakdownIngestLimit`。
            if publicBreakdownListed.isEmpty {
                app.logger.warning(
                    "内訳取り込み listed codes empty (listed universe empty and no --codes); skipping business/geography",
                    metadata: ["event": "ingest_skipped", "target": "breakdowns", "reason": "empty_listed_codes"])
            }
            if nikkeiListed.isEmpty {
                app.logger.warning(
                    "内訳取り込み unpublished axes empty (nikkei225.csv missing and no --codes); skipping deterministic metric axes",
                    metadata: ["event": "ingest_skipped", "target": "breakdowns", "reason": "empty_priority_codes"])
            }
            let unpublishedLimit = codes == nil ? unpublishedBreakdownIngestLimit : nil
            let unpublishedSets =
                nikkeiListed == publicBreakdownListed
                ? publicBreakdownSets : nikkeiFilingSets
            let s6Business = try await runBreakdownIngest(
                db: app.db, listedCodes: publicBreakdownListed, years: filingSectionsIngestYears, limit: stageLimit,
                explicitCodes: codes, priorityCodes: priority,
                cachedDocIDs: cachedDocIDs,
                axis: breakdownAxisBusiness, candidateSets: publicBreakdownSets, logger: app.logger
            ) { docID in
                await context.resolveBusinessBreakdown(docID: docID)
            }
            let s6Geography = try await runBreakdownIngest(
                db: app.db, listedCodes: publicBreakdownListed, years: filingSectionsIngestYears, limit: stageLimit,
                explicitCodes: codes, priorityCodes: priority,
                cachedDocIDs: cachedDocIDs,
                axis: breakdownAxisGeography, candidateSets: publicBreakdownSets, logger: app.logger
            ) { docID in
                await context.resolveGeographyBreakdown(docID: docID)
            }
            let s6Employees = try await runBreakdownIngest(
                db: app.db, listedCodes: nikkeiListed, years: filingSectionsIngestYears, limit: unpublishedLimit,
                explicitCodes: codes, priorityCodes: priority,
                cachedDocIDs: cachedDocIDs,
                axis: breakdownAxisEmployees, candidateSets: unpublishedSets, logger: app.logger
            ) { docID in
                await context.resolveEmployeesBreakdown(docID: docID)
            }
            let s6RD = try await runBreakdownIngest(
                db: app.db, listedCodes: nikkeiListed, years: filingSectionsIngestYears, limit: unpublishedLimit,
                explicitCodes: codes, priorityCodes: priority,
                cachedDocIDs: cachedDocIDs,
                axis: breakdownAxisResearchAndDevelopment, candidateSets: unpublishedSets, logger: app.logger
            ) { docID in
                await context.resolveResearchAndDevelopmentBreakdown(docID: docID)
            }
            let s6Goodwill = try await runBreakdownIngest(
                db: app.db, listedCodes: nikkeiListed, years: filingSectionsIngestYears, limit: unpublishedLimit,
                explicitCodes: codes, priorityCodes: priority,
                cachedDocIDs: cachedDocIDs,
                axis: breakdownAxisGoodwill, candidateSets: unpublishedSets, logger: app.logger
            ) { docID in
                await context.resolveGoodwillBreakdown(docID: docID)
            }
            let segmentMetricAxes = [
                breakdownAxisSegmentAssets,
                breakdownAxisDepreciationAndAmortization,
                breakdownAxisGoodwillAmortization,
                breakdownAxisImpairmentLoss,
                breakdownAxisEquityMethodInvestments,
                breakdownAxisCapitalExpenditures,
                breakdownAxisCapitalExpendituresOverview,
                breakdownAxisNoncurrentAssetAdditions,
            ]
            var segmentMetricSummaries: [(axis: String, summary: BreakdownIngestSummary)] = []
            for axis in segmentMetricAxes {
                let resolver: BreakdownResolveFn
                switch axis {
                case breakdownAxisSegmentAssets:
                    resolver = { docID in await context.resolveSegmentAssetsBreakdown(docID: docID) }
                case breakdownAxisDepreciationAndAmortization:
                    resolver = { docID in
                        await context.resolveDepreciationAndAmortizationBreakdown(docID: docID)
                    }
                case breakdownAxisGoodwillAmortization:
                    resolver = { docID in
                        await context.resolveGoodwillAmortizationBreakdown(docID: docID)
                    }
                case breakdownAxisImpairmentLoss:
                    resolver = { docID in await context.resolveImpairmentLossBreakdown(docID: docID) }
                case breakdownAxisEquityMethodInvestments:
                    resolver = { docID in
                        await context.resolveEquityMethodInvestmentsBreakdown(docID: docID)
                    }
                case breakdownAxisCapitalExpenditures:
                    resolver = { docID in
                        await context.resolveCapitalExpendituresBreakdown(docID: docID)
                    }
                case breakdownAxisCapitalExpendituresOverview:
                    resolver = { docID in
                        await context.resolveCapitalExpendituresOverviewBreakdown(docID: docID)
                    }
                case breakdownAxisNoncurrentAssetAdditions:
                    resolver = { docID in
                        await context.resolveNoncurrentAssetAdditionsBreakdown(docID: docID)
                    }
                default:
                    continue
                }
                let summary = try await runBreakdownIngest(
                    db: app.db, listedCodes: nikkeiListed, years: filingSectionsIngestYears,
                    limit: unpublishedLimit, explicitCodes: codes, priorityCodes: priority,
                    cachedDocIDs: cachedDocIDs, axis: axis, candidateSets: unpublishedSets,
                    logger: app.logger, resolve: resolver)
                segmentMetricSummaries.append((axis: axis, summary: summary))
            }
            let coverage = try? await withDbRetry(
                logger: app.logger, context: "company_breakdowns 集計"
            ) {
                try await countServableBreakdowns(db: app.db)
            }
            logIngestSummary(
                app.logger, target: "breakdowns", attempted: s6Business.attempted, stored: s6Business.stored,
                failed: s6Business.failed, skipped: s6Business.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable,
                notApplicable: s6Business.notApplicable,
                notApplicableGeographyOnly: s6Business.notApplicableGeographyOnly,
                notApplicableSingleSegmentDisclosed: s6Business.notApplicableSingleSegmentDisclosed,
                notApplicableUnknown: s6Business.notApplicableUnknown,
                purged: s6Business.purged)
            logIngestSummary(
                app.logger, target: "breakdowns-geography", attempted: s6Geography.attempted,
                stored: s6Geography.stored, failed: s6Geography.failed, skipped: s6Geography.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable,
                notApplicable: s6Geography.notApplicable,
                notApplicableGeographyOnly: s6Geography.notApplicableGeographyOnly,
                notApplicableSingleSegmentDisclosed: s6Geography
                    .notApplicableSingleSegmentDisclosed,
                notApplicableUnknown: s6Geography.notApplicableUnknown,
                purged: s6Geography.purged)
            logIngestSummary(
                app.logger, target: "breakdowns-employees", attempted: s6Employees.attempted,
                stored: s6Employees.stored, failed: s6Employees.failed, skipped: s6Employees.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable,
                notApplicable: s6Employees.notApplicable,
                notApplicableGeographyOnly: s6Employees.notApplicableGeographyOnly,
                notApplicableSingleSegmentDisclosed: s6Employees
                    .notApplicableSingleSegmentDisclosed,
                notApplicableUnknown: s6Employees.notApplicableUnknown,
                purged: s6Employees.purged)
            logIngestSummary(
                app.logger, target: "breakdowns-rd", attempted: s6RD.attempted,
                stored: s6RD.stored, failed: s6RD.failed, skipped: s6RD.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable,
                notApplicable: s6RD.notApplicable,
                notApplicableGeographyOnly: s6RD.notApplicableGeographyOnly,
                notApplicableSingleSegmentDisclosed: s6RD.notApplicableSingleSegmentDisclosed,
                notApplicableUnknown: s6RD.notApplicableUnknown,
                purged: s6RD.purged)
            logIngestSummary(
                app.logger, target: "breakdowns-goodwill", attempted: s6Goodwill.attempted,
                stored: s6Goodwill.stored, failed: s6Goodwill.failed, skipped: s6Goodwill.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable,
                notApplicable: s6Goodwill.notApplicable,
                notApplicableGeographyOnly: s6Goodwill.notApplicableGeographyOnly,
                notApplicableSingleSegmentDisclosed: s6Goodwill.notApplicableSingleSegmentDisclosed,
                notApplicableUnknown: s6Goodwill.notApplicableUnknown,
                purged: s6Goodwill.purged)
            for item in segmentMetricSummaries {
                let summary = item.summary
                logIngestSummary(
                    app.logger, target: "breakdowns-\(item.axis)",
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
                logger: app.logger
            ) { docID in
                await context.extractStatement(docID: docID)
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
            // 財務諸表注記取り込み: 日経225（`priority`）限定のまま（statements の上場拡大とは独立）。
            // EPS/発行済株式・資本金/配当金/borrowings_schedule/PPE・のれん/
            // lease_liabilities/policy_holding_securities/sga_expense_breakdown は注記からXBRL直接抽出（決定論）。
            let statementNotesListed = codes ?? priority
            if statementNotesListed.isEmpty {
                app.logger.warning(
                    "財務諸表注記取り込み listed codes empty (nikkei225.csv missing and no --codes); skipping",
                    metadata: ["event": "ingest_skipped", "target": "statement-notes", "reason": "empty_listed_codes"])
            }
            let statementNoteTypes:
                [(noteType: String, resolve: StatementNoteResolveFn)] = [
                    (
                        statementNoteTypePerShareInformation,
                        { docID, _ in await context.resolvePerShareInformationNote(docID: docID) }
                    ),
                    (
                        statementNoteTypeIssuedSharesAndCapital,
                        { docID, _ in await context.resolveIssuedSharesAndCapitalNote(docID: docID) }
                    ),
                    (
                        statementNoteTypeDividends,
                        { docID, _ in await context.resolveDividendsNote(docID: docID) }
                    ),
                    (
                        statementNoteTypeBorrowingsSchedule,
                        { docID, _ in await context.resolveBorrowingsScheduleNote(docID: docID) }
                    ),
                    (
                        statementNoteTypePropertyPlantEquipmentSchedule,
                        { docID, _ in await context.resolvePropertyPlantEquipmentScheduleNote(docID: docID) }
                    ),
                    (
                        statementNoteTypeGoodwillAndIntangibles,
                        { docID, _ in await context.resolveGoodwillAndIntangiblesNote(docID: docID) }
                    ),
                    (
                        statementNoteTypeLeaseLiabilities,
                        { docID, _ in await context.resolveLeaseLiabilitiesNote(docID: docID) }
                    ),
                    (
                        statementNoteTypePolicyHoldingSecurities,
                        { docID, _ in await context.resolvePolicyHoldingSecuritiesNote(docID: docID) }
                    ),
                    (
                        statementNoteTypeSgaExpenseBreakdown,
                        { docID, _ in await context.resolveSgaExpenseBreakdownNote(docID: docID) }
                    ),
                ]
            let noteTypeFilter = noteTypes
            for entry in statementNoteTypes {
                if let noteTypeFilter, !noteTypeFilter.contains(entry.noteType) { continue }
                let s8 = try await runStatementNotesIngest(
                    db: app.db, listedCodes: statementNotesListed, years: filingSectionsIngestYears,
                    limit: stageLimit, explicitCodes: codes,
                    cachedDocIDs: cachedDocIDs,
                    noteType: entry.noteType,
                    candidateSets: nikkeiFilingSets,
                    logger: app.logger, resolve: entry.resolve)
                let coverage = try? await withDbRetry(
                    logger: app.logger, context: "company_statement_notes(\(entry.noteType)) 集計"
                ) {
                    try await countServableStatementNotes(db: app.db)
                }
                logIngestSummary(
                    app.logger, target: "statement-notes-\(entry.noteType)", attempted: s8.attempted,
                    stored: s8.stored, failed: s8.failed, skipped: s8.skipped,
                    servable: coverage?.servable, unservable: coverage?.unservable,
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
                    await context.extractAndUploadCompanyIcon(docID: docID, code: code, r2Config: r2Config)
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
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
