// blt-server エントリポイント。
// 使い方:
//   blt-server [--host HOST] [--port PORT]                   REST サーバーを起動
//   blt-server sync [--from YYYY-MM-DD] [--to YYYY-MM-DD]    EDINET 書類一覧を DB へ同期
//   blt-server ingest [--limit N] [--with-facts] [--stages financials,
//                     filing-sections,breakdowns,statements,statement-notes,icons] [--codes 7203,6758]
//                     [--note-types per_share_information,borrowings_schedule,...]
//                                                            対象を DB へ取り込み（--stages で選択、既定は全て）。
//                                                            breakdowns: business/geography は上場全体（--limit 適用）、
//                                                            employees/rd/goodwill は日経225（1ジョブ 30）。
//                                                            statements は上場全体（日経225は処理順の優先のみ）。
//                                                            statement-notes は日経225構成銘柄限定。
//                                                            icons は BLT_R2_* 環境変数未設定時はスキップされる。
//                                                            --with-facts は残存（数値 facts 永続は閉じた。BLT-23）。
//                                                            --codes で対象を証券コード集合に絞り、--limit を無視して全件処理する。
//                                                            statements/statement-notes では --codes を対象母集団にも使う
//                                                            （nikkei225.csv 未配置でも手動再ingest可能）。
//                                                            --note-types は statement-notes ステージで ingest する
//                                                            note_type を絞る（未指定時は公開全8種）。
//                                                            バグ修正確認後の手動・単発再計算向け。定期実行では使わない）
//   blt-server master-data-upload <path>                    EDINET コードリスト CSV を Neon へ反映
//                                                            （正本を丸ごと差し替え。稼働中サーバーは定期ポーリングで自動反映）
//   blt-server status-report                                5 ステージ（financials/statements/
//                                                            filing_sections/breakdown_business/
//                                                            breakdown_geography）のカバレッジ・鮮度・
//                                                            最新有報スライスを JSON で stdout へ出力
//                                                            （DB read-only。notes 等は含めない）。
//                                                            status.html 生成用
//                                                            （scripts/generate-status-page.sh が呼ぶ。
//                                                            パスは BLT_STATUS_HTML）。
//
// bind アドレスの解決順位: CLI 引数 > 環境変数（BLT_HOST / BLT_PORT）> デフォルト。
// クラウド（Fly.io 等）では env で 0.0.0.0 / 注入ポートをバインドできるようにする。

import BltServerCore
import Foundation

/// エントリ専用。Core の `printError` に頼らず stderr へ書く（BltServer → BlueTickerCore 直リンクを避ける）。
private func printError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

/// エラーメッセージに紛れ込みうるシークレットをマスクする。
/// - EDINET: `Subscription-Key=<key>`（URLSession 系エラーの userInfo 経由。EdinetAPIClient で
///   発生源でも無害化済みだが、ここでも多層防御する）
/// - DATABASE_URL: `postgres(ql)://user:password@host` の password 部分
///   （`SQLPostgresConfiguration(url:)` のパースエラーが URL 文字列を含みうるため）
private func redactSecrets(_ message: String) -> String {
    var result = message
    let patterns: [(pattern: String, template: String)] = [
        (#"(Subscription-Key=)[^&\s"]+"#, "$1***"),
        (#"((?:postgres(?:ql)?://[^:/@\s]+:))[^@\s]+@"#, "$1***@"),
    ]
    for (pattern, template) in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: template)
        }
    }
    return result
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

do {
    // 第1引数がサブコマンドなら分岐する（無ければサーバー起動）。
    if argv.count > 1, argv[1] == "sync" {
        try await runDocumentSyncCommand(
            from: optionValue("--from", in: argv),
            to: optionValue("--to", in: argv)
        )
    } else if argv.count > 1, argv[1] == "ingest" {
        guard let targets = parseIngestTargets(optionValue("--stages", in: argv)) else {
            printError("blt-server error: --stages は financials,filing-sections,breakdowns,statements,statement-notes,icons のカンマ区切りで指定してください\n")
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
        let noteTypesPresent = argv.contains("--note-types")
        let noteTypes = parseStatementNoteTypes(optionValue("--note-types", in: argv))
        if noteTypesPresent, noteTypes?.isEmpty ?? true {
            printError(
                "blt-server error: --note-types は note_type のカンマ区切りで指定してください（例: per_share_information,borrowings_schedule）\n")
            exit(1)
        }
        try await runFactsIngestCommand(
            limit: optionValue("--limit", in: argv).flatMap(Int.init),
            includeFacts: argv.contains("--with-facts"),
            targets: targets,
            codes: codes,
            noteTypes: noteTypes
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
    printError("blt-server error: \(redactSecrets(String(reflecting: error)))\n")
    exit(1)
}
