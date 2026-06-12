# BLUE TICKER — Claude Code ガイド

日本株の財務データCLIツール（Swift / SwiftPM）。

## ビルド・テスト

```bash
swift build                  # ticker / blt-server バイナリを生成
swift test                   # 全テスト（Swift Testing）
.build/debug/ticker --help   # ローカル実行
```

## ターゲット構成と依存ルール

| ターゲット | 内容 |
|---|---|
| `BlueTickerCore`（`Sources/BlueTicker/`） | CLI・XBRL解析・サービス・MCPサーバーを含む共有ライブラリ |
| `BlueTicker`（`Sources/BlueTickerMain/`） | `ticker` CLI のエントリポイントのみ |
| `BltServer`（`Sources/BltServer/`） | `blt-server` のエントリポイントのみ |

`BlueTickerCore` 内のディレクトリ責務（同一モジュールのため import 方向はコンパイラで強制されない。レビューで担保する）:

- `Services/` は `CLI/` のコマンド型を参照してはならない
- `Analysis/` / `API/` / `Infrastructure/` / `Utils/` は `CLI/`・`Services/`・`MCPServer/` を参照してはならない

@.agents/rules/generic/commit-conventions.md
@.agents/rules/project/date-conversion.md
@.agents/rules/project/versioning.md
@.agents/rules/project/error-handling.md
@.agents/rules/project/xbrl-analysis.md
@.agents/rules/project/dependencies.md
@.agents/rules/project/caching.md
@.agents/rules/project/constants.md
@.agents/rules/project/typing.md
