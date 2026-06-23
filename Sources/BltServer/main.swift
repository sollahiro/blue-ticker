// blt-server エントリポイント。
// 使い方: blt-server [--host HOST] [--port PORT]
//
// bind アドレスの解決順位: CLI 引数 > 環境変数（BLT_HOST / BLT_PORT）> デフォルト。
// クラウド（Fly.io 等）では env で 0.0.0.0 / 注入ポートをバインドできるようにする。

import BltServerCore
import BlueTickerCore
import Foundation

struct ServerArgs {
    var host: String
    var port: Int

    static func parse() -> ServerArgs {
        // デフォルトは env を起点にし、CLI 引数があれば上書きする。
        let env = ProcessInfo.processInfo.environment
        var args = ServerArgs(
            host: env["BLT_HOST"] ?? "127.0.0.1",
            port: env["BLT_PORT"].flatMap(Int.init) ?? 3000
        )
        let argv = CommandLine.arguments
        var i = 1
        while i < argv.count {
            switch argv[i] {
            case "--host":
                i += 1
                if i < argv.count { args.host = argv[i] }
            case "--port":
                i += 1
                if i < argv.count, let p = Int(argv[i]) { args.port = p }
            default:
                break
            }
            i += 1
        }
        return args
    }
}

let args = ServerArgs.parse()
do {
    try await runBltServer(host: args.host, port: args.port)
} catch {
    printError("blt-server error: \(error)\n")
    exit(1)
}
