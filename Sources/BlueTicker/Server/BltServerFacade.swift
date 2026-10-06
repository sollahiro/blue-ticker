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
/// 戻り値パターン（`.agents/rules/data-handling.md`）に従い、失敗は throw せず case で表現する。
public enum BltServerResponse {
    /// 成功。JSON 値（オブジェクト or 配列）。
    case ok(Any)
    /// リクエストが不正（400 相当）。
    case badRequest(String)
    /// 対象が見つからない（404 相当）。
    case notFound(String)
    /// 外部取得の失敗（502 相当）。
    case upstreamFailure(String)
}

// MARK: - BltServerContext

/// blt-server が共有するコンテキスト兼ファサード（EDINET クライアント・キャッシュを保持）。
/// クライアント参照は不変。決定論指標軸の XBRL 再パース回避だけ actor メモを持つ。
public struct BltServerContext: Sendable {
    let edinetClient: EdinetAPIClient
    let cacheManager: CacheManager
    let cacheDir: URL
    /// Overview 生成。`OPENROUTER_OVERVIEW_API_KEY` 未設定なら `UnavailableChatClient`。
    let overviewChatClient: ChatCompleting
    let overviewModel: String
    /// セグメント注記の Jev。`OPENROUTER_DECISION_API_KEY` 未設定なら nil（今日の分類のまま）。
    let segmentNoteDecider: (any SegmentNoteDeciding)?
    /// 収益分解の当期列選択。同じキーが無いときは nil（Chat Completions には落とさない）。
    let revenueRecognitionColumnDecider: (any RevenueRecognitionColumnDeciding)?
    /// geography html_table の当期列選択。同じキーが無いときは nil。
    let geographyColumnDecider: (any RevenueRecognitionColumnDeciding)?
    /// セグメント情報 html_table の列・行選択。同じキーが無いときは列デサイダへ落とす。
    let segmentInfoDecider: (any SegmentInfoDeciding)?
    /// 研究開発費の本文総額。同じキーが無いときは nil（数値タグが無い書類は not_found のまま）。
    let researchAndDevelopmentProseDecider: (any ResearchAndDevelopmentProseDeciding)?
    /// 設備投資マトリクスの本文総額。同じキーが無いときは nil。
    let capexProseDecider: (any CapexProseDeciding)?
    /// employees / rd / goodwill / 報告セグメント指標軸が同一 doc を軸ループで再パースしないためのメモ。
    let businessSegmentDimensionCache: BusinessSegmentDimensionCache

    init(
        apiKey: String, cacheDir: URL,
        overviewChatClient: ChatCompleting = UnavailableChatClient(),
        overviewModel: String = companyOverviewDefaultModel,
        segmentNoteDecider: (any SegmentNoteDeciding)? = nil,
        revenueRecognitionColumnDecider: (any RevenueRecognitionColumnDeciding)? = nil,
        geographyColumnDecider: (any RevenueRecognitionColumnDeciding)? = nil,
        segmentInfoDecider: (any SegmentInfoDeciding)? = nil,
        researchAndDevelopmentProseDecider: (any ResearchAndDevelopmentProseDeciding)? = nil,
        capexProseDecider: (any CapexProseDeciding)? = nil
    ) {
        self.cacheDir = cacheDir
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let xbrlObjectStore: (any XbrlObjectStoring)? =
            R2StorageConfig.resolveXbrlFromEnvironment().map { R2XbrlObjectStore(config: $0) }
        self.edinetClient = EdinetAPIClient(
            apiKey: apiKey, cacheStore: store, xbrlObjectStore: xbrlObjectStore)
        self.cacheManager = CacheManager(cacheDir: derivedCacheDir(cacheDir))
        self.overviewChatClient = overviewChatClient
        self.overviewModel = overviewModel
        self.segmentNoteDecider = segmentNoteDecider
        self.revenueRecognitionColumnDecider = revenueRecognitionColumnDecider
        self.geographyColumnDecider = geographyColumnDecider
        self.segmentInfoDecider = segmentInfoDecider
        self.researchAndDevelopmentProseDecider = researchAndDevelopmentProseDecider
        self.capexProseDecider = capexProseDecider
        self.businessSegmentDimensionCache = BusinessSegmentDimensionCache()
    }
}

/// 事業セグメント dimension の fact / ラベルを docID 単位でメモする。
/// ingest が軸ごとに `runBreakdownIngest` するため、同一書類の XML 再パースを避ける落とし所。
/// doc 単位の一括解決（軸ループ自体の再設計）は別スコープ。
actor BusinessSegmentDimensionCache {
    struct Entry: Sendable {
        let facts: [BreakdownFact]
        let labelsByTag: [String: String]
    }

    private var entries: [String: Entry] = [:]

    func load(docID: String, xbrlDir: URL) -> Entry {
        if let hit = entries[docID] { return hit }
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: xbrlDir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labelsByTag = XBRLUtils.breakdownMemberLabels(in: xbrlDir)
        let entry = Entry(facts: facts, labelsByTag: labelsByTag)
        entries[docID] = entry
        return entry
    }
}

// MARK: - Factory

/// EDINET API キーを解決する。blt-server はヘッドレスなサーバープロセスのため、
/// BLT_EDINET_API_KEY 環境変数のみを見る。
private func resolveEdinetApiKey() async -> String? {
    let envKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"]
    return (envKey?.isEmpty == false) ? envKey : nil
}

