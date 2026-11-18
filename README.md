# 有報LAB API

日本株の財務データ基盤。外向きの製品名は **有報LAB**（API・MCP も有報LAB）。内部の抽出・解析ロジックは **BLT**（Business Line Terminal）と呼び、`blt-*` の名前はこの略です。**Swift** 製の **REST API**（`blt-server`）が、EDINET 由来のデータを取り込み・提供します。製品面は REST・iOS と、HAPIS 経由の公開 MCP コネクタ（Claude を先に、次に ChatGPT）です。

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
| ブラウザ | `https://api.yuholab.com` | Access SSO / OTP |

### REST API

開発ではローカルの `blt-server`（`127.0.0.1`、無認証）を叩きます。本番オリジンの Access Service Token は HAPIS ゲートウェイ専用で、人・agents 用のトークンは発行しません。本番経路の確認はスモークトークンを使います（`.agents/skills/deploy/SKILL.md`「本番 REST の確認」）。

```bash
curl -s "http://127.0.0.1:3000/v1/companies/7203/financials?years=1" | jq '.schema_version, .code'
```

よく使うエンドポイントの例:

| メソッド | パス | 内容 |
|---|---|---|
| `GET` | `/v1/companies?q=` | 企業検索 |
| `GET` | `/v1/companies/{code}/financials` | 年次財務サマリ（`?fields=sales,operating_profit` でキーを射影） |
| `GET` | `/v1/companies/{code}/waterfall` | 年次増減分析 |
| `GET` | `/v1/companies/{code}/filings` | 提出書類一覧 |
| `GET` | `/v1/skills` | 能力カタログ |

認証の住み分け: [`docs/api-auth.md`](docs/api-auth.md)。発行手順: [`.agents/skills/deploy/SKILL.md`](.agents/skills/deploy/SKILL.md)  
互換ポリシー: [`docs/api-compatibility.md`](docs/api-compatibility.md)

### MCP

公開コネクタは HAPIS（[sollahiro/hapis](https://github.com/sollahiro/hapis) の `mcp/`）が提供し、HAPIS ゲートウェイ経由で REST を呼びます。出すツールと引数の範囲は [`hapis/catalog.json`](hapis/catalog.json) が正本で、`scripts/hapis-sync-catalog.sh` で HAPIS へ同期します（[`hapis/README.md`](hapis/README.md)）。

## ドキュメント

- [`docs/architecture.md`](docs/architecture.md) — 構成・提供面・エンドポイント
- [`AGENTS.md`](AGENTS.md) — エージェント向け常時ガードレール
- [`.agents/skills/deploy/SKILL.md`](.agents/skills/deploy/SKILL.md) — Fly / Tunnel / Access
- [`.agents/skills/production-ingest/SKILL.md`](.agents/skills/production-ingest/SKILL.md) — 本番取り込み運用

## 免責事項

本ソフトウェアおよび提供される情報は、投資判断の参考として提供されるものであり、投資の勧誘を目的としたものではありません。最終的な投資判断は、必ず利用者ご自身の責任において行ってください。

---

Developed by [sollahiro](https://github.com/sollahiro)
