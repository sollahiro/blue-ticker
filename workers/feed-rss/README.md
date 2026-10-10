# Feed RSS Worker

EDINET に提出された上場会社の開示書類（ヘッドラインのみ）を RSS 2.0 で公開する。
Cron が 1 日 1 回 Neon を読み、RSS XML を R2 の静的オブジェクトとして書き出す。
配信は R2 カスタムドメイン `feed.sollahiro.com` が担い、この Worker 自体は公開ルートを持たない。

## スケジュール

- cron `15 10 * * *`（UTC）= 毎日 19:15 JST。18:00 JST の blt-sync 完了後に回す。

## 抽出条件（`/v1/feed/updates` と同じ listed 選択）

- 書類種別: `120` / `130` / `140` / `160`（`Api.feedAllowedDocTypes` と同じ）
- 期間: 直近 7 暦日（UTC、今日を含む。`feedInclusiveCutoffDateString(days: 7)` と同じ下限）
- 上限: 200 件
- 上場のみ: 府令 `010`（会社開示）・5 桁 `sec_code` 末尾 `0`・`00000` 以外
- 並び順: `submit_date_time` 降順、`doc_id` 降順

`/v1/feed/updates` と違い、同日過多の安定サンプリング（`feedSelectItems`）は行わない。
RSS は窓内を時系列で全部出すフィードなので、同日の絞り込みは不要。

## item マッピング

- `title` = `{filer_name}（{code}） {doc_type_label}`（ラベルは Swift `docTypeLabel` と同じ。未知コードは `doc_description`）
- `link` = EDINET 提出書類内容照会画面 `https://disclosure2.edinet-fsa.go.jp/WZEK0040.aspx?{doc_id}`（公開ビューア。API キー不要）
- `guid`（isPermaLink="false"）= `doc_id`
- `pubDate` = `submit_date_time`（JST 壁時計 → RFC 822 `+0900`）
- `category` = 2 つ: `<category domain="edinet:doc_type">{doc_type}</category>` と `<category domain="jp:sec_code">{code}</category>`
- `description` = `決算期: {fy_end} / 証券コード: {code}`（`fy_end` は期末日の先頭 7 文字）

会社アイコンは意図的に載せない（アイコンは認証越しの配信のみ）。

チャネル `<link>` は `https://sollahiro.com/blue-ticker/`（workers/legal が配信するアプリ紹介ページ）。

## Swift とのパリティ

抽出条件・item マッピングは REST `/v1/feed/updates` の Swift 実装と揃える。対応関係:

- listed 抽出 SQL: `feedListedQuery` + `loadFeedListedRows`（Sources/BltServerCore/FeedServe.swift）
- item 組み立て: `feedFilingItem`、`listedTickerCode(fromSecCode:)`、`feedInclusiveCutoffDateString`（Sources/BlueTicker/Server/FeedAssembly.swift）
- ラベル・辞書形: `filingDict`、`docTypeLabel`（Sources/BlueTicker/Server/BltServerFacade.swift）
- 対象書類種別・府令: `Api.documentSyncDocTypes` / `feedAllowedDocTypes`、`Api.ordinanceCompanyDisclosure`（Sources/BlueTicker/Constants/Api.swift）

共有 fixture `test-fixtures/feed-parity.json` を正本に、両側のテストでドリフトを検知する:

- JS: `src/parity.test.js`（`node --test src/*.test.js` に含まれる。Swift ソースも直接パースして定数・ラベル・生 SQL を照合する）
- Swift: `SwiftTests/BlueTickerTests/FeedRssParityFixtureTests.swift`

Swift 側のラベル・対象種別・listed 判定を変えたら fixture も一緒に更新すること。

## fail closed

- クエリ失敗・0 件（全件非上場含む）では R2 を上書きしない（既存オブジェクトを残す）
- `FEED_BUCKET` / `FEED_OBJECT_KEY` / `FEED_DATABASE_URL` 未設定は `misconfigured` で skip
- R2 `put` の失敗だけは再スローして cron 実行を失敗として見せる
- ログは構造化 JSON（`feed_rss_skip` / `feed_rss_written` / `feed_rss_put_error`）。接続文字列は出さない

## R2 メタデータ

- `Content-Type: application/rss+xml; charset=utf-8`
- `Cache-Control: public, max-age=3600, s-maxage=3600`

## 公開 URL

- `https://feed.sollahiro.com/blue-ticker/edinet-filings.xml`

## セキュリティ

- `FEED_DATABASE_URL` は読み取り専用ロール。書き込み URL（`BLT_NEON_WRITE_DATABASE_URL` 系）は絶対に入れない
- fetch ハンドラは常に 404。公開ルートなし（`workers_dev: false`、routes なし）
- origin（api.* / mcp.*）はロックしたまま。`BLT_ALLOW_UNAUTHENTICATED` は使わない
- この Worker を api.* / mcp.* の前段に置かない
- バケット `blt-public-feed` はカスタムドメインで丸ごと公開になるので、公開フィード以外のオブジェクトを置かない。`r2.dev` の公開 URL は有効化しない
- R2 カスタムドメインはクエリ文字列を解釈しない（キーはパスだけ）。オリジンへ抜ける経路はない

## 初回セットアップ（人間が実行）

1. R2 バケット作成:

   ```bash
   npx wrangler@4 r2 bucket create blt-public-feed
   ```

2. カスタムドメイン `feed.sollahiro.com` をバケットへ接続（ダッシュボード: R2 → バケット → Settings → Custom Domains）

3. Neon に読み取り専用ロールを作る:

   ```sql
   CREATE ROLE blt_feed_reader LOGIN PASSWORD '...';
   GRANT CONNECT ON DATABASE <dbname> TO blt_feed_reader;
   GRANT USAGE ON SCHEMA public TO blt_feed_reader;
   GRANT SELECT ON public.edinet_documents TO blt_feed_reader;
   ALTER ROLE blt_feed_reader SET default_transaction_read_only = on;
   ```

4. secret を入れてデプロイ:

   ```bash
   cd workers/feed-rss
   npx wrangler@4 secret put FEED_DATABASE_URL   # blt_feed_reader の接続文字列
   npx wrangler@4 deploy
   ```

## 検証

```bash
node --test src/*.test.js
```
