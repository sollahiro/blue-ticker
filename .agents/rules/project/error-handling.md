# エラーハンドリング

分析・サービス層は戻り値で失敗を表す（`nil` / 空 / `method: "not_found"`）。独自エラー型の `throw` は禁止。

stderr は `printError`（`Utils/StandardError.swift`）。`fputs(..., stderr)` は禁止。

`throws` してよいのは `ExitCode` と外部ライブラリ境界（SwiftSoup は `try?` 可）だけ。
