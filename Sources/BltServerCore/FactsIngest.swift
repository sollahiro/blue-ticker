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
func runFactsIngest(
    db: Database, limit: Int?, logger: Logger? = nil, parse: XbrlFactParser
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

    for doc in documents {
        guard let docID = doc.id else { continue }
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため数値 fact 取り込みを中断します(リトライ\(unhealthyRetries)回・残り分類待ち書類あり)")
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await EdinetXbrlFacts.find(docID, on: db)
        }
        if existing == nil {
            missing.append(docID)
        } else if existing?.cacheVersion != xbrlFactsCacheVersion {
            stale.append(docID)
        } else {
            skipped += 1
        }
    }

    let candidates = missing + stale
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

// MARK: - CLI エントリ

/// 財務取り込みで格納する年数。要求が増えても再計算が走らないよう余裕を持たせる
/// （REST の financials は years 既定 5。read 時に要求年数へ縮める）。
let financialsIngestYears = 6

/// `blt-server ingest` の本体。Application を一時起動して DB を配線し、
/// 財務取り込み（計算済み財務サマリ）→ 半期財務取り込み（半期）→ 有報セクション取り込み（有報セクション）→
/// 内訳取り込み（事業別内訳・business軸のみ・日経225構成銘柄限定）を取り込む。
///
/// 数値 fact 取り込み（`edinet_xbrl_facts`・XBRL 数値 fact）は **既定でスキップ**する（issue #22）。
/// facts は現状どこからも消費されない RAW アーカイブで、全件投影 ~800MB は Neon の
/// branch logical size 上限 512MB を超える。消費者（タグ系抽出の facts 化＝目標 A）が
/// できるまで蓄積を止める。停止は可逆で、`includeFacts: true`（CLI: `--with-facts`）で
/// 再開できる。財務取り込みの `computeFinancials` は自前で生 XBRL を DL するため、数値 fact 取り込みを
/// 飛ばしても financials は自足する（機能影響なし）。判断の詳細は blt-server-roadmap.md。
///
/// `targets` は実行する financials/filing-sections/breakdowns/statements/statement-notes/icons の集合
/// （CLI: `--stages filing-sections` 等）。既定は全対象。icons は `BLT_R2_*` 環境変数未設定時はスキップされる。
/// 例えば有報セクション取り込みだけを先に流したいとき、重い financials の全件 drain を挟まずに済む。
/// 数値 fact 取り込みは `targets` に含めず、従来どおり `includeFacts` で別制御する。
/// `codes` は financials/filing-sections/breakdowns の対象を明示的な証券コード集合に絞る（CLI: `--codes 7203,6758`）。
/// バグ修正確認後などに特定銘柄だけを手動・単発で先に再計算したいケース向け（定期 launchd drain には
/// 使わない）。指定時は `limit` を無視して該当コードを全件処理する（対象自体が小さいため）。
/// 数値 fact 取り込みは `codes` の対象外（doc 単位のため、コードへの紐付けは別スコープ）。
/// 内訳取り込みの対象母集団は `listed`（上場全体）ではなく `priority`（日経225構成銘柄）に限定する
/// （LLM 呼び出し費用抑制。`priority` 空集合＝`assets/nikkei225.csv` 未配置時は内訳取り込み対象0件）。
/// DATABASE_URL 未設定なら databaseUnavailable、EDINET キー未設定なら apiKeyMissing を投げる。
public func runFactsIngestCommand(
    limit: Int?, includeFacts: Bool = false,
    targets: Set<IngestTarget> = Set(IngestTarget.allCases),
    codes: Set<String>? = nil
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
        if includeFacts {
            let s3 = try await runFactsIngest(db: app.db, limit: limit, logger: app.logger) { docID in
                await context.parseXbrlFactIndex(docID: docID)
            }
            logIngestSummary(
                app.logger, target: "facts", attempted: s3.attempted, stored: s3.stored,
                failed: s3.failed, skipped: s3.skipped)
        } else {
            app.logger.notice(
                "facts ingest disabled",
                metadata: ["event": "ingest_skipped", "target": "facts", "reason": "issue_22"])
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
                priorityCodes: priority, logger: app.logger
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
            // 内訳取り込み: 既定は日経225（`priority`）を対象母集団（LLM 費用抑制）。
            // `--codes` 指定時はその集合を母集団にする（CSV 未配置の Cloud 等でも
            // 手動再ingestが attempted=0 にならない。issue #160）。
            // 年数は 有報セクション取り込み と同じ集合から取るため filingSectionsIngestYears を共用する。
            // limit は軸ごとの呼び出しで独立に適用する。
            let breakdownListed = codes ?? priority
            if breakdownListed.isEmpty {
                app.logger.warning(
                    "内訳取り込み listed codes empty (nikkei225.csv missing and no --codes); skipping",
                    metadata: ["event": "ingest_skipped", "target": "breakdowns", "reason": "empty_listed_codes"])
            }
            let s6Business = try await runBreakdownIngest(
                db: app.db, listedCodes: breakdownListed, years: filingSectionsIngestYears, limit: stageLimit,
                explicitCodes: codes, axis: breakdownAxisBusiness, logger: app.logger
            ) { docID, consolidatedSales in
                await context.resolveBusinessBreakdown(
                    docID: docID, consolidatedSales: consolidatedSales)
            }
            let s6Geography = try await runBreakdownIngest(
                db: app.db, listedCodes: breakdownListed, years: filingSectionsIngestYears, limit: stageLimit,
                explicitCodes: codes, axis: breakdownAxisGeography, logger: app.logger
            ) { docID, consolidatedSales in
                await context.resolveGeographyBreakdown(
                    docID: docID, consolidatedSales: consolidatedSales)
            }
            // employees/research_and_development は連結売上ではなく 財務取り込み 計算済みの従業員数・
            // 研究開発費合計を分母(全社合計)として使う(重複ロジック回避、2026-08-01 監査指摘対応)。
            let s6Employees = try await runBreakdownIngest(
                db: app.db, listedCodes: breakdownListed, years: filingSectionsIngestYears, limit: stageLimit,
                explicitCodes: codes, axis: breakdownAxisEmployees, logger: app.logger,
                denominatorForDoc: employeesForDocFromFinancials
            ) { docID, total in
                await context.resolveEmployeesBreakdown(docID: docID, total: total)
            }
            let s6RD = try await runBreakdownIngest(
                db: app.db, listedCodes: breakdownListed, years: filingSectionsIngestYears, limit: stageLimit,
                explicitCodes: codes, axis: breakdownAxisResearchAndDevelopment, logger: app.logger,
                denominatorForDoc: rdForDocFromFinancials
            ) { docID, total in
                await context.resolveResearchAndDevelopmentBreakdown(docID: docID, total: total)
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
        }
        if targets.contains(.statements) {
            // Statement 取り込み: 既定は日経225（`priority`）限定。`--codes` 指定時はその集合を母集団にする
            // （内訳取り込み と同型。CSV 未配置でも手動再ingest可能）。
            let statementListed = codes ?? priority
            if statementListed.isEmpty {
                app.logger.warning(
                    "Statement 取り込み listed codes empty (nikkei225.csv missing and no --codes); skipping",
                    metadata: ["event": "ingest_skipped", "target": "statements", "reason": "empty_listed_codes"])
            }
            let s7 = try await runStatementIngest(
                db: app.db, listedCodes: statementListed, years: filingSectionsIngestYears, limit: stageLimit,
                explicitCodes: codes, logger: app.logger
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
            // 財務諸表注記取り込み: 内訳取り込み・Statement 取り込み と同じ日経225限定母集団。財務取り込み
            // 計算済みの値をそのまま再公開するのは research_and_development のみ（passthrough）。
            // EPS/発行済株式数/設備投資概要/配当金は注記からXBRL直接抽出（決議・イベント単位のテーブル
            // 等）へ再設計済み。加えて borrowings_schedule / PPE・のれん明細（IFRS連結限定）/
            // policy_holding_securities（EDINET標準タクソノミの銘柄別構造化タグ、決定論・LLM不要）を
            // 実装・配信中（9 note_type）。
            //
            // sga_breakdown は実装済みだが配信を見送り中（2026-08-02、実データレビューで判明:
            // XBRLタグとして開示されるのは常に非連結（`NonConsolidatedMember`）のみで、連結内訳は
            // タグ化されず本文自由記述にしかない会社が複数あった。「販管費内訳」として非連結値だけ
            // 返すのは利用者を誤解させるためユーザー判断で保留。resolver・回帰テストは将来の連結
            // 対応（本文解析/LLM要）に備えて残す。`StatementNotesResolver.resolveSGABreakdown` /
            // `SwiftTests/BlueTickerTests/RealXbrlStatementNotesTests.swift` 参照。
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
                        statementNoteTypeResearchAndDevelopment,
                        StatementNotesFinancialsPassthroughResolvers.researchAndDevelopment(db: app.db)
                    ),
                    (
                        statementNoteTypeCapitalExpendituresOverview,
                        { docID, _ in await context.resolveCapitalExpendituresOverviewNote(docID: docID) }
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
                        statementNoteTypePolicyHoldingSecurities,
                        { docID, _ in await context.resolvePolicyHoldingSecuritiesNote(docID: docID) }
                    ),
                ]
            for entry in statementNoteTypes {
                let s8 = try await runStatementNotesIngest(
                    db: app.db, listedCodes: statementNotesListed, years: filingSectionsIngestYears,
                    limit: stageLimit, explicitCodes: codes, noteType: entry.noteType,
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
                    priorityCodes: priority, logger: app.logger
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