/// Overview 生成の OpenRouter エンドポイント。
/// `OPENROUTER_OVERVIEW_API_KEY` のみ読む。未設定なら nil。
func resolveOverviewLLMEndpoint(
    _ env: [String: String] = ProcessInfo.processInfo.environment
) -> ChatCompletionEndpoint? {
    func nonEmpty(_ key: String) -> String? {
        let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
    guard let apiKey = nonEmpty(companyOverviewAPIKeyEnv) else { return nil }
    let model = nonEmpty(companyOverviewModelEnv) ?? companyOverviewDefaultModel
    let baseURL = nonEmpty(companyOverviewBaseURLEnv) ?? Api.openrouterBaseURL
    return ChatCompletionEndpoint(
        baseURL: baseURL, apiKey: apiKey, model: model, timeoutSeconds: 90,
        provider: .openrouter, maxTokens: 1024)
}

/// EDINET API キー（env 優先）と設定から BltServerContext を構築する。
/// EDINET API キーが未設定なら nil を返す（呼び出し元がユーザー向けメッセージを出す）。
/// Decisions キー未設定でも 内訳取り込み の xbrl_facts 経路は動く（html_table の Jev 列選択のみに影響）。
public func makeBltServerContext() async -> BltServerContext? {
    let env = ProcessInfo.processInfo.environment
    guard let key = await resolveEdinetApiKey() else {
        return nil
    }
    let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
    let cacheDir = URL(
        fileURLWithPath: cacheDirStr.isEmpty ? settingsStore.cacheDir.path : cacheDirStr)
    let overviewEndpoint = resolveOverviewLLMEndpoint(env)
    let overviewChatClient: ChatCompleting =
        overviewEndpoint.map { ChatCompletionClient(endpoint: $0) } ?? UnavailableChatClient()
    let decisionsClient = resolveOpenRouterDecisionsEndpoint(env).map {
        OpenRouterDecisionsClient(endpoint: $0)
    }
    let segmentNoteDecider: (any SegmentNoteDeciding)? = decisionsClient.map {
        OpenRouterSegmentNoteDecider(client: $0)
    }
    let revenueRecognitionColumnDecider: (any RevenueRecognitionColumnDeciding)? =
        decisionsClient.map {
            OpenRouterRevenueRecognitionColumnDecider(client: $0)
        }
    let geographyColumnDecider: (any RevenueRecognitionColumnDeciding)? =
        decisionsClient.map {
            OpenRouterGeographyColumnDecider(client: $0)
        }
    let segmentInfoDecider: (any SegmentInfoDeciding)? = decisionsClient.map {
        OpenRouterSegmentInfoDecider(client: $0)
    }
    let researchAndDevelopmentProseDecider: (any ResearchAndDevelopmentProseDeciding)? =
        decisionsClient.map {
            OpenRouterResearchAndDevelopmentProseDecider(client: $0)
        }
    let capexProseDecider: (any CapexProseDeciding)? = decisionsClient.map {
        OpenRouterCapexProseDecider(client: $0)
    }
    return BltServerContext(
        apiKey: key, cacheDir: cacheDir, overviewChatClient: overviewChatClient,
        overviewModel: overviewEndpoint?.model ?? companyOverviewDefaultModel,
        segmentNoteDecider: segmentNoteDecider,
        revenueRecognitionColumnDecider: revenueRecognitionColumnDecider,
        geographyColumnDecider: geographyColumnDecider,
        segmentInfoDecider: segmentInfoDecider,
        researchAndDevelopmentProseDecider: researchAndDevelopmentProseDecider,
        capexProseDecider: capexProseDecider)
}

// MARK: - REST Facade

public extension BltServerContext {
    func searchCompanies(q: String) async -> BltServerResponse {
        let results = await masterDataManager.search(q, limit: Api.companySearchLimit)
        return .ok(results.map(companyJSON))
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

    /// 書類同期 DB（`edinet_documents`）から取り込んだ書類レコードで filings 応答を組み立てる。
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
    /// 財務取り込み（`blt-server ingest` → Neon 保存）の単一の実装点。
    /// EDINET 取得・XBRL パースを伴う高コスト処理。「有価証券報告書未提出」（対象外）と
    /// 「抽出失敗」を区別して返す（戻り値パターン、issue #86）。
    func computeFinancials(code: String, years: Int) async -> FinancialsComputeResult {
        let analyzer = IndividualAnalyzer(edinetClient: edinetClient, cacheManager: cacheManager)
        // Ingest は derived `individual_analysis_*` を使わない。そのキーは
        // `blueTickerVersion` であり `companyFinancialsCacheVersion`（fin-vN）ではない。
        // 既定 `useCache: true` のままだと fin-vN ingest が古 IBD/ROIC を現行として書く。
        switch await analyzer.analyze(code: code, analysisYears: years, useCache: false) {
        case .result(let result):
            let stock = await masterDataManager.getByCode(code)
            return .success(
                FinancialsResponse(
                    code: code,
                    name: stock?.coName ?? result.code ?? "",
                    sector: stock?.s33nm ?? "",
                    market: stock?.mktNm ?? "",
                    result: result))
        case .notApplicable:
            return .notApplicable
        case .failed:
            return .failed
        }
    }

    /// 有報セクション取り込み: 書類1件分の XBRL を取得（XBRL 取得キャッシュ経由）し、全セクションを抽出して
    /// 格納用 payload を返す。重い SwiftSoup 抽出を含むため **ingest 専用**（大企業の有報で 1GB OOM を
    /// 実測。serving のライブ抽出は撤去し、read は Neon 格納済みを返す）。ダウンロード失敗は nil（戻り値パターン）。
    /// texts は xbrlSections 全 key を格納（未検出は ""）、specials は segments/geography。
    func extractFilingSections(docID: String, correctionDocIDs: [String] = []) async -> FilingSectionsPayload? {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return nil }

        // honbun HTML 系は1回パースでまとめて抽出（セクション数ぶん再パースしない＝メモリ節約）。
        let parser = XBRLParser()
        let titlesByKey = Dictionary(
            xbrlSections.map { ($0.key, $0.value.title) },
            uniquingKeysWith: { first, _ in first })
        let found = parser.extractSections(in: xbrlDir, titlesByKey: titlesByKey)
        var texts: [String: String] = [:]
        for key in xbrlSections.keys { texts[key] = found[key] ?? "" }  // 全 key 存在を維持

        var specials: [String: ExtractedBreakdownPayload] = [:]
        for key in BreakdownExtractor.specialSectionKeys {
            if let seg = BreakdownExtractor.extractSpecialSection(key, xbrlDir: xbrlDir) {
                specials[key] = extractedBreakdownPayload(from: seg)
            }
        }
        return FilingSectionsPayload(texts: texts, specials: specials)
    }

    /// 上場ユニバース（東証上場）の 4 桁コード集合。有報セクション取り込みの対象選定に使う
    /// （EDINET 公式 CSV の「上場区分」から導出。roadmap の著作権判断参照）。
    func listedCompanyCodes() async -> Set<String> {
        await masterDataManager.listedCodes()
    }

    /// 提出者種別が「外国法人・組合」の 4 桁コード。書類同期で `edinet_documents` から除外する。
    func foreignFilerCodes() async -> Set<String> {
        await masterDataManager.foreignFilerCodes()
    }

    /// 上場・国内法人の EDINETコード → 5 桁証券コード。書類の空 `secCode` を補う。
    func listedSecCodeByEdinetCode() async -> [String: String] {
        await masterDataManager.listedSecCodeByEdinetCode()
    }

    /// 4 桁上場コードに対応する EDINET 提出者コード。未収録は nil。
    func edinetCode(forListedCode code: String) async -> String? {
        await masterDataManager.edinetCode(forListedCode: code)
    }

    /// Statement 取り込み（Statement 本体）: 単一書類の XBRL から BS/PL/CF/SS を抽出する。決定論のみ（LLM不要）。
    /// `extractFilingSections`（有報セクション取り込み）と同型: 1書類分のみを扱い、複数年度の履歴集約は
    /// 行わない。US-GAAP は `.notApplicable`（連結に数値 fact が無く正規化不可。notes と同方針）。
    /// ダウンロード失敗は `.failed`。
    func extractStatement(
        docID: String, statementTypes: Set<StatementSectionType> = Set(StatementSectionType.allCases),
        correctionDocIDs: [String] = []
    ) async -> StatementDocResolveResult {
        let analyzer = StatementAnalyzer(edinetClient: edinetClient)
        return await analyzer.extract(
            docID: docID, statementTypes: statementTypes, correctionDocIDs: correctionDocIDs)
    }

    /// 会社アイコン取り込み: 手動 origin / 公式画像があれば XBRL を使わず取得する。それ以外は
    /// 書類1件分のXBRLから電子公告URLを抽出し、faviconを取得してR2へアップロードする。
    /// URL抽出（`CorporateWebsiteExtractor`）・favicon取得（`FaviconFetcher`）・R2アップロード
    /// （`R2Client`）のいずれかが失敗すれば `.failure`（戻り値パターン。段名をログ用に返す）。
    /// `r2Config` は呼び出し側（BltServerCore ingest）が環境変数から解決して渡す。
    func extractAndUploadCompanyIcon(
        docID: String, code: String, r2Config: R2Config, correctionDocIDs: [String] = []
    ) async
        -> Swift.Result<CompanyIconExtractResult, CompanyIconExtractFailure>
    {
        if let manual = CompanyIconOriginOverride.manualSource(for: code) {
            return await fetchAndUploadManualCompanyIcon(
                source: manual, code: code, r2Config: r2Config)
        }
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else {
            return .failure(.downloadFailed)
        }
        let extracted = CorporateWebsiteExtractor.extract(xbrlDir: xbrlDir)
        guard let extractedOrigin = extracted.url else {
            return .failure(CompanyIconExtractFailure.urlExtractFailed(method: extracted.method))
        }
        let origin = CompanyIconOriginOverride.originForFavicon(
            code: code, extractedOrigin: extractedOrigin)
        guard let icon = await FaviconFetcher.fetch(origin: origin) else {
            return .failure(CompanyIconExtractFailure.faviconFetchFailed(origin: origin))
        }
        return await uploadFetchedCompanyIcon(
            icon, code: code, sourceURL: origin, cacheVersion: companyIconsCacheVersion,
            r2Config: r2Config)
    }

    /// ユーザーが用意した優先コード一覧（`assets/nikkei225.csv`）の証券コード集合。
    /// financials/filing-sections/breakdowns/statement-notes 取り込みの処理順序づけに使う
    /// （対象選定ではなく優先度のみ）。ファイル未配置なら空集合（優先なし・従来どおりの順序にフォールバック）。
    func priorityIngestCodes() async -> Set<String> {
        loadPriorityIngestCodes()
    }

    /// ローカル XBRL キャッシュに展開済みの docID。内訳取り込みが軸を跨いで同じ書類を先に回すため。
    func cachedXbrlDocIDs() async -> Set<String> {
        await edinetClient.cachedXbrlDocIDs()
    }

    /// 財務諸表注記取り込み: 書類1件分の `borrowings_schedule` note_type を解決する。ロジックは
    /// `StatementNotesResolver.resolveBorrowingsSchedule`（＝`BorrowingsSchedule.extractRows`、
    /// `IBDExtractor` が使う `extract` と表探索ロジックを共有）に委譲する。
    func resolveBorrowingsScheduleNote(docID: String, correctionDocIDs: [String] = [])
        async -> StatementNoteResolveResult
    {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        return statementNoteByRecordingOverlayRegressions(
            StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: xbrlDir), xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `property_plant_equipment_schedule` note_type を解決する
    /// （IFRS 注記 role → BS 区分タグ当期値で `available_via_statement` → それ以外。
    /// J-GAAP 附属明細表 TextBlock は未対応。`StatementNotesResolver` のドキュメント参照）。
    func resolvePropertyPlantEquipmentScheduleNote(docID: String, correctionDocIDs: [String] = [])
        async -> StatementNoteResolveResult
    {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        return statementNoteByRecordingOverlayRegressions(
            StatementNotesResolver.resolvePropertyPlantEquipmentSchedule(xbrlDir: xbrlDir),
            xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `goodwill_and_intangibles` note_type を解決する（IFRS連結企業限定、
    /// J-GAAP単体には対応する法定附属明細表が無い）。
    func resolveGoodwillAndIntangiblesNote(docID: String, correctionDocIDs: [String] = [])
        async -> StatementNoteResolveResult
    {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        return statementNoteByRecordingOverlayRegressions(
            StatementNotesResolver.resolveGoodwillAndIntangibles(xbrlDir: xbrlDir), xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `lease_liabilities` note_type を解決する。
    /// 連結 BS タグまたは IFRS リース注記 TextBlock（`IFRSLease`）から決定論で抽出する。
    func resolveLeaseLiabilitiesNote(docID: String, correctionDocIDs: [String] = [])
        async -> StatementNoteResolveResult
    {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        return statementNoteByRecordingOverlayRegressions(
            StatementNotesResolver.resolveLeaseLiabilities(xbrlDir: xbrlDir), xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `sga_expense_breakdown` note_type を解決する。
    /// 連結損益計算書関係注記の構造化 `*SGA` / IFRS 販管費費目タグから決定論で抽出する。
    func resolveSgaExpenseBreakdownNote(docID: String, correctionDocIDs: [String] = [])
        async -> StatementNoteResolveResult
    {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        return statementNoteByRecordingOverlayRegressions(
            StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir), xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `per_share_information` note_type を解決する。ロジックは
    /// `StatementNotesResolver.resolvePerShareInformation` に委譲する（「業績等の概要」の
    /// 離散数値タグから決定論で抽出、LLM 不要）。財務取り込み の単一値（EPSのみ）passthrough を
    /// 置き換える（実データレビューでBPS・潜在株式調整後EPSも取得可能と判明、2026-08-02）。
    func resolvePerShareInformationNote(docID: String, correctionDocIDs: [String] = [])
        async -> StatementNoteResolveResult
    {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        return statementNoteByRecordingOverlayRegressions(
            StatementNotesResolver.resolvePerShareInformation(xbrlDir: xbrlDir), xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `issued_shares_and_capital` note_type を解決する。ロジックは
    /// `StatementNotesResolver.resolveIssuedSharesAndCapital` に委譲する。期末スナップショット（離散タグ:
    /// 発行済・資本金・資本準備金）と textblock 表のイベント列を併記（LLM不要）。
    func resolveIssuedSharesAndCapitalNote(docID: String, correctionDocIDs: [String] = [])
        async -> StatementNoteResolveResult
    {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        return statementNoteByRecordingOverlayRegressions(
            StatementNotesResolver.resolveIssuedSharesAndCapital(xbrlDir: xbrlDir), xbrlDir: xbrlDir)
    }

    /// 有報(120)の XBRL。同一 FY の訂正(130)があれば、パースできるものを提出順に overlay する。
    func downloadAnnualFilingXbrl(docID: String, correctionDocIDs: [String] = []) async -> URL? {
        await resolveAnnualXbrlDirectory(
            originalDocID: docID,
            correctionDocIDs: correctionDocIDs,
            download: { await edinetClient.downloadDocument($0) })
    }
}

// MARK: - Overview

/// Overview 生成結果（ingest 用）。ダウンロード失敗と生成完了を分ける。
/// 入力空（applicable=false）も `.generated`（行を残して次回 skip する）。
public enum CompanyOverviewResolveResult: Sendable {
    /// 生成できた（検証失敗の `ok=false` も含む。`needs_review` で再試行する）。
    case generated(draft: CompanyOverviewDraft, sourceText: String)
    /// 書類取得自体が失敗。行は作らない。
    case failed
}

// MARK: - 内訳取り込み（事業別・地域別内訳）

/// 内訳取り込み 内訳（business / geography）の解決結果（`computeFinancials` と同じ3値パターン）。
public enum BreakdownResolveResult: Sendable {
    /// 解決成功。格納用ペイロード一式。
    case resolved(
        payload: BreakdownSnapshotPayload, source: String, contentHash: String,
        audit: LLMBreakdownAuditPayload?)
    /// 書類の取得・抽出自体は成功したが、当該軸の内訳が解決できなかった。
    /// `reason` は `breakdownNotApplicable*`（`Models/BreakdownContract.swift`）のいずれか。
    /// 呼び出し元の `BreakdownIngest` が `company_breakdowns.not_applicable_reason` へ永続化する
    /// （business / geography どちらも REST/MCP の 404 応答へ反映）。
    case notApplicable(reason: String, audit: LLMBreakdownAuditPayload?)
    /// 書類取得・抽出自体が失敗（EDINET ダウンロード不可等）。行は作らない。
    case failed

    /// 監査の無い not_applicable。既存の呼び出しはこちら。
    public static func notApplicable(reason: String) -> BreakdownResolveResult {
        .notApplicable(reason: reason, audit: nil)
    }
}

public extension BltServerContext {
    /// Overview 生成（ingest 用）。Filing `texts` には足さない。格納先は `company_overviews`
    /// （会社1社=1行。stage は `overviews`。公開 REST は `GET /v1/companies/{code}/overview`）。
    /// 社名・業種はマスタから引く（プロンプト用。本文からの補完には使わない）。
    func generateCompanyOverview(
        docID: String, code: String, correctionDocIDs: [String] = []
    ) async -> CompanyOverviewResolveResult {
        let stock = await masterDataManager.getByCode(code)
        return await generateCompanyOverview(
            docID: docID, code: code, name: stock?.coName ?? "", sector: stock?.s33nm ?? "",
            correctionDocIDs: correctionDocIDs)
    }

    /// Overview 生成（ingest 用）。社名・業種を呼び出し側が渡す。
    func generateCompanyOverview(docID: String, code: String, name: String, sector: String,
        correctionDocIDs: [String] = [])
        async -> CompanyOverviewResolveResult
    {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        let businessText = DescriptionOfBusinessExtractor.extract(in: xbrlDir)
        var sourceText = businessText
        var input = CompanyOverviewInput(
            code: code, name: name, sector: sector, docID: docID, sourceText: sourceText)
        var draft = await CompanyOverviewGenerator.generate(
            input: input, client: overviewChatClient, model: overviewModel)
        if !draft.applicable {
            let fallback = ReportableSegmentsOverviewExtractor.extract(in: xbrlDir)
            if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sourceText = fallback
                input = CompanyOverviewInput(
                    code: code, name: name, sector: sector, docID: docID, sourceText: fallback,
                    inputKey: companyOverviewSegmentOverviewInputKey,
                    sectionTitle: companyOverviewSegmentOverviewSectionTitle)
                draft = await CompanyOverviewGenerator.generate(
                    input: input, client: overviewChatClient, model: overviewModel,
                    retryWhenApplicableFalse: true)
            } else if !draft.ok, draft.attempts < companyOverviewMaxAttempts {
                draft = await CompanyOverviewGenerator.generate(
                    input: input, client: overviewChatClient, model: overviewModel,
                    retryWhenApplicableFalse: true)
            }
        }
        return .generated(draft: draft, sourceText: sourceText)
    }

    /// セグメント注記の Jev。`extracted == nil` は省略確定（呼び出し側が not_applicable にする）。
    /// business の専用タグに**当期**本文があるとき、収益認識の分解表も製品・サービス別表も無く、
    /// かつ当期の報告セグメント売上 member が 1 以下なら `single_segment_disclosed`。
    /// 製品・サービス別表があるときは専用タグで短絡せず表ステップへ進む（475A S100YJX2）。
    /// 当期 member が 2 以上ならタグを信じず表ステップへ進む。分解表があるときは表ステップへ進む。
    /// 選んだ表が合計行だけでカテゴリが無いときは専用タグへ戻す（8771）。
    /// 顧客表・製品90％・本邦90％はその省略を取り消さない。
    /// 専用タグは geography を飛ばさない。キーがある geography は Jev のまま。
    /// キーが無いとき、応答が無いときは、専用タグ以外は抽出結果をそのまま返す。
    /// 呼び出し失敗では `needsReview` を足さない。
    /// 表を選んだときは確率に関係なくその表を残す。ただし組立不能・前期・非製品（製品表あり）
    /// の keepTable は1表に閉じない。`none_of_these` の確率が閾値未満のときは
    /// 抽出結果を変えず、`needsReview` を立てる。
    /// 決定論が単一セグメントまたは LLM の NR にしたあとは Jev 第二パスで妥当性を聞く。
    /// 低信頼は提案を維持する（published-wrong=0）。
    internal func segmentsAfterNoteDecision(
        axis: SegmentNoteAxis, docID: String, extracted: ExtractedBreakdown, xbrlDir: URL,
        consolidatedSales: Double?, labelsByTag: [String: String]
    ) async -> (extracted: ExtractedBreakdown?, outcome: SegmentNoteDecisionOutcome) {
        let pass = (extracted: extracted as ExtractedBreakdown?, outcome: SegmentNoteDecisionOutcome.unchanged)
        let currentYearReportableCount =
            BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: xbrlDir)
        let fiscalYearEnd = BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir)
        let sentences = BreakdownExtractor.segmentNoteOmissionSentences(xbrlDir: xbrlDir)
        if axis == .business,
            let tagText = BreakdownExtractor.dedicatedSingleSegmentTagTrustedForOmission(xbrlDir: xbrlDir),
            !extracted.tables.contains(where: {
                $0.heading == BreakdownExtractor.revenueRecognitionHeading
            }),
            !SegmentInfoLLMNormalizer.hasUsableProductOrBusinessTable(extracted.tables)
        {
            let omitted = SegmentNoteDecision.dedicatedTagBusinessOutcome(docID: docID, tagText: tagText)
            return await applyingReviewedOmission(
                omitted, axis: axis, docID: docID, extracted: extracted, sentences: sentences,
                fiscalYearEnd: fiscalYearEnd)
        }
        guard let decider = segmentNoteDecider else { return pass }
        guard !extracted.tables.isEmpty else { return pass }
        let clean: Bool
        if let snapshot = BreakdownNormalizer.normalize(
            extracted, consolidatedSales: consolidatedSales, labelsByTag: labelsByTag)
        {
            switch axis {
            case .business:
                clean = snapshot.axis == breakdownAxisProductService && !snapshot.needsReview
            case .geography:
                clean = snapshot.axis == "geography" && !snapshot.needsReview
            }
        } else {
            clean = false
        }
        let outcome = await SegmentNoteDecision.decide(
            axis: axis, docID: docID, tables: extracted.tables,
            sentences: sentences,
            hasCleanDeterministicSnapshot: clean, decider: decider)
        switch outcome.action {
        case .unchanged:
            return (extracted, outcome)
        case .omitBusiness:
            guard axis == .business else { return (extracted, outcome) }
            if currentYearReportableCount >= 2 {
                var kept = outcome
                kept.action = .unchanged
                kept.omissionReason = nil
                kept.needsReview = true
                return (extracted, kept)
            }
            let resolved = SegmentNoteDecision.resolveBusinessOmissionReason(
                outcome,
                reportedSegmentsAreGeographic: BreakdownExtractor.reportedOperatingSegmentsAreGeographic(
                    xbrlDir: xbrlDir))
            if resolved.action == .omitBusiness {
                if SegmentInfoLLMNormalizer.hasUsableProductOrBusinessTable(extracted.tables) {
                    var kept = resolved
                    kept.action = .unchanged
                    kept.omissionReason = nil
                    return (extracted, kept)
                }
                return await applyingReviewedOmission(
                    resolved, axis: axis, docID: docID, extracted: extracted, sentences: sentences,
                    fiscalYearEnd: fiscalYearEnd)
            }
            return (extracted, resolved)
        case .omitGeography:
            return (axis == .geography ? nil : extracted, outcome)
        case .keepTable(let index):
            return isolatingKeptTableIfSafe(
                extracted, index: index, outcome: outcome, fiscalYearEnd: fiscalYearEnd)
        }
    }

    /// 単一セグメント提案を Jev 第二パスで確認する。表が高信頼なら keepTable。
    /// キー無し・表無しは提案のまま省略する。
    private func applyingReviewedOmission(
        _ omitted: SegmentNoteDecisionOutcome,
        axis: SegmentNoteAxis,
        docID: String,
        extracted: ExtractedBreakdown,
        sentences: [String],
        fiscalYearEnd: String?
    ) async -> (extracted: ExtractedBreakdown?, outcome: SegmentNoteDecisionOutcome) {
        guard let decider = segmentNoteDecider, !extracted.tables.isEmpty else {
            return (nil, omitted)
        }
        let reviewed = await SegmentNoteDecision.review(
            proposal: .singleSegment(
                reason: omitted.audit?.decisionSource ?? breakdownNotApplicableSingleSegmentDisclosed),
            axis: axis, docID: docID, tables: extracted.tables, sentences: sentences,
            existing: omitted, decider: decider)
        if case .keepTable(let index) = reviewed.action {
            return isolatingKeptTableIfSafe(
                extracted, index: index, outcome: reviewed, fiscalYearEnd: fiscalYearEnd)
        }
        return (nil, reviewed)
    }

    private func isolatingKeptTableIfSafe(
        _ extracted: ExtractedBreakdown,
        index: Int,
        outcome: SegmentNoteDecisionOutcome,
        fiscalYearEnd: String?
    ) -> (extracted: ExtractedBreakdown?, outcome: SegmentNoteDecisionOutcome) {
        guard extracted.tables.indices.contains(index) else { return (extracted, outcome) }
        guard SegmentInfoLLMNormalizer.shouldIsolateKeptTable(
            index: index, tables: extracted.tables, fiscalYearEnd: fiscalYearEnd)
        else {
            return (extracted, outcome)
        }
        var copy = extracted
        copy.tables = [extracted.tables[index]]
        return (copy, outcome)
    }

    /// 内訳取り込み: 書類1件分の product_service 軸内訳を解決する。xbrl_facts（決定的）/ 収益認識注記 LLM /
    /// segment_info LLM のいずれかへ `BusinessBreakdownResolver` が振り分ける。LLM 呼び出しは
    /// html_table 経路でのみ発生する（xbrl_facts で解決できれば呼ばない。LLM 費用最小化）。
    /// 売上分母は同一 XBRL パスで `BreakdownFinancialsResolver` が直接解決する（#9 / #10b）。
    /// 収益認識表へ寄せた会社は顧客契約の連結金額、無ければ本表外タグへフォールバックする
    /// （三菱商事）。由来タグは実タグ / `llm_table_subtotal` で、偽の `income_statement.sales` は出さない。
    /// 保険等で売上欠測でも xbrl_facts 決定論（第一生命型）が使える場合は解決を試す。
    func resolveBusinessBreakdown(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        guard let segments = BreakdownExtractor.extractSpecialSection("segments", xbrlDir: xbrlDir)
        else { return .notApplicable(reason: breakdownNotApplicableUnknown) }

        let denomItem = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(
            xbrlDir: xbrlDir, tables: segments.tables)
        let consolidatedSales = denomItem.value
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)
        let gate = await segmentsAfterNoteDecision(
            axis: .business, docID: docID, extracted: segments, xbrlDir: xbrlDir,
            consolidatedSales: consolidatedSales, labelsByTag: labelsByTag)
        guard let resolvedSegments = gate.extracted else {
            return .notApplicable(
                reason: gate.outcome.omissionReason ?? breakdownNotApplicableSingleSegmentDisclosed,
                audit: gate.outcome.audit.map(LLMBreakdownAuditPayload.segmentNoteJev))
        }
        let hash = breakdownContentHash(extracted: resolvedSegments, consolidatedSales: consolidatedSales)
        let result = await BusinessBreakdownResolver.resolve(
            segments: resolvedSegments, consolidatedSales: consolidatedSales,
            labelsByTag: labelsByTag, denominatorTag: denomItem.tag,
            columnDecider: revenueRecognitionColumnDecider,
            segmentInfoDecider: segmentInfoDecider,
            fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir),
            docID: docID)
        let dedicatedTexts = BreakdownExtractor.dedicatedSingleSegmentDisclosureTexts(xbrlDir: xbrlDir)
        let currentYearReportableCount =
            BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: xbrlDir)
        let dedicatedTag = currentYearReportableCount >= 2
            ? nil : (dedicatedTexts.currentYear ?? dedicatedTexts.any)
        if BusinessBreakdownResolver.dedicatedSingleSegmentFallback(
            snapshot: result.snapshot, dedicatedTagText: dedicatedTag,
            currentYearReportableSalesMemberCount: currentYearReportableCount),
           let dedicatedTag
        {
            let outcome = SegmentNoteDecision.dedicatedTagBusinessOutcome(
                docID: docID, tagText: dedicatedTag)
            let reviewed = await applyingReviewedOmission(
                outcome, axis: .business, docID: docID, extracted: segments,
                sentences: BreakdownExtractor.segmentNoteOmissionSentences(xbrlDir: xbrlDir),
                fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir))
            if let recoveredExtracted = reviewed.extracted {
                let retry = await BusinessBreakdownResolver.resolve(
                    segments: recoveredExtracted, consolidatedSales: consolidatedSales,
                    labelsByTag: labelsByTag,
                    denominatorTag: denomItem.tag,
                    columnDecider: revenueRecognitionColumnDecider,
                    segmentInfoDecider: segmentInfoDecider,
                    fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir),
                    docID: docID)
                if let recovered = retry.snapshot,
                   BusinessBreakdownResolver.hasUsableSegmentRows(recovered)
                {
                    return applyingSegmentNoteDecision(
                        reviewed.outcome,
                        to: breakdownByRecordingOverlayRegressions(
                            .resolved(
                                payload: breakdownSnapshotPayload(from: recovered),
                                source: retry.source.rawValue,
                                contentHash: hash,
                                audit: retry.audit.map(llmBreakdownAuditPayload(from:))),
                            xbrlDir: xbrlDir))
                }
            }
            var audit = reviewed.outcome.audit.map(LLMBreakdownAuditPayload.segmentNoteJev)
            if let column = result.audit {
                let columnPayload = llmBreakdownAuditPayload(from: column)
                audit?.columnJev = columnPayload.columnJev ?? columnPayload.jev
                audit?.sourceTableIndex = columnPayload.sourceTableIndex
                audit?.periodColumn = columnPayload.periodColumn
                audit?.unit = columnPayload.unit
                if audit?.notes.isEmpty == true {
                    audit?.notes = columnPayload.notes
                }
            }
            return .notApplicable(
                reason: breakdownNotApplicableSingleSegmentDisclosed, audit: audit)
        }
        guard var snapshot = result.snapshot else {
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: consolidatedSales, xbrlDir: xbrlDir,
                llmHint: result.audit?.notApplicableReason)
            return applyingSegmentNoteDecision(
                gate.outcome,
                to: .notApplicable(
                    reason: reason.rawValue,
                    audit: result.audit.map(llmBreakdownAuditPayload(from:))))
        }
        if shouldReviewLLMNeedsReview(snapshot, source: result.source),
           let decider = segmentNoteDecider,
           !segments.tables.isEmpty
        {
            let reviewed = await SegmentNoteDecision.review(
                proposal: .needsReview(reason: snapshot.warnings.first ?? "needs_review"),
                axis: .business, docID: docID, tables: segments.tables,
                sentences: BreakdownExtractor.segmentNoteOmissionSentences(xbrlDir: xbrlDir),
                existing: gate.outcome, decider: decider)
            if case .keepTable(let index) = reviewed.action, segments.tables.indices.contains(index) {
                var copy = segments
                copy.tables = [segments.tables[index]]
                let retry = await BusinessBreakdownResolver.resolve(
                    segments: copy, consolidatedSales: consolidatedSales,
                    labelsByTag: labelsByTag,
                    denominatorTag: denomItem.tag,
                    columnDecider: revenueRecognitionColumnDecider,
                    segmentInfoDecider: segmentInfoDecider,
                    fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir),
                    docID: docID)
                if let recovered = retry.snapshot,
                   BusinessBreakdownResolver.hasUsableSegmentRows(recovered)
                {
                    snapshot = recovered
                    if BreakdownExtractor.dedicatedTagDisagreesWithCurrentYearReportableSegments(
                        xbrlDir: xbrlDir)
                    {
                        snapshot = BreakdownExtractor.applyingDedicatedTagDisagreementWarning(
                            to: snapshot)
                    }
                    return applyingSegmentNoteDecision(
                        reviewed,
                        to: breakdownByRecordingOverlayRegressions(
                            .resolved(
                                payload: breakdownSnapshotPayload(from: snapshot),
                                source: retry.source.rawValue,
                                contentHash: hash,
                                audit: retry.audit.map(llmBreakdownAuditPayload(from:))),
                            xbrlDir: xbrlDir))
                }
            }
        }
        if BreakdownExtractor.dedicatedTagDisagreesWithCurrentYearReportableSegments(xbrlDir: xbrlDir) {
            snapshot = BreakdownExtractor.applyingDedicatedTagDisagreementWarning(to: snapshot)
        }
        return applyingSegmentNoteDecision(
            gate.outcome,
            to: breakdownByRecordingOverlayRegressions(
                .resolved(
                    payload: breakdownSnapshotPayload(from: snapshot), source: result.source.rawValue,
                    contentHash: hash, audit: result.audit.map(llmBreakdownAuditPayload(from:))),
                xbrlDir: xbrlDir))
    }

    /// 内訳取り込み: 書類1件分の geography 軸内訳を解決する。`GeographyBreakdownResolver` が
    /// xbrl_facts / geography_llm へ振り分ける。正当欠測（地域注記なし、または Jev が
    /// none_of_these）は `not_applicable` / `not_found`、正規化・列選択失敗は
    /// `unknown`（要再試行）。売上分母は同一 XBRL パスで直接解決する。
    func resolveGeographyBreakdown(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        let consolidatedSales = BreakdownFinancialsResolver.financialsCanonicalSales(xbrlDir: xbrlDir)
        if consolidatedSales == nil || consolidatedSales == 0 {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)
        if geography.method == "not_found" {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)
        let gate = await segmentsAfterNoteDecision(
            axis: .geography, docID: docID, extracted: geography, xbrlDir: xbrlDir,
            consolidatedSales: consolidatedSales, labelsByTag: labelsByTag)
        guard let resolvedGeography = gate.extracted else {
            return .notApplicable(
                reason: breakdownNotApplicableNotFound,
                audit: gate.outcome.audit.map(LLMBreakdownAuditPayload.segmentNoteJev))
        }

        let hash = breakdownContentHash(extracted: resolvedGeography, consolidatedSales: consolidatedSales)
        let result = await GeographyBreakdownResolver.resolve(
            geography: resolvedGeography, consolidatedSales: consolidatedSales,
            columnDecider: geographyColumnDecider, labelsByTag: labelsByTag,
            fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir),
            docID: docID)
        guard let snapshot = result.snapshot else {
            // Resolver の notFound は「地域注記なし」または列が無い／none_of_these。
            // audit があれば Jev が明示的に非該当と答えた正当欠測。audit 無しで表だけある場合は
            // 列選択失敗の可能性が高いので unknown（再試行）に落とす。
            let reason: String
            if result.source == .notFound {
                if result.audit != nil || geography.tables.isEmpty {
                    reason = breakdownNotApplicableNotFound
                } else {
                    reason = breakdownNotApplicableUnknown
                }
            } else {
                reason = breakdownNotApplicableUnknown
            }
            return applyingSegmentNoteDecision(
                gate.outcome, to: .notApplicable(reason: reason, audit: nil))
        }
        return applyingSegmentNoteDecision(
            gate.outcome,
            to: breakdownByRecordingOverlayRegressions(
                .resolved(
                    payload: breakdownSnapshotPayload(from: snapshot), source: result.source.rawValue,
                    contentHash: hash, audit: result.audit.map(llmBreakdownAuditPayload(from:))),
                xbrlDir: xbrlDir))
    }
}

