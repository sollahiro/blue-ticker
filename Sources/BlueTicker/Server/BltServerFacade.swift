// blt-server の REST API が呼ぶ Core 側ファサード。
// HTTP トランスポート（BltServerCore ターゲット）から呼ばれ、計算済みの応答データを返す。
// このファイルは NIO に依存しない（トランスポートと分離）。
// 内部では CLI と同じ Services / Analysis 層を呼ぶ。

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - BltServerResponse

/// ファサードの応答。HTTP ステータスコードはトランスポート側が決める。
/// 戻り値パターン（error-handling.md）に従い、失敗は throw せず case で表現する。
public enum BltServerResponse {
    /// 成功。JSON 値（オブジェクト or 配列）。
    case ok(Any)
    /// 対象が見つからない（404 相当）。
    case notFound(String)
    /// 外部取得の失敗（502 相当）。
    case upstreamFailure(String)
}

// MARK: - BltServerContext

/// blt-server が共有するコンテキスト兼ファサード（EDINET クライアント・キャッシュを保持）。
/// 可変状態を持たないため `actor` ではなく `Sendable` struct。
public struct BltServerContext: Sendable {
    let edinetClient: EdinetAPIClient
    let cacheManager: CacheManager
    let cacheDir: URL

    init(apiKey: String, cacheDir: URL) {
        self.cacheDir = cacheDir
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        self.edinetClient = EdinetAPIClient(apiKey: apiKey, cacheStore: store)
        self.cacheManager = CacheManager(cacheDir: derivedCacheDir(cacheDir))
    }
}

// MARK: - Factory

/// EDINET API キーを解決する。env（BLT_EDINET_API_KEY）を優先し、未設定なら settingsStore に
/// フォールバックする。クラウド（keychain 非搭載の Linux サーバー）では env から注入する。
private func resolveEdinetApiKey() async -> String? {
    if let envKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"], !envKey.isEmpty {
        return envKey
    }
    let stored = await settingsStore.get(.edinetApiKey)
    return (stored?.isEmpty == false) ? stored : nil
}

/// EDINET API キー（env 優先）と設定から BltServerContext を構築する。
/// EDINET API キーが未設定なら nil を返す（呼び出し元がユーザー向けメッセージを出す）。
public func makeBltServerContext() async -> BltServerContext? {
    guard let key = await resolveEdinetApiKey() else {
        return nil
    }
    let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
    let cacheDir = URL(
        fileURLWithPath: cacheDirStr.isEmpty ? settingsStore.cacheDir.path : cacheDirStr)
    return BltServerContext(apiKey: key, cacheDir: cacheDir)
}

// MARK: - REST Facade

public extension BltServerContext {
    func searchCompanies(q: String) async -> BltServerResponse {
        let results = await masterDataManager.search(q, limit: Api.companySearchLimit)
        return .ok(results.map(companyJSON))
    }

    func searchBySector(sector: String, limit: Int) async -> BltServerResponse {
        let results = await masterDataManager.searchBySector(sector, limit: limit)
        let json = results.map(companyJSON)
        return .ok(json)
    }

    func getFilings(code: String, maxYears: Int) async -> BltServerResponse {
        let stock = await masterDataManager.getByCode(code)
        let service = FilingService(edinetClient: edinetClient)
        let docs = await service.searchFilings(
            code: code, maxYears: maxYears, maxDocuments: Api.filingsMaxDocuments)

        let filings: [[String: Any]] = docs.map { doc in
            filingDict(
                docID: doc["docID"] as? String ?? "",
                docType: doc["docTypeCode"] as? String ?? "",
                rawFyEnd: doc["edinet_fy_end"] as? String ?? "",
                submitAt: (doc["submitDateTime"] as? String) ?? (doc["submitDate"] as? String) ?? "",
                docDescription: doc["docDescription"] as? String ?? "")
        }

        return .ok(["code": code, "name": stock?.coName ?? "", "filings": filings])
    }

