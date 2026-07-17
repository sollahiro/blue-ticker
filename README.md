BLUE TICKER は、EDINET API と財務省CSVを活用した日本株分析 CLI ツールです（Swift 製・単一バイナリ）。

---

## 主な機能

- **銘柄検索**: 社名・証券コードから日本株を検索
- **財務分析**: 年次・半期の財務指標を取得
- **有価証券報告書抽出**: MD&A、事業等のリスク、経営方針を抽出

## インストール

### Homebrew

```bash
brew tap sollahiro/blue-ticker
brew install blue-ticker
```

短縮 alias として `blt` も利用できます。

## 初期設定

`ticker` は blt-server（REST API）へ接続して動作します。サーバーが Cloudflare Access で保護されている場合は SSO ログインを行ってください。

```bash
ticker login          # Cloudflare Access SSO ログイン
ticker config show     # 接続先・ログイン状態を確認
```

- サーバーURLの既定値は組み込み済みです。別サーバーに接続する場合は `ticker config set --server-url <url>` または環境変数 `BLT_SERVER_URL` で上書きしてください（環境変数が優先されます）。
- 自分で blt-server を立てる手順は [`docs/deploy.md`](docs/deploy.md) を参照してください。

## 使い方

### 銘柄検索

```bash
ticker search トヨタ
ticker search 7203 --json
```

### 財務分析

```bash
ticker summarize 7203          # 主要財務指標の網羅表（水準値）
ticker analyze 7203            # 増減分析（前年差分解）
ticker analyze 7203 --half
```

- `summarize`: 売上・利益・BS・CF など主要指標の水準値を年度横断で一覧表示（直近5年分）
- `analyze`: 5つの増減分析を表示（直近5年分）
  - ① 事業利益増減（売上差・粗利率差・販管費差の3要因）
  - ② ROIC増減（NOPATマージン差・投下資本回転率差）
  - ③ ROE増減（純利益率差・総資産回転率差・財務レバレッジ差）
  - ④ ネットキャッシュ増減（現金増減・有利子負債増減）
  - ⑤ 運転資本・CCC増減（売掛金・棚卸資産・買掛金の前年差、DSO/DIO/DPO/CCC）
- `--half`: 上半期(H1)・下半期(H2)の半期推移を表示（前年同期差）
- `--json`: JSON 形式で出力

### EDINET書類

```bash
ticker filings 7203
ticker filings 7203 --years 6
ticker filing 7203 --sections business_risks mda
ticker filing 7203 --doc-id S100XXXX --sections segments geography
```

`ticker filing` の `--sections` には以下を指定できます。

| section | 内容 |
|---|---|
| `business_risks` | 事業等のリスク |
| `mda` | 経営者による財政状態・経営成績の分析 |
| `capex_overview` | 設備投資等の概要 |
| `major_facilities` | 主要な設備の状況 |
| `facility_plans` | 設備の新設・除却等の計画 |
| `research_and_development` | 研究開発活動 |
| `segments` | 報告セグメント別情報（Markdown 表または dimension 付きファクト） |
| `geography` | 地域別情報（同上） |

### 業種一覧

東証33業種と各業種の銘柄数を一覧表示します。

```bash
ticker sector
ticker sector --json
```

## 開発者向け

ソースからのビルド・テスト、EDINET を直接叩くローカル解析用の開発専用 CLI（`TickerDev`、配布しない）については [`CLAUDE.md`](CLAUDE.md) を参照してください。

## 免責事項

本ソフトウェアおよび提供される情報は、投資判断の参考として提供されるものであり、投資の勧誘を目的としたものではありません。最終的な投資判断は、必ず利用者ご自身の責任において行ってください。

---

Developed by [sollahiro](https://github.com/sollahiro)