public extension BltServerContext {
    /// 内訳取り込み: 書類1件分の employees 軸内訳を解決する（2026-08-01追加）。`NumberOfEmployees` /
    /// `NumberOfGroupEmployees` のセグメント dimension 付き fact のみを対象にした決定論経路
    /// （LLM フォールバックなし）。全社合計は同一 XBRL パスで `BreakdownFinancialsResolver` が
    /// 直接解決する（#9 / #10b）。
    func resolveEmployeesBreakdown(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        let total = BreakdownFinancialsResolver.financialsCanonicalEmployees(xbrlDir: xbrlDir)
        let cached = await businessSegmentDimensionCache.load(docID: docID, xbrlDir: xbrlDir)
        let memberParents = XBRLUtils.operatingSegmentMemberParents(in: xbrlDir)
        guard
            let snapshot = BreakdownNormalizer.normalizeEmployees(
                facts: cached.facts, total: total, axis: breakdownAxisEmployees,
                labelsByTag: cached.labelsByTag, memberParents: memberParents)
        else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let extracted = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: cached.facts)
        let hash = breakdownContentHash(extracted: extracted, consolidatedSales: nil)
        return breakdownByRecordingOverlayRegressions(
            .resolved(
                payload: breakdownSnapshotPayload(from: snapshot), source: breakdownSourceXbrlFacts,
                contentHash: hash, audit: nil),
            xbrlDir: xbrlDir)
    }

    /// 内訳取り込み: 書類1件分の research_and_development 軸を解決する（2026-08-01追加）。
    /// 全社 R&D 分母は同一 XBRL パスで `BreakdownFinancialsResolver` /
    /// `financialsCanonicalRd` が直接解決する（#9 / #10b）。セグメント dimension が無くても
    /// total があれば denominator のみの resolved になる（合計の正本を本軸に寄せる）。
    /// 数値タグもセグメント fact も無いときだけ、キーがあれば本文の当期総額を補う。
    /// タグ付き行が全社合計より 5% 以上足りないときは、差額と一致する本文1文を足す。
    /// タグ付き合計が全社合計を超えるときは、総額の外の金額を負の行で足す。
    /// 活動タグの全社合計が無く本文総額が製造費用込みの注記と一致するときは、その注記が分母になる。
    /// Summary の `rd` は本文だけの総額を読まず、この注記へ替わった分母は読む。
    func resolveResearchAndDevelopmentBreakdown(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: xbrlDir)
        let cached = await businessSegmentDimensionCache.load(docID: docID, xbrlDir: xbrlDir)
        guard
            let snapshot = BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: cached.facts, total: rd.value, totalTag: rd.tag,
                axis: breakdownAxisResearchAndDevelopment, labelsByTag: cached.labelsByTag)
        else {
            return await resolveResearchAndDevelopmentProseTotal(xbrlDir: xbrlDir, docID: docID)
        }
        let filled = await fillResearchAndDevelopmentShortfall(
            snapshot: snapshot, xbrlDir: xbrlDir, docID: docID)
        let extracted = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: cached.facts)
        let hash = breakdownContentHash(extracted: extracted, consolidatedSales: rd.value)
        return breakdownByRecordingOverlayRegressions(
            .resolved(
                payload: breakdownSnapshotPayload(from: filled.snapshot), source: breakdownSourceXbrlFacts,
                contentHash: hash, audit: filled.audit),
            xbrlDir: xbrlDir)
    }

    /// 内訳取り込み: 書類1件分の goodwill 軸内訳を解決する（2026-08-12追加）。決定論のみ、LLMなし。
    ///
    /// `Xbrl.goodwillSegmentTags` の無dimension fact から本関数が独立に解決する（`resolveItem`）。
    func resolveGoodwillBreakdown(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        let cached = await businessSegmentDimensionCache.load(docID: docID, xbrlDir: xbrlDir)
        let goodwill = BreakdownFinancialsResolver.financialsCanonicalGoodwillItem(xbrlDir: xbrlDir)
        guard
            let snapshot = BreakdownNormalizer.normalizeGoodwill(
                facts: cached.facts, total: goodwill.value, totalTag: goodwill.tag,
                axis: breakdownAxisGoodwill, labelsByTag: cached.labelsByTag)
        else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let extracted = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: cached.facts)
        let hash = breakdownContentHash(extracted: extracted, consolidatedSales: goodwill.value)
        return breakdownByRecordingOverlayRegressions(
            .resolved(
                payload: breakdownSnapshotPayload(from: snapshot), source: breakdownSourceXbrlFacts,
                contentHash: hash, audit: nil),
            xbrlDir: xbrlDir)
    }
}

