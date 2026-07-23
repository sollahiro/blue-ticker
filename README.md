# BLUE TICKER

日本株の財務データ基盤（Swift）。**blt-server** が EDINET 由来のデータを取り込み、**REST API** と **MCP** で提供します。配布 CLI（`ticker` / Homebrew）は廃止しました。

## 主な機能

- 銘柄検索・業種一覧
- 年次・半期の財務サマリ（Summarize）と増減分析（Analyze）
- 有価証券報告書のセクション本文（Filing）
- 事業別・地域別売上の内訳（Breakdown・整備中）

機能の無料/有料方針は [`docs/feature-tiers.md`](docs/feature-tiers.md)。

## 使い方（本番 REST）

本番ホストは Cloudflare Access 配下です。機械アクセスは **Service Token**（ブラウザ不要）。

```bash
export CF_ACCESS_CLIENT_ID='....access'
export CF_ACCESS_CLIENT_SECRET='...'

curl -s "https://api.sollahiro.com/v1/companies/7203/financials?years=1" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  | jq '.schema_version, .code'
```

認証の住み分け・発行手順: [`docs/api-auth.md`](docs/api-auth.md) / [`docs/deploy.md`](docs/deploy.md)  
互換ポリシー: [`docs/api-compatibility.md`](docs/api-compatibility.md)

ユーザー介在のブラウザ SSO / MCP（`mcp.sollahiro.com` の Managed OAuth）も利用できます。

## サーバー運用

`blt-server` のデプロイ・sync / ingest・Neon 接続は [`docs/deploy.md`](docs/deploy.md) / [`docs/operations.md`](docs/operations.md)。

## 開発者向け

```bash
swift build                     # blt-server / TickerDev を生成
swift test
swift run TickerDev analyze 7203   # 開発用ローカル解析（配布しない。要 BLT_EDINET_API_KEY）
```

構成の詳細は [`CLAUDE.md`](CLAUDE.md) / [`docs/architecture.md`](docs/architecture.md)。

## 免責事項

本ソフトウェアおよび提供される情報は、投資判断の参考として提供されるものであり、投資の勧誘を目的としたものではありません。最終的な投資判断は、必ず利用者ご自身の責任において行ってください。

---

Developed by [sollahiro](https://github.com/sollahiro)
