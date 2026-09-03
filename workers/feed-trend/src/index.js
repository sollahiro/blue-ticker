// 匿名 Feed Trend カウンター。origin からの fire-and-forget ingest を Analytics Engine に書き、
// GET /trend で SQL API からランキングを返す。IP / ユーザー / cookie は受け取らない。

import { parseIngestBody, parseTrendQuery, sqlString, bearerOk } from "./validate.js";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/ingest") {
      if (request.method !== "POST") {
        return json({ error: "method not allowed" }, 405);
      }
      return ingest(request, env);
    }
    if (url.pathname === "/trend") {
      if (request.method !== "GET") {
        return json({ error: "method not allowed" }, 405);
      }
      return trend(request, env, url.searchParams);
    }
    return json({ error: "not found" }, 404);
  },
};

async function ingest(request, env) {
  const token = env.INGEST_TOKEN || env.TOKEN;
  if (!bearerOk(request.headers.get("Authorization"), token)) {
    return json({ error: "unauthorized" }, 401);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }
  const parsed = parseIngestBody(body);
  if (parsed.error) {
    return json({ error: parsed.error }, 400);
  }
  const event = parsed.event;
  // writeDataPoint は非ブロッキング。await しない。
  env.TREND.writeDataPoint({
    blobs: [event.surface, event.tool, event.code, event.q],
    doubles: [1],
    indexes: [event.code || "none"],
  });
  return new Response(null, { status: 204 });
}

async function trend(request, env, searchParams) {
  const token = env.QUERY_TOKEN || env.TOKEN;
  if (!bearerOk(request.headers.get("Authorization"), token)) {
    return json({ error: "unauthorized" }, 401);
  }
  const parsed = parseTrendQuery(searchParams);
  if (parsed.error) {
    return json({ error: parsed.error }, 400);
  }
  const accountId = env.ACCOUNT_ID || env.CF_ACCOUNT_ID;
  const sqlToken = env.AE_SQL_TOKEN;
  if (!accountId || !sqlToken) {
    return json({ error: "trend query is not configured" }, 503);
  }

  const since = `timestamp >= NOW() - INTERVAL '${parsed.days}' DAY`;
  const codeFilter = parsed.code
    ? ` AND blob3 = ${sqlString(parsed.code)}`
    : " AND blob3 != ''";

  try {
    const items = await runSql(
      accountId,
      sqlToken,
      `SELECT blob3 AS code, SUM(_sample_interval) AS count
       FROM feed_trend
       WHERE ${since}${codeFilter}
       GROUP BY code
       ORDER BY count DESC
       LIMIT ${parsed.limit}`
    );

    const payload = {
      days: parsed.days,
      items: items.map((row) => ({
        code: String(row.code ?? ""),
        count: toCount(row.count),
      })),
    };

    if (parsed.code) {
      const [byTool, bySurface, byQuery] = await Promise.all([
        runSql(
          accountId,
          sqlToken,
          `SELECT blob2 AS tool, SUM(_sample_interval) AS count
           FROM feed_trend
           WHERE ${since} AND blob3 = ${sqlString(parsed.code)}
           GROUP BY tool
           ORDER BY count DESC
           LIMIT ${parsed.limit}`
        ),
        runSql(
          accountId,
          sqlToken,
          `SELECT blob1 AS surface, SUM(_sample_interval) AS count
           FROM feed_trend
           WHERE ${since} AND blob3 = ${sqlString(parsed.code)}
           GROUP BY surface
           ORDER BY count DESC
           LIMIT ${parsed.limit}`
        ),
        runSql(
          accountId,
          sqlToken,
          `SELECT blob4 AS q, SUM(_sample_interval) AS count
           FROM feed_trend
           WHERE ${since} AND blob3 = ${sqlString(parsed.code)} AND blob4 != ''
           GROUP BY q
           ORDER BY count DESC
           LIMIT ${parsed.limit}`
        ),
      ]);
      payload.by_tool = byTool.map((row) => ({
        tool: String(row.tool ?? ""),
        count: toCount(row.count),
      }));
      payload.by_surface = bySurface.map((row) => ({
        surface: String(row.surface ?? ""),
        count: toCount(row.count),
      }));
      payload.by_query = byQuery.map((row) => ({
        q: String(row.q ?? ""),
        count: toCount(row.count),
      }));
    }

    return json(payload, 200);
  } catch {
    return json({ error: "trend query failed" }, 503);
  }
}

async function runSql(accountId, sqlToken, sql) {
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${accountId}/analytics_engine/sql`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${sqlToken}`,
        "Content-Type": "text/plain",
      },
      body: sql,
    }
  );
  if (!response.ok) {
    throw new Error(`sql ${response.status}`);
  }
  const payload = await response.json();
  if (Array.isArray(payload?.data)) return payload.data;
  if (Array.isArray(payload?.result?.data)) return payload.result.data;
  return [];
}

function toCount(value) {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n) || n < 0) return 0;
  return Math.round(n);
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}