private extension BltServerContext {
    /// タグ付き行が全社合計より 5% 以上足りないとき、差額と一致する本文1文を足す。
    /// 億円丸めで差額とずれる配分不能の1文も、足した合計が 5% 以内なら足す。
    /// タグ付き合計が全社合計を 5% 以上超えるときは、総額の外と分類された金額を負の行で足す。
    /// キーが無い、一致が1文でない、分類が外れた、応答が無いときは決定論のスナップショットを残す。
    func fillResearchAndDevelopmentShortfall(
        snapshot: BreakdownSnapshot, xbrlDir: URL, docID: String
    ) async -> (snapshot: BreakdownSnapshot, audit: LLMBreakdownAuditPayload?) {
        guard let decider = researchAndDevelopmentProseDecider,
            let text = ResearchAndDevelopmentProseTotalDecision.activityPlainText(in: xbrlDir)
        else { return (snapshot, nil) }
        let filled = await ResearchAndDevelopmentProseTotalDecision.fillShortfall(
            snapshot: snapshot, plainText: text, docID: docID, decider: decider)
        if filled.audit != nil {
            return (filled.snapshot, filled.audit.map { .segmentNoteJev($0) })
        }
        let excluded = await ResearchAndDevelopmentProseTotalDecision.fillExclusion(
            snapshot: snapshot, plainText: text, docID: docID, decider: decider)
        return (excluded.snapshot, excluded.audit.map { .segmentNoteJev($0) })
    }

