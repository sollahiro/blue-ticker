import assert from "node:assert/strict";
import { test } from "node:test";

import { refreshStatus } from "./refresh.js";
import {
  STAGES,
  STALE_HOURS,
  buildStatusRss,
  describeStages,
  escapeXml,
  jstDateString,
  stageSql,
  summarizeStage,
  versionNumber,
} from "./status.js";

const NOW = new Date("2026-11-03T10:30:00Z"); // 19:30 JST
const hoursAgo = (h) => new Date(NOW.getTime() - h * 3600 * 1000).toISOString();
const stage = STAGES[0];

test("versionNumber は版の末尾の数字を返す", () => {
  assert.equal(versionNumber("fin-v24"), 24);
  assert.equal(versionNumber("industry-kpi-bank-v1"), 1);
  assert.equal(versionNumber("none"), -1);
  assert.equal(versionNumber(null), -1);
});

test("stageSql は許可リストのテーブルだけ受け付ける", () => {
  assert.match(stageSql("company_financials"), /FROM company_financials/);
  assert.throws(() => stageSql("users; DROP TABLE x"), /unknown table/);
});

test("summarizeStage は最新の版の割合・直近の更新数・遅延を出す", () => {
  const s = summarizeStage(
    stage,
    [
      { cache_version: "fin-v23", rows: 900, recent: 10, last_updated: hoursAgo(5) },
      { cache_version: "fin-v24", rows: 100, recent: 90, last_updated: hoursAgo(1) },
      { cache_version: "fin-v9", rows: 5, recent: 0, last_updated: hoursAgo(300) },
    ],
    NOW
  );
  assert.equal(s.total, 1005);
  assert.equal(s.recent, 100);
  assert.equal(s.newestVersion, "fin-v24");
  assert.equal(s.newestRows, 100);
  assert.equal(s.newestPct, 10);
  assert.deepEqual(s.versions.map((v) => v.version), ["fin-v24", "fin-v23", "fin-v9"]);
  assert.equal(s.stale, false);
});

test("最終更新が古い、または行が無いと遅延", () => {
  const old = summarizeStage(
    stage,
    [{ cache_version: "fin-v24", rows: 1, recent: 0, last_updated: hoursAgo(STALE_HOURS + 1) }],
    NOW
  );
  assert.equal(old.stale, true);
  const empty = summarizeStage(stage, [], NOW);
  assert.equal(empty.stale, true);
  assert.equal(empty.total, 0);
  assert.equal(empty.newestVersion, null);
});

test("buildStatusRss は 1 日 1 件で、遅延があれば題に出す", () => {
  const ok = summarizeStage(
    stage,
    [{ cache_version: "fin-v24", rows: 10, recent: 1, last_updated: hoursAgo(1) }],
    NOW
  );
  const xml = buildStatusRss({ summaries: [ok], now: NOW, feedUrl: "https://example.test/f.xml" });
  assert.match(xml, /<title>取り込み状況 2026-11-03<\/title>/);
  assert.match(xml, /<guid isPermaLink="false">ingest-status-2026-11-03<\/guid>/);
  assert.match(xml, /<pubDate>Tue, 03 Nov 2026 19:30:00 \+0900<\/pubDate>/);
  assert.equal((xml.match(/<item>/g) ?? []).length, 1);

  const bad = summarizeStage(stage, [], NOW);
  const xml2 = buildStatusRss({ summaries: [ok, bad], now: NOW, feedUrl: "https://example.test/f.xml" });
  assert.match(xml2, /<title>【遅延】取り込み状況 2026-11-03（財務サマリー）<\/title>/);
});

test("describeStages は件数・最新の版・最終更新を書き、XML の特殊文字を escapeXml が潰す", () => {
  const s = summarizeStage(
    stage,
    [{ cache_version: "fin-v24", rows: 1234, recent: 5, last_updated: hoursAgo(1) }],
    NOW
  );
  const text = describeStages([s]);
  assert.match(text, /全 1,234 件、直近24時間に更新 5 件/);
  assert.match(text, /最新の版 fin-v24: 1,234 件（100%）/);
  assert.equal(escapeXml("<a & 'b'>"), "&lt;a &amp; &apos;b&apos;&gt;");
});

test("jstDateString は JST の暦日", () => {
  assert.equal(jstDateString(new Date("2026-11-03T15:30:00Z")), "2026-11-04");
});

function fakeEnv() {
  const puts = [];
  return {
    puts,
    env: {
      FEED_OBJECT_KEY: "k.xml",
      FEED_PUBLIC_URL: "https://example.test/k.xml",
      FEED_BUCKET: { put: async (key, body, opts) => puts.push({ key, body, opts }) },
    },
  };
}
const quiet = { log() {}, error() {} };

test("refreshStatus は全ステージを集計して R2 に書く", async () => {
  const { env, puts } = fakeEnv();
  const seen = [];
  const result = await refreshStatus({
    env,
    now: NOW,
    log: quiet,
    runQuery: async (text) => {
      seen.push(text);
      return [{ cache_version: "x-v1", rows: 3, recent: 1, last_updated: hoursAgo(1) }];
    },
  });
  assert.equal(result.written, true);
  assert.equal(seen.length, STAGES.length);
  assert.equal(puts.length, 1);
  assert.equal(puts[0].key, "k.xml");
  assert.equal(puts[0].opts.httpMetadata.contentType, "application/rss+xml; charset=utf-8");
});

test("1 ステージでも集計に失敗したら R2 を上書きしない", async () => {
  const { env, puts } = fakeEnv();
  let n = 0;
  const result = await refreshStatus({
    env,
    now: NOW,
    log: quiet,
    runQuery: async () => {
      n += 1;
      if (n === 3) throw new Error("permission denied for table");
      return [{ cache_version: "x-v1", rows: 3, recent: 1, last_updated: hoursAgo(1) }];
    },
  });
  assert.deepEqual(result, { written: false, reason: "query_error" });
  assert.equal(puts.length, 0);
});

test("設定が足りなければ skip する", async () => {
  const result = await refreshStatus({ env: {}, runQuery: async () => [], log: quiet });
  assert.deepEqual(result, { written: false, reason: "misconfigured" });
});

test("R2 の put が失敗したら再スローする", async () => {
  const env = {
    FEED_OBJECT_KEY: "k.xml",
    FEED_PUBLIC_URL: "https://example.test/k.xml",
    FEED_BUCKET: {
      put: async () => {
        throw new Error("r2 down");
      },
    },
  };
  await assert.rejects(
    refreshStatus({
      env,
      now: NOW,
      log: quiet,
      runQuery: async () => [{ cache_version: "x-v1", rows: 1, recent: 0, last_updated: hoursAgo(1) }],
    }),
    /r2 down/
  );
});
