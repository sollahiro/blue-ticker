// blt-server エントリポイント。
// 使い方:
//   blt-server [--host HOST] [--port PORT]                   REST サーバーを起動
//   blt-server sync [--from YYYY-MM-DD] [--to YYYY-MM-DD]    Stage 1 書類一覧を DB へ同期
//   blt-server ingest [--limit N] [--with-facts] [--stages 4,4half,5,6] [--codes 7203,6758]
//                                                            Stage 4/4-half/5/6 を DB へ取り込み（--stages で対象を選択、既定は全て。
//                                                            Stage 6 は日経225構成銘柄限定（LLM費用抑制）。
//                                                            --with-facts で Stage 3 数値 fact も。既定は停止。issue #22。
//                                                            --codes で対象を証券コード集合に絞り、--limit を無視して全件処理する。
//                                                            Stage 6/7 では --codes を対象母集団にも使う
//                                                            （nikkei225.csv 未配置でも手動再ingest可能）。
//                                                            バグ修正確認後の手動・単発再計算向け。定期実行では使わない）
//   blt-server master-data-upload <path>                    EDINET コードリスト CSV を Neon へ反映
//                                                            （正本を丸ごと差し替え。稼働中サーバーは定期ポーリングで自動反映）
//   blt-server status-report                                5 ステージ（financials/half_financials/
//                                                            filing_sections/breakdown_business/
//                                                            breakdown_geography）のカバレッジ・鮮度を
//                                                            JSON で stdout へ出力（DB read-only）。
//                                                            assets/apex-site/status.html 生成用
//                                                            （scripts/generate-status-page.sh が呼ぶ）。
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
            printError("blt-server error: --stages は 4,4half,5,6 のカンマ区切りで指定してください\n")
            exit(1)
        }
        // `optionValue` はフラグが argv 末尾（値なし）のとき nil を返し、フラグ未指定と区別できない。
        // 「値なしの裸 --codes」を絞り込みなし（全企業対象）へ誤って縮退させないよう、
        // フラグの有無は argv.contains で別途判定する。
        let codesPresent = argv.contains("--codes")
        let codes = parseIngestCodes(optionValue("--codes", in: argv))
        if codesPresent, codes?.isEmpty ?? true {
            printError("blt-server error: --codes は証券コードのカンマ区切りで指定してください\n")
            exit(1)
        }
        try await runStage3IngestCommand(
            limit: optionValue("--limit", in: argv).flatMap(Int.init),
            includeFacts: argv.contains("--with-facts"),
            stages: stages,
            codes: codes
        )
    } else if argv.count > 1, argv[1] == "master-data-upload" {
        guard argv.count > 2 else {
            printError("blt-server error: master-data-upload には CSV ファイルパスを指定してください\n")
            exit(1)
        }
        try await runMasterDataUploadCommand(path: argv[2])
    } else if argv.count > 1, argv[1] == "status-report" {
        try await runStatusReportCommand()
    } else {
        let args = ServerArgs.parse(argv)
        try await runBltServer(host: args.host, port: args.port)
    }
} catch {
    printError("blt-server error: \(error)\n")
    exit(1)
}
