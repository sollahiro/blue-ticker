# Feed Trend Worker

匿名の検索・ツールヒットを Workers Analytics Engine に蓄積し、ランキングを返す。
`blt-server` は `BLT_FEED_TREND_URL` + `BLT_FEED_TREND_TOKEN` でここに fire-and-forget POST する。

**この Worker を `api.*` / `mcp.*` の前段に置かない。** Tunnel + Access はそのまま。カウンター専用の別ホスト。

## エンドポイント

| パス | 用途 |
|---|---|
| `POST /ingest` | origin からの 1 イベント。Bearer。204 |
| `GET /trend?days=7&limit=50&code=` | ランキング。Bearer。空は `items=[]` |

書き込みは binding（`writeDataPoint`）。読み取りは Account Analytics Engine SQL API。

## デプロイ

```bash
cd workers/feed-trend
npx wrangler@4 deploy
npx wrangler@4 secret put TOKEN          # origin の BLT_FEED_TREND_TOKEN と同じ値
npx wrangler@4 secret put ACCOUNT_ID     # Cloudflare account id
npx wrangler@4 secret put AE_SQL_TOKEN   # Account Analytics:Read
```

`TOKEN` の代わりに `INGEST_TOKEN` / `QUERY_TOKEN` を分けることもできる。
デプロイ後の URL を Fly 等の origin に載せる:

```bash
fly secrets set BLT_FEED_TREND_URL='https://blt-feed-trend.<account>.workers.dev' \
  BLT_FEED_TREND_TOKEN='...'
```

未設定の origin は emit しない。`GET /v1/feed/trend` は 503。

## 検証

```bash
node --test src/validate.test.js
```
