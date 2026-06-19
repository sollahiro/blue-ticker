// blt-server エントリポイント。
// 使い方: blt-server [--host HOST] [--port PORT]

import BlueTickerCore
import Foundation

struct ServerArgs {
    var host: String = "127.0.0.1"
    var port: Int = 3000

    static func parse() -> ServerArgs {
        var args = ServerArgs()
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
