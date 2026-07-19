// Neon cold start 向けの接続設定が、プール待ちと操作タイムアウトの大小関係を
// 崩さないことを回帰として固定する。

import BlueTickerCore
import Testing

@Suite struct DatabaseBootstrapConfigTests {
    @Test func connectionPoolTimeoutExceedsFluentDefault() {
        // FluentPostgresDriver 既定 10s では launchd sync/ingest 起動時の cold start に不足。
        #expect(Api.dbConnectionPoolTimeoutSeconds > 10)
    }

    @Test func operationTimeoutsExceedConnectionPoolTimeout() {
        // プール待ちより短いと withOperationTimeout が先に切れ、maxConnections=1 の
        // プールを占有したままリトライが詰まる（ingest / read / bootstrap 共通）。
        let pool = Double(Api.dbConnectionPoolTimeoutSeconds)
        #expect(Api.dbOperationTimeoutSeconds > pool)
        #expect(Api.dbBootstrapOperationTimeoutSeconds > pool)
    }
}
