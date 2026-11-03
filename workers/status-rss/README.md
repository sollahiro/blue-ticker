# Status RSS Worker

取り込み（ingest）の状況を RSS 2.0 で公開する。ステージごとの件数・最新の版の割合・直近 24 時間に更新された行数・最終更新を 1 日 1 件の記事にする。
Cron が 1 日 1 回 Neon を読み、RSS XML を R2 の静的オブジェクトとして書き出す。配信は R2 カスタムドメイン `feed.sollahiro.com` が担い、この Worker 自体は公開ルートを持たない（`workers/feed-rss` と同じ作り）。

## スケジュール

- cron `30 10 * * *`（UTC）= 毎日 19:30 JST。18:00 JST の blt-sync と feed-rss（19:15）の後に回す。

## 集計するステージ

`src/status.js` の `STAGES`（テーブル名は固定の許可リスト）:

| 表示 | テーブル |
|---|---|
| 財務サマリー | `company_financials` |
| 財務諸表 | `company_statements` |
| 有報の文章 | `company_filing_sections` |
| 内訳 | `company_breakdowns` |
| 業種KPI | `industry_kpi_facts` |

各テーブルを `cache_version` で GROUP BY し、行数・直近 24 時間に更新された行数・最終更新を読む。「最新の版」は版名の末尾の数字が最大のもの（`fin-v24` なら 24）。銘柄コードの一覧は出さない（集計件数だけ）。

## 遅延の判定

最終更新が 36 時間より古い、または行が 1 件も無いステージは「遅延」。1 つでもあれば記事の題が `【遅延】取り込み状況 YYYY-MM-DD（ステージ名）` になる。

## 記事

- 1 日 1 件。`guid` = `ingest-status-YYYY-MM-DD`（JST の日付）。同じ日に再実行すると同じ記事を更新する
- 本文はプレーンテキスト（ステージごとのブロック）

## fail closed

- どれか 1 ステージでも集計に失敗したら R2 を上書きしない（既存オブジェクトを残す）
- `FEED_BUCKET` / `FEED_OBJECT_KEY` / `FEED_PUBLIC_URL` / `FEED_DATABASE_URL` 未設定は `misconfigured` で skip
- R2 `put` の失敗だけは再スローして cron 実行を失敗として見せる
- ログは構造化 JSON（`status_rss_skip` / `status_rss_written` / `status_rss_put_error`）。接続文字列は出さない

## 公開 URL

- `https://feed.sollahiro.com/blue-ticker/ingest-status.xml`

## デプロイ

`workers/feed-rss` と同じく手元から出す。

```
cd workers/status-rss
npm install
npx wrangler@4 secret put FEED_DATABASE_URL   # 読み取り専用ロール（feed-rss と同じ値でよい）
npx wrangler@4 deploy
```

## セキュリティ

- `FEED_DATABASE_URL` は読み取り専用ロール。書き込み URL（`BLT_NEON_WRITE_DATABASE_URL` 系）は絶対に入れない
- fetch ハンドラは常に 404。公開ルートなし（`workers_dev: false`、routes なし）
- バケット `blt-public-feed` はカスタムドメインで丸ごと公開になるので、公開フィード以外のオブジェクトを置かない
