public enum Api {
    static let edinetBaseURL = "https://api.edinet-fsa.go.jp/api/v2"

    /// Chat Completions 互換エンドポイントの既定ベースURL。
    /// 内訳取り込み の html_table 正規化でのみ使用。稼働先は `LLM_PROVIDER`、
    /// 明示 `*_BASE_URL` があればそちらが勝つ。
    static let xaiBaseURL = "https://api.x.ai/v1"
    static let openaiBaseURL = "https://api.openai.com/v1"
    /// Overview 生成（OpenRouter / Chat Completions 互換）。内訳 LLM の `LLM_PROVIDER` とは別。
    static let openrouterBaseURL = "https://openrouter.ai/api/v1"

    /// remote バックエンドの既定 blt-server URL（契約ドキュメント・クライアント既定用。秘密情報ではない）。
    static let defaultRemoteServerURL = "https://api.sollahiro.com"

    // 検索キャッシュ TTL（日）
    static let searchEmptyTTLDays = 1
    static let searchHitTTLDays = 30
    static let searchPastTTLDays = 3650

    /// 当日分キャッシュの有効期間（時間）。EDINET は当日の書類一覧を営業時間中随時更新するため、
    /// 日単位 TTL（searchHitTTLDays）だと同一日内の複数回 sync 実行（launchd 6時間間隔）で
    /// 再取得されず、後から提出された書類が同日キャッシュに永久に欠落する
    /// （実例: 2026-06-29 提出の有報が欠落）。launchd の実行間隔より短くし、次回実行で必ず再取得させる。
    static let searchTodayTTLHours = 4

    // 年次書類インデックス
    static let documentIndexVersion = "edinet-doc-index-v1"
    static let documentIndexBatchSize = 2
    static let documentIndexMinRangeDays = 30
    static let documentIndexKeepYears = 6

    // デフォルト年数（CLI）
    static let filingsDefaultYears = 3
    static let prepareDefaultYears = 5
    static let analyzeDefaultYears = 6

    // REST API クエリの省略時デフォルト（BltServerCore から参照するため public）。
    // 値は既存の直書きと同一（挙動不変）。
    public static let filingsMaxYearsDefault = 5
    /// filings の `max_years` 上限。ライブ探索の年次並列取得を無制限にしない。
    public static let filingsMaxYearsMax = 10
    public static let financialsYearsDefault = 5
    /// Screen（`GET /v1/screen`）の返却件数省略時。
    public static let screenLimitDefault = 50
    /// Screen の返却件数上限。フィルタ無し全件は返さない。
    public static let screenLimitMax = 200
    /// Feed Update の返却件数省略時。
    public static let feedLimitDefault = 50
    /// Feed Update の返却件数上限。
    public static let feedLimitMax = 100
    /// Feed Update の items 窓（日）省略時。
    public static let feedTrendDaysDefault = 7
    /// Feed Update の items 窓（日）上限。
    public static let feedTrendDaysMax = 90
    /// Update の `total.week` 窓（日）。クエリ `days`（items の窓）とは独立。
    public static let feedUpdateWeekDays = 7
    /// Feed Update 応答の公開契約バージョン。形を破壊的に変えたときのみ +1。
    public static let feedSchemaVersion = 2
    /// Feed Trend 応答の公開契約バージョン（Update とは別リソース）。
    public static let feedTrendSchemaVersion = 1
    /// 検索クエリ `q` の蓄積上限（文字）。超えた分は切る。
    public static let feedTrendQueryMaxLength = 128

    /// filings のライブ EDINET 探索フォールバック（DB 未同期銘柄）の応答待ち上限（秒）。
    /// URLSession 既定（60s）より長めに取りつつ、リクエストが無期限に待たないようにする。
    public static let filingsLiveTimeoutSeconds: Double = 90
    /// 窓内書類の走査上限。Update の `total` はメモリ集計。
    public static let feedTrendScanLimit = 5000
    /// Statement 取り込み（Statement）read の既定年数。`filingSectionsIngestYears`（6年保持）以下に収める。
    public static let statementYearsDefault = 5

    // 件数上限
    static let companySearchLimit = 50      // searchCompanies の返却上限

    static let filingsMaxDocuments = 50     // server read（getFilings / filingsList）の filings 上限
    static let filingsCliMaxDocuments = 10  // CLI `filings` コマンドの表示上限

    /// REST read パス（Routes.swift）で Neon cold-start（scale-to-zero 後の再接続）を
    /// 吸収するための DB リトライ設定。ingest（`withDbRetry` 既定値、最大5回/16秒）より
    /// 短めにし、DB が本当に落ちている場合に同期リクエストを長時間ブロックしないようにする。
    public static let dbReadRetryMaxAttempts = 3
    public static let dbReadRetryMaxBackoffSeconds: Double = 4