    /// Stage 1 DB（`edinet_documents`）から取り込んだ書類レコードで filings 応答を組み立てる。
    /// ライブ EDINET 探索（getFilings）と同一スキーマを返す read 経路。EDINET 取得を伴わず OOM を避ける。
    /// records は呼び出し側（BltServerCore）が当該銘柄分を DB から引いて渡す（空なら呼ばれない）。
    func getFilingsFromRecords(
        code: String, records: [EdinetDocumentRecord], maxYears: Int
    ) async -> BltServerResponse {
        let stock = await masterDataManager.getByCode(code)
        let filings = filingsList(from: records, maxYears: maxYears)
        return .ok(["code": code, "name": stock?.coName ?? "", "filings": filings])
    }

    /// 財務サマリ（公開契約 `FinancialsResponse`）を計算する。
    /// Stage 4 取り込み（`blt-server ingest` → Neon 保存）の単一の実装点。
    /// EDINET 取得・XBRL パースを伴う高コスト処理。失敗・データ無しは nil（戻り値パターン）。
    func computeFinancials(code: String, years: Int) async -> FinancialsResponse? {
        let analyzer = IndividualAnalyzer(edinetClient: edinetClient, cacheManager: cacheManager)
        guard let result = await analyzer.analyze(code: code, analysisYears: years) else {
            return nil
        }
        let stock = await masterDataManager.getByCode(code)
        return FinancialsResponse(
            code: code,
            name: stock?.coName ?? result.code ?? "",
            sector: stock?.s33nm ?? "",
            market: stock?.mktNm ?? "",
            result: result)
    }

    /// 半期財務サマリ（公開契約 `HalfFinancialsResponse`）を計算する。
    /// 半期 Stage 4 取り込み（`blt-server ingest` → Neon 保存）の単一の実装点。HalfYearAnalyzer は
    /// 内部で 5 年分を構築し analysisYears へ trim するため、years に全集合分（半期最大年数）を渡せば
    /// 全集合が返る。EDINET 取得・XBRL パースを伴う高コスト処理。失敗・データ無しは nil（戻り値パターン）。
    func computeHalfFinancials(code: String, years: Int) async -> HalfFinancialsResponse? {
        let analyzer = HalfYearAnalyzer(edinetClient: edinetClient, cacheManager: cacheManager)
        guard let periods = await analyzer.analyze(code: code, analysisYears: years) else {
            return nil
        }
        let stock = await masterDataManager.getByCode(code)
        return HalfFinancialsResponse(code: code, name: stock?.coName ?? "", periods: periods)
    }

    /// Stage 5: 書類1件分の XBRL を取得（Stage 2 キャッシュ経由）し、全セクションを抽出して
    /// 格納用 payload を返す。重い SwiftSoup 抽出を含むため **ingest 専用**（大企業の有報で 1GB OOM を
    /// 実測。serving のライブ抽出は撤去し、read は Neon 格納済みを返す）。ダウンロード失敗は nil（戻り値パターン）。
    /// texts は xbrlSections 全 key を格納（未検出は ""）、specials は segments/geography。
    func extractFilingSections(docID: String) async -> FilingSectionsPayload? {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return nil }

        // honbun HTML 系は1回パースでまとめて抽出（セクション数ぶん再パースしない＝メモリ節約）。
        let parser = XBRLParser()
        let titlesByKey = Dictionary(
            xbrlSections.map { ($0.key, $0.value.title) },
            uniquingKeysWith: { first, _ in first })
        let found = parser.extractSections(in: xbrlDir, titlesByKey: titlesByKey)
        var texts: [String: String] = [:]
        for key in xbrlSections.keys { texts[key] = found[key] ?? "" }  // 全 key 存在を維持

        var specials: [String: SegmentPayload] = [:]
        for key in SegmentExtractor.specialSectionKeys {
            if let seg = SegmentExtractor.extractSpecialSection(key, xbrlDir: xbrlDir) {
                specials[key] = segmentPayload(from: seg)
            }
        }
        return FilingSectionsPayload(texts: texts, specials: specials)
    }

    /// 上場ユニバース（東証上場）の 4 桁コード集合。Stage 5 取り込みの対象選定に使う
    /// （EDINET 公式 CSV の「上場区分」から導出。roadmap の著作権判断参照）。
    func listedCompanyCodes() async -> Set<String> {
        await masterDataManager.listedCodes()
    }
}

