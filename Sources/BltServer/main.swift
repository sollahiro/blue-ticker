// blt-server エントリポイント。
// 使い方:
//   blt-server [--host HOST] [--port PORT]                   REST / MCP サーバーを起動（DB は読み取りのみ。migrate しない）
//
// 取り込み・書き込み・マイグレーション・status-report・overrides は blt-ingest（Mac 専用）へ移した。
//
// bind アドレスの解決順位: CLI 引数 > 環境変数（BLT_HOST / BLT_PORT）> デフォルト。
// クラウド（Fly.io 等）では env で 0.0.0.0 / 注入ポートをバインドできるようにする。

import BltServerCore
import BltStoreCore
import Foundation

/// エントリ専用。Core の `printError` に頼らず stderr へ書く（BltServer → BlueTickerCore 直リンクを避ける）。
private func printError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

/// 名前付きオプション（--key value）を argv から取り出す。
private func optionValue(_ name: String, in argv: [String]) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

struct ServerArgs {
    var host: String
    var port: Int

    static func parse(_ argv: [String]) -> ServerArgs {
        // デフォルトは env を起点にし、CLI 引数があれば上書きする。
        let env = ProcessInfo.processInfo.environment
        var args = ServerArgs(
            host: env["BLT_HOST"] ?? "127.0.0.1",
            port: env["BLT_PORT"].flatMap(Int.init) ?? 3000
        )
        if let h = optionValue("--host", in: argv) { args.host = h }
        if let p = optionValue("--port", in: argv).flatMap(Int.init) { args.port = p }
        return args
    }
}

let argv = CommandLine.arguments

/// blt-ingest へ移したサブコマンド。誤って blt-server で呼んだときはサーバーを起動せずに止める。
private let ingestSubcommands: Set<String> = [
    "migrate", "sync", "ingest", "master-data-upload", "screen-rebuild", "status-report", "overrides",
]

do {
    if argv.count > 1, ingestSubcommands.contains(argv[1]) {
        printError("blt-server error: `\(argv[1])` は blt-ingest のサブコマンドです（blt-server は配信専用）\n")
        exit(1)
    }
    let args = ServerArgs.parse(argv)
    try await runBltServer(host: args.host, port: args.port)
} catch {
    printError("blt-server error: \(redactSecrets(String(reflecting: error)))\n")
    exit(1)
}