    /// 数値タグが無い研究開発費。キーが無い、候補が無い、分類が採用条件を外れたときは not_found。
    /// 応答が無いときは行を作らない。
    func resolveResearchAndDevelopmentProseTotal(xbrlDir: URL, docID: String) async -> BreakdownResolveResult {
        guard let decider = researchAndDevelopmentProseDecider else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        guard let text = ResearchAndDevelopmentProseTotalDecision.activityPlainText(in: xbrlDir) else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        switch await ResearchAndDevelopmentProseTotalDecision.decide(
            plainText: text, docID: docID, decider: decider)
        {
        case .applied(let total):
            let snapshot = ResearchAndDevelopmentProseTotalDecision.snapshot(
                axis: breakdownAxisResearchAndDevelopment, total: total)
            let extracted = ExtractedBreakdown(
                method: breakdownSourceResearchAndDevelopmentProse, tables: [], facts: [])
            let hash = breakdownContentHash(extracted: extracted, consolidatedSales: total.yen)
            return breakdownByRecordingOverlayRegressions(
                .resolved(
                    payload: breakdownSnapshotPayload(from: snapshot),
                    source: breakdownSourceResearchAndDevelopmentProse,
                    contentHash: hash,
                    audit: .segmentNoteJev(total.audit)),
                xbrlDir: xbrlDir)
        case .notApplied:
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        case .unavailable:
            return .failed
        }
    }

