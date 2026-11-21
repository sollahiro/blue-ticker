# Benchmark Static Worker

比較タブの業種ベンチマーク（現状 `bank` のみ）を、`GET /v1/benchmark/{group}` と同じ JSON の静的ファイルとして公開する。
Cron が 1 日 1 回 Neon を読み、JSON を R2 に書き出す。配信は R2 カスタムドメイン `feed.sollahiro.com`（feed-rss と同じバケット）が担い、
この Worker 自体は公開ルートを持たない。iOS は `BenchmarkStaticStore` が端末に保存して条件付き GET（ETag）で再検証し、
取れないときだけ REST にフォールバックする。

- 出力: `https://feed.sollahiro.com/blue-ticker/benchmark/{group}.json`（`Cache-Control: public, max-age=3600`）
- cron `30 10 * * *`（UTC）= 毎日 19:30 JST（blt-sync 18:00、feed-rss 19:15 の後）
- 抽出条件は Swift の `loadStoredIndustryBenchmark` と同じ: 現行 `cache_version`、会社開示府令・上場コードの書類だけから会社ごとに最新 1 件、
  最新が対象外・要レビュー・値なしならその会社は出さない、KPI は連結 → 提出会社（子会社は出さない）
- 社名は `edinet_documents.filer_name` を `displayFilerName` で整える（feed-rss と同じ関数を共有）。東証 33 業種は DB に無いので `sector` は空文字（比較タブは使わない）
- `icon_url` は `company_icons`（無い会社は `null`）。アイコン取得に失敗しても本体は書く
- fail closed: クエリ失敗・公開できる会社が 0 件のときは R2 を上書きしない

## デプロイ（初回）

1. `cd workers/benchmark-static && npm ci`
2. `npx wrangler secret put BENCHMARK_DATABASE_URL`（Neon の読み取り専用ロール。feed-rss の `FEED_DATABASE_URL` と同じ値。書き込み URL は入れない）
3. `npx wrangler deploy`
4. 初回は手動で `npx wrangler triggers`／ダッシュボードから cron を実行して `bank.json` を生成し、`curl -I` で配信を確認する
