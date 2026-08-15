# JP / EDINET

Region `JP` · Source `EDINET`。命名規約は `.agents/rules/project/regions.md`。

本番ロジックの正本は Swift モノレポ側:

| 役割 | 置き場 |
|---|---|
| 取得 | `Sources/BlueTicker/API/EdinetAPIClient.swift` 等 |
| 解析 | `Sources/BlueTicker/Analysis/` |
| 定数・コンテキスト | `Sources/BlueTicker/Constants/Xbrl.swift` |
| 開発 CLI | `Sources/BlueTicker/DevCLI/`（`swift run TickerDev`） |
| ローカル cache | `tmp_cache/edinet/` |

対となる EU / ESEF 探索: `scripts/eu/esef/`。