/// 内部型 SegmentResult を公開格納用 SegmentPayload へ写経する（Stage 3 の XbrlFactRecord 方式）。
private func segmentPayload(from r: SegmentResult) -> SegmentPayload {
    SegmentPayload(
        method: r.method,
        tables: r.tables.map {
            SegmentTablePayload(heading: $0.heading, markdown: $0.markdown, period: $0.period)
        },
        facts: r.facts.map {
            SegmentFactPayload(
                tag: $0.tag, contextRef: $0.contextRef, dimensions: $0.dimensions,
                value: $0.value, label: $0.label, unitRef: $0.unitRef, decimals: $0.decimals)
        })
}

// MARK: - Stage 1 同期

public extension BltServerContext {
    /// Stage 1 同期用に、指定期間（YYYY-MM-DD）の EDINET 書類を正規化済みレコードで返す。
    /// seed 種別（Api.stage1SyncDocTypes）に絞り、docID で重複排除する。
    /// 取得失敗日は `failedDates` に含め、高水位を進めない判定に使う。
    func fetchDocumentsForSync(from: String, to: String) async -> Stage1FetchResult {
        guard let start = parseDateString(from), let end = parseDateString(to), start <= end else {
            return Stage1FetchResult(records: [], failedDates: [])
        }
        let byDate = await edinetClient.getDocumentsForDateRange(start: start, end: end)
        let failedDates = byDate.compactMap { date, docs -> String? in
            docs == nil ? date : nil
        }
        let allDocs = byDate.values.compactMap { $0 }.flatMap { $0 }
        return Stage1FetchResult(
            records: mapEdinetDocumentRecords(allDocs),
            failedDates: failedDates
        )
    }
}

/// EDINET の動的 JSON（[String: Any]）配列を正規化済みレコードへ写す。
/// seed 種別フィルタ・docID 重複排除・日付正規化を行う純粋関数（ネットワーク非依存・テスト対象）。
func mapEdinetDocumentRecords(_ docs: [[String: Any]]) -> [EdinetDocumentRecord] {
    var seen = Set<String>()
    var records: [EdinetDocumentRecord] = []
    for doc in docs {
        guard let docID = doc["docID"] as? String, !docID.isEmpty else { continue }
        guard let docType = doc["docTypeCode"] as? String,
              Api.stage1SyncDocTypes.contains(docType) else { continue }
        guard seen.insert(docID).inserted else { continue }
        records.append(EdinetDocumentRecord(
            docID: docID,
            edinetCode: nonEmptyString(doc["edinetCode"]) ?? "",
            secCode: nonEmptyString(doc["secCode"]),
            filerName: nonEmptyString(doc["filerName"]) ?? "",
            docTypeCode: docType,
            ordinanceCode: nonEmptyString(doc["ordinanceCode"]),
            formCode: nonEmptyString(doc["formCode"]),
            periodStart: normalizeDateFormat(doc["periodStart"] as? String),
            periodEnd: normalizeDateFormat(doc["periodEnd"] as? String),
            submitDateTime: nonEmptyString(doc["submitDateTime"]) ?? "",
            docDescription: nonEmptyString(doc["docDescription"])
        ))
    }
    return records
}

