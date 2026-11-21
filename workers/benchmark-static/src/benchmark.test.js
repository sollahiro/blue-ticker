// benchmark.js の組み立てと fail closed のテスト。R2 はフェイク、log は沈黙させる。

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import {
  BENCHMARK_SQL,
  CACHE_CONTROL,
  CACHE_VERSION,
  CONTENT_TYPE,
  ICON_SQL,
  benchmarkKpis,
  buildBenchmark,
  redact,
  refreshBenchmarks,
  toBenchmarkCompany,
} from "./benchmark.js";

const kpi = (key, value, scope = "consolidated") => ({
  kpi_key: key,
  value,
  unit: "percent",
  period_basis: "period_end",
  scope,
});

function row(overrides = {}) {
  return {
    code: "8306",
    doc_id: "S100AAAA",
    sec_code: "83060",
    filer_name: "株式会社三菱ＵＦＪフィナンシャル・グループ",
    period_end: "2026-03-31",
    needs_review: false,
    not_applicable_reason: null,
    source: "xbrl_facts",
    payload: {
      industry_group: "bank",
      needs_review: false,
      warnings: ["ncd_absent_assumed_zero"],
      facts: [kpi("ldr", 60.5), kpi("ohr", 55, "filer"), kpi("ohr", 50), kpi("ldr", 1, "named_subsidiary")],
    },
    ...overrides,
  };
}

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
  return { lines, log: (l) => lines.push(l), error: (l) => lines.push(l) };
}

const env = (bucket) => ({
  BENCHMARK_BUCKET: bucket,
  BENCHMARK_OBJECT_PREFIX: "blue-ticker/benchmark/",
  BENCHMARK_ICON_BASE_URL: "https://icons.sollahiro.com",
});

describe("benchmarkKpis", () => {
  test("連結を優先し、提出会社へ落とし、子会社は出さない", () => {
    const out = benchmarkKpis(row().payload.facts);
    assert.equal(out.ldr.value, 60.5);
    assert.equal(out.ohr.value, 50);
    assert.equal(out.ohr.scope, "consolidated");
    assert.deepEqual(Object.keys(out.ldr).sort(), ["period_basis", "scope", "unit", "value"]);
    assert.equal(benchmarkKpis([kpi("x", 1, "named_subsidiary")]).x, undefined);
    assert.equal(benchmarkKpis([kpi("x", 3, "filer")]).x.scope, "filer");
  });
  test("有限でない値は落とす", () => {
    assert.deepEqual(benchmarkKpis([kpi("x", null)]), {});
  });
});

describe("toBenchmarkCompany", () => {
  test("REST と同じ形", () => {
    const item = toBenchmarkCompany(row());
    assert.equal(item.code, "8306");
    assert.equal(item.doc_id, "S100AAAA");
    assert.equal(item.fy_end, "2026-03-31");
    assert.deepEqual(item.warnings, ["ncd_absent_assumed_zero"]);
    assert.equal(item.sector, "");
  });
  test("要レビュー・対象外・値なし・非上場は出さない", () => {
    assert.equal(toBenchmarkCompany(row({ needs_review: true })), null);
    assert.equal(toBenchmarkCompany(row({ not_applicable_reason: "not_bank" })), null);
    assert.equal(toBenchmarkCompany(row({ source: "not_applicable" })), null);
    assert.equal(toBenchmarkCompany(row({ payload: { facts: [], needs_review: false } })), null);
    assert.equal(toBenchmarkCompany(row({ payload: { facts: [kpi("a", 1)], needs_review: true } })), null);
    assert.equal(toBenchmarkCompany(row({ sec_code: "00000" })), null);
    assert.equal(toBenchmarkCompany(row({ sec_code: "83061" })), null);
  });
  test("payload が文字列でも読める", () => {
    const r = row();
    assert.ok(toBenchmarkCompany({ ...r, payload: JSON.stringify(r.payload) }));
  });
});

