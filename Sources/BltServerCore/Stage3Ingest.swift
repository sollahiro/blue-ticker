// Stage 3 取り込み: edinet_documents の各書類について XBRL を取得（Stage 2）・パースし、
// 数値 fact インデックスを edinet_xbrl_facts へ upsert する。
// 取得・パースは BlueTickerCore のファサード（parseXbrlFactIndex）に委譲し、
// ここでは候補選定・staleness 判定・DB upsert のみを担う（ネットワーク非依存でテスト可能）。

import BlueTickerCore
import Fluent
import Foundation
import Vapor

/// 取り込み結果のサマリ。
public struct Stage3IngestSummary: Sendable, Equatable {
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
func runStage3Ingest(
    db: Database, limit: Int?, logger: Logger? = nil, parse: XbrlFactParser
) async throws -> Stage3IngestSummary {
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
                "DB接続が不安定なため Stage 3 を中断します(リトライ\(unhealthyRetries)回・残り分類待ち書類あり)")
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
                "DB接続が不安定なため Stage 3 を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
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
            logger?.warning("Stage 3 取り込み失敗: docID=\(docID)")
            continue
        }
        try await withDbRetry(
            logger: logger, context: "docID=\(docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await storeXbrlFacts(existing: existing, docID: docID, facts: payload, db: db)
        }
        stored += 1
    }

    return Stage3IngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped)
}

/// fact インデックスを edinet_xbrl_facts へ書き込む（既存行があれば更新、無ければ作成）。
/// `existing` は呼び出し側で取得済みの行（再 find を避ける）。cache_version に現行 xbrlFactsCacheVersion を埋め込む。
func storeXbrlFacts(
    existing: EdinetXbrlFacts?, docID: String, facts: XbrlFactIndexPayload, db: Database
) async throws {
    if let row = existing {
        row.facts = facts
        row.cacheVersion = xbrlFactsCacheVersion
        try await row.update(on: db)
    } else {
        let model = EdinetXbrlFacts()
        model.id = docID
        model.facts = facts
        model.cacheVersion = xbrlFactsCacheVersion
        try await model.create(on: db)
    }
}

// MARK: - CLI エントリ

/// Stage 4 取り込みで格納する年数。要求が増えても再計算が走らないよう余裕を持たせる
/// （REST の financials は years 既定 5。read 時に要求年数へ縮める）。
let stage4IngestYears = 6

