// 会社アイコン取り込み: 上場企業について、直近の有報からEDINET電子公告URLを抽出し、faviconを取得して
// R2へアップロードし company_icons へ upsert する。1社=1行（filing-sections等の書類単位の保持とは異なり、
// 会社の公式サイトは事実上不変のため直近有報1件のみを対象にする。過去書類の履歴保持・purgeは不要）。
//
// 抽出元行（「公告掲載方法」）が紙媒体のみ・別注記委譲などで URL 抽出できない会社（実データ検証で
// 148件中12件）は、直近有報が同一内容である限り毎回 failed として再試行され続ける
// （既知の制約。company_breakdowns の not_applicable のような永続プレースホルダは未実装）。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// 会社アイコン取り込み結果のサマリ。
public struct IconsIngestSummary: Sendable, Equatable {
    /// 抽出を試みた会社数。
    public let attempted: Int
    /// 取得・格納に成功した会社数。
    public let stored: Int
    /// URL抽出・favicon取得・R2アップロードのいずれかで失敗した会社数。
    public let failed: Int
    /// 既に現行バージョンで格納済みのためスキップした会社数。
    public let skipped: Int
}

/// docID・codeを受けて抽出・アップロード結果を返す関数。
/// 本番は `context.extractAndUploadCompanyIcon`、テストはフェイクを注入する。
public typealias CompanyIconExtractor =
    @Sendable (String, String) async -> Swift.Result<CompanyIconExtractResult, CompanyIconExtractFailure>

/// 上場企業の直近有報1件ずつを走査し、未取得 or バージョン不一致の会社アイコンを取得・格納する。
/// `limit` は新規取得件数の上限（favicon取得・R2アップロードのネットワークI/Oのためバッチ実行用）。
/// `explicitCodes` を渡すと候補をその集合に絞る（`--codes` 手動指定。`nil` は絞り込みなし）。
/// `priorityCodes` に含まれる企業は候補の中で先頭へ寄せる（対象選定ではなく処理順序のみ）。
/// `cachedDocIDs` はローカル XBRL 展開済み。処理順は日経225 → キャッシュ済み → 欠測/版ずれのラウンドロビン。
func runIconsIngest(
    db: Database, listedCodes: Set<String>, limit: Int?, explicitCodes: Set<String>? = nil,
    priorityCodes: Set<String> = [], cachedDocIDs: Set<String> = [],
    logger: Logger? = nil, extract: CompanyIconExtractor
) async throws -> IconsIngestSummary {
    let baseCandidates = try await latestAnnualReportPerCompany(
        db: db, listedCodes: listedCodes, explicitCodes: explicitCodes, logger: logger)

    var attempted = 0
    var stored = 0
    var failed = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [(docID: String, code: String)] = []
    var staleVersion: [(docID: String, code: String)] = []

    let classifyRows = try await withDbRetry(
        logger: logger, context: "会社アイコン取り込み 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await CompanyIconCacheVersionOnly.query(on: db).all()
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for cand in baseCandidates {
        guard let existing = classifyIndex[cand.code] else {
            missing.append(cand)
            continue
        }
        if existing.cacheVersion != companyIconsCacheVersion {
            staleVersion.append(cand)
        } else {
            skipped += 1
        }
    }
    let candidates = ingestOrdered(
        interleaved([missing, staleVersion]),
        docIDOf: \.docID, codeOf: \.code, cachedDocIDs: cachedDocIDs, priorityCodes: priorityCodes)
    // 分類フェーズと実処理フェーズでリトライ予算を分ける。
    unhealthyRetries = 0

    for cand in candidates {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため 会社アイコン取り込み を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "code=\(cand.code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyIcon.find(cand.code, on: db)
        }
        if let row = existing, row.cacheVersion == companyIconsCacheVersion {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        switch await extract(cand.docID, cand.code) {
        case .failure(let reason):
            failed += 1
            logger?.warning(
                "会社アイコン取り込み失敗: docID=\(cand.docID) code=\(cand.code) reason=\(reason)")
            continue
        case .success(let result):
            try await withDbRetry(
                logger: logger, context: "code=\(cand.code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyIcon(
                    existing: try await CompanyIcon.find(cand.code, on: db),
                    code: cand.code, result: result, db: db)
            }
            stored += 1
        }
    }

    return IconsIngestSummary(attempted: attempted, stored: stored, failed: failed, skipped: skipped)
}

/// 上場（listedCodes）× 会社有報(120・府令010) の直近1件を会社ごとに選ぶ。`explicitCodes` を渡すとさらに絞る。
/// docType 120 でも特定有価証券府令(030)の信託受益証券等は除外（statements / filings と同じ）。
func latestAnnualReportPerCompany(
    db: Database, listedCodes: Set<String>, explicitCodes: Set<String>? = nil, logger: Logger? = nil
) async throws -> [(docID: String, code: String)] {
    let documents = try await withDbRetry(logger: logger, context: "有報一覧") {
        try await EdinetDocumentListing.query(on: db)
            .filter(\.$docTypeCode == Api.docTypeAnnualReport)
            .all()
    }

    var byCode: [String: (docID: String, submitDateTime: String)] = [:]
    for doc in documents {
        guard let docID = doc.id,
            let sec = doc.secCode, sec.count == 5, sec.hasSuffix("0"),
            Api.isCompanyDisclosureOrdinance(doc.ordinanceCode)
        else { continue }
        let code = String(sec.dropLast())
        guard listedCodes.contains(code) else { continue }
        if let explicit = explicitCodes, !explicit.contains(code) { continue }
        if let current = byCode[code], current.submitDateTime >= doc.submitDateTime { continue }
        byCode[code] = (docID, doc.submitDateTime)
    }
    return byCode.map { (docID: $0.value.docID, code: $0.key) }.sorted { $0.code < $1.code }
}

/// 抽出・アップロード済みの会社アイコンを company_icons へ書き込む（既存行があれば更新、無ければ作成）。
func storeCompanyIcon(
    existing: CompanyIcon?, code: String, result: CompanyIconExtractResult, db: Database
) async throws {
    let applyFields: (CompanyIcon) -> Void = { row in
        row.sourceURL = result.sourceURL
        row.r2ObjectKey = result.r2ObjectKey
        row.contentType = result.contentType
        row.cacheVersion = companyIconsCacheVersion
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = CompanyIcon(
            code: code, sourceURL: result.sourceURL, r2ObjectKey: result.r2ObjectKey,
            contentType: result.contentType, cacheVersion: companyIconsCacheVersion)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                guard let recovered = try await CompanyIcon.find(code, on: db) else { return false }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

/// `cache_version` のみを対象にした軽量射影（分類の N+1 find 回避用）。
final class CompanyIconCacheVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyIcon.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    init() {}
}