    /// 報告セグメント別の決定論指標を共通の XBRL fact 経路で解決する。
    func resolveSegmentMetricBreakdown(docID: String, axis: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        let cached = await businessSegmentDimensionCache.load(docID: docID, xbrlDir: xbrlDir)
        let snapshot: BreakdownSnapshot?
        switch axis {
        case breakdownAxisGoodwillAmortization:
            snapshot = BreakdownNormalizer.normalizeGoodwillAmortization(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        case breakdownAxisEquityMethodInvestments:
            snapshot = BreakdownNormalizer.normalizeEquityMethodInvestments(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        default:
            snapshot = nil
        }
        guard let snapshot else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let extracted = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: cached.facts)
        let hash = breakdownContentHash(extracted: extracted, consolidatedSales: snapshot.denominator)
        return breakdownByRecordingOverlayRegressions(
            .resolved(
                payload: breakdownSnapshotPayload(from: snapshot), source: breakdownSourceXbrlFacts,
                contentHash: hash, audit: nil),
            xbrlDir: xbrlDir)
    }

    /// 設備投資マトリクス。旧 4 軸を 1 軸にまとめる。Jev は Role だけ、円はコード。
    func resolveCapexBreakdownImpl(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return .failed }
        let cached = await businessSegmentDimensionCache.load(docID: docID, xbrlDir: xbrlDir)
        let memberParents = XBRLUtils.operatingSegmentMemberParents(in: xbrlDir)
        let cePresent = CapexNormalizer.filingHasCurrentTags(
            in: xbrlDir, tags: Xbrl.segmentCapitalExpenditureTags)
        let naaPresent = CapexNormalizer.filingHasCurrentTags(
            in: xbrlDir, tags: Xbrl.segmentNoncurrentAssetAdditionTags)
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let durationFS = fieldSetFromDuration(allTags)
        let flowTags = cePresent
            ? Xbrl.segmentCapitalExpenditureTags : Xbrl.segmentNoncurrentAssetAdditionTags
        let flowItem = resolveItem(durationFS, tags: flowTags)
        let flowTotal: (value: Double, tag: String)? =
            flowItem.current.flatMap { value in
                guard let tag = flowItem.tag, value > 0 else { return nil }
                return (value, tag)
            }
        let overviewItem = BreakdownFinancialsResolver.breakdownCanonicalCapexOverviewItem(
            xbrlDir: xbrlDir)
        let overviewTotal: (value: Double, tag: String)? =
            overviewItem.value.flatMap { value in
                guard let tag = overviewItem.tag, value > 0 else { return nil }
                return (value, tag)
            }
        var overviewHTML: BreakdownSnapshot?
        if case .resolved(let note, _, _) =
            StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: xbrlDir),
            let segments = note.capexSegments
        {
            overviewHTML = BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                segments: segments)
        }
        var assets = BreakdownNormalizer.normalizeSegmentAssets(
            facts: cached.facts, labelsByTag: cached.labelsByTag, memberParents: memberParents)
        assets = BreakdownNormalizer.enrichSegmentAssetsWithDifferenceTable(
            snapshot: assets, xbrlDir: xbrlDir)

        let payload = CapexNormalizer.normalize(
            facts: cached.facts, labelsByTag: cached.labelsByTag, memberParents: memberParents,
            capitalExpendituresPresent: cePresent, noncurrentAssetAdditionsPresent: naaPresent,
            overviewHTML: overviewHTML, overviewCompanyTotal: overviewTotal,
            flowCompanyTotal: flowTotal, prebuiltAssets: assets)

        let filled = await fillCapexProse(
            payload: payload, xbrlDir: xbrlDir, docID: docID)
        switch filled {
        case .failed:
            return .failed
        case .notFound:
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        case .resolved(let result):
            var extracted = ExtractedBreakdown(
                method: result.source, tables: [], facts: cached.facts)
            if let html = SegmentAssetsDifferenceTable.differenceTextBlockHtml(in: xbrlDir) {
                extracted.tables = [
                    BreakdownTable(
                        heading: SegmentAssetsDifferenceTable.textBlockTag, markdown: html,
                        period: "当期", unitCaption: nil),
                ]
            }
            let hash = breakdownContentHash(
                extracted: extracted, consolidatedSales: result.payload.segmentAssets?.denominator
                    ?? result.payload.flow?.denominator
                    ?? result.payload.capitalExpendituresOverview?.denominator)
            return breakdownByRecordingOverlayRegressions(
                .resolved(
                    payload: result.payload, source: result.source, contentHash: hash,
                    audit: result.audit),
                xbrlDir: xbrlDir)
        }
    }

    /// 本文総額と remainder / exclusion。タグが無い書類で応答が無いときは行を作らず failed。
    /// 決定論のマトリクスがあるときは、Overview 本文の応答無しで既存セルを捨てない。
    func fillCapexProse(
        payload: BreakdownSnapshotPayload?, xbrlDir: URL, docID: String
    ) async -> CapexProseFillResult {
        if var payload {
            let filled = await fillCapexTaggedShortfalls(
                payload: payload, xbrlDir: xbrlDir, docID: docID)
            payload = filled.payload
            if payload.capitalExpendituresOverview == nil,
                let decider = capexProseDecider,
                let text = CapexProseTotalDecision.overviewPlainText(in: xbrlDir)
            {
                switch await CapexProseTotalDecision.decide(
                    plainText: text, docID: docID, decider: decider)
                {
                case .applied(let total):
                    payload = CapexProseTotalDecision.applyCompanyTotal(to: payload, total: total)
                    let audit = filled.audit ?? .segmentNoteJev(total.audit)
                    return .resolved((payload, payload.sourceKind, audit))
                case .unavailable:
                    break
                case .notApplied:
                    break
                }
            }
            return .resolved((payload, payload.sourceKind, filled.audit))
        }
        guard let decider = capexProseDecider else { return .notFound }
        guard let text = CapexProseTotalDecision.overviewPlainText(in: xbrlDir) else { return .notFound }
        switch await CapexProseTotalDecision.decide(plainText: text, docID: docID, decider: decider)
        {
        case .applied(let total):
            let snapshot = CapexProseTotalDecision.snapshotFromCompanyTotal(total)
            return .resolved((snapshot, breakdownSourceCapexProse, .segmentNoteJev(total.audit)))
        case .notApplied:
            return .notFound
        case .unavailable:
            return .failed
        }
    }

    func fillCapexTaggedShortfalls(
        payload: BreakdownSnapshotPayload, xbrlDir: URL, docID: String
    ) async -> (payload: BreakdownSnapshotPayload, audit: LLMBreakdownAuditPayload?) {
        guard let decider = capexProseDecider,
            let text = CapexProseTotalDecision.overviewPlainText(in: xbrlDir)
        else { return (payload, nil) }
        var current = payload
        var audit: LLMBreakdownAuditPayload?
        for cell in [CapexProseCell.segmentAssets, .flow, .overview] {
            let remainder = await CapexProseTotalDecision.fillShortfall(
                payload: current, cell: cell, plainText: text, docID: docID, decider: decider)
            if remainder.audit != nil {
                current = remainder.payload
                audit = remainder.audit.map { .segmentNoteJev($0) }
                continue
            }
            let excluded = await CapexProseTotalDecision.fillExclusion(
                payload: current, cell: cell, plainText: text, docID: docID, decider: decider)
            if excluded.audit != nil {
                current = excluded.payload
                audit = excluded.audit.map { .segmentNoteJev($0) }
            }
        }
        return (current, audit)
    }
}

