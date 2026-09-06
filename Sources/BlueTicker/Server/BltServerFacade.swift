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
    /// EU/ESEF Meta Search（REST preview。skills/MCP 未掲載）。
    let esefSearch: EsefSearchService
    /// 内訳取り込み business 軸の html_table 正規化（LLM）に使うクライアント。
    /// `XAI_BUSINESS_*` / `OPENAI_BUSINESS_*` が無いときは `UnavailableChatClient`。
    /// xbrl_facts 経路はこのフィールドに触れない。
    let businessChatClient: ChatCompleting
    /// 内訳取り込み geography 軸の html_table 正規化（LLM）に使うクライアント。
    /// `OPENAI_GEOGRAPHY_*` / `XAI_GEOGRAPHY_*` 未設定時は `UnavailableChatClient`。
    let geographyChatClient: ChatCompleting
    /// Overview 生成。`OPENROUTER_OVERVIEW_API_KEY` 未設定なら `UnavailableChatClient`。
    let overviewChatClient: ChatCompleting
    let overviewModel: String
    /// employees / rd / goodwill / 報告セグメント指標軸が同一 doc を軸ループで再パースしないためのメモ。
    let businessSegmentDimensionCache: BusinessSegmentDimensionCache

    init(
        apiKey: String, cacheDir: URL, businessChatClient: ChatCompleting,
        geographyChatClient: ChatCompleting,
        overviewChatClient: ChatCompleting = UnavailableChatClient(),
        overviewModel: String = companyOverviewDefaultModel,
        esefSearch: EsefSearchService? = nil
    ) {
        self.cacheDir = cacheDir
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let xbrlObjectStore: (any XbrlObjectStoring)? =
            R2StorageConfig.resolveXbrlFromEnvironment().map { R2XbrlObjectStore(config: $0) }
        self.edinetClient = EdinetAPIClient(
            apiKey: apiKey, cacheStore: store, xbrlObjectStore: xbrlObjectStore)
        self.cacheManager = CacheManager(cacheDir: derivedCacheDir(cacheDir))
        self.esefSearch = esefSearch ?? EsefSearchService(cacheDir: esefCacheDir(cacheDir))
        self.businessChatClient = businessChatClient
        self.geographyChatClient = geographyChatClient
        self.overviewChatClient = overviewChatClient
        self.overviewModel = overviewModel
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

/// 内訳取り込み の LLM 軸。環境変数は軸別に読む（`resolveBreakdownLLMEndpoint`）。
enum BreakdownLLMAxis: String, Sendable {
    case business
    case geography
}

/// 内訳取り込み の LLM（Chat Completions 互換）エンドポイントを軸別に環境変数から解決する。
/// 稼働プロバイダは軸共通の `LLM_PROVIDER`（`openai` / `xai`。未設定は xai。不正値は未解決）。
/// openai は `OPENAI_{BUSINESS,GEOGRAPHY}_*`、xai は `XAI_{BUSINESS,GEOGRAPHY}_*`
/// （xai の business のみ旧 `XAI_*` へフォールバック）。未設定なら nil。
func resolveBreakdownLLMEndpoint(axis: BreakdownLLMAxis) -> ChatCompletionEndpoint? {
    let env = ProcessInfo.processInfo.environment
    guard let provider = LLMProvider.fromEnv(env) else { return nil }
    return provider.endpoint(axis: axis.rawValue, env: env)
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
/// LLM キー未設定でも 内訳取り込み の xbrl_facts 経路は動く（LLM 未設定は html_table 経路のみに影響）。
public func makeBltServerContext() async -> BltServerContext? {
    let env = ProcessInfo.processInfo.environment
    if let provider = env["LLM_PROVIDER"], !provider.isEmpty,
       LLMProvider.fromEnv(env) == nil
    {
        printError(
            "[blue-ticker] Warning: LLM_PROVIDER='\(provider)' は不正です（openai または xai）。breakdowns の html_table 経路（LLM正規化）が無効になります。\n"
        )
    }
    guard let key = await resolveEdinetApiKey() else {
        return nil
    }
    let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
    let cacheDir = URL(
        fileURLWithPath: cacheDirStr.isEmpty ? settingsStore.cacheDir.path : cacheDirStr)
    let businessChatClient: ChatCompleting =
        resolveBreakdownLLMEndpoint(axis: .business).map { ChatCompletionClient(endpoint: $0) }
        ?? UnavailableChatClient()
    let geographyChatClient: ChatCompleting =
        resolveBreakdownLLMEndpoint(axis: .geography).map { ChatCompletionClient(endpoint: $0) }
        ?? UnavailableChatClient()
    let overviewEndpoint = resolveOverviewLLMEndpoint(env)
    let overviewChatClient: ChatCompleting =
        overviewEndpoint.map { ChatCompletionClient(endpoint: $0) } ?? UnavailableChatClient()
    return BltServerContext(
        apiKey: key, cacheDir: cacheDir, businessChatClient: businessChatClient,
        geographyChatClient: geographyChatClient, overviewChatClient: overviewChatClient,
        overviewModel: overviewEndpoint?.model ?? companyOverviewDefaultModel)
}

// MARK: - REST Facade

public extension BltServerContext {
    func searchCompanies(q: String) async -> BltServerResponse {
        let results = await masterDataManager.search(q, limit: Api.companySearchLimit)
        return .ok(results.map(companyJSON))
    }

    /// EU/ESEF Meta Search（`GET /v1/eu/companies`）。skills / MCP 未掲載の preview。
    func searchEuCompanies(q: String) async -> BltServerResponse {
        do {
            let results = try await esefSearch.search(q, limit: Api.companySearchLimit)
            return .ok(results.map(esefCompanyJSON))
        } catch EsefSearchError.emptyIndex {
            // 索引未構築時は空配列（呼び出し側で refreshIndex が必要）。
            return .ok([[String: Any]]())
        } catch {
            return .upstreamFailure("ESEF search failed")
        }
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
        switch await analyzer.analyze(code: code, analysisYears: years) {
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

    /// Statement 取り込み（Statement 本体）: 単一書類の XBRL から BS/PL/CF/SS を抽出する。決定論のみ（LLM不要）。
    /// `extractFilingSections`（有報セクション取り込み）と同型: 1書類分のみを扱い、複数年度の履歴集約は
    /// 行わない。US-GAAP は `.notApplicable`（連結に数値 fact が無く正規化不可。notes と同方針）。
    /// ダウンロード失敗は `.failed`。
    func extractStatement(
        docID: String, statementTypes: Set<StatementSectionType> = Set(StatementSectionType.allCases)
    ) async -> StatementDocResolveResult {
        let analyzer = StatementAnalyzer(edinetClient: edinetClient)
        return await analyzer.extract(docID: docID, statementTypes: statementTypes)
    }

    /// 会社アイコン取り込み: 書類1件分のXBRLから電子公告URLを抽出し、faviconを取得してR2へアップロードする。
    /// URL抽出（`CorporateWebsiteExtractor`）・favicon取得（`FaviconFetcher`）・R2アップロード
    /// （`R2Client`）のいずれかが失敗すれば `.failure`（戻り値パターン。段名をログ用に返す）。
    /// `r2Config` は呼び出し側（BltServerCore ingest）が環境変数から解決して渡す。
    func extractAndUploadCompanyIcon(docID: String, code: String, r2Config: R2Config) async
        -> Swift.Result<CompanyIconExtractResult, CompanyIconExtractFailure>
    {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else {
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

        let key = "company-icons/\(code)\(companyIconFileExtension(forContentType: icon.contentType))"
        switch await R2Client.upload(
            icon.data, key: key, contentType: icon.contentType, config: r2Config
        ) {
        case .success:
            return .success(
                CompanyIconExtractResult(
                    sourceURL: origin, r2ObjectKey: key, contentType: icon.contentType))
        case .invalidURL:
            return .failure(CompanyIconExtractFailure.r2UploadFailed(detail: "invalid_url"))
        case .transportError(let message):
            return .failure(CompanyIconExtractFailure.r2UploadFailed(detail: "transport:\(message)"))
        case .httpStatus(let status, let bodySnippet):
            return .failure(
                CompanyIconExtractFailure.r2UploadFailed(detail: "http_\(status):\(bodySnippet)"))
        }
    }

    /// ユーザーが用意した優先コード一覧（`assets/nikkei225.csv`）の証券コード集合。
    /// financials/filing-sections 取り込みの処理順序づけに使う（対象選定ではなく優先度のみ）。
    /// ファイル未配置なら空集合（優先なし・従来どおりの順序にフォールバック）。
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
    func resolveBorrowingsScheduleNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `property_plant_equipment_schedule` note_type を解決する
    /// （IFRS 注記 role → BS 区分タグ当期値で `available_via_statement` → それ以外。
    /// J-GAAP 附属明細表 TextBlock は未対応。`StatementNotesResolver` のドキュメント参照）。
    func resolvePropertyPlantEquipmentScheduleNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolvePropertyPlantEquipmentSchedule(xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `goodwill_and_intangibles` note_type を解決する（IFRS連結企業限定、
    /// J-GAAP単体には対応する法定附属明細表が無い）。
    func resolveGoodwillAndIntangiblesNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolveGoodwillAndIntangibles(xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `lease_liabilities` note_type を解決する。
    /// 連結 BS タグまたは IFRS リース注記 TextBlock（`IFRSLease`）から決定論で抽出する。
    func resolveLeaseLiabilitiesNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolveLeaseLiabilities(xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `sga_expense_breakdown` note_type を解決する。
    /// 連結損益計算書関係注記の構造化 `*SGA` / IFRS 販管費費目タグから決定論で抽出する。
    func resolveSgaExpenseBreakdownNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolveSgaExpenseBreakdown(xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `per_share_information` note_type を解決する。ロジックは
    /// `StatementNotesResolver.resolvePerShareInformation` に委譲する（「業績等の概要」の
    /// 離散数値タグから決定論で抽出、LLM 不要）。財務取り込み の単一値（EPSのみ）passthrough を
    /// 置き換える（実データレビューでBPS・潜在株式調整後EPSも取得可能と判明、2026-08-02）。
    func resolvePerShareInformationNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolvePerShareInformation(xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `dividends` note_type を解決する。ロジックは
    /// `StatementNotesResolver.resolveDividends` に委譲する（EDINET標準タクソノミの決議単位
    /// 構造化タグから決定論で抽出、LLM 不要）。財務取り込み の単一集計値 passthrough を置き換える
    /// （実データレビューで決議単位のテーブル構造が判明したため、2026-08-02）。
    func resolveDividendsNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolveDividends(xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `issued_shares_and_capital` note_type を解決する。ロジックは
    /// `StatementNotesResolver.resolveIssuedSharesAndCapital` に委譲する。期末スナップショット（離散タグ:
    /// 発行済・資本金・資本準備金）と textblock 表のイベント列を併記（LLM不要）。
    func resolveIssuedSharesAndCapitalNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolveIssuedSharesAndCapital(xbrlDir: xbrlDir)
    }

    /// 財務諸表注記取り込み: 書類1件分の `policy_holding_securities` note_type を解決する。ロジックは
    /// `StatementNotesResolver.resolvePolicyHoldingSecurities` に委譲する（EDINET標準タクソノミの
    /// 銘柄別構造化タグから決定論で抽出、LLM 不要）。
    func resolvePolicyHoldingSecuritiesNote(docID: String) async -> StatementNoteResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        return StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: xbrlDir)
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
    case notApplicable(reason: String)
    /// 書類取得・抽出自体が失敗（EDINET ダウンロード不可等）。行は作らない。
    case failed
}

public extension BltServerContext {
    /// Overview 生成（ingest 用）。Filing `texts` には足さない。格納先は `company_overviews`
    /// （会社1社=1行。stage は `overviews`。serving / 別 EP は未配線）。
    /// 社名・業種はマスタから引く（プロンプト用。本文からの補完には使わない）。
    func generateCompanyOverview(docID: String, code: String) async -> CompanyOverviewResolveResult {
        let stock = await masterDataManager.getByCode(code)
        return await generateCompanyOverview(
            docID: docID, code: code, name: stock?.coName ?? "", sector: stock?.s33nm ?? "")
    }

    /// Overview 生成（ingest 用）。社名・業種を呼び出し側が渡す。
    func generateCompanyOverview(docID: String, code: String, name: String, sector: String)
        async -> CompanyOverviewResolveResult
    {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
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
                    input: input, client: overviewChatClient, model: overviewModel)
            }
        }
        return .generated(draft: draft, sourceText: sourceText)
    }

    /// 内訳取り込み: 書類1件分の business 軸内訳を解決する。xbrl_facts（決定的）/ 収益認識注記 LLM /
    /// segment_info LLM のいずれかへ `BusinessBreakdownResolver` が振り分ける。LLM 呼び出しは
    /// html_table 経路でのみ発生する（xbrl_facts で解決できれば呼ばない。LLM 費用最小化）。
    /// 売上分母は同一 XBRL パスで `BreakdownFinancialsResolver` が直接解決する（#9 / #10b）。
    /// 保険等で売上欠測でも xbrl_facts 決定論（第一生命型）が使える場合は解決を試す。
    func resolveBusinessBreakdown(docID: String) async -> BreakdownResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        let consolidatedSales = BreakdownFinancialsResolver.financialsCanonicalSales(xbrlDir: xbrlDir)
        guard let segments = BreakdownExtractor.extractSpecialSection("segments", xbrlDir: xbrlDir)
        else { return .notApplicable(reason: breakdownNotApplicableUnknown) }

        let hash = breakdownContentHash(extracted: segments, consolidatedSales: consolidatedSales)
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)
        let result = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: consolidatedSales, client: businessChatClient,
            labelsByTag: labelsByTag)
        guard let snapshot = result.snapshot else {
            let reason = BreakdownExtractor.classifyNotApplicableReason(
                segments: segments, consolidatedSales: consolidatedSales, xbrlDir: xbrlDir,
                llmHint: result.audit?.notApplicableReason)
            return .notApplicable(reason: reason.rawValue)
        }
        return .resolved(
            payload: breakdownSnapshotPayload(from: snapshot), source: result.source.rawValue,
            contentHash: hash, audit: result.audit.map(llmBreakdownAuditPayload(from:)))
    }

    /// 内訳取り込み: 書類1件分の geography 軸内訳を解決する。`GeographyBreakdownResolver` が
    /// xbrl_facts / geography_llm へ振り分ける。正当欠測（地域注記なし、または LLM が
    /// applicable=false）は `not_applicable` / `not_found`、正規化・LLM 呼び出し失敗は
    /// `unknown`（要再試行）。売上分母は同一 XBRL パスで直接解決する（#9 / #10b）。
    func resolveGeographyBreakdown(docID: String) async -> BreakdownResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        let consolidatedSales = BreakdownFinancialsResolver.financialsCanonicalSales(xbrlDir: xbrlDir)
        if consolidatedSales == nil || consolidatedSales == 0 {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)
        if geography.method == "not_found" {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }

        let hash = breakdownContentHash(extracted: geography, consolidatedSales: consolidatedSales)
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)
        let result = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: consolidatedSales, client: geographyChatClient,
            labelsByTag: labelsByTag)
        guard let snapshot = result.snapshot else {
            // Resolver の notFound は「地域注記なし」または LLM の applicable=false。
            // audit があれば LLM が明示的に非該当と答えた正当欠測。audit 無しで表だけある場合は
            // LLM 呼び出し失敗の可能性が高いので unknown（再試行）に落とす。
            if result.source == .notFound {
                if result.audit != nil || geography.tables.isEmpty {
                    return .notApplicable(reason: breakdownNotApplicableNotFound)
                }
                return .notApplicable(reason: breakdownNotApplicableUnknown)
            }
            return .notApplicable(reason: breakdownNotApplicableUnknown)
        }
        return .resolved(
            payload: breakdownSnapshotPayload(from: snapshot), source: result.source.rawValue,
            contentHash: hash, audit: result.audit.map(llmBreakdownAuditPayload(from:)))
    }
}

