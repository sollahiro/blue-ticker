// BltServer の public エントリポイント。
// BltServer 実行可能ターゲットの main.swift がこれを呼ぶ。

import Foundation
import Logging
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// MCP HTTP サーバーを起動する。
/// - Parameters:
///   - host: バインドアドレス（デフォルト 127.0.0.1）
///   - port: ポート番号（デフォルト 3000）
public func runBltServer(host: String = "127.0.0.1", port: Int = 3000) async throws {
    let logger: Logger = {
        var l = Logger(label: "blt-server", factory: { StreamLogHandler.standardError(label: $0) })
        l.logLevel = .info
        return l
    }()

    let apiKey = await settingsStore.get(.edinetApiKey)
    guard let key = apiKey, !key.isEmpty else {
        logger.error("EDINET API キーが設定されていません。ticker config set edinet-key <key> で設定してください。")
        exit(1)
    }

    let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
    let cacheDir = URL(fileURLWithPath: cacheDirStr.isEmpty ? settingsStore.cacheDir.path : cacheDirStr)

    let context = BltServerContext(apiKey: key, cacheDir: cacheDir)

    logger.info("blt-server starting", metadata: ["host": "\(host)", "port": "\(port)"])

    let app = HTTPApp(
        configuration: .init(
            host: host,
            port: port,
            endpoint: "/mcp",
            retryInterval: 1000
        ),
        validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.localhost(port: port),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ]),
        serverFactory: { sessionID, transport in
            logger.debug("Creating MCP session", metadata: ["sessionID": "\(sessionID)"])
            return await makeBltServer(context: context, transport: transport)
        },
        logger: logger
    )

    try await app.start()
}