enum CapexProseFillResult {
    case resolved((payload: BreakdownSnapshotPayload, source: String, audit: LLMBreakdownAuditPayload?))
    case failed
    case notFound
}

public extension BltServerContext {
    /// 報告セグメント別ののれんの償却額を解決する。
    func resolveGoodwillAmortizationBreakdown(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(
            docID: docID, axis: breakdownAxisGoodwillAmortization, correctionDocIDs: correctionDocIDs)
    }

    /// 報告セグメント別の持分法会計処理される投資を解決する。
    func resolveEquityMethodInvestmentsBreakdown(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(
            docID: docID, axis: breakdownAxisEquityMethodInvestments, correctionDocIDs: correctionDocIDs)
    }

    /// 設備投資マトリクス（axis=`capex`）を解決する。
    func resolveCapexBreakdown(docID: String, correctionDocIDs: [String] = []) async -> BreakdownResolveResult {
        await resolveCapexBreakdownImpl(docID: docID, correctionDocIDs: correctionDocIDs)
    }
}

/// 内部型 BreakdownSnapshot を公開格納用 BreakdownSnapshotPayload へ写経する。

private func breakdownSnapshotPayload(from s: BreakdownSnapshot) -> BreakdownSnapshotPayload {
    BreakdownSnapshotPayload(
        axis: s.axis, denominator: s.denominator, denominatorTag: s.denominatorTag,
        rows: s.rows.map {
            BreakdownRowPayload(
                labelRaw: $0.labelRaw, label: $0.label ?? $0.labelRaw, amount: $0.amount,
                profit: $0.profit, rowKind: $0.rowKind, description: $0.description,
                categoryGroup: $0.categoryGroup, category: $0.category)
        },
        sourceKind: s.sourceKind, needsReview: s.needsReview, warnings: s.warnings)
}

/// LLM が空行・取り違え表で NR にしたときだけ第二パス対象。xbrl_facts（8316 の距離など）は見ない。
private func shouldReviewLLMNeedsReview(
    _ snapshot: BreakdownSnapshot, source: BusinessBreakdownSource
) -> Bool {
    guard source == .segmentInfoLLM || source == .revenueRecognitionLLM else { return false }
    guard snapshot.needsReview else { return false }
    if !BusinessBreakdownResolver.hasUsableSegmentRows(snapshot) { return true }
    let wrongTable = [
        SegmentInfoPublishGuards.warningGeographyWhileProductExists,
        SegmentInfoPublishGuards.warningPriorPeriodColumn,
        SegmentInfoPublishGuards.warningMetricRowLabels,
        SegmentInfoPublishGuards.warningNumericOrCodeLabels,
    ]
    return snapshot.warnings.contains(where: { wrongTable.contains($0) })
}

/// 相談した Jev 判断を結果へ載せる。適用しなかったときは needs_review を立て、決定論の中身は変えない。
private func applyingSegmentNoteDecision(
    _ outcome: SegmentNoteDecisionOutcome, to result: BreakdownResolveResult
) -> BreakdownResolveResult {
    guard let jev = outcome.audit else { return result }
    switch result {
    case .resolved(var payload, let source, let contentHash, let audit):
        if outcome.needsReview { payload.needsReview = true }
        let merged = (audit ?? .segmentNoteJev(jev)).replacingJev(jev)
        return .resolved(payload: payload, source: source, contentHash: contentHash, audit: merged)
    case .notApplicable(let reason, let audit):
        let merged = (audit ?? .segmentNoteJev(jev)).replacingJev(jev)
        return .notApplicable(reason: reason, audit: merged)
    case .failed:
        return result
    }
}

/// 内部型 LLMBreakdownAudit を公開格納用 LLMBreakdownAuditPayload へ写経する。
private func llmBreakdownAuditPayload(from a: LLMBreakdownAudit) -> LLMBreakdownAuditPayload {
    LLMBreakdownAuditPayload(
        sourceTableIndex: a.sourceTableIndex, periodColumn: a.periodColumn, unit: a.unit,
        profitDisclosed: a.profitDisclosed, notes: a.notes, jev: a.jev, columnJev: a.columnJev)
}

/// 生入力（ExtractedBreakdown + 採用前の consolidatedSales）のみのハッシュ。プロンプト/モデル/
/// スキーマは含めない（含めるとプロンプト微修正のたびに正しい行まで再計算対象になる。
/// docs/breakdown.md）。ExtractedBreakdown は Codable ではないため
/// 既存の ExtractedBreakdownPayload 写経を経由する。CryptoKit は Linux（Fly.io 配信）で使えないため、
/// 非暗号学的だが決定的な FNV-1a を使う（目的は変更検知であり耐改ざん性は不要）。
/// business / geography いずれの抽出結果にも使う（軸ごとに入力が異なるためハッシュも分かれる）。
private func breakdownContentHash(
    extracted: ExtractedBreakdown, consolidatedSales: Double?
) -> String {
    // Codable キー名 `segments` は business 既存行の content_hash 互換のため残す
    // （geography 入力でも同フィールドへ載せる。スキップ判定には未使用）。
    struct HashInput: Codable {
        let segments: ExtractedBreakdownPayload
        let consolidatedSales: Double?
    }
    let input = HashInput(
        segments: extractedBreakdownPayload(from: extracted), consolidatedSales: consolidatedSales)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(input) else { return "" }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
}

/// 内部型 ExtractedBreakdown を公開格納用 ExtractedBreakdownPayload へ写経する（数値 fact 取り込み の XbrlFactRecord 方式）。
private func extractedBreakdownPayload(from r: ExtractedBreakdown) -> ExtractedBreakdownPayload {
    ExtractedBreakdownPayload(
        method: r.method,
        tables: r.tables.map {
            // unitCaption は LLM prompt 専用。hash / 公開 payload の形は変えない。
            BreakdownTablePayload(heading: $0.heading, markdown: $0.markdown, period: $0.period)
        },
        facts: r.facts.map {
            BreakdownFactPayload(
                tag: $0.tag, contextRef: $0.contextRef, dimensions: $0.dimensions,
                value: $0.value, label: $0.label, unitRef: $0.unitRef, decimals: $0.decimals)
        })
}

// MARK: - 書類同期