public extension BltServerContext {
    /// 内訳取り込み: 書類1件分の employees 軸内訳を解決する（2026-08-01追加）。`NumberOfEmployees` /
    /// `NumberOfGroupEmployees` のセグメント dimension 付き fact のみを対象にした決定論経路
    /// （LLM フォールバックなし）。全社合計は同一 XBRL パスで `BreakdownFinancialsResolver` が
    /// 直接解決する（#9 / #10b）。
    func resolveEmployeesBreakdown(docID: String) async -> BreakdownResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        let total = BreakdownFinancialsResolver.financialsCanonicalEmployees(xbrlDir: xbrlDir)
        let cached = await businessSegmentDimensionCache.load(docID: docID, xbrlDir: xbrlDir)
        guard
            let snapshot = BreakdownNormalizer.normalizeEmployees(
                facts: cached.facts, total: total, axis: breakdownAxisEmployees,
                labelsByTag: cached.labelsByTag)
        else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let extracted = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: cached.facts)
        let hash = breakdownContentHash(extracted: extracted, consolidatedSales: nil)
        return .resolved(
            payload: breakdownSnapshotPayload(from: snapshot), source: breakdownSourceXbrlFacts,
            contentHash: hash, audit: nil)
    }

    /// 内訳取り込み: 書類1件分の research_and_development 軸を解決する（2026-08-01追加）。
    /// 決定論のみ、LLM なし。全社 R&D 分母は同一 XBRL パスで `BreakdownFinancialsResolver` /
    /// `financialsCanonicalRd` が直接解決する（#9 / #10b）。セグメント dimension が無くても
    /// total があれば denominator のみの resolved になる（合計の正本を本軸に寄せる）。
    func resolveResearchAndDevelopmentBreakdown(docID: String) async -> BreakdownResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        let rd = BreakdownFinancialsResolver.financialsCanonicalRdItem(xbrlDir: xbrlDir)
        let cached = await businessSegmentDimensionCache.load(docID: docID, xbrlDir: xbrlDir)
        guard
            let snapshot = BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: cached.facts, total: rd.value, totalTag: rd.tag,
                axis: breakdownAxisResearchAndDevelopment, labelsByTag: cached.labelsByTag)
        else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let extracted = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: cached.facts)
        let hash = breakdownContentHash(extracted: extracted, consolidatedSales: rd.value)
        return .resolved(
            payload: breakdownSnapshotPayload(from: snapshot), source: breakdownSourceXbrlFacts,
            contentHash: hash, audit: nil)
    }

    /// 内訳取り込み: 書類1件分の goodwill 軸内訳を解決する（2026-08-12追加）。決定論のみ、LLMなし。
    ///
    /// `Xbrl.goodwillSegmentTags` の無dimension fact から本関数が独立に解決する（`resolveItem`）。
    func resolveGoodwillBreakdown(docID: String) async -> BreakdownResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
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
        return .resolved(
            payload: breakdownSnapshotPayload(from: snapshot), source: breakdownSourceXbrlFacts,
            contentHash: hash, audit: nil)
    }
}

