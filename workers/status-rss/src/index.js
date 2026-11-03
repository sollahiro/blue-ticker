// 取り込み状況の RSS 生成 Worker。Cron 専用（公開ルートなし）。
// Neon は読み取り専用ロールの接続文字列（secret FEED_DATABASE_URL）で HTTP 経由。
// 生成物は R2（binding FEED_BUCKET）へ置き、配信は R2 カスタムドメイン側が担う。

import { neon } from "@neondatabase/serverless";
import { refreshStatus } from "./refresh.js";

export default {
  async scheduled(controller, env, ctx) {
    if (!env.FEED_DATABASE_URL) {
      console.error(JSON.stringify({ event: "status_rss_skip", reason: "misconfigured" }));
      return;
    }
    const sql = neon(env.FEED_DATABASE_URL);
    const runQuery = (text, params) => sql.query(text, params);
    await refreshStatus({ env, runQuery });
  },

  // 公開ルートは持たない。フィード本体は R2 カスタムドメインから配信する。
  async fetch() {
    return new Response("Not Found", { status: 404 });
  },
};
