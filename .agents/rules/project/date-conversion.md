# 日付変換のコーディング規約

日付フォーマット変換（YYYYMMDD ↔ YYYY-MM-DD）には、必ず以下の正規関数を使用すること。
インラインでの文字列スライス変換や独自 `DateFormatter` 生成は禁止。

## 正規関数（`Sources/BlueTicker/Utils/FiscalYear.swift`）

| 関数 | 入力 | 出力 | 用途 |
|---|---|---|---|
| `normalizeDateFormat(_:)` | YYYYMMDD / YYYY-MM-DD | `String?` | 文字列として YYYY-MM-DD が必要な場合 |
| `parseDateString(_:)` | YYYYMMDD / YYYY-MM-DD | `Date?` | Date オブジェクトとして扱いたい場合 |
| `extractYearMonth(_:)` | YYYYMMDD / YYYY-MM-DD | `(Int?, Int?)` | 年・月を整数で取り出す場合 |

## 使用例

```swift
normalizeDateFormat("20231231")   // => "2023-12-31"
normalizeDateFormat("2023-12-31") // => "2023-12-31"（冪等）
normalizeDateFormat(nil)          // => nil（安全）

parseDateString("20231231")       // => Date(2023-12-31)
extractYearMonth("20231231")      // => (2023, 12)
```

## 日付長定数

マジックナンバー `8` や `10` は使わず `Sources/BlueTicker/Constants/Formats.swift` の定数を使う。

```swift
DateFormat.compactLength      // 8  (YYYYMMDD)
DateFormat.hyphenatedLength   // 10 (YYYY-MM-DD)
```

## タイムゾーン

EDINET の日付処理は **UTC 固定**が最終形（JST 0:00〜8:59 の間は当日提出分の取得が最大1日遅れるが許容。次回実行時の catchup で埋まる）。`Calendar.current` を新規コードで使わず、UTC カレンダーを使うこと。

## filing コマンドの期末日フォーマット（fy_end）

`filing` コマンドの JSON 出力では期末日を `fy_end` フィールドに **YYYY-MM** 形式で表示する。`edinet_fy_end`（YYYY-MM-DD）の先頭 7 文字をそのまま使う。これはフォーマット変換ではなく単純な切り詰めであり、`prefix(7)` が許容される唯一の例外。
