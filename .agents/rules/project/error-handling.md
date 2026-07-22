# エラーハンドリング規約

分析・サービス層のエラー処理は**戻り値パターン**で統一する。エラー型を新設して `throw` する設計は採用しない。

## 正規パターン

```swift
// ✅ Optional・空コレクション・method フィールドでエラー状態を返す
func fetchAndBuild(code: String, years: Int) async -> [YearEntry] {
    guard let docs = ... else { return [] }  // 失敗は空配列
    ...
}

// 抽出結果は「見つからなかった」を値で表現する
ExtractedBreakdown(method: "not_found", tables: [], facts: [])
```

呼び出し元（CLI 層）が `nil` / 空を判定し、ユーザー向けメッセージを stderr へ出して `ExitCode.failure` を投げる。

stderr への書き出しは必ず `printError(_:)`（`Utils/StandardError.swift`）を使う。C の `fputs(..., stderr)` は禁止。Glibc の `stderr` はグローバル `var` で Swift 6 言語モードの並行性チェックに通らないため、`FileHandle.standardError` ベースの `printError` に集約している。

```swift
guard !entries.isEmpty else {
    printError("エラー: 財務データの取得に失敗しました。\n")
    throw ExitCode.failure
}
```

## やってはいけないパターン

```swift
// ❌ 分析・サービス層で独自エラー型を throw する
enum AnalysisError: Error { case insufficientData(required: Int, available: Int) }
throw AnalysisError.insufficientData(required: 5, available: 2)
```

## 例外（throws を使ってよい箇所）

- `ArgumentParser` の `ExitCode`（CLI 終了コード）
- SwiftSoup 等の外部ライブラリ境界（`try?` で Optional に落としてよい）