private extension BltServerContext {
    /// 報告セグメント別の決定論指標を共通の XBRL fact 経路で解決する。
    /// 分母は normalizer が segment + reconciling で決定論に組み立てる（表小計は行のみ）。
    func resolveSegmentMetricBreakdown(docID: String, axis: String) async -> BreakdownResolveResult {
        guard let xbrlDir = await edinetClient.downloadDocument(docID) else { return .failed }
        let cached = await businessSegmentDimensionCache.load(docID: docID, xbrlDir: xbrlDir)
        let snapshot: BreakdownSnapshot?
        switch axis {
        case breakdownAxisSegmentAssets:
            snapshot = BreakdownNormalizer.normalizeSegmentAssets(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        case breakdownAxisDepreciationAndAmortization:
            snapshot = BreakdownNormalizer.normalizeDepreciationAndAmortization(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        case breakdownAxisGoodwillAmortization:
            snapshot = BreakdownNormalizer.normalizeGoodwillAmortization(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        case breakdownAxisImpairmentLoss:
            snapshot = BreakdownNormalizer.normalizeImpairmentLoss(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        case breakdownAxisEquityMethodInvestments:
            snapshot = BreakdownNormalizer.normalizeEquityMethodInvestments(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        case breakdownAxisCapitalExpenditures:
            snapshot = BreakdownNormalizer.normalizeCapitalExpenditures(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        case breakdownAxisCapitalExpendituresOverview:
            if case .resolved(let payload, _, _) =
                StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: xbrlDir),
                let segments = payload.capexSegments,
                let htmlSnapshot = BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                    segments: segments)
            {
                snapshot = htmlSnapshot
            } else {
                let overview = BreakdownFinancialsResolver.breakdownCanonicalCapexOverviewItem(
                    xbrlDir: xbrlDir)
                snapshot = BreakdownNormalizer.normalizeCapitalExpendituresOverview(
                    facts: cached.facts, total: overview.value, totalTag: overview.tag,
                    labelsByTag: cached.labelsByTag)
            }
        case breakdownAxisNoncurrentAssetAdditions:
            snapshot = BreakdownNormalizer.normalizeNoncurrentAssetAdditions(
                facts: cached.facts, labelsByTag: cached.labelsByTag)
        default:
            snapshot = nil
        }
        guard let snapshot else {
            return .notApplicable(reason: breakdownNotApplicableNotFound)
        }
        let extracted = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: cached.facts)
        let hash = breakdownContentHash(extracted: extracted, consolidatedSales: snapshot.denominator)
        return .resolved(
            payload: breakdownSnapshotPayload(from: snapshot), source: breakdownSourceXbrlFacts,
            contentHash: hash, audit: nil)
    }
}

public extension BltServerContext {
    /// 報告セグメント別のセグメント資産を解決する。
    func resolveSegmentAssetsBreakdown(docID: String) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(docID: docID, axis: breakdownAxisSegmentAssets)
    }

    /// 報告セグメント別の減価償却費及び償却費を解決する。
    func resolveDepreciationAndAmortizationBreakdown(docID: String) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(
            docID: docID, axis: breakdownAxisDepreciationAndAmortization)
    }

    /// 報告セグメント別ののれんの償却額を解決する。
    func resolveGoodwillAmortizationBreakdown(docID: String) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(docID: docID, axis: breakdownAxisGoodwillAmortization)
    }

