// blt-ingest エントリポイント（Mac 専用。取り込み・書き込み・マイグレーションと、手元で使う read 系コマンド）。
// Vapor / MCP をリンクしない。配信（REST / MCP）は blt-server。
// 使い方:
//   blt-ingest migrate                                       未適用のマイグレーションを DATABASE_URL へ適用
//                                                            （DDL 権限が要る。sync / ingest 等の書き込みコマンドも
//                                                            冒頭で同じ適用を行う。blt-server のデプロイ前に実行する）
//   blt-ingest sync [--from YYYY-MM-DD] [--to YYYY-MM-DD]    EDINET 書類一覧を DB へ同期
//   blt-ingest ingest [--limit N] [--stages financials,
//                     filing-sections,breakdowns,statements,statement-notes,icons,overviews,
//                     relations,industry-kpis]
//                     [--codes 7203,6758] [--doc-ids S100W0S7]
//                     [--note-types per_share_information,property_plant_equipment_schedule,...]
//                                                            対象を DB へ取り込み（--stages で選択、既定は relations と industry-kpis 以外の全て）。
//                                                            breakdowns: product_service/geography は上場全体（--limit 適用）、
//                                                            employees/rd/goodwill 等の決定論指標軸も上場全体
//                                                            （1ジョブ 30。日経225は処理順の優先のみ）。
//                                                            statements は上場全体（日経225は処理順の優先のみ）。
//                                                            statement-notes も上場全体（日経225は処理順の優先のみ）。
//                                                            icons は BLT_R2_* 環境変数未設定時はスキップされる。
//                                                            overviews は OPENROUTER_OVERVIEW_API_KEY 未設定時は
//                                                            スキップされる。上場全体・最新有報1件（日経225は処理順）。
//                                                            --codes で対象を証券コード集合に絞り、--limit を無視して全件処理する。
//                                                            --doc-ids は原本有報(120)の doc_id 単位（会社-FY）。
//                                                            該当書類だけ再計算し、他 FY は purge しない。
//                                                            cache_version / needs_review でも skip しない。
//                                                            statements/statement-notes では --codes を対象母集団にも使う
//                                                            （nikkei225.csv 未配置でも手動再ingest可能）。
//                                                            --note-types は statement-notes ステージで ingest する
//                                                            note_type を絞る（未指定時は公開全4種）。
//                                                            バグ修正確認後の手動・単発再計算向け。定期実行では使わない）
//   blt-ingest master-data-upload <path>                    EDINET コードリスト CSV を Neon へ反映
//                                                            （正本を丸ごと差し替え。稼働中サーバーは定期ポーリングで自動反映）
//   blt-ingest screen-rebuild [--limit N]                   company_financials から screen_index
//                                                            （Screen 検索用 Read Model）を再生成。
//                                                            --limit は走査件数上限（部分実行では孤児削除なし）
//   blt-ingest status-report                                5 ステージ（financials/statements/
//                                                            filing_sections/breakdown_product_service/
//                                                            breakdown_geography）のカバレッジ・鮮度・
//                                                            最新有報スライスを JSON で stdout へ出力
//                                                            （DB read-only。読み取りロールでも動く。notes 等は含めない）。
//                                                            status.html 生成用
//                                                            （scripts/generate-status-page.sh が呼ぶ。
//                                                            パスは BLT_STATUS_HTML）。
//   blt-ingest overrides add --file <path.json> [--created-by NAME] [--dry-run]
//                                                            手動 XBRL 上書きを追加する。書き込みは
//                                                            BLT_NEON_WRITE_DATABASE_URL 必須。
//                                                            --dry-run は検証と現行値との diff のみ。
//   blt-ingest overrides list [--edinet-code E03614] [--item capex]
//                             [--include-revoked]
//                                                            上書きの一覧（read。DATABASE_URL）。
//   blt-ingest overrides revoke --id UUID
//   blt-ingest overrides revoke --edinet-code E --period-end YYYY-MM-DD --item capex
//                                                            有効行を revoke。WRITE URL 必須。

import BltIngestCore
import BltStoreCore
import Foundation

/// エントリ専用。Core の `printError` に頼らず stderr へ書く（BltIngest → BlueTickerCore 直リンクを避ける）。
private func printError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

/// 名前付きオプション（--key value）を argv から取り出す。
private func optionValue(_ name: String, in argv: [String]) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

