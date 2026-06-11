BLUE TICKER は、EDINET API と財務省CSVを活用した日本株分析 Python CLI ツールです。

---

## 主な機能

- **銘柄検索**: 社名・証券コードから日本株を検索
- **財務サマリー**: EDINET XBRL/HTML から年次・半期の財務指標を取得
- **分析指標出力**: ROIC・ROE・事業利益前年差のウォーターフォール分解を出力
- **有価証券報告書抽出**: MD&A、事業等のリスク、経営方針を抽出
- **キャッシュ管理**: EDINET 年次インデックス、XBRL 展開、分析結果キャッシュを確認・準備・整理

## インストール

### Homebrew

```bash
brew tap sollahiro/blue-ticker
brew install blue-ticker
```

短縮 alias として `blt` も利用できます。

## 初期設定

EDINET APIキーを設定し、直近5年分のEDINET年次インデックスを準備します。

```bash
ticker config init
ticker cache status
ticker cache prepare --years 5
```

EDINET APIキーは [EDINET公式サイト](https://disclosure2.edinet-fsa.go.jp/) で取得してください。

## 使い方

### 銘柄検索

```bash
ticker search トヨタ
ticker search 7203 --format json
```

### 財務サマリー

```bash
ticker cache status
ticker summarize 7203
ticker summarize 7203 --years 6
ticker summarize 7203 --half
ticker summarize 7203 --no-cache
```

- `--years N`: 通期分析はデフォルト6年、半期分析はデフォルト3年
- `--half`: 上半期(H1)・下半期(H2)の半期推移を表示
- `--no-cache`: 分析結果キャッシュを使わず再計算。最新の財務省10年国債利回りをWACCへ反映したい場合にも使用
- `--include-debug-fields`: `--format json` で `MetricSources` や `IBDComponents` などの内部検証フィールドも出力

ROE、ROIC、営業CF、投資CF、フリーCF、有利子負債、WACC、営業利益増減分解などを確認できます。

### 分析指標（ウォーターフォール分解）

```bash
ticker analyze 7203
ticker analyze 7203 --years 6
ticker analyze 7203 --indicators roic roe
ticker analyze 7203 --format table
```

- `--indicators`: `business-profit`（事業利益前年差分解）、`roic`（NOPATマージン×投下資本回転率）、`roe`（デュポン3要因）から選択。省略時は全指標

### EDINET書類

```bash
ticker filings 7203
ticker filings 7203 --years 6
ticker filing 7203 --sections business_risks mda
ticker filing 7203 --doc-id S100XXXX --sections management_policy
```

`ticker filing` の `--sections` には以下を指定できます。

| section | 内容 |
|---|---|
| `business_risks` | 事業等のリスク |
| `mda` | 経営者による財政状態・経営成績の分析 |
| `management_policy` | 経営方針 |

### キャッシュ管理

```bash
ticker cache status
ticker cache prepare --years 5
ticker cache catchup --years 5
ticker cache refresh --years 5
ticker cache clean
ticker cache clean --execute --edinet-xbrl-days 30
```

- `status`: キャッシュ状態と次の推奨アクションを表示
- `prepare`: EDINET年次インデックスを事前準備
- `catchup`: 不足分だけ差分更新
- `refresh`: EDINET年次インデックスを作り直して更新
- `clean`: 不要なキャッシュを削除。`--execute` 未指定時は dry-run

日本株の分析やEDINET書類抽出の前には、API負荷を抑えるため `ticker cache status` を確認し、表示された `next action` を先に実行してください。

### セクター検索

```bash
ticker sector
ticker sector 輸送用機器
ticker sector 情報・通信業 --format json
```

## 開発

```bash
poetry install
poetry run pytest
poetry run pyright blue_ticker/
```

XBRL解析のタグ体系・コンテキスト仕様は `docs/xbrl-parsing.md` を参照してください。

## 免責事項

本ソフトウェアおよび提供される情報は、投資判断の参考として提供されるものであり、投資の勧誘を目的としたものではありません。最終的な投資判断は、必ず利用者ご自身の責任において行ってください。

---

Developed by [sollahiro](https://github.com/sollahiro)
