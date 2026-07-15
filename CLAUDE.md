@/Users/shutosorahiro/.claude/CLAUDE.md

# BLUE TICKER — Claude Code ガイド

日本株の財務データCLIツール（Swift / SwiftPM）。

## ビルド・テスト

```bash
swift build                     # ticker / blt-server / TickerDev バイナリを生成
swift test                      # 全テスト（Swift Testing）
.build/debug/ticker --help      # ローカル実行（remote 専用）
swift run TickerDev analyze <code>  # 開発用ローカル解析（配布しない。要 BLT_EDINET_API_KEY）
```

## ターゲット構成と依存ルール

| ターゲット | 内容 |
|---|---|
| `BlueTickerCore`（`Sources/BlueTicker/`） | CLI（remote 専用）・XBRL解析・サービス・REST サーバーのファサード（`Server/`）・開発用ローカル解析のファサード（`DevCLI/`）を含む共有ライブラリ。**Vapor/Fluent には依存しない** |
| `BltMcpServerCore`（`Sources/BltMcpServerCore/`） | MCP プロトコル層（ツールカタログ・`MCP.Server` ファクトリ）。ビジネスロジック・DB は持たない。**Vapor/Fluent には依存しない** |
| `BltServerCore`（`Sources/BltServerCore/`） | REST サーバーのトランスポート層（Vapor）と DB 層（Fluent）。`BlueTickerCore` のファサードと `BltMcpServerCore` を呼ぶ。MCP プロトコルもここでルートパス（`POST /`）として Vapor ルートに配線する。Web/DB 依存（Vapor・Fluent）をここに閉じ込める |
| `BlueTicker`（`Sources/BlueTickerMain/`） | `ticker` CLI（remote 専用・配布）のエントリポイントのみ |
| `BltServer`（`Sources/BltServer/`） | `blt-server` のエントリポイントのみ |
| `TickerDev`（`Sources/TickerDevMain/`） | 開発用ローカル解析 CLI のエントリポイントのみ。**`Package.swift` の `products` に含めない**（release ビルド・Homebrew formula から到達不能。`swift run TickerDev` でのみ実行） |

ターゲット間の依存方向: `BltServerCore` → `BlueTickerCore` / `BltMcpServerCore` は可。逆は不可（Core は Vapor/Fluent を参照しない）。これにより `ticker` CLI に Web/DB 依存がリンクされない。

`BlueTickerCore` 内のディレクトリ責務（同一モジュールのため import 方向はコンパイラで強制されない。レビューで担保する）:

- `Services/` は `CLI/` のコマンド型を参照してはならない
- `Analysis/` / `API/` / `Infrastructure/` / `Utils/` は `CLI/`・`Services/`・`Server/`・`DevCLI/` を参照してはならない
- `Server/` は REST サーバーの **ファサード**（`BltServerContext`・`BltServerResponse`・`makeBltServerContext`）のみを置く。Vapor トランスポート・Fluent DB 層は `BltServerCore` ターゲットに置く
- `DevCLI/` は `TickerDev` ターゲット向けの **ファサード**。`Server/` と同型で、公開面は `DevCLIEntry` の1点のみに絞る。EDINET を直接叩くコマンド実装（旧 `CLI/` local 分岐）はここに internal のまま置き、新たに public 化しない

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