/// `blt-server ingest` の本体。Application を一時起動して DB を配線し、
/// Stage 4（計算済み財務サマリ）→ Stage 4-half（半期）を取り込む。
///
/// Stage 3（`edinet_xbrl_facts`・XBRL 数値 fact）は **既定でスキップ**する（issue #22）。
/// facts は現状どこからも消費されない RAW アーカイブで、全件投影 ~800MB は Neon の
/// branch logical size 上限 512MB を超える。消費者（タグ系抽出の facts 化＝目標 A）が
/// できるまで蓄積を止める。停止は可逆で、`includeFacts: true`（CLI: `--with-facts`）で
/// 再開できる。Stage 4 の `computeFinancials` は自前で生 XBRL を DL するため、Stage 3 を
/// 飛ばしても Stage 4/4-half は自足する（機能影響なし）。判断の詳細は blt-server-roadmap.md。
///
/// `stages` は実行する Stage 4/4-half/5 の集合（CLI: `--stages 5` 等）。既定は全ステージ。
/// 例えば Stage 5 だけを先に流したいとき、重い Stage 4/4-half の全件 drain を挟まずに済む。
/// Stage 3 は `stages` に含めず、従来どおり `includeFacts` で別制御する。
/// `codes` は Stage 4/4-half/5 の対象を明示的な証券コード集合に絞る（CLI: `--codes 7203,6758`）。
/// バグ修正確認後などに特定銘柄だけを手動・単発で先に再計算したいケース向け（定期 launchd drain には
/// 使わない）。指定時は `limit` を無視して該当コードを全件処理する（対象自体が小さいため）。
/// Stage 3 は `codes` の対象外（doc 単位のため、コードへの紐付けは別スコープ）。
/// DATABASE_URL 未設定なら databaseUnavailable、EDINET キー未設定なら apiKeyMissing を投げる。
public func runStage3IngestCommand(
    limit: Int?, includeFacts: Bool = false,
    stages: Set<IngestStage> = Set(IngestStage.allCases),
    codes: Set<String>? = nil
) async throws {
    guard let context = await makeBltServerContext() else {
        throw Stage1SyncError.apiKeyMissing
    }
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        throw Stage1SyncError.databaseUnavailable
    }

    var env = Environment(name: "production", arguments: ["blt-server"])
    try bootstrapBltLogging(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app)
        // 上場・国内法人の対象ユニバース。Stage 4/4-half/5 共通で候補を絞り込み、
        // 上場廃止・外国法人など二度と成功しない企業への無駄なリトライを避ける。
        let listed = await context.listedCompanyCodes()
        // ユーザーが用意した優先コード一覧（`assets/nikkei225.csv`）。対象選定ではなく
        // Stage 4/4-half/5 共通の処理順序づけにのみ使う（未配置なら空集合＝優先なし）。
        let priority = await context.priorityIngestCodes()
        if !priority.isEmpty {
            app.logger.notice(
                "Priority ingest codes loaded",
                metadata: ["event": "priority_codes_loaded", "count": "\(priority.count)"])
        }
        // `--codes` 指定時は Stage 4/4-half/5 の対象をその集合へ絞り、`limit` は無視して全件処理する
        // （手動・単発の対象は小さい前提。Stage 3 は doc 単位のためスコープ外）。
        let stageLimit = codes == nil ? limit : nil
        if let codes {
            app.logger.notice(
                "Explicit ingest codes specified",
                metadata: ["event": "explicit_codes_loaded", "count": "\(codes.count)"])
        }
        if includeFacts {
            let s3 = try await runStage3Ingest(db: app.db, limit: limit, logger: app.logger) { docID in
                await context.parseXbrlFactIndex(docID: docID)
            }
            logIngestSummary(
                app.logger, stage: "3", attempted: s3.attempted, stored: s3.stored,
                failed: s3.failed, skipped: s3.skipped)
        } else {
            app.logger.notice(
                "Stage 3 facts ingest disabled",
                metadata: ["event": "ingest_skipped", "stage": "3", "reason": "issue_22"])
        }
        if stages.contains(.financials) {
            let s4 = try await runStage4Ingest(
                db: app.db, years: stage4IngestYears, limit: stageLimit, listedCodes: listed,
                explicitCodes: codes, priorityCodes: priority, logger: app.logger
            ) { code in
                await context.computeFinancials(code: code, years: stage4IngestYears)
            }
            let coverage = try? await withDbRetry(logger: app.logger, context: "company_financials 集計") {
                try await countServableCompanyFinancials(db: app.db)
            }
            logIngestSummary(
                app.logger, stage: "4", attempted: s4.attempted, stored: s4.stored,
                failed: s4.failed, skipped: s4.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable)
        }
        if stages.contains(.half) {
            let s4h = try await runStage4HalfIngest(
                db: app.db, years: stage4HalfIngestYears, limit: stageLimit, listedCodes: listed,
                explicitCodes: codes, priorityCodes: priority, logger: app.logger
            ) { code in
                await context.computeHalfFinancials(code: code, years: stage4HalfIngestYears)
            }
            let halfCoverage = try? await withDbRetry(
                logger: app.logger, context: "company_half_financials 集計"
            ) {
                try await countServableCompanyHalfFinancials(db: app.db)
            }
            logIngestSummary(
                app.logger, stage: "4half", attempted: s4h.attempted, stored: s4h.stored,
                failed: s4h.failed, skipped: s4h.skipped,
                servable: halfCoverage?.servable, unservable: halfCoverage?.unservable,
                notApplicable: s4h.notApplicable)
        }
        if stages.contains(.sections) {
            // Stage 5: 上場企業の有報セクション本文を抽出・格納（filing-content の read-only 化）。
            let s5 = try await runStage5Ingest(
                db: app.db, listedCodes: listed, years: stage5IngestYears,
                sectionKeys: currentFilingSectionKeys(), limit: stageLimit, explicitCodes: codes,
                priorityCodes: priority, logger: app.logger
            ) { docID in
                await context.extractFilingSections(docID: docID)
            }
            let coverage = try? await withDbRetry(logger: app.logger, context: "company_filing_sections 集計") {
                try await countServableFilingSections(db: app.db)
            }
            logIngestSummary(
                app.logger, stage: "5", attempted: s5.attempted, stored: s5.stored,
                failed: s5.failed, skipped: s5.skipped,
                servable: coverage?.servable, unservable: coverage?.unservable)
        }
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
