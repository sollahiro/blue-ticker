# 定数の置き場所

マジックナンバー・文字列リテラルは `Sources/BlueTicker/Constants/` 配下に置く。コードに直書きしない。

## ファイル分類

| ファイル | 置くもの |
|---|---|
| `Formats.swift` | 日付・文字列フォーマットに関する定数（`DateFormat.compactLength` など） |
| `Financial.swift` | 財務計算の単位・乗数（`Financial.millionYen`、`Financial.percent` など） |
| `Xbrl.swift` | XBRLタグ名・コンテキストパターン・セクション定義（`enum Xbrl`、`xbrlSections`） |
| `Api.swift` | 外部APIのベースURL・デフォルトパラメーター（`enum Api`） |
| `Version.swift` | アプリケーションバージョン（`blueTickerVersion`、単一の真実源） |

## やってはいけないパターン

```swift
// ❌ マジックナンバーの直書き
value / 1_000_000
ratio * 100
if dateStr.count == 8 { ... }

// ❌ タグ名のハードコード
let allowedTags = ["GrossProfit", "GrossProfitIFRS"]

// ✅ 定数を使う
value / Financial.millionYen
ratio * Financial.percent
if dateStr.count == DateFormat.compactLength { ... }
let allowedTags = Xbrl.grossProfitDirectTags
```

## 新しい定数を追加するとき

既存のファイル分類に合うものはそのファイルへ追加する。どれにも当てはまらない場合は、新ファイルを作る前にユーザーへ確認する。
