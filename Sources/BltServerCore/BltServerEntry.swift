// BltServer の public エントリポイント。
// BltServer 実行可能ターゲットの main.swift がこれを呼ぶ。

import BlueTickerCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// REST HTTP サーバーを起動する。
/// - Parameters:
///   - host: バインドアドレス（デフォルト 127.0.0.1）
///   - port: ポート番号（デフォルト 3000）
public func runBltServer(host: String = "127.0.0.1", port: Int = 3000) async throws {
    guard let context = await makeBltServerContext() else {
        printError("EDINET API キーが設定されていません。ticker config set edinet-key <key> で設定してください。\n")
        exit(1)
    }

    let restRouter = RESTRouter(context: context)

    let app = HTTPApp(
        configuration: .init(host: host, port: port),
        restHandler: { method, path, params, body in
            await restRouter.handle(method: method, path: path, queryParams: params, body: body)
        }
    )

    try await app.start()
}
