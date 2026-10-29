// `blt-ingest ingest` の本体。財務取り込み・有報セクション・内訳・Statement・注記・
// アイコン・Overview・関係を取り込む。数値 fact の Neon 永続（旧 edinet_xbrl_facts）は閉じた。
// 配信も他 stage も生 XBRL を直接読む。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation

// MARK: - CLI エントリ

/// 財務取り込みで格納する年数。要求が増えても再計算が走らないよう余裕を持たせる
/// （REST の financials は years 既定 5。read 時に要求年数へ縮める）。
let financialsIngestYears = 6

/// 報告セグメント別の決定論指標軸の1ジョブ上限。対象母集団は上場全体（日経225は処理順の先頭寄せ）。
/// product_service / geography の `--limit`（定期ジョブ既定 50）とは独立。`--codes` 時は無視して全件。
let unpublishedBreakdownIngestLimit = 30

/// `blt-ingest ingest` の本体。DB へ接続し、
/// 財務取り込み（計算済み財務サマリ）→ 有報セクション取り込み（有報セクション）→
/// 内訳取り込み（product_service/geography・決定論指標軸ともに上場全体。日経225は処理順の先頭寄せ）を取り込む。
///
/// `targets` は実行する financials/filing-sections/breakdowns/statements/statement-notes/icons/overviews の集合
/// （CLI: `--stages filing-sections` 等）。既定は全対象。icons は `BLT_R2_*` 環境変数未設定時は
/// スキップされる。overviews は `OPENROUTER_OVERVIEW_API_KEY` 未設定時はスキップされる。
/// 例えば有報セクション取り込みだけを先に流したいとき、重い financials の全件 drain を挟まずに済む。
/// `codes` は financials/filing-sections/breakdowns の対象を明示的な証券コード集合に絞る（CLI: `--codes 7203,6758`）。
/// `docIDs` は会社-FY（原本 120 の doc_id）単位の再 ingest（CLI: `--doc-ids S100W0S7`）。
/// 指定時は該当書類だけを keep し、cache_version / needs_review に関係なく再計算する（分類で
/// missing に入れたあと実処理ループでも fresh skip しない。艦隊の skip は変えない）。
/// financials は会社1行のため
/// その doc の発行体だけ再計算する（他 FY は原本 120 を再読。overlay は訂正がある FY だけ）。
/// バグ修正確認後などに特定銘柄だけを手動・単発で先に再計算したいケース向け（定期 launchd drain には
/// 使わない）。指定時は `limit` を無視して該当コードを全件処理する（対象自体が小さいため）。
/// 内訳取り込み: product_service/geography・決定論指標軸ともに `listed`（上場全体。日経225=`priority`は
/// 処理順の先頭寄せのみ）。`--codes` 指定時は全軸その集合。
/// DATABASE_URL 未設定なら databaseUnavailable、EDINET キー未設定なら apiKeyMissing を投げる。
public func runFactsIngestCommand(
    limit: Int?,
    targets: Set<IngestTarget> = Set(IngestTarget.allCases),
    codes: Set<String>? = nil,
    docIDs: Set<String>? = nil,
    noteTypes: Set<String>? = nil
) async throws {
    guard let context = await makeBltServerContext() else {
        throw DocumentSyncError.apiKeyMissing
    }
    guard let urlString = bltEnvironmentValue("DATABASE_URL"), !urlString.isEmpty else {
        throw DocumentSyncError.databaseUnavailable
    }

    let app = try BltCommandDatabase.connect(urlString: urlString, label: "blt-ingest")
    do {
        try await migrateBltSchema(app)
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
        // （手動・単発の対象は小さい前提）。
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

        var inFlightOriginalIDs = Set(listedFilingSets.keep.map(\.docID))
        inFlightOriginalIDs.formUnion(publicBreakdownSets.keep.map(\.docID))
        inFlightOriginalIDs.formUnion(deterministicMetricsFilingSets.keep.map(\.docID))
        if let docIDs { inFlightOriginalIDs.formUnion(docIDs) }
        let inFlightListedCodes: Set<String>
        if inFlightOriginalIDs.isEmpty {
            let companyWide =
                targets.contains(.financials) || targets.contains(.icons)
                || targets.contains(.overviews) || targets.contains(.relations)
            inFlightListedCodes = codes ?? (companyWide ? listed : [])
        } else {
            inFlightListedCodes = []
        }
        let correctionIDsByOriginal = try await loadAnnualXbrlCorrectionIDsByOriginal(
            db: app.db, originalDocIDs: inFlightOriginalIDs, listedCodes: inFlightListedCodes,
            logger: app.logger)
        let activeOverrides = try await loadActiveManualXbrlOverrides(on: app.db)
        let overrideForce = try await manualXbrlOverrideForceTargets(
            overrides: activeOverrides, on: app.db)
        if !activeOverrides.isEmpty {
            app.logger.notice(
                "Active manual XBRL overrides loaded",
                metadata: [
                    "event": "manual_xbrl_overrides_loaded",
                    "count": "\(activeOverrides.count)",
                ])
        }
        let forceDocIDs = (docIDs ?? []).union(overrideForce.docIDs)
        let financialsExplicitCodes: Set<String>?
        if docIDs != nil {
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

        if targets.contains(.financials) {
            let s4 = try await runFinancialsIngest(
                db: app.db, years: financialsIngestYears, limit: stageLimit, listedCodes: listed,
                explicitCodes: financialsExplicitCodes, priorityCodes: priority,
                forceCodes: (docIDs == nil ? [] : (financialsExplicitCodes ?? [])).union(
                    overrideForce.codes),
                logger: app.logger
            ) { code in
                let computed = await context.computeFinancials(
                    code: code, years: financialsIngestYears)
                let edinet = await context.edinetCode(forListedCode: code) ?? ""
                let matched = activeOverrides.filter {
                    $0.edinetCode == edinet && $0.item == .capex
                }
                return applyingManualCapexOverrides(to: computed, overrides: matched)
            }
            let coverage = try? await withDbRetry(logger: app.logger, context: "company_financials 集計") {
                try await countServableCompanyFinancials(db: app.db)
            }
            logIngestSummary(
                app.logger, target: "financials", attempted: s4.attempted, stored: s4.stored,
                failed: s4.failed, skipped: s4.skipped, refused: s4.refused,
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
            // 内訳取り込み: product_service/geography・決定論指標軸ともに上場全体（`listed`。日経225=
            // `priority` は処理順の先頭寄せのみ）。`--codes` 時は全軸その集合。
            // `--limit` は product_service/geography に適用。決定論指標軸は `unpublishedBreakdownIngestLimit`。
            if publicBreakdownListed.isEmpty {
                app.logger.warning(
                    "内訳取り込み listed codes empty (listed universe empty and no --codes); skipping product_service/geography",
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
                    axis: breakdownAxisSegment, target: "breakdowns-segment",
                    listedCodes: publicBreakdownListed, limit: stageLimit,
                    candidateSets: publicBreakdownSets
                ) { docID in
                    await context.resolveSegmentBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisProductService, target: "breakdowns",
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
                    axis: breakdownAxisEquityMethodInvestments,
                    target: "breakdowns-\(breakdownAxisEquityMethodInvestments)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit, candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveEquityMethodInvestmentsBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisCapex,
                    target: "breakdowns-\(breakdownAxisCapex)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit,
                    candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveCapexBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisInterestBearingDebt,
                    target: "breakdowns-interest_bearing_debt",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit,
                    candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveInterestBearingDebtBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisPropertyPlantEquipment,
                    target: "breakdowns-\(breakdownAxisPropertyPlantEquipment)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit,
                    candidateSets: unpublishedSets
                ) { docID in
                    await context.resolvePropertyPlantEquipmentBreakdown(
                        docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
                },
                BreakdownStage(
                    axis: breakdownAxisGoodwillAndIntangibles,
                    target: "breakdowns-\(breakdownAxisGoodwillAndIntangibles)",
                    listedCodes: deterministicMetricsListed, limit: unpublishedLimit,
                    candidateSets: unpublishedSets
                ) { docID in
                    await context.resolveGoodwillAndIntangiblesBreakdown(
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
                    logger: app.logger,
                    resolve: stage.axis == breakdownAxisInterestBearingDebt
                        || breakdownAssetCategoryAxes.contains(stage.axis)
                        ? stage.resolve
                        : { docID in
                            // セグメント member を分類する軸だけ、会社拡張の調整列の Jev 判定を載せる。
                            await context.withSegmentMemberRoles(
                                docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? []
                            ) { await stage.resolve(docID) }
                        })
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
            // EPS/発行済株式・資本金は注記からXBRL直接抽出（決定論）。
            // `borrowings_schedule` / `lease_liabilities` は公開面から廃止（パーサは IBD 軸が使う）。
            // `property_plant_equipment_schedule` / `goodwill_and_intangibles` は Breakdown の
            // `property_plant_equipment` / `goodwill_and_intangibles` 軸へ移した。
            // `sga_expense_breakdown` は未公開のためここにも job-03 にも載せない。
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
            let overviewKey = bltEnvironmentValue(companyOverviewAPIKeyEnv)?
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
        if targets.contains(.relations) {
            // 関係取り込み: 上場企業の最新有報1件（overviews と同じ選び方）。名前解決は決定論。
            let s11 = try await runRelationsIngest(
                db: app.db, listedCodes: listed, limit: stageLimit, explicitCodes: codes,
                priorityCodes: priority, cachedDocIDs: cachedDocIDs, forceDocIDs: forceDocIDs,
                onlyDocIDs: docIDs, retryJevPending: context.canDecideRelationKinds,
                directory: await context.relationNameDirectory(), logger: app.logger
            ) { docID, _ in
                await context.extractCompanyRelations(
                    docID: docID, correctionDocIDs: correctionIDsByOriginal[docID] ?? [])
            }
            logIngestSummary(
                app.logger, target: "relations", attempted: s11.attempted, stored: s11.stored,
                failed: s11.failed, skipped: s11.skipped)
            app.logger.notice(
                "関係取り込み 解き直し",
                metadata: [
                    "event": "relations_reresolved", "changed": .stringConvertible(s11.reresolved),
                ])
        }
    } catch {
        await app.asyncShutdown()
        throw error
    }
    await app.asyncShutdown()
}