let argv = CommandLine.arguments
bootstrapBltLogging(level: bltLogLevelFromEnvironment())

do {
    // 第1引数がサブコマンドなら分岐する（無ければサーバー起動）。
    if argv.count > 1, argv[1] == "migrate" {
        try await runMigrateCommand()
    } else if argv.count > 1, argv[1] == "sync" {
        try await runDocumentSyncCommand(
            from: optionValue("--from", in: argv),
            to: optionValue("--to", in: argv)
        )
    } else if argv.count > 1, argv[1] == "ingest" {
        guard let targets = parseIngestTargets(optionValue("--stages", in: argv)) else {
            printError("blt-ingest error: --stages は financials,filing-sections,breakdowns,statements,statement-notes,icons,overviews,relations,industry-kpis のカンマ区切りで指定してください\n")
            exit(1)
        }
        // `optionValue` はフラグが argv 末尾（値なし）のとき nil を返し、フラグ未指定と区別できない。
        // 「値なしの裸 --codes」を絞り込みなし（全企業対象）へ誤って縮退させないよう、
        // フラグの有無は argv.contains で別途判定する。
        let codesPresent = argv.contains("--codes")
        let codes = parseIngestCodes(optionValue("--codes", in: argv))
        if codesPresent, codes?.isEmpty ?? true {
            printError("blt-ingest error: --codes は証券コードのカンマ区切りで指定してください\n")
            exit(1)
        }
        let docIDsPresent = argv.contains("--doc-ids")
        let docIDs = parseIngestDocIDs(optionValue("--doc-ids", in: argv))
        if docIDsPresent, docIDs?.isEmpty ?? true {
            printError("blt-ingest error: --doc-ids は原本有報 doc_id のカンマ区切りで指定してください\n")
            exit(1)
        }
        let noteTypesPresent = argv.contains("--note-types")
        let noteTypes = parseStatementNoteTypes(optionValue("--note-types", in: argv))
        if noteTypesPresent, noteTypes?.isEmpty ?? true {
            printError(
                "blt-ingest error: --note-types は note_type のカンマ区切りで指定してください（例: per_share_information,issued_shares_and_capital）\n")
            exit(1)
        }
        try await runFactsIngestCommand(
            limit: optionValue("--limit", in: argv).flatMap(Int.init),
            targets: targets,
            codes: codes,
            docIDs: docIDs,
            noteTypes: noteTypes
        )
    } else if argv.count > 1, argv[1] == "master-data-upload" {
        guard argv.count > 2 else {
            printError("blt-ingest error: master-data-upload には CSV ファイルパスを指定してください\n")
            exit(1)
        }
        try await runMasterDataUploadCommand(path: argv[2])
    } else if argv.count > 1, argv[1] == "screen-rebuild" {
        let limitPresent = argv.contains("--limit")
        let limit = optionValue("--limit", in: argv).flatMap(Int.init)
        if limitPresent, limit == nil || (limit ?? 0) < 1 {
            printError("blt-ingest error: --limit は 1 以上の整数で指定してください\n")
            exit(1)
        }
        try await runScreenRebuildCommand(limit: limit)
    } else if argv.count > 1, argv[1] == "status-report" {
        try await runStatusReportCommand()
    } else if argv.count > 1, argv[1] == "overrides" {
        guard argv.count > 2 else {
            printError("blt-ingest error: overrides のサブコマンドは add / list / revoke です\n")
            exit(1)
        }
        try await runManualXbrlOverrideCommand(
            ManualXbrlOverrideCLIArgs(
                subcommand: argv[2],
                file: optionValue("--file", in: argv),
                createdBy: optionValue("--created-by", in: argv),
                dryRun: argv.contains("--dry-run"),
                edinetCode: optionValue("--edinet-code", in: argv),
                item: optionValue("--item", in: argv),
                includeRevoked: argv.contains("--include-revoked"),
                id: optionValue("--id", in: argv),
                periodEnd: optionValue("--period-end", in: argv)
            )
        )
    } else {
        printError("blt-ingest error: サブコマンドを指定してください（migrate / sync / ingest / master-data-upload / screen-rebuild / status-report / overrides）。配信サーバーは blt-server です\n")
        exit(1)
    }
} catch {
    printError("blt-ingest error: \(redactSecrets(String(reflecting: error)))\n")
    exit(1)
}