/// Any? を String? に落とし、空文字・空白のみは nil 扱いにする。
private func nonEmptyString(_ value: Any?) -> String? {
    guard let s = value as? String else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - filings 応答の組み立て（ライブ／DB read 共通）

/// Stage 1 DB レコードから filings の配列を組み立てる純粋関数（ネットワーク・DB 非依存・テスト対象）。
/// 提出日時降順 → docID 重複排除 → 直近 maxYears 年度窓 → 最大 50 件。
/// 年度窓は最新書類の期末年を起点に maxYears 年ぶんを残す（ライブ探索の analysisYears に対応）。
///
/// 簡易セマンティクス（ライブ探索との意図的な差分・確定事項）:
/// 各書類の `fy_end` は自身の period_end をそのまま使う（自己完結ビュー）。主要 doc type の
/// 有報(120)・半期報告書(160) は period_end が通期期末のためライブ経路と完全一致する。
/// 一方、旧四半期(140) は period_end が 2Q 末、訂正(130) は親有報リンクを `edinet_documents` が
/// 保持しない（parentDocID 列なし）ため、ライブ経路の「親 FY 末への正規化／親リンク書類のみ採用」は
/// 再現せず、自身の period_end・窓内全件で返す。schema 変更を避ける判断（docs/blt-server-roadmap.md）。
func filingsList(from records: [EdinetDocumentRecord], maxYears: Int) -> [[String: Any]] {
    let sorted = records.sorted { $0.submitDateTime > $1.submitDateTime }
    let cutoffYear = sorted.compactMap { extractYearMonth($0.periodEnd ?? "").0 }.max()
        .map { $0 - maxYears + 1 }

    var seen = Set<String>()
    var filings: [[String: Any]] = []
    for rec in sorted {
        guard !rec.docID.isEmpty, seen.insert(rec.docID).inserted else { continue }
        if let cutoff = cutoffYear, let y = extractYearMonth(rec.periodEnd ?? "").0, y < cutoff {
            continue
        }
        filings.append(filingDict(
            docID: rec.docID,
            docType: rec.docTypeCode ?? "",
            rawFyEnd: rec.periodEnd ?? "",
            submitAt: rec.submitDateTime,
            docDescription: rec.docDescription ?? ""))
        if filings.count >= Api.filingsMaxDocuments { break }
    }
    return filings
}

/// filings 応答の 1 件分（公開スキーマ）。ライブ経路と DB read 経路でマッピングを共有しドリフトを防ぐ。
/// fy_end は期末日（YYYY-MM-DD）の先頭 7 文字（YYYY-MM）。date-conversion.md で許容された prefix(7)。
func filingDict(
    docID: String, docType: String, rawFyEnd: String, submitAt: String, docDescription: String
) -> [String: Any] {
    let fyEnd = rawFyEnd.count >= 7 ? String(rawFyEnd.prefix(7)) : rawFyEnd
    return [
        "doc_id": docID,
        "doc_type": docType,
        "doc_type_label": docTypeLabel(docType) ?? docDescription,
        "fy_end": fyEnd,
        "submitted_at": submitAt,
    ]
}

/// EDINET 書類種別コード → 表示ラベル。未知コードは nil（呼び出し側が docDescription へフォールバック）。
func docTypeLabel(_ code: String) -> String? {
    switch code {
    case "120": return "有価証券報告書"
    case "130": return "訂正有価証券報告書"
    case "140": return "四半期報告書"
    case "150": return "訂正四半期報告書"
    case "160": return "半期報告書"
    case "170": return "訂正半期報告書"
    default: return nil
    }
}

// MARK: - Stage 3 取り込み（XBRL 数値 fact）

public extension BltServerContext {
    /// Stage 3: 書類1件分の XBRL をダウンロード（Stage 2）してパースし、
    /// 数値 fact インデックス（公開 Codable `XbrlFactIndexPayload`）を返す。
    /// IndividualAnalyzer と同じ `nilAsZero: false` で収集し、Stage 4 が消費する値と一致させる。
    /// ダウンロード失敗・fact 0 件は nil（戻り値パターン）。生 XBRL はローカルキャッシュに保持する。
    func parseXbrlFactIndex(docID: String) async -> XbrlFactIndexPayload? {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return nil }
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir, nilAsZero: false)
        guard !facts.isEmpty else { return nil }
        return facts.mapValues { ctxMap in ctxMap.mapValues(xbrlFactRecord(from:)) }
    }
}

/// 内部型 `XbrlFact` を公開格納用 `XbrlFactRecord` へ写経する（欠落なく保持）。
private func xbrlFactRecord(from f: XbrlFact) -> XbrlFactRecord {
    XbrlFactRecord(
        value: f.value, consolidation: f.consolidation, unitRef: f.unitRef,
        decimals: f.decimals, role: f.role, section: f.section,
        roles: f.roles, sections: f.sections, label: f.label, sourceFile: f.sourceFile)
}

// MARK: - Helpers

private extension BltServerContext {
    /// 企業検索結果の公開 JSON（companies / sectors エンドポイント共通）。
    func companyJSON(_ s: StockSearchResult) -> [String: Any] {
        ["code": s.code, "name": s.name, "sector": s.sector, "market": s.market, "location": s.location]
    }
}
