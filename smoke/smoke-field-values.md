# スモークテスト フィールド値データセット

ロジック変更時のリグレッション検知を目的とした、XBRL解析レベルの期待値データセット。

## ファイル構成

```
tests/
  fixtures/
    smoke_expected/
      {code}_{fy_end}.json   # 企業ごとの期待値ファイル
  test_smoke_field_values.py # テスト本体
```

## テストの動作

- `smoke/smoke_expected/*.json` を動的に読み込んでパラメータ化
- キャッシュ済みXBRL（`tmp_cache/edinet/`）から各 `extract_*` 関数を実行
- 期待値フィールドが `null` のものはスキップ（TODO扱い）
- **全フィールドが `null` のファイルはテスト自体をスキップ**
- XBRLキャッシュが存在しない環境でもスキップ（CIでは通常スキップ）

## 期待値ファイルのフィールド一覧

| セクション | フィールド | 単位 | 対応する extract 関数 |
|---|---|---|---|
| `income_statement.sales` | 売上高 | 円 | `extract_income_statement` |
| `income_statement.operating_profit` | 営業利益 | 円 | 同上 |
| `income_statement.net_profit` | 純利益 | 円 | 同上 |
| `income_statement.accounting_standard` | 会計基準 | 文字列 | 同上 |
| `gross_profit.gross_profit` | 売上総利益 | 円 | `extract_gross_profit` |
| `gross_profit.method` | 取得方法 | 文字列 | 同上 |
| `balance_sheet.total_assets` | 総資産 | 円 | `extract_balance_sheet` |
| `balance_sheet.current_assets` | 流動資産 | 円 | 同上 |
| `balance_sheet.non_current_assets` | 固定資産 | 円 | 同上 |
| `balance_sheet.current_liabilities` | 流動負債 | 円 | 同上 |
| `balance_sheet.non_current_liabilities` | 固定負債 | 円 | 同上 |
| `balance_sheet.net_assets` | 純資産 | 円 | 同上 |
| `balance_sheet.accounting_standard` | 会計基準 | 文字列 | 同上 |
| `interest_bearing_debt.total` | 有利子負債合計 | 円 | `extract_interest_bearing_debt` |
| `interest_bearing_debt.method` | 取得方法 | 文字列 | 同上 |
| `cash_flow.cfo` | 営業CF | 円 | `extract_cash_flow` |
| `cash_flow.cfi` | 投資CF | 円 | 同上 |
| `interest_expense.current` | 支払利息 | 円 | `extract_interest_expense` |
| `employees.current` | 従業員数 | 人（整数） | `extract_employees` |
| `employees.method` | 取得方法 | 文字列 | 同上 |
| `tax_expense.pretax_income` | 税引前利益 | 円 | `extract_tax_expense` |
| `tax_expense.income_tax` | 法人税等 | 円 | 同上 |
| `tax_expense.effective_tax_rate` | 実効税率 | % | 同上 |
| `tangible_fixed_assets.total` | 有形固定資産合計 | 円 | `extract_tangible_fixed_assets` |
| `tangible_fixed_assets.buildings` | 建物及び構築物 | 円 | 同上 |
| `tangible_fixed_assets.land` | 土地 | 円 | 同上 |
| `tangible_fixed_assets.machinery` | 機械装置及び運搬具 | 円 | 同上 |
| `tangible_fixed_assets.tools` | 工具器具及び備品 | 円 | 同上 |
| `tangible_fixed_assets.construction_in_progress` | 建設仮勘定 | 円 | 同上 |
| `order_book.order_intake` | 受注高 | 円 | `extract_order_book` |
| `order_book.order_backlog` | 受注残高 | 円 | 同上 |

**金額はすべて円単位**（百万円ではない）。  
`effective_tax_rate` は比率（例: `0.254` = 25.4%）。`extract_tax_expense` が返す生の小数値をそのまま入力する。

許容誤差: 数値フィールドは相対誤差 1e-4（0.01%）以内で一致を確認。

## 対象企業（初期登録10社）

| ファイル | 企業 | 会計基準 |
|---|---|---|
| `4901_2025-03-31.json` | 富士フイルム | US-GAAP |
| `7751_2024-12-31.json` | キヤノン | US-GAAP/IFRS移行 |
| `8306_2025-03-31.json` | 三菱UFJ | J-GAAP（金融） |
| `8316_2025-03-31.json` | 三井住友 | J-GAAP（金融） |
| `6103_2025-03-31.json` | オークマ | J-GAAP（事業会社） |
| `6326_2024-12-31.json` | クボタ | IFRS |
| `2802_2025-03-31.json` | 味の素 | IFRS |
| `7269_2025-03-31.json` | スズキ | J-GAAP→IFRS移行 |
| `7422_2025-03-31.json` | 東和薬品 | J-GAAP（非連結） |
| `3490_2025-02-28.json` | AZplanning | J-GAAP |

## 値の入力手順

### 1. 実際の値を確認する

```bash
ticker waterfall 4901 --years 1 --format json | python3 -m json.tool
```

または XBRL 解析結果を直接確認する場合は、`SmokeTests.swift` の比較出力（DIFF 行）を参照する。

### 2. JSON に値を入力する

```json
{
  "income_statement": {
    "sales": 2951500000000,
    "operating_profit": 246700000000,
    "net_profit": 195000000000,
    "accounting_standard": "US-GAAP"
  }
}
```

- 確認できていないフィールドは `null` のまま残す
- 一部のフィールドだけ埋めても動作する

### 3. テストを実行する

```bash
# スモークテストを含む全テスト
swift test

# スモークテストのみ
swift test --filter SmokeTests
```

## 新しい企業を追加する

```json
{
  "_comment": "TODO: 実際の値を確認して null を埋める。金額は円単位。",
  "code": "7203",
  "name": "トヨタ自動車",
  "fy_end": "2025-03-31",
  "income_statement": {
    "sales": null,
    ...
  }
}
```

ファイル名は `{code}_{fy_end}.json` の形式で `smoke/smoke_expected/` に置くと自動でテストに追加される。

## `fy_end` がキャッシュにない場合

テスト実行時に以下のメッセージが出てスキップされる：

```
SKIPPED: 4901 2025-03-31 の書類がキャッシュに見つかりません
```

この場合、`BLT_EDINET_API_KEY` 環境変数を設定してテストを再実行する（不足分は自動ダウンロードされる）か、ファイル名の `fy_end` をキャッシュにある年度に合わせる。詳細は `docs/xbrl-parsing.md`「6. スモークテスト」を参照。