    /// 報告セグメント別の減損損失を解決する。
    func resolveImpairmentLossBreakdown(docID: String) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(docID: docID, axis: breakdownAxisImpairmentLoss)
    }

    /// 報告セグメント別の持分法会計処理される投資を解決する。
    func resolveEquityMethodInvestmentsBreakdown(docID: String) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(docID: docID, axis: breakdownAxisEquityMethodInvestments)
    }

    /// 報告セグメント別の資本的支出を解決する。
    func resolveCapitalExpendituresBreakdown(docID: String) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(docID: docID, axis: breakdownAxisCapitalExpenditures)
    }

    /// notes「設備投資等の概要」のCapexをbreakdown軸として解決する。
    func resolveCapitalExpendituresOverviewBreakdown(docID: String) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(
            docID: docID, axis: breakdownAxisCapitalExpendituresOverview)
    }

    /// 報告セグメント別の非流動性資産への追加額を解決する。
    func resolveNoncurrentAssetAdditionsBreakdown(docID: String) async -> BreakdownResolveResult {
        await resolveSegmentMetricBreakdown(
            docID: docID, axis: breakdownAxisNoncurrentAssetAdditions)
    }
}

/// 内部型 BreakdownSnapshot を公開格納用 BreakdownSnapshotPayload へ写経する。

