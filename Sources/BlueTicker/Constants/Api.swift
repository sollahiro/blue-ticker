public enum Api {
    static let edinetBaseURL = "https://api.edinet-fsa.go.jp/api/v2"

    /// Chat Completions 互換エンドポイントの既定ベースURL（`XAI_BASE_URL` 未設定時のフォールバック）。
    /// Stage 6 の html_table 正規化（`SegmentBreakdownLLMNormalizer`）でのみ使用。
    static let xaiBaseURL = "https://api.x.ai/v1"

    /// remote バックエンドの既定 blt-server URL。インストール直後に `ticker login` だけで
    /// 使い始められるよう、config 未設定時のフォールバック先として組み込む
    /// （`ticker config set --server-url` / `BLT_SERVER_URL` で上書き可能）。
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
    public static let sectorCompaniesLimitDefault = 20
    public static let filingsMaxYearsDefault = 5
    public static let financialsYearsDefault = 5
    public static let halfFinancialsYearsDefault = 3

    // 件数上限
    static let companySearchLimit = 50      // searchCompanies の返却上限
    static let filingsMaxDocuments = 50     // server read（getFilings / filingsList）の filings 上限
    static let filingsCliMaxDocuments = 10  // CLI `filings` コマンドの表示上限

    /// 半期分析で算出・格納できる最大年数（HalfYearAnalyzer の探索上限）。
    /// 半期は FY/2Q の組から H1/H2 を導出する都合でこの年数までしか作れない。
    /// 格納（Stage 4-half）・read クランプ・分析の単一の真実源。
    /// BltServerCore（Stage 4-half ingest / read クランプ）からも参照するため public。
    public static let halfMaxYears = 5

    /// REST read パス（Routes.swift）で Neon cold-start（scale-to-zero 後の再接続）を
    /// 吸収するための DB リトライ設定。ingest（`withDbRetry` 既定値、最大5回/16秒）より
    /// 短めにし、DB が本当に落ちている場合に同期リクエストを長時間ブロックしないようにする。
    public static let dbReadRetryMaxAttempts = 3
    public static let dbReadRetryMaxBackoffSeconds: Double = 4

    /// `withDbRetry` のエラーログに含めるエラー詳細（`String(reflecting:)`）の最大文字数。
    /// Stage 3/4 の facts/response は JSONB で巨大なため、ログ行が肥大化しないよう切り詰める。
    public static let dbRetryErrorLogMaxLength = 2000

    /// ingest（Stage 3/4/4-half/5）で「DB が不安定」と判断してその場でループを打ち切るまでの
    /// リトライ発生回数の閾値。Neon の scale-to-zero 明けの再接続が不調な状態が続くと、
    /// 1件ずつは（数回リトライの末に）復旧してもトータルでは長時間を浪費するため、
    /// 閾値超で早期中断し、残りは次回スケジュールに委ねる。
    public static let ingestDbUnhealthyRetryThreshold = 10

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

    static let xbrlMaxBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB

    /// XBRL ダウンロード＋fact インデックス展開（processDocument）の同時実行数。
    /// メモリピーク抑制のため（issue #34）。
    static let xbrlProcessConcurrency = 2

    // 書類種別
    // Stage 5 取り込み（BltServerCore）が有報のみを対象にするため public。
    public static let docTypeAnnualReport = "120"
    static let docTypeAmendment = "130"           // 訂正有価証券報告書
    static let docTypeQuarterlyReport = "140"
    static let docTypeAmendedQuarterlyReport = "150"
    static let docTypeHalfYearReport = "160"
    static let docTypeAmendedHalfYearReport = "170"

    /// financials レスポンスの公開契約バージョン。blueTickerVersion とは独立。
    /// レスポンス形を破壊的に変更したときのみ +1 する（クライアントのデコード整合判定用）。
    /// v2: remote CLI のローカル同等表示のため、flatten にラベル・SGA・NOPAT・実効税率・
    ///     支払利息・流動/固定資産負債・PPE・ネット D/E・capex/buyback/RD・配当内訳等を追加。
    static let financialsSchemaVersion = 2

    /// 半期 financials レスポンス（HalfFinancialsResponse）の公開契約バージョン。
    /// financials とは独立採番。レスポンス形を破壊的に変更したときのみ +1 する。
    static let halfFinancialsSchemaVersion = 1

    /// Stage 1 同期で DB へ取り込む書類種別（日次書類の全件 → DB。seed 種別に絞る）。
    /// 有報・半期・四半期＋訂正有報のみ。訂正四半期(150)・訂正半期(170) は意図的に含めない
    /// （有報中心の財務計算に対し、訂正は訂正有報(130)のみ採用する設計）。
    /// filings 表示用の上位集合とは別セット → `filingsDisplayDocTypes`。
    static let stage1SyncDocTypes: Set<String> = [
        docTypeAnnualReport,
        docTypeAmendment,
        docTypeQuarterlyReport,
        docTypeHalfYearReport,
    ]

    /// Stage 4（通期 company_financials）の high-water 鮮度判定が対象とする書類種別。
    /// `EdinetDiscovery.buildDocumentIndexForCode` が実際に消費する種別（有報＋訂正有報）とだけ
    /// 揃える。これ以外の新規提出（四半期等）では通期の再計算をトリガーしない。
    /// BltServerCore（Stage4Ingest）から参照するため public。
    public static let stage4FreshnessDocTypes: Set<String> = [
        docTypeAnnualReport,
        docTypeAmendment,
    ]

    /// Stage 4-half（company_half_financials）の high-water 鮮度判定が対象とする書類種別。
    /// `HalfYearAnalyzer` → `EdinetDiscovery.buildHalfYearDocumentIndexForCode` が消費する
    /// 有報＋半期/四半期に加え、通期側の訂正(130)も含める（訂正で FY 基準が動き、半期の
    /// 再計算が必要になるため）。BltServerCore（Stage4HalfIngest）から参照するため public。
    public static let stage4HalfFreshnessDocTypes: Set<String> = [
        docTypeAnnualReport,
        docTypeAmendment,
        docTypeQuarterlyReport,
        docTypeHalfYearReport,
    ]

    /// filings 表示（CLI `filings`）で採用する書類種別。探索済み書類に対する表示フィルタで、
    /// 訂正を含む全 6 種の上位集合（Stage 1 sync 用より広い。上の別セットと区別）。
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