    /// `withDbRetry` のエラーログに含めるエラー詳細（`String(reflecting:)`）の最大文字数。
    /// 数値 fact 取り込み/財務取り込みの facts/response は JSONB で巨大なため、ログ行が肥大化しないよう切り詰める。
    public static let dbRetryErrorLogMaxLength = 2000

    /// ingest（数値 fact 取り込み/財務取り込み/有報セクション取り込み）で「DB が不安定」と判断してその場でループを打ち切るまでの
    /// リトライ発生回数の閾値。Neon の scale-to-zero 明けの再接続が不調な状態が続くと、
    /// 1件ずつは（数回リトライの末に）復旧してもトータルでは長時間を浪費するため、
    /// 閾値超で早期中断し、残りは次回スケジュールに委ねる。
    public static let ingestDbUnhealthyRetryThreshold = 10

    /// `blt-server status-report`（status.html 生成用。パスは `BLT_STATUS_HTML`）が各ステージを
    /// 「更新遅延中」と判定するまでの経過時間（時間）。`scripts/check-ingest-freshness.sh` の
    /// `BLT_FRESHNESS_MAX_AGE_HOURS` 既定値（36）と揃えている。値を変える場合は両方を見直すこと
    /// （2つの独立した仕組みのため自動同期はしない）。
    public static let ingestFreshnessMaxAgeHours: Double = 36

    /// Postgres 接続プールの設定（Neon 向け）。
    /// `maxConnectionsPerEventLoop` は FluentPostgresDriver 既定と同一。
    /// `connectionPoolTimeout` は既定 10s だと Neon cold start（ap-southeast-1）の
    /// 初回接続待ちに足りず、launchd の sync/ingest 起動直後に
    /// `connectionRequestTimeout` でプロセスが落ちるため延長する。
    public static let dbMaxConnectionsPerEventLoop = 1
    public static let dbConnectionPoolTimeoutSeconds: Int64 = 45

    /// `withDbRetry` の1試行あたりに許容する DB 操作の応答待ち上限（秒）。
    /// Neon 接続が TCP 的に無応答のまま死ぬ（FIN/RST が来ない）と、クエリの await が
    /// 例外を投げずに無期限へ待ち続け、`withDbRetry` のリトライが一切発動しない
    /// （catch に入れないため）。この上限を超えたら強制的にタイムアウト例外を投げ、
    /// 通常のリトライ経路に載せる。
    /// `dbConnectionPoolTimeoutSeconds` より長く保つ（短いとプール待ち中に
    /// `withOperationTimeout` が先に切れ、切り離された要求がプールを占有する）。
    public static let dbOperationTimeoutSeconds: Double = 60

    /// プロセス起動時 `autoMigrate` 用の操作タイムアウト。
    /// 通常の `dbOperationTimeoutSeconds` より長く取り、cold start 直後の migrate を許容する。
    /// いずれも `dbConnectionPoolTimeoutSeconds` より長く保つこと。
    public static let dbBootstrapOperationTimeoutSeconds: Double = 75

    /// XBRL ZIP 展開の安全上限（ZIP 爆弾対策）。信頼ソース（EDINET/R2）前提だが、
    /// キャッシュ汚染・誤格納への防御として展開前に検査する。実測の有報 ZIP は
    /// 非圧縮でも数百 MB に届かないため、1 GiB / 1 万エントリは十分な余裕を持つ上限。
    static let xbrlZipMaxUncompressedBytes: Int64 = 1_073_741_824
    static let xbrlZipMaxEntryCount = 10_000

    /// MCP ルート（`POST /`）1リクエストあたりの HTTP 応答待ち上限（秒）。
    /// 依存 `modelcontextprotocol/swift-sdk`（0.12.1）の `StatelessHTTPServerTransport` に
    /// waiter deadline が実装されておらず、クライアントの `notifications/cancelled`（issue #255）や
    /// 同一 JSON-RPC id の同時リクエスト（issue #254）で応答待ちの継続（continuation）が永久に
    /// resume されず、HTTP リクエストが無期限にハングすることがある（upstream 未修正・
    /// blue-ticker issue #84 で追跡）。
    /// この上限は「格納データ系ツール（get_waterfall 等）が `withDbRetry` 経由で DB 再接続を
    /// 最大3回試行し、1回あたり `dbOperationTimeoutSeconds`（60秒）まで正常に待つ」既存仕様上の
    /// 理論上限（60×3+backoff ≈ 183秒）より長く取り、正常だが遅い応答を誤ってタイムアウト扱い
    /// しないようにする。
    public static let mcpRequestTimeoutSeconds: Double = 200

    static let xbrlMaxBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB

