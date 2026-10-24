# アーキテクチャ

- 構成の正本は `docs/architecture.md`。product は `blt-ingest`（Mac 専用・取り込みと書き込み）と `blt-server`（Fly・配信）の 2 つ。
- 依存方向は `BltIngest` → `BltIngestCore` → `BltStoreCore` → `BlueTickerCore`、`BltServer` → `BltServerCore` → `BltStoreCore` / `BltMcpServerCore`。`BltStoreCore` と `BltIngestCore` は Vapor / MCP 非依存、マイグレーションは `BltIngestCore` だけに置く。Core は Vapor / Fluent 非依存。
- `BlueTickerCore` 内では `Analysis/`・`API/`・`Infrastructure/`・`Utils/` → `Services/`・`Server/`、`Services/` → `Server/` を禁止する。
- 外部パッケージの正本は `Package.swift` 先頭コメント。追加はパッケージ名・必要理由・使用 target を示してユーザーに確認する。
- Linux では `URLSession` に `FoundationNetworking`、`XMLParser` に `FoundationXML` を使い、macOS 専用 API は `#if canImport` で分離する。
- 新しい Swift 名の頭字語は全大文字にする。ただし EDINET は既存契約に合わせて `Edinet` とする。
- ローカルで Linux コンテナが必要な場合は Apple `container` を使う。Dockerfile は Fly 向け OCI 契約として維持する。
