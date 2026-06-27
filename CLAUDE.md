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
| `BlueTickerCore`（`Sources/BlueTicker/`） | CLI・XBRL解析・サービス・REST サーバーのファサード（`Server/`）を含む共有ライブラリ。**Vapor/Fluent には依存しない** |
| `BltServerCore`（`Sources/BltServerCore/`） | REST サーバーのトランスポート層（Vapor）と DB 層（Fluent）。`BlueTickerCore` のファサードを呼ぶ。Web/DB 依存（Vapor・Fluent）をここに閉じ込める |
| `BlueTicker`（`Sources/BlueTickerMain/`） | `ticker` CLI のエントリポイントのみ |
| `BltServer`（`Sources/BltServer/`） | `blt-server` のエントリポイントのみ |

ターゲット間の依存方向: `BltServerCore` → `BlueTickerCore` は可。逆は不可（Core は Vapor/Fluent を参照しない）。これにより `ticker` CLI に Web/DB 依存がリンクされない。

`BlueTickerCore` 内のディレクトリ責務（同一モジュールのため import 方向はコンパイラで強制されない。レビューで担保する）:

- `Services/` は `CLI/` のコマンド型を参照してはならない
- `Analysis/` / `API/` / `Infrastructure/` / `Utils/` は `CLI/`・`Services/`・`Server/` を参照してはならない
- `Server/` は REST サーバーの **ファサード**（`BltServerContext`・`BltServerResponse`・`makeBltServerContext`）のみを置く。Vapor トランスポート・Fluent DB 層は `BltServerCore` ターゲットに置く

@.agents/rules/generic/workflow.md
@.agents/rules/generic/documentation.md
@.agents/rules/generic/commit-conventions.md
@.agents/rules/project/date-conversion.md
@.agents/rules/project/versioning.md
@.agents/rules/project/error-handling.md
@.agents/rules/project/xbrl-analysis.md
@.agents/rules/project/dependencies.md
@.agents/rules/project/caching.md
@.agents/rules/project/constants.md
@.agents/rules/project/typing.md