    /// 生 XBRL ZIP の R2 オブジェクトキー接頭辞（Region JP / Source EDINET）。
    /// 完成キーは `{prefix}/{docID}.zip`。公開 URL は付けない（私有 L2）。
    static let xbrlR2KeyPrefix = "jp/edinet/xbrl"

    /// R2 へ置く XBRL パッケージの Content-Type。
    static let xbrlZipContentType = "application/zip"

    /// 会社アイコン PUT の待ち上限（秒）。小さいオブジェクト向け。
    static let r2IconUploadTimeoutSeconds: Double = 15

    /// 生 XBRL ZIP の R2 GET/PUT 待ち上限（秒）。有報パッケージは数十 MB になりうる。
    static let r2XbrlTransferTimeoutSeconds: Double = 180

    /// XBRL ダウンロード＋fact インデックス展開（processDocument）の同時実行数。
    /// メモリピーク抑制のため（issue #34）。
    static let xbrlProcessConcurrency = 2

    // 書類種別
    // 有報セクション取り込み（BltServerCore）が有報のみを対象にするため public。
    public static let docTypeAnnualReport = "120"
    static let docTypeAmendment = "130"           // 訂正有価証券報告書
    static let docTypeQuarterlyReport = "140"
    static let docTypeAmendedQuarterlyReport = "150"
    static let docTypeHalfYearReport = "160"
    static let docTypeAmendedHalfYearReport = "170"

    /// 企業内容等の開示に関する内閣府令。会社の有報・訂正有報はこれ。
    /// `030`（特定有価証券の開示に関する内閣府令）は投資信託・信託受益証券等で、
    /// docType 120 でも会社財務の latest / yearRank には使わない。
    public static let ordinanceCompanyDisclosure = "010"

    /// 会社開示府令の書類か（ordinance 欠落は false。テストシードは明示すること）。
    public static func isCompanyDisclosureOrdinance(_ ordinanceCode: String?) -> Bool {
        ordinanceCode == ordinanceCompanyDisclosure
    }

    /// financials レスポンスの公開契約バージョン。blueTickerVersion とは独立。
    /// レスポンス形を破壊的に変更したときのみ +1 する。
    static let financialsSchemaVersion = 2

    /// 書類同期で DB へ取り込む書類種別（日次書類の全件 → DB。seed 種別に絞る）。
    /// 有報・半期・四半期＋訂正有報のみ。訂正四半期(150)・訂正半期(170) は意図的に含めない
    /// （有報中心の財務計算に対し、訂正は訂正有報(130)のみ採用する設計）。
    /// filings 表示用の上位集合とは別セット → `filingsDisplayDocTypes`。
    static let documentSyncDocTypes: Set<String> = [
        docTypeAnnualReport,
        docTypeAmendment,
        docTypeQuarterlyReport,
        docTypeHalfYearReport,
    ]

    /// Feed が受け付ける書類種別。sync 済み集合と一致（DB に無い種別は返らない）。
    public static var feedAllowedDocTypes: Set<String> { documentSyncDocTypes }
    /// Feed の `doc_type` 省略時。有報のみ。
    public static let feedDefaultDocTypes = [docTypeAnnualReport]

    /// 財務取り込み（通期 company_financials）の high-water 鮮度判定が対象とする書類種別。
    /// `EdinetDiscovery.buildDocumentIndexForCode` が実際に消費する種別（会社有報＋訂正有報、
    /// 府令010）とだけ揃える。これ以外の新規提出（四半期・信託受益証券の 120 等）では
    /// 通期の再計算をトリガーしない。BltServerCore（FinancialsIngest）から参照するため public。
    public static let financialsFreshnessDocTypes: Set<String> = [
        docTypeAnnualReport,
        docTypeAmendment,
    ]

    /// filings 表示（CLI `filings`）で採用する書類種別。探索済み書類に対する表示フィルタで、
    /// 訂正を含む全 6 種の上位集合（書類同期 sync 用より広い。上の別セットと区別）。
    static let filingsDisplayDocTypes: Set<String> = [
        docTypeAnnualReport,
        docTypeAmendment,
        docTypeQuarterlyReport,
        docTypeAmendedQuarterlyReport,
        docTypeHalfYearReport,
        docTypeAmendedHalfYearReport,
    ]

    // キャッシュロック
    static let cacheLockPollSeconds: Double = 0.2
    static let cacheLockNoticeSeconds: Double = 1.0
    static let cacheLockStaleSeconds: Double = 10 * 60
    static let cacheLockTimeoutSeconds: Double = 3 * 60

    /// EDINET マスタデータ（コードリスト CSV）の Neon 定期ポーリング間隔（秒）。
    /// デプロイ不要で手動アップロードを反映するための鮮度チェック周期。
    /// BltServerCore（起動中サーバーのポーリングループ）から参照するため public。
    public static let masterDataPollIntervalSeconds: UInt64 = 1800
}
