// 業種ベンチマーク（比較タブ）の静的 JSON 生成 Worker。Cron 専用（公開ルートなし）。
// Neon は読み取り専用ロールの接続文字列（secret BENCHMARK_DATABASE_URL）で HTTP 経由。
// 生成物は R2（binding BENCHMARK_BUCKET）へ置き、配信は R2 カスタムドメイン側が担う。

import { neon } from "@neondatabase/serverless";
import { refreshBenchmarks } from "./benchmark.js";

export default {
  async scheduled(controller, env, ctx) {
    if (!env.BENCHMARK_DATABASE_URL) {
      console.error(JSON.stringify({ event: "benchmark_static_skip", reason: "misconfigured" }));
      return;
    }
    const sql = neon(env.BENCHMARK_DATABASE_URL);
    const runQuery = (text, params) => sql.query(text, params);
    await refreshBenchmarks({ env, runQuery });
  },

  // 公開ルートは持たない。JSON 本体は R2 カスタムドメインから配信する。
  async fetch() {
    return new Response("Not Found", { status: 404 });
  },
};
