// feed.js の fail-closed 動作テスト。R2 はフェイク、log は沈黙させる。

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { CACHE_CONTROL, CONTENT_TYPE, refreshFeed } from "./feed.js";
import { FEED_DOC_TYPES, FEED_ITEM_LIMIT, FEED_SQL } from "./query.js";

const NOW = new Date("2026-10-10T10:15:00Z");
const KEY = "blue-ticker/edinet-filings.xml";

function fakeBucket() {
  const calls = [];
  return {
    calls,
    async put(key, body, options) {
      calls.push({ key, body, options });
    },
  };
}

function silentLog() {
  const lines = [];
  return {
    lines,
    log(line) {
      lines.push(line);
    },
    error(line) {
      lines.push(line);
    },
  };
}

function makeEnv(bucket) {
  return {
    FEED_BUCKET: bucket,
    FEED_OBJECT_KEY: KEY,
    FEED_PUBLIC_URL: "https://feed.sollahiro.com/blue-ticker/edinet-filings.xml",
    COMPANY_URL_TEMPLATE: "https://sollahiro.com/blue-ticker/companies/{code}",
  };
}

const LISTED_ROW = {
  doc_id: "S100AAA",
  sec_code: "72030",
  filer_name: "テスト株式会社",
  doc_type_code: "120",
  period_end: "2026-03-31",
  submit_date_time: "2026-10-09 15:30",
  doc_description: "有価証券報告書－第100期",
};

describe("refreshFeed", () => {
  test("成功: put を 1 回、正しいキー・メタデータ・SQL パラメータで呼ぶ", async () => {
    const bucket = fakeBucket();
    const log = silentLog();
    const queries = [];
    const runQuery = async (text, params) => {
      queries.push({ text, params });
      return [LISTED_ROW];
    };

    const result = await refreshFeed({ env: makeEnv(bucket), runQuery, now: NOW, log });

    assert.deepEqual(result, { written: true, count: 1 });
    assert.equal(queries.length, 1);
    assert.equal(queries[0].text, FEED_SQL);
    assert.deepEqual(queries[0].params, [FEED_DOC_TYPES, "2026-10-04", FEED_ITEM_LIMIT]);

    assert.equal(bucket.calls.length, 1);
    const put = bucket.calls[0];
    assert.equal(put.key, KEY);
    assert.deepEqual(put.options, {
      httpMetadata: { contentType: CONTENT_TYPE, cacheControl: CACHE_CONTROL },
    });
    assert.ok(put.body.includes("<title>テスト株式会社 有価証券報告書</title>"));
    assert.ok(log.lines.some((line) => line.includes('"feed_rss_written"')));
  });

  test("クエリ失敗: put せず query_error", async () => {
    const bucket = fakeBucket();
    const log = silentLog();
    const runQuery = async () => {
      throw new Error("connection refused");
    };

    const result = await refreshFeed({ env: makeEnv(bucket), runQuery, now: NOW, log });

    assert.deepEqual(result, { written: false, reason: "query_error" });
    assert.equal(bucket.calls.length, 0);
    assert.ok(log.lines.some((line) => line.includes('"feed_rss_skip"')));
    assert.ok(log.lines.some((line) => line.includes('"query_error"')));
  });

  test("0 件: put せず empty", async () => {
    const bucket = fakeBucket();
    const log = silentLog();
    const runQuery = async () => [];

    const result = await refreshFeed({ env: makeEnv(bucket), runQuery, now: NOW, log });

    assert.deepEqual(result, { written: false, reason: "empty" });
    assert.equal(bucket.calls.length, 0);
  });

  test("全部非上場: put せず empty", async () => {
    const bucket = fakeBucket();
    const log = silentLog();
    const runQuery = async () => [
      { ...LISTED_ROW, sec_code: "72031" },
      { ...LISTED_ROW, sec_code: "00000" },
      { ...LISTED_ROW, sec_code: null },
    ];

    const result = await refreshFeed({ env: makeEnv(bucket), runQuery, now: NOW, log });

    assert.deepEqual(result, { written: false, reason: "empty" });
    assert.equal(bucket.calls.length, 0);
  });

  test("バケット未設定: misconfigured でクエリも呼ばない", async () => {
    const log = silentLog();
    let queried = false;
    const runQuery = async () => {
      queried = true;
      return [LISTED_ROW];
    };
    const env = makeEnv(null);

    const result = await refreshFeed({ env, runQuery, now: NOW, log });

    assert.deepEqual(result, { written: false, reason: "misconfigured" });
    assert.equal(queried, false);
  });

  test("put 失敗: 例外を再スローする", async () => {
    const bucket = {
      async put() {
        throw new Error("r2 unavailable");
      },
    };
    const log = silentLog();
    const runQuery = async () => [LISTED_ROW];

    await assert.rejects(
      refreshFeed({ env: makeEnv(bucket), runQuery, now: NOW, log }),
      /r2 unavailable/
    );
  });
});
