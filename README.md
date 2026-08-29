# BLUE TICKER

日本株の財務データ基盤。**Swift** 製の **REST API** と、Apps in ChatGPT 向け **MCP**（`blt-server`）が、EDINET 由来のデータを取り込み・提供します。

## 主な機能

- 銘柄検索・業種一覧
- 年次の財務サマリ（Summary）と増減分析（Waterfall）
- 有価証券報告書のセクション本文（Filing）
- 事業別・地域別売上の内訳（Breakdown）

機能一覧・提供面は [`docs/feature-tiers.md`](docs/feature-tiers.md)。利用可能な API / ツールは `GET /v1/skills`（MCP では `tools/list`）でも取得できます。

## 使い方

本番ホストは Cloudflare Access 配下です。

| 用途 | ホスト | 認証 |
|---|---|---|
| curl / スクリプト / CI | `https://api.sollahiro.com` | Access Service Token |
| Apps in ChatGPT | `https://mcp.sollahiro.com` | Managed OAuth（ブラウザで認可） |

### REST API

機械アクセスは **Service Token**（ブラウザ不要）。ヘッダーに Client ID / Secret を付けて呼び出します。

```bash
export CF_ACCESS_CLIENT_ID='....access'
export CF_ACCESS_CLIENT_SECRET='...'

curl -s "https://api.sollahiro.com/v1/companies/7203/financials?years=1" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  | jq '.schema_version, .code'
```

よく使うエンドポイントの例:

| メソッド | パス | 内容 |
|---|---|---|
| `GET` | `/v1/companies?q=` | 企業検索 |
| `GET` | `/v1/companies/{code}/financials` | 年次財務サマリ |
| `GET` | `/v1/companies/{code}/waterfall` | 年次増減分析 |
| `GET` | `/v1/companies/{code}/filings` | 提出書類一覧 |
| `GET` | `/v1/skills` | 能力カタログ |

認証の発行手順・住み分け: [`docs/api-auth.md`](docs/api-auth.md) / [`docs/deploy.md`](docs/deploy.md)  
互換ポリシー: [`docs/api-compatibility.md`](docs/api-compatibility.md)

### MCP（Apps in ChatGPT）

ChatGPT の Apps / コネクタ向けに **`https://mcp.sollahiro.com`** を登録し、ブラウザで OAuth 認可します。接続後は REST と同じ能力をツールとして呼べます（例: `search_companies`・`get_financial_summary`・`get_waterfall`）。**当面この面専用**です（他 MCP クライアントはサポート対象外）。

## ドキュメント

デプロイ・セルフホスト・開発検証（`swift test` / 使い捨て ingest + `/v1`）などは [`docs/`](docs/) を参照してください。

- [`docs/architecture.md`](docs/architecture.md) — 構成
- [`docs/feature-tiers.md`](docs/feature-tiers.md) — 機能マトリクス
- [`docs/deploy.md`](docs/deploy.md) / [`docs/operations.md`](docs/operations.md) — 運用
- [`AGENTS.md`](AGENTS.md) — エージェント向け常時ガードレール

## 免責事項

本ソフトウェアおよび提供される情報は、投資判断の参考として提供されるものであり、投資の勧誘を目的としたものではありません。最終的な投資判断は、必ず利用者ご自身の責任において行ってください。

---

Developed by [sollahiro](https://github.com/sollahiro)