describe("buildBenchmark", () => {
  test("コード昇順で schema_version を付ける", () => {
    const body = buildBenchmark("bank", [row({ code: "8316", sec_code: "83160" }), row()]);
    assert.equal(body.schema_version, 1);
    assert.equal(body.industry_group, "bank");
    assert.deepEqual(body.companies.map((c) => c.code), ["8306", "8316"]);
  });
});

describe("redact", () => {
  test("接続文字列を伏せる", () => {
    const out = redact("bad url (connection string: 'postgresql://user:secret@host/db?sslmode=require')");
    assert.ok(!out.includes("secret"));
    assert.ok(out.includes("[redacted]"));
  });
  test("クエリ失敗のログに接続文字列が出ない", async () => {
    const log = silentLog();
    const runQuery = async () => {
      throw new Error("invalid 'postgresql://u:topsecret@h/d'");
    };
    await refreshBenchmarks({ env: env(fakeBucket()), runQuery, log });
    assert.ok(!log.lines.join("\n").includes("topsecret"));
  });
});

describe("SQL", () => {
  test("現行 cache_version と会社開示・上場で絞る", () => {
    assert.equal(CACHE_VERSION, "industry-kpi-bank-v2");
    assert.match(BENCHMARK_SQL, /DISTINCT ON \(f\.code\)/);
    assert.match(BENCHMARK_SQL, /ordinance_code = '010'/);
    assert.match(BENCHMARK_SQL, /sec_code LIKE '____0'/);
  });
});

describe("refreshBenchmarks", () => {
  test("R2 に bank.json を書く（アイコン付き）", async () => {
    const bucket = fakeBucket();
    const log = silentLog();
    const runQuery = async (text) => {
      if (text === BENCHMARK_SQL) return [row()];
      if (text === ICON_SQL) return [{ code: "8306", r2_object_key: "icons/8306.png" }];
      throw new Error("unexpected");
    };
    const result = await refreshBenchmarks({ env: env(bucket), runQuery, log });
    assert.deepEqual(result.written, ["bank"]);
    assert.equal(bucket.calls[0].key, "blue-ticker/benchmark/bank.json");
    assert.equal(bucket.calls[0].options.httpMetadata.contentType, CONTENT_TYPE);
    assert.equal(bucket.calls[0].options.httpMetadata.cacheControl, CACHE_CONTROL);
    const body = JSON.parse(bucket.calls[0].body);
    assert.equal(body.companies[0].icon_url, "https://icons.sollahiro.com/icons/8306.png");
  });
  test("アイコン失敗でも本体は書く（icon_url は null）", async () => {
    const bucket = fakeBucket();
    const runQuery = async (text) => {
      if (text === BENCHMARK_SQL) return [row()];
      throw new Error("denied");
    };
    await refreshBenchmarks({ env: env(bucket), runQuery, log: silentLog() });
    assert.equal(JSON.parse(bucket.calls[0].body).companies[0].icon_url, null);
  });
  test("クエリ失敗・0 件では上書きしない", async () => {
    for (const runQuery of [
      async () => {
        throw new Error("boom");
      },
      async () => [],
      async () => [row({ needs_review: true })],
    ]) {
      const bucket = fakeBucket();
      const result = await refreshBenchmarks({ env: env(bucket), runQuery, log: silentLog() });
      assert.deepEqual(result.written, []);
      assert.equal(bucket.calls.length, 0);
    }
  });
  test("設定が無ければ何もしない", async () => {
    const result = await refreshBenchmarks({ env: {}, runQuery: async () => [], log: silentLog() });
    assert.equal(result.reason, "misconfigured");
  });
  test("put の失敗は再スローする", async () => {
    const bucket = {
      async put() {
        throw new Error("r2");
      },
    };
    await assert.rejects(
      refreshBenchmarks({ env: env(bucket), runQuery: async (t) => (t === BENCHMARK_SQL ? [row()] : []), log: silentLog() })
    );
  });
});
