@/Users/shutosorahiro/.claude/CLAUDE.md
@AGENTS.md

# BLUE TICKER — Claude Code ガイド

日本株の財務データ基盤（Swift / SwiftPM）。ユーザー接点は REST / MCP。配布 CLI は廃止。

原理原則・機能の実装サイクル・監査／モデル分担・Cursor Cloud 手順は `AGENTS.md`。下記はビルドとターゲット境界の正本。

## ビルド・テスト

```bash
swift build                          # blt-server / TickerDev バイナリを生成
swift test                           # 全テスト（Swift Testing）
.build/debug/blt-server --help       # ローカル実行（要 BLT_EDINET_API_KEY 等）
swift run TickerDev analyze <code>   # 開発用ローカル解析（配布しない。要 BLT_EDINET_API_KEY）
```

## ターゲット構成と依存ルール

| ターゲット | 内容 |
|---|---|
| `BlueTickerCore`（`Sources/BlueTicker/`） | XBRL解析・サービス・REST ファサード（`Server/`）・開発用ローカル解析（`DevCLI/`）を含む共有ライブラリ。**Vapor/Fluent には依存しない** |
| `BltMcpServerCore`（`Sources/BltMcpServerCore/`） | MCP プロトコル層（ツールカタログ・`MCP.Server` ファクトリ）。ビジネスロジック・DB は持たない。**Vapor/Fluent には依存しない** |
| `BltServerCore`（`Sources/BltServerCore/`） | REST サーバーのトランスポート層（Vapor）と DB 層（Fluent）。`BlueTickerCore` のファサードと `BltMcpServerCore` を呼ぶ。MCP はルートパス（`POST /`）として配線。Web/DB 依存をここに閉じ込める |
| `BltServer`（`Sources/BltServer/`） | `blt-server` のエントリポイントのみ（唯一の配布 executable product） |
| `TickerDev`（`Sources/TickerDevMain/`） | 開発用ローカル解析 CLI のエントリポイントのみ。**`Package.swift` の `products` に含めない**（`swift run TickerDev` でのみ実行） |

ターゲット間の依存方向: `BltServerCore` → `BlueTickerCore` / `BltMcpServerCore` は可。逆は不可（Core は Vapor/Fluent を参照しない）。

`BlueTickerCore` 内のディレクトリ責務（同一モジュールのため import 方向はコンパイラで強制されない。レビューで担保する）:

- `Services/` は `DevCLI/` のコマンド型を参照してはならない
- `Analysis/` / `API/` / `Infrastructure/` / `Utils/` は `Services/`・`Server/`・`DevCLI/` を参照してはならない
- `Server/` は REST サーバーの **ファサード**（`BltServerContext`・`BltServerResponse`・`makeBltServerContext`、breakdowns 取り込み結果を表す `BreakdownResolveResult` 等）のみを置く。Vapor トランスポート・Fluent DB 層は `BltServerCore` ターゲットに置く
- `DevCLI/` は `TickerDev` ターゲット向けの **ファサード**。公開面は `DevCLIEntry` の1点のみ。ローカル解析コマンド実装は internal のまま置き、新たに public 化しない

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