private func breakdownSnapshotPayload(from s: BreakdownSnapshot) -> BreakdownSnapshotPayload {
    BreakdownSnapshotPayload(
        axis: s.axis, denominator: s.denominator, denominatorTag: s.denominatorTag,
        rows: s.rows.map {
            BreakdownRowPayload(
                labelRaw: $0.labelRaw, label: $0.label ?? $0.labelRaw, amount: $0.amount,
                profit: $0.profit, rowKind: $0.rowKind, description: $0.description)
        },
        sourceKind: s.sourceKind, needsReview: s.needsReview, warnings: s.warnings)
}

/// 内部型 LLMBreakdownAudit を公開格納用 LLMBreakdownAuditPayload へ写経する。
private func llmBreakdownAuditPayload(from a: LLMBreakdownAudit) -> LLMBreakdownAuditPayload {
    LLMBreakdownAuditPayload(
        sourceTableIndex: a.sourceTableIndex, periodColumn: a.periodColumn, unit: a.unit,
        profitDisclosed: a.profitDisclosed, notes: a.notes)
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
    /// seed 種別（Api.documentSyncDocTypes）に絞り、docID で重複排除する。
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
        return DocumentFetchResult(
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
              Api.documentSyncDocTypes.contains(docType) else { continue }
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

/// 書類同期 DB レコードから filings の配列を組み立てる純粋関数（ネットワーク・DB 非依存・テスト対象）。
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
    /// 企業検索結果の公開 JSON。
    func companyJSON(_ s: StockSearchResult) -> [String: Any] {
        ["code": s.code, "name": s.name, "sector": s.sector, "market": s.market, "location": s.location]
    }

    func esefCompanyJSON(_ s: EsefSearchResult) -> [String: Any] {
        var row: [String: Any] = [
            "identifier": s.identifier,
            "name": s.name,
            "region": s.region,
            "source": s.source,
        ]
        if let filing = s.matchedFiling {
            row["matched_filing"] = [
                "fxo_id": filing.fxoId,
                "country": filing.country,
                "period_end": filing.periodEnd,
                "json_url": filing.jsonURL ?? NSNull(),
                "package_url": filing.packageURL ?? NSNull(),
                "report_url": filing.reportURL ?? NSNull(),
            ] as [String: Any]
        } else {
            row["matched_filing"] = NSNull()
        }
        return row
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
    default: return ""
    }
}
