# データ処理

- 日付変換は `FiscalYear.swift` の `normalizeDateFormat` / `parseDateString` / `formatDateString` / `extractYearMonth` を使う。長さは `DateFormat.compactLength` / `hyphenatedLength` を使う。
- EDINET 日付は UTC。新規コードで `Calendar.current` を使わない。`fy_end` だけは `BltServerFacade` で `edinet_fy_end.prefix(7)` を許可する。
- 分析・サービス層の「見つからない」は `nil` / 空 / `method: "not_found"` で表す。独自エラー型を throw しない。
- 分析・サービス層で throws を許すのは `ExitCode` と外部ライブラリ境界だけ。`try?` は外部ライブラリ境界に限る。
- stderr は `Utils/StandardError.swift` の `printError` を使い、`fputs(..., stderr)` を追加しない。
- 契約・キャッシュは `Codable` を使う。`[String: Any]` は外部 JSON または動的 DB 応答の境界に限る。
- 共有する書式・財務・XBRL・API・version 定数は `Sources/BlueTicker/Constants/` に置く。
