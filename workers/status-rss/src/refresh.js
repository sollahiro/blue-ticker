// Cron 本体: 各ステージを集計して RSS を R2 へ書く。
// どれか 1 ステージでも集計に失敗したら R2 を上書きしない（fail closed）。
// 接続文字列は絶対にログへ出さない。

import { STAGES, buildStatusRss, stageSql, summarizeStage } from "./status.js";

export const CONTENT_TYPE = "application/rss+xml; charset=utf-8";
export const CACHE_CONTROL = "public, max-age=3600, s-maxage=3600";

export async function refreshStatus({ env, runQuery, now = new Date(), log = console }) {
  const bucket = env.FEED_BUCKET;
  const key = env.FEED_OBJECT_KEY;
  if (!bucket || !key || !env.FEED_PUBLIC_URL) {
    log.error(JSON.stringify({ event: "status_rss_skip", reason: "misconfigured" }));
    return { written: false, reason: "misconfigured" };
  }

  const summaries = [];
  for (const stage of STAGES) {
    try {
      const rows = await runQuery(stageSql(stage.table), []);
      summaries.push(summarizeStage(stage, rows, now));
    } catch (error) {
      log.error(
        JSON.stringify({
          event: "status_rss_skip",
          reason: "query_error",
          stage: stage.key,
          message: String(error?.message ?? error),
        })
      );
      return { written: false, reason: "query_error" };
    }
  }

  const xml = buildStatusRss({ summaries, now, feedUrl: env.FEED_PUBLIC_URL });
  try {
    await bucket.put(key, xml, {
      httpMetadata: { contentType: CONTENT_TYPE, cacheControl: CACHE_CONTROL },
    });
  } catch (error) {
    // put の失敗は cron の実行結果として失敗に見せるため再スローする。
    log.error(
      JSON.stringify({ event: "status_rss_put_error", message: String(error?.message ?? error) })
    );
    throw error;
  }
  const stale = summaries.filter((s) => s.stale).map((s) => s.key);
  log.log(JSON.stringify({ event: "status_rss_written", stages: summaries.length, stale }));
  return { written: true, stale };
}
