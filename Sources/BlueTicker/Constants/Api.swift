enum Api {
    static let edinetBaseURL = "https://api.edinet-fsa.go.jp/api/v2"

    // 検索キャッシュ TTL（日）
    static let searchEmptyTTLDays = 1
    static let searchHitTTLDays = 30
    static let searchPastTTLDays = 3650

    // 年次書類インデックス
    static let documentIndexVersion = "edinet-doc-index-v1"
    static let documentIndexBatchSize = 2
    static let documentIndexMinRangeDays = 30
    static let documentIndexKeepYears = 6

    // デフォルト年数
    static let filingsDefaultYears = 3
    static let prepareDefaultYears = 5
    static let analyzeDefaultYears = 6

    static let docDiscoveryLimit = 10
    static let xbrlMaxBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB

    // 書類種別
    static let docTypeAnnualReport = "120"
    static let docTypeAmendment = "130"
    static let docTypeQuarterlyReport = "140"
    static let docTypeHalfYearReport = "160"

    /// financials レスポンスの公開契約バージョン。blueTickerVersion とは独立。
    /// レスポンス形を破壊的に変更したときのみ +1 する（クライアントのデコード整合判定用）。
    /// v2: remote CLI のローカル同等表示のため、flatten にラベル・SGA・NOPAT・実効税率・
    ///     支払利息・流動/固定資産負債・PPE・ネット D/E・capex/buyback/RD・配当内訳等を追加。
    static let financialsSchemaVersion = 2

    /// Stage 1 同期で DB へ取り込む書類種別。
    /// 現状は有報・半期・四半期＋訂正有報。他種別へ拡張する場合はここへ追加する（単一の真実源）。
    static let stage1SyncDocTypes: Set<String> = [
        docTypeAnnualReport,
        docTypeAmendment,
        docTypeQuarterlyReport,
        docTypeHalfYearReport,
    ]

    // キャッシュロック
    static let cacheLockPollSeconds: Double = 0.2
    static let cacheLockNoticeSeconds: Double = 1.0
    static let cacheLockStaleSeconds: Double = 10 * 60
    static let cacheLockTimeoutSeconds: Double = 3 * 60

    // SSL 証明書候補（macOS / Linux）
    static let sslCertFileEnv = "SSL_CERT_FILE"
    static let sslCaBundleCandidates: [String] = [
        "/opt/homebrew/etc/openssl@3/cert.pem",
        "/opt/homebrew/etc/ca-certificates/cert.pem",
        "/usr/local/etc/openssl@3/cert.pem",
        "/usr/local/etc/ca-certificates/cert.pem",
        "/etc/ssl/cert.pem",
        "/etc/ssl/certs/ca-certificates.crt",
    ]
}
