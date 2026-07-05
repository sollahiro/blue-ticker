// BltServer の public エントリポイント。
// Vapor の Application ライフサイクルを管理し、ルート・DB を配線して起動する。
// データ取得は BlueTickerCore の BltServerContext ファサードに委譲する（ファサード境界は不変）。

import BlueTickerCore
import Fluent
import Foundation
import Vapor

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// REST HTTP サーバーを起動する。
/// - Parameters:
///   - host: バインドアドレス（デフォルト 127.0.0.1）
///   - port: ポート番号（デフォルト 3000）
public func runBltServer(host: String = "127.0.0.1", port: Int = 3000) async throws {
    guard let context = await makeBltServerContext() else {
        printError("EDINET API キーが設定されていません。BLT_EDINET_API_KEY 環境変数、または ticker config set --edinet-api-key <KEY> で設定してください。\n")
        exit(1)
    }

    // CLI の --host/--port は main.swift で解析済みのため、Vapor には環境引数を渡さず
    // サーバー設定を直接指定する（Environment.detect が --host を誤解釈するのを避ける）。
    var env = Environment(name: "production", arguments: ["blt-server"])
    try LoggingSystem.bootstrap(from: &env)

    let app = try await Application.make(env)
    // 成功時の shutdown は do/catch の外に置く。do 内に含めると、shutdown が throw した際に
    // catch で再度 shutdown され二重 shutdown になる（asyncShutdown は冪等ではない）。
    do {
        app.http.server.configuration.hostname = host
        app.http.server.configuration.port = port

        try await configureDatabase(app)
        if let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty {
            startMasterDataPolling(app: app)
        }
        registerRoutes(app, context: context)

        try await app.execute()
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