public extension BltServerContext {
    /// 書類同期用に、指定期間（YYYY-MM-DD）の EDINET 書類を正規化済みレコードで返す。
    /// seed 種別（Api.documentSyncDocTypes）に絞り、外国法人・組合を除き、docID で重複排除する。
    /// 取得失敗日は `failedDates` に含め、高水位を進めない判定に使う。
    func fetchDocumentsForSync(from: String, to: String) async -> DocumentFetchResult {
        guard let start = parseDateString(from), let end = parseDateString(to), start <= end else {
            return DocumentFetchResult(records: [], failedDates: [])
        }
        let byDate = await edinetClient.getDocumentsForDateRange(start: start, end: end)
        let failedDates = byDate.compactMap { date, docs -> String? in
            docs == nil ? date : nil
        }
        let allDocs = byDate.values.compactMap { $0 }.flatMap { $0 }
        let excludedCodes = await masterDataManager.foreignFilerCodes()
        let listedSecByEdinet = await masterDataManager.listedSecCodeByEdinetCode()
        return DocumentFetchResult(
            records: mapEdinetDocumentRecords(
                allDocs, excludedCodes: excludedCodes,
                listedSecCodeByEdinetCode: listedSecByEdinet),
            failedDates: failedDates
        )
    }
}

/// EDINET の動的 JSON（[String: Any]）配列を正規化済みレコードへ写す。
/// seed 種別フィルタ・外国法人・組合除外・docID 重複排除・日付正規化を行う純粋関数
/// （ネットワーク非依存・テスト対象）。`excludedCodes` は
/// `MasterDataManager.foreignFilerCodes()`（4 桁）を渡す。
/// API / キャッシュが `secCode` を欠くときは `listedSecCodeByEdinetCode` で補う。
/// 非空の EDINET `secCode` は上書きしない。
func mapEdinetDocumentRecords(
    _ docs: [[String: Any]], excludedCodes: Set<String> = [],
    listedSecCodeByEdinetCode: [String: String] = [:]
) -> [EdinetDocumentRecord] {
    var seen = Set<String>()
    var records: [EdinetDocumentRecord] = []
    for doc in docs {
        guard let docID = doc["docID"] as? String, !docID.isEmpty else { continue }
        guard let docType = doc["docTypeCode"] as? String,
              Api.documentSyncDocTypes.contains(docType) else { continue }
        guard seen.insert(docID).inserted else { continue }
        let edinetCode = nonEmptyString(doc["edinetCode"]) ?? ""
        let apiSecCode = nonEmptyString(doc["secCode"])
        let secCode = apiSecCode ?? listedSecCodeByEdinetCode[edinetCode]
        guard shouldStoreEdinetDocumentForSync(secCode: secCode, excludedCodes: excludedCodes)
        else { continue }
        records.append(EdinetDocumentRecord(
            docID: docID,
            edinetCode: edinetCode,
            secCode: secCode,
            filerName: nonEmptyString(doc["filerName"]) ?? "",
            docTypeCode: docType,
            ordinanceCode: nonEmptyString(doc["ordinanceCode"]),
            formCode: nonEmptyString(doc["formCode"]),
            periodStart: normalizeDateFormat(doc["periodStart"] as? String),
            periodEnd: normalizeDateFormat(doc["periodEnd"] as? String),
            submitDateTime: nonEmptyString(doc["submitDateTime"]) ?? "",
            docDescription: nonEmptyString(doc["docDescription"]),
            parentDocID: nonEmptyString(doc["parentDocID"])
        ))
    }
    return records
}

/// 書類同期で `edinet_documents` に載せるか。`excludedCodes` は外国法人・組合の 4 桁コード。
/// secCode が上場形式（5 桁・末尾 0）で除外集合に入るときだけ落とす。識別できない書類は残す。
public func shouldStoreEdinetDocumentForSync(
    secCode: String?, excludedCodes: Set<String>
) -> Bool {
    guard let code = listedTickerCode(fromSecCode: secCode) else { return true }
    return !excludedCodes.contains(code)
}

/// Any? を String? に落とし、空文字・空白のみは nil 扱いにする。
private func nonEmptyString(_ value: Any?) -> String? {
    guard let s = value as? String else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - filings 応答の組み立て（ライブ／DB read 共通）

/// 書類同期 DB レコードから filings の配列を組み立てる純粋関数（ネットワーク・DB 非依存・テスト対象）。
/// 提出日時降順 → docID 重複排除 → 直近 maxYears 年度窓 → 最大 50 件。
/// 年度窓は最新書類の期末年を起点に maxYears 年ぶんを残す（ライブ探索の analysisYears に対応）。
///
/// 簡易セマンティクス（ライブ探索との意図的な差分・確定事項）:
/// 各書類の `fy_end` は自身の period_end をそのまま使う（自己完結ビュー）。主要 doc type の
/// 有報(120)・半期報告書(160) は period_end が通期期末のためライブ経路と完全一致する。
/// 一方、旧四半期(140) は period_end が 2Q 末。訂正(130) の `parent_doc_id` は ingest の
/// XBRL 選定用で、filings の `fy_end` は引き続き各行の period_end（空なら空）を返す。
/// ライブ経路の「親 FY 末への正規化」は filings 公開形では再現しない。
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
/// fy_end は期末日（YYYY-MM-DD）の先頭 7 文字（YYYY-MM）。`.agents/rules/data-handling.md` で許容された prefix(7)。
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

// MARK: - 数値 fact 取り込み（XBRL 数値 fact）

public extension BltServerContext {
    /// 数値 fact 取り込み: 書類1件分の XBRL をダウンロード（XBRL 取得キャッシュ）してパースし、
    /// 数値 fact インデックス（公開 Codable `XbrlFactIndexPayload`）を返す。
    /// IndividualAnalyzer と同じ `nilAsZero: false` で収集し、財務取り込み が消費する値と一致させる。
    /// ダウンロード失敗・fact 0 件は nil（戻り値パターン）。生 XBRL はローカルキャッシュに保持する。
    func parseXbrlFactIndex(docID: String, correctionDocIDs: [String] = []) async -> XbrlFactIndexPayload? {
        guard let xbrlDir = await downloadAnnualFilingXbrl(
            docID: docID, correctionDocIDs: correctionDocIDs
        ) else { return nil }
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
    /// 企業検索結果の公開 JSON。
    func companyJSON(_ s: StockSearchResult) -> [String: Any] {
        ["code": s.code, "name": s.name, "sector": s.sector, "market": s.market, "location": s.location]
    }
}

private func fetchAndUploadManualCompanyIcon(
    source: CompanyIconManualSource, code: String, r2Config: R2Config
) async -> Swift.Result<CompanyIconExtractResult, CompanyIconExtractFailure> {
    switch source {
    case .homepageOrigin(let origin):
        guard let icon = await FaviconFetcher.fetch(origin: origin) else {
            return .failure(.faviconFetchFailed(origin: origin))
        }
        return await uploadFetchedCompanyIcon(
            icon, code: code, sourceURL: origin, cacheVersion: companyIconsManualCacheVersion,
            r2Config: r2Config)
    case .imageURL(let urlString):
        guard let icon = await FaviconFetcher.fetch(imageURL: urlString) else {
            return .failure(.faviconFetchFailed(origin: urlString))
        }
        return await uploadFetchedCompanyIcon(
            icon, code: code, sourceURL: urlString, cacheVersion: companyIconsManualCacheVersion,
            r2Config: r2Config)
    }
}

private func uploadFetchedCompanyIcon(
    _ icon: FaviconFetcher.FetchedIcon, code: String, sourceURL: String, cacheVersion: String,
    r2Config: R2Config
) async -> Swift.Result<CompanyIconExtractResult, CompanyIconExtractFailure> {
    let key = "company-icons/\(code)\(companyIconFileExtension(forContentType: icon.contentType))"
    switch await R2Client.upload(
        icon.data, key: key, contentType: icon.contentType, config: r2Config
    ) {
    case .success:
        return .success(
            CompanyIconExtractResult(
                sourceURL: sourceURL, r2ObjectKey: key, contentType: icon.contentType,
                cacheVersion: cacheVersion))
    case .invalidURL:
        return .failure(CompanyIconExtractFailure.r2UploadFailed(detail: "invalid_url"))
    case .transportError(let message):
        return .failure(CompanyIconExtractFailure.r2UploadFailed(detail: "transport:\(message)"))
    case .httpStatus(let status, let bodySnippet):
        return .failure(
            CompanyIconExtractFailure.r2UploadFailed(detail: "http_\(status):\(bodySnippet)"))
    }
}

/// R2オブジェクトキーの拡張子（`FaviconFetcher.sniffImageContentType` が返す値のみ受理）。
/// 未知の content-type は拡張子なし（`R2Client` 側はキーそのものでアップロードでき、必須ではない）。
private func companyIconFileExtension(forContentType contentType: String) -> String {
    switch contentType {
    case "image/png": return ".png"
    case "image/x-icon": return ".ico"
    case "image/jpeg": return ".jpg"
    case "image/gif": return ".gif"
    case "image/bmp": return ".bmp"
    case "image/svg+xml": return ".svg"
    case "image/webp": return ".webp"
    default: return ""
    }
}
