// Stage 5 取り込み: 上場企業（東証上場）の有報について、セクション本文を抽出し
// company_filing_sections へ upsert する。抽出は BlueTickerCore のファサード（extractFilingSections）に
// 委譲し、ここでは対象選定・staleness 判定・DB upsert のみを担う（ネットワーク非依存でテスト可能）。
//
// filing-content のライブ抽出は大企業有報で 1GB OOM を実測したため撤去し、read は本テーブルの
// DB read-only（loadStoredFilingSections）へ移した。抽出（重い SwiftSoup）はローカル等の余裕ある
// 環境で ingest し、Neon へ保存する。
//
// 対象は「東証上場（EDINET 上場区分）× 有報(120) × 直近 years 年ぶん」。過去書類も docID 単位で保持する。
// 容量（Neon 512MB）のため当面 years を絞る（ストレージ強化＝issue #22 決定後に緩められる）。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// Stage 5 取り込みで保持する有報の年数（1社あたり直近 N 件の有報）。
/// 全書類を持つと容量超過（issue #22）のため直近に絞る。ストレージ強化後に緩められる。
let stage5IngestYears = 3

/// Stage 5 取り込み結果のサマリ。
public struct Stage5IngestSummary: Sendable, Equatable {
    /// 抽出を試みた書類数（skip を除く）。
    public let attempted: Int
    /// 抽出・格納に成功した書類数。
    public let stored: Int
    /// 取得失敗等で格納できずスキップした書類数。
    public let failed: Int
    /// 既に現行バージョン・同一セクション集合で抽出済みのためスキップした書類数。
    public let skipped: Int
}

/// docID を受けてセクション本文 payload を返す抽出器（成功で payload、失敗で nil）。
/// 本番は `context.extractFilingSections`、テストはフェイクを注入する。
public typealias FilingSectionsExtractor = @Sendable (String) async -> FilingSectionsPayload?

/// 上場企業の有報（直近 years 年ぶん）を走査し、未抽出 or バージョン／セクション集合不一致のものを
/// 抽出・格納する。`limit` は新規抽出件数の上限（抽出が重いためバッチ実行用）。
func runStage5Ingest(
    db: Database, listedCodes: Set<String>, years: Int, sectionKeys: String,
    limit: Int?, logger: Logger? = nil, extract: FilingSectionsExtractor
) async throws -> Stage5IngestSummary {
    let candidates = try await stage5Candidates(
        db: db, listedCodes: listedCodes, years: years, logger: logger)

    var attempted = 0
    var stored = 0
    var failed = 0
    var skipped = 0
    var unhealthyRetries = 0

    for cand in candidates {
        // continue（skip/failed）で下の判定を素通りされないよう、各項目の先頭で判定する。
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため Stage 5 を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted - skipped)件は次回スケジュールで再試行)"
            )
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyFilingSections.find(cand.docID, on: db)
        }
        if let row = existing, row.cacheVersion == filingSectionsCacheVersion,
            row.sectionKeys == sectionKeys
        {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        guard let payload = await extract(cand.docID) else {
            failed += 1
            continue
        }
        try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await storeCompanyFilingSections(
                existing: existing, docID: cand.docID, code: cand.code,
                submitDateTime: cand.submitDateTime, payload: payload,
                sectionKeys: sectionKeys, db: db)
        }
        stored += 1
    }

    return Stage5IngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped)
}

/// 取り込み候補（docID, 4桁コード, 提出日時）を返す。
/// 「上場（listedCodes）× 有報(120) × 各社 提出日時降順の直近 years 件」に絞る。
func stage5Candidates(
    db: Database, listedCodes: Set<String>, years: Int, logger: Logger? = nil
) async throws -> [(docID: String, code: String, submitDateTime: String)] {
    let documents = try await withDbRetry(logger: logger, context: "有報一覧") {
        try await EdinetDocument.query(on: db)
            .filter(\.$docTypeCode == Api.docTypeAnnualReport)
            .all()
    }

    // 4 桁コードごとに有報をまとめる。secCode は 5 桁（4 桁＋種別 1 桁 "0"）。
    var byCode: [String: [(docID: String, submitDateTime: String)]] = [:]
    for doc in documents {
        guard let docID = doc.id,
            let sec = doc.secCode, sec.count == 5, sec.hasSuffix("0")
        else { continue }
        let code = String(sec.dropLast())
        guard listedCodes.contains(code) else { continue }
        byCode[code, default: []].append((docID, doc.submitDateTime))
    }

    var result: [(docID: String, code: String, submitDateTime: String)] = []
    for (code, docs) in byCode {
        let recent = docs.sorted { $0.submitDateTime > $1.submitDateTime }.prefix(years)
        for d in recent {
            result.append((docID: d.docID, code: code, submitDateTime: d.submitDateTime))
        }
    }
    return result
}

/// 抽出済みセクションを company_filing_sections へ書き込む（既存行があれば更新、無ければ作成）。
func storeCompanyFilingSections(
    existing: CompanyFilingSections?, docID: String, code: String, submitDateTime: String,
    payload: FilingSectionsPayload, sectionKeys: String, db: Database
) async throws {
    if let row = existing {
        row.code = code
        row.submitDateTime = submitDateTime
        row.payload = payload
        row.cacheVersion = filingSectionsCacheVersion
        row.sectionKeys = sectionKeys
        try await row.update(on: db)
    } else {
        let model = CompanyFilingSections()
        model.id = docID
        model.code = code
        model.submitDateTime = submitDateTime
        model.payload = payload
        model.cacheVersion = filingSectionsCacheVersion
        model.sectionKeys = sectionKeys
        try await model.create(on: db)
    }
}

// MARK: - read 経路（REST filing-content）

/// 格納済み Stage 5 セクションを引いて公開契約 {code, doc_id, sections} を返す。
/// doc_id 指定時はその書類（当該 code のもの）、省略時は当該 code の最新有報。
/// 無い・古い（cache_version 不一致）なら nil（呼び出し側は 404。ライブ抽出へはフォールバックしない）。
func loadStoredFilingSections(
    code: String, docId: String?, sections: [String]?, db: Database
) async throws -> [String: Any]? {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }

    let row: CompanyFilingSections?
    if let docId, !docId.isEmpty {
        // 指定書類。取り違え防止に当該 code の書類であることを確認する。
        let found = try await CompanyFilingSections.find(docId, on: db)
        row = (found?.code == code4) ? found : nil
    } else {
        // 最新有報（提出日時降順の先頭）。
        row = try await CompanyFilingSections.query(on: db)
            .filter(\.$code == code4)
            .filter(\.$cacheVersion == filingSectionsCacheVersion)
            .sort(\.$submitDateTime, .descending)
            .first()
    }

    guard let row, row.cacheVersion == filingSectionsCacheVersion, let docID = row.id else {
        return nil
    }
    return [
        "code": code4,
        "doc_id": docID,
        "sections": row.payload.sectionsObject(sections: sections),
    ]
}
