// blt-server エントリポイント。
// 使い方:
//   blt-server [--host HOST] [--port PORT]                   REST サーバーを起動
//   blt-server sync [--from YYYY-MM-DD] [--to YYYY-MM-DD]    Stage 1 書類一覧を DB へ同期
//   blt-server ingest [--limit N] [--with-facts] [--stages 4,4half,5]
//                                                            Stage 4/4-half/5 を DB へ取り込み（--stages で対象を選択、既定は全て。
//                                                            --with-facts で Stage 3 数値 fact も。既定は停止。issue #22）
//
// bind アドレスの解決順位: CLI 引数 > 環境変数（BLT_HOST / BLT_PORT）> デフォルト。
// クラウド（Fly.io 等）では env で 0.0.0.0 / 注入ポートをバインドできるようにする。

import BltServerCore
import BlueTickerCore
import Foundation

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

do {
    // 第1引数がサブコマンドなら分岐する（無ければサーバー起動）。
    if argv.count > 1, argv[1] == "sync" {
        try await runStage1SyncCommand(
            from: optionValue("--from", in: argv),
            to: optionValue("--to", in: argv)
        )
    } else if argv.count > 1, argv[1] == "ingest" {
        guard let stages = parseIngestStages(optionValue("--stages", in: argv)) else {
            printError("blt-server error: --stages は 4,4half,5 のカンマ区切りで指定してください\n")
            exit(1)
        }
        try await runStage3IngestCommand(
            limit: optionValue("--limit", in: argv).flatMap(Int.init),
            includeFacts: argv.contains("--with-facts"),
            stages: stages
        )
    } else {
        let args = ServerArgs.parse(argv)
        try await runBltServer(host: args.host, port: args.port)
    }
} catch {
    printError("blt-server error: \(error)\n")
    exit(1)
}
