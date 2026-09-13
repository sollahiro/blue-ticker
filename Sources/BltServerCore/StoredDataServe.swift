// 格納済みデータ提供ロジック（REST ルートと MCP ツールディスパッチの共通処理）。
// ルート登録・HTTP 変換は Routes.swift、ここは DB 読み取りの共通関数のみを置く。
// Vapor の Response に依存しないため MCPRoute からも直接呼べる。

import BlueTickerCore
import Fluent
import Foundation
import Logging
import Vapor

/// DB 格納済みデータ提供の結果。Vapor に依存しないため MCP ディスパッチからも直接呼べる。
enum StoredDataServeResult {
    /// 成功。JSON 値（`[String: Any]`）。
    case ok([String: Any])
    /// 未格納・未抽出（404 相当）。
    case notFound
    /// DB 未接続・読み取り失敗（503 相当）。
    case dbUnavailable
}

/// `financials` の DB 読み取り共通ロジック。ライブ計算へのフォールバックは行わない（OOM 回避）。
/// `db` は DB 未接続時 `nil` を渡す（`Database` の取得自体が未接続時に fatalError するため、
/// 呼び出し側で dbAvailable ガード済みの値のみ渡すこと。呼び出し例は Routes.swift 内を参照）。
/// `fields` は `years[]` 要素の射影（BLT-57）。nil なら従来どおり全キー。
func serveStoredFinancials(
    code: String, years: Int, fields: Set<String>? = nil, db: Database?, logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredFinancials(code: code, years: years, fields: fields, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `waterfall`（Waterfall・年次）の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveStoredAnalysis(
    code: String, years: Int, db: Database?, logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredAnalysis(code: code, years: years, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `overview` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveStoredOverview(
    code: String, db: Database?, logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredOverview(code: code, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `filing-content` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveStoredFilingSections(
    code: String, docId: String?, sections: [String]?, db: Database?,
    logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredFilingSections(
                code: code, docId: docId, sections: sections, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `statement` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
/// ライブ抽出へのフォールバックは行わない（有報セクション取り込み と同じ理由。決定論のみだが EDINET DL 自体は重い）。
func serveStoredStatement(
    code: String, docId: String?, years: Int, db: Database?, logger: Logger
) async -> StoredDataServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredStatement(code: code, docId: docId, years: years, db: db)
        }
        guard let stored else { return .notFound }
        return .ok(stored)
    } catch {
        return .dbUnavailable
    }
}

/// `breakdown` 専用の DB 読み取り結果。E/F/unknown の reason を 404 応答へ載せるため、他の
/// エンドポイントが共有する `StoredDataServeResult` とは別に持つ（影響範囲を breakdown に限定。issue #132）。
enum BreakdownServeResult {
    /// 成功。JSON 値（`[String: Any]`）。
    case ok([String: Any])
    /// 行はあるが business 軸が解決できなかった（`breakdownNotApplicable*` のいずれか）。404 だが理由を返す。
    case notApplicable(reason: String)
    /// 未格納（404 相当。reason 無し）。
    case notFound
    /// DB 未接続・読み取り失敗（503 相当）。
    case dbUnavailable
}

/// `breakdown` 404 応答の軸別メッセージ（REST/MCP 共用）。
func breakdownNotFoundMessage(axis: String) -> String {
    switch axis {
    case breakdownAxisGeography: return "地域別内訳は未算出です"
    case breakdownAxisEmployees: return "従業員数の内訳は未算出です"
    case breakdownAxisResearchAndDevelopment: return "研究開発費の内訳は未算出です"
    case breakdownAxisGoodwill: return "のれんのセグメント別内訳は未算出です"
    case breakdownAxisSegmentAssets: return "セグメント資産の内訳は未算出です"
    case breakdownAxisDepreciationAndAmortization: return "減価償却費及び償却費の内訳は未算出です"
    case breakdownAxisGoodwillAmortization: return "のれんの償却額の内訳は未算出です"
    case breakdownAxisImpairmentLoss: return "減損損失の内訳は未算出です"
    case breakdownAxisEquityMethodInvestments: return "持分法会計処理される投資の内訳は未算出です"
    case breakdownAxisCapitalExpenditures: return "資本的支出の内訳は未算出です"
    case breakdownAxisCapitalExpendituresOverview: return "設備投資等の概要の内訳は未算出です"
    case breakdownAxisNoncurrentAssetAdditions: return "非流動性資産への追加額の内訳は未算出です"
    default: return "事業別内訳は未算出です"
    }
}

/// `breakdown` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
/// ライブ解決へのフォールバックは行わない（有報セクション取り込み と同じ理由。LLM 呼び出しを serving 経路に持ち込まない）。
func serveStoredBreakdown(
    code: String, docId: String?, axis: String, db: Database?, logger: Logger
) async -> BreakdownServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredBreakdown(code: code, docId: docId, axis: axis, db: db)
        }
        switch stored {
        case .found(let value): return .ok(value)
        case .notApplicable(let reason): return .notApplicable(reason: reason)
        case .absent: return .notFound
        }
    } catch {
        return .dbUnavailable
    }
}

/// `statement/notes` 専用の DB 読み取り結果。`BreakdownServeResult` と同型（対象外 reason を
/// 404 応答へ載せるため、他エンドポイントが共有する `StoredDataServeResult` とは別に持つ）。
enum StatementNoteServeResult {
    /// 成功。JSON 値（`[String: Any]`）。
    case ok([String: Any])
    /// 行はあるが当該 note_type が対象外だった（`statementNoteNotApplicable*` のいずれか）。404 だが理由を返す。
    case notApplicable(reason: String)
    /// 未格納（404 相当。reason 無し）。
    case notFound
    /// DB 未接続・読み取り失敗（503 相当）。
    case dbUnavailable
}

/// notApplicable の reason を持つ read 結果の共通形。
/// `BreakdownServeResult` / `StatementNoteServeResult` の応答変換（REST/MCP）を共通化するための型。
enum ReasonedServeResult {
    case ok([String: Any])
    case notApplicable(reason: String)
    case notFound
    case dbUnavailable
}

extension BreakdownServeResult {
    var reasoned: ReasonedServeResult {
        switch self {
        case .ok(let value): return .ok(value)
        case .notApplicable(let reason): return .notApplicable(reason: reason)
        case .notFound: return .notFound
        case .dbUnavailable: return .dbUnavailable
        }
    }
}

extension StatementNoteServeResult {
    var reasoned: ReasonedServeResult {
        switch self {
        case .ok(let value): return .ok(value)
        case .notApplicable(let reason): return .notApplicable(reason: reason)
        case .notFound: return .notFound
        case .dbUnavailable: return .dbUnavailable
        }
    }
}

/// `statement/notes` の DB 読み取り共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
/// ライブ解決へのフォールバックは行わない（有報セクション取り込み・内訳取り込み・Statement取り込み と同型）。
func serveStoredStatementNote(
    code: String, docId: String?, noteType: String, db: Database?, logger: Logger
) async -> StatementNoteServeResult {
    guard let db else { return .dbUnavailable }
    do {
        let stored = try await withDbRetry(
            maxAttempts: Api.dbReadRetryMaxAttempts,
            maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
            logger: logger
        ) {
            try await loadStoredStatementNote(code: code, docId: docId, noteType: noteType, db: db)
        }
        switch stored {
        case .found(let value): return .ok(value)
        case .notApplicable(let reason): return .notApplicable(reason: reason)
        case .absent: return .notFound
        }
    } catch {
        return .dbUnavailable
    }
}

/// `filings` の DB 優先＋ライブ探索フォールバック共通ロジック。`db` の扱いは `serveStoredFinancials` 参照。
func serveFilings(
    code: String, maxYears: Int, db: Database?, logger: Logger,
    context: BltServerContext
) async -> BltServerResponse {
    guard let code = feedTrendTickerCode(code) else {
        return .badRequest("code は4桁の銘柄コードです")
    }
    let maxYears = parseFilingsMaxYears(maxYears)
    if let db {
        do {
            let records = try await withDbRetry(
                maxAttempts: Api.dbReadRetryMaxAttempts,
                maxBackoffSeconds: Api.dbReadRetryMaxBackoffSeconds,
                logger: logger
            ) {
                try await loadStoredFilingRecords(code: code, db: db)
            }
            if !records.isEmpty {
                return await context.getFilingsFromRecords(
                    code: code, records: records, maxYears: maxYears)
            }
        } catch {
            logger.warning("DB からの filing 取得に失敗、ライブ探索へフォールバック: \(error)")
        }
    }
    // ライブ探索には応答待ち上限を設ける（URLSession 既定の 60s 以上・無限待ち防止）。
    do {
        return try await withOperationTimeout(
            label: "filings ライブ探索", seconds: Api.filingsLiveTimeoutSeconds
        ) {
            await context.getFilings(code: code, maxYears: maxYears)
        }
    } catch {
        logger.warning("filings ライブ探索がタイムアウト: \(error)")
        return .upstreamFailure("書類一覧の取得がタイムアウトしました")
    }
}
