// Cron 本体: Neon から listed 書類を読み、RSS XML を R2 へ書く。
// 失敗・0 件では既存オブジェクトを上書きしない（fail closed）。
// 接続文字列は絶対にログへ出さない。

import { buildRss } from "./rss.js";
import {
  FEED_DAYS,
  FEED_DOC_TYPES,
  FEED_ITEM_LIMIT,
  FEED_SQL,
  ICON_SQL,
  feedCutoffDateString,
  iconPublicUrl,
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

  const iconCount = await attachIcons({ items, env, runQuery, log });

  const xml = buildRss({ items, now, feedUrl: env.FEED_PUBLIC_URL });

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

  log.log(
    JSON.stringify({ event: "feed_rss_written", count: items.length, icons: iconCount, cutoff })
  );
  return { written: true, count: items.length };
}

// items に icon_url を足す（アイコンのない会社は付けない）。戻り値は付けた件数。
// アイコンは付加情報なので、ベース URL 未設定・クエリ失敗でもフィード本体は書く（アイコンなし）。
async function attachIcons({ items, env, runQuery, log }) {
  const baseUrl = env.FEED_ICON_BASE_URL;
  if (!baseUrl) {
    log.error(JSON.stringify({ event: "feed_rss_icons_skip", reason: "misconfigured" }));
    return 0;
  }
  const codes = [...new Set(items.map((item) => item.code))];
  let rows;
  try {
    rows = await runQuery(ICON_SQL, [codes]);
  } catch (error) {
    log.error(
      JSON.stringify({
        event: "feed_rss_icons_skip",
        reason: "query_error",
        message: String(error?.message ?? error),
      })
    );
    return 0;
  }
  const keys = new Map();
  for (const row of Array.isArray(rows) ? rows : []) {
    if (typeof row.code === "string" && typeof row.r2_object_key === "string" && row.r2_object_key) {
      keys.set(row.code, row.r2_object_key);
    }
  }
  let count = 0;
  for (const item of items) {
    const key = keys.get(item.code);
    if (key) {
      item.icon_url = iconPublicUrl(baseUrl, key);
      count += 1;
    }
  }
  return count;
}
