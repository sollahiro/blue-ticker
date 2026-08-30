# BLUE TICKER

日本株の財務データ基盤。**Swift** 製の **REST API**（`blt-server`）が、EDINET 由来のデータを取り込み・提供します。近傍の製品面は REST と iOS。MCP は開発時（Cursor / 手元）のみ使い、製品としては伸ばしません。

## 主な機能

- 銘柄検索・業種一覧
- 年次の財務サマリ（Summary）と増減分析（Waterfall）
- 有価証券報告書のセクション本文（Filing）
- 事業別・地域別売上の内訳（Breakdown）
- 財務諸表本体と注記（Statement / Notes）

エンドポイント一覧は [`docs/architecture.md`](docs/architecture.md)。利用可能な API は `GET /v1/skills` でも取得できます。ドメイン契約は [`docs/statement.md`](docs/statement.md) / [`docs/breakdown.md`](docs/breakdown.md)。

## 使い方

本番ホストは Cloudflare Access 配下です。

| 用途 | ホスト | 認証 |
|---|---|---|
| curl / スクリプト / CI | `https://api.sollahiro.com` | Access Service Token |

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

認証の住み分け: [`docs/api-auth.md`](docs/api-auth.md)。発行手順: [`.agents/skills/deploy/SKILL.md`](.agents/skills/deploy/SKILL.md)  
互換ポリシー: [`docs/api-compatibility.md`](docs/api-compatibility.md)

### MCP（開発用）

Cursor と手元検証向けに `BltMcpServerCore` が REST と同じ能力をツールとして提供します。ChatGPT Apps 向けの公開は凍結しています。ホストや OAuth の配線は deploy skill。

## ドキュメント

- [`docs/architecture.md`](docs/architecture.md) — 構成・提供面・エンドポイント
- [`AGENTS.md`](AGENTS.md) — エージェント向け常時ガードレール
- [`.agents/skills/deploy/SKILL.md`](.agents/skills/deploy/SKILL.md) — Fly / Tunnel / Access
- [`.agents/skills/production-ingest/SKILL.md`](.agents/skills/production-ingest/SKILL.md) — Neon write

## 免責事項

本ソフトウェアおよび提供される情報は、投資判断の参考として提供されるものであり、投資の勧誘を目的としたものではありません。最終的な投資判断は、必ず利用者ご自身の責任において行ってください。

---

Developed by [sollahiro](https://github.com/sollahiro)
