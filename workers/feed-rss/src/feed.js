// Cron 本体: Neon から listed 書類を読み、RSS XML を R2 へ書く。
// 失敗・0 件では既存オブジェクトを上書きしない（fail closed）。
// 接続文字列は絶対にログへ出さない。

import { buildRss } from "./rss.js";
import {
  FEED_DAYS,
  FEED_DOC_TYPES,
  FEED_ITEM_LIMIT,
  FEED_SQL,
  feedCutoffDateString,
  toFeedItem,
} from "./query.js";

export const CONTENT_TYPE = "application/rss+xml; charset=utf-8";
export const CACHE_CONTROL = "public, max-age=3600, s-maxage=3600";

export async function refreshFeed({ env, runQuery, now = new Date(), log = console }) {
  const bucket = env.FEED_BUCKET;
  const key = env.FEED_OBJECT_KEY;
  if (!bucket || !key) {
    log.error(JSON.stringify({ event: "feed_rss_skip", reason: "misconfigured" }));
    return { written: false, reason: "misconfigured" };
  }

  const cutoff = feedCutoffDateString(FEED_DAYS, now);
  let rows;
  try {
    rows = await runQuery(FEED_SQL, [FEED_DOC_TYPES, cutoff, FEED_ITEM_LIMIT]);
  } catch (error) {
    log.error(
      JSON.stringify({
        event: "feed_rss_skip",
        reason: "query_error",
        message: String(error?.message ?? error),
      })
    );
    return { written: false, reason: "query_error" };
  }

  const items = (Array.isArray(rows) ? rows : [])
    .map((row) => toFeedItem(row))
    .filter((item) => item !== null);
  if (items.length === 0) {
    log.error(
      JSON.stringify({ event: "feed_rss_skip", reason: "empty", cutoff })
    );
    return { written: false, reason: "empty" };
  }

  const xml = buildRss({
    items,
    now,
    feedUrl: env.FEED_PUBLIC_URL,
    companyUrlTemplate:
      env.COMPANY_URL_TEMPLATE ??
      "https://sollahiro.com/blue-ticker/companies/{code}",
  });

  try {
    await bucket.put(key, xml, {
      httpMetadata: { contentType: CONTENT_TYPE, cacheControl: CACHE_CONTROL },
    });
  } catch (error) {
    // put の失敗は cron の実行結果として失敗に見せるため再スローする。
    log.error(
      JSON.stringify({
        event: "feed_rss_put_error",
        message: String(error?.message ?? error),
      })
    );
    throw error;
  }

  log.log(JSON.stringify({ event: "feed_rss_written", count: items.length, cutoff }));
  return { written: true, count: items.length };
}
