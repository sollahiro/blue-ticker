# 依存

レイヤー間の依存は `AGENTS.md`。外部パッケージ追加はユーザー確認後（パッケージ名・代替不可の理由・使用箇所）。一覧の正本は `Package.swift` のコメント（ここに表を置かない）。

Linux は `URLSession`→`FoundationNetworking`、`XMLParser`→`FoundationXML`。macOS 専用 API は `#if canImport`。MemberImportVisibility 回避フラグは `AGENTS.md`「Cursor Cloud」。
