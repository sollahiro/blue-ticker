// 業種ベンチマーク（GET /v1/benchmark/{group} と同じ JSON）の組み立てと R2 書き出し。
// 抽出条件は Swift の loadStoredIndustryBenchmark（Sources/BltStoreCore/StoredReads/StoredIndustryKpi.swift）と
// GET /v1/benchmark/{group} のルート（Sources/BltServerCore/Routes.swift）に揃える。
// 失敗・0 件では既存オブジェクトを上書きしない（fail closed）。接続文字列は絶対にログへ出さない。

import { displayFilerName, iconPublicUrl, listedTickerCode } from "../../feed-rss/src/query.js";

// 公開する業種グループ（Swift industryBenchmarkPublicGroups）。
export const PUBLIC_GROUPS = ["bank"];
// Swift industryKpiCacheVersion / industryBenchmarkServeSchemaVersion / industryKpiSourceNotApplicable。
export const CACHE_VERSION = "industry-kpi-bank-v2";
export const SERVE_SCHEMA_VERSION = 1;
export const SOURCE_NOT_APPLICABLE = "not_applicable";
export const SCOPE_CONSOLIDATED = "consolidated";
export const SCOPE_FILER = "filer";

// neon() の例外メッセージは接続文字列（パスワード入り）をそのまま含むことがある。ログに出す前に伏せる。
export function redact(message) {
  return String(message ?? "").replace(/postgres(?:ql)?:\/\/[^\s'"]+/g, "postgresql://[redacted]");
}

export const CONTENT_TYPE = "application/json; charset=utf-8";
// iOS の再検証間隔に合わせる。有報が出たときしか変わらないので 1 時間で十分。
export const CACHE_CONTROL = "public, max-age=3600, s-maxage=3600";

// 会社ごとに提出日時が最新の 1 件（会社開示府令・上場コードの書類だけを対象にしてから最新を選ぶ）。
// 最新が対象外・要レビューなら、その会社は出さない（古い書類へはさかのぼらない）。
// $1: 業種グループ、$2: cache_version。
export const BENCHMARK_SQL = `SELECT DISTINCT ON (f.code)
  f.code, f.doc_id, f.payload, f.needs_review, f.not_applicable_reason, f.source,
  d.filer_name, d.period_end, d.sec_code
FROM industry_kpi_facts f
JOIN edinet_documents d ON d.doc_id = f.doc_id
WHERE f.industry_group = $1
  AND f.cache_version = $2
  AND d.ordinance_code = '010'
  AND d.sec_code LIKE '____0'
  AND d.sec_code <> '00000'
ORDER BY f.code, f.submit_date_time DESC, f.doc_id DESC`;

export const ICON_SQL = `SELECT code, r2_object_key
FROM company_icons
WHERE code = ANY($1::text[])`;

function asPayload(value) {
  if (typeof value === "string") {
    try {
      return JSON.parse(value);
    } catch {
      return null;
    }
  }
  return value && typeof value === "object" ? value : null;
}

// KPI キーごとに連結 → 提出会社の順で 1 つ選ぶ（Swift industryBenchmarkKpis）。子会社の値は出さない。
export function benchmarkKpis(facts) {
  const out = {};
  const keys = [...new Set(facts.map((fact) => fact.kpi_key))];
  for (const key of keys) {
    const fact =
      facts.find((f) => f.kpi_key === key && f.scope === SCOPE_CONSOLIDATED) ??
      facts.find((f) => f.kpi_key === key && f.scope === SCOPE_FILER);
    if (!fact || typeof fact.value !== "number" || !Number.isFinite(fact.value)) continue;
    out[key] = {
      value: fact.value,
      unit: fact.unit,
      period_basis: fact.period_basis,
      scope: fact.scope,
    };
  }
  return out;
}

// 1 行 → 応答の会社。公開できない行は null。
// sector は静的 JSON では持たない（東証 33 業種は DB に無い。比較タブは使わない）。
export function toBenchmarkCompany(row) {
  const code = listedTickerCode(row.sec_code);
  if (!code || code !== row.code) return null;
  const payload = asPayload(row.payload);
  if (!payload) return null;
  const facts = Array.isArray(payload.facts) ? payload.facts : [];
  if (
    row.needs_review ||
    row.not_applicable_reason ||
    row.source === SOURCE_NOT_APPLICABLE ||
    payload.needs_review ||
    facts.length === 0
  ) {
    return null;
  }
  const kpis = benchmarkKpis(facts);
  if (Object.keys(kpis).length === 0) return null;
  const name = displayFilerName(row.filer_name);
  if (!name) return null;
  const item = {
    code,
    name,
    sector: "",
    doc_id: row.doc_id,
    kpis,
    warnings: Array.isArray(payload.warnings) ? payload.warnings : [],
  };
  if (row.period_end) item.fy_end = row.period_end;
  return item;
}

export function buildBenchmark(group, rows) {
  const companies = rows
    .map((row) => toBenchmarkCompany(row))
    .filter((item) => item !== null)
    .sort((a, b) => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0));
  return {
    schema_version: SERVE_SCHEMA_VERSION,
    industry_group: group,
    companies,
  };
}

export async function refreshBenchmarks({ env, runQuery, log = console }) {
  const bucket = env.BENCHMARK_BUCKET;
  const prefix = env.BENCHMARK_OBJECT_PREFIX;
  if (!bucket || !prefix) {
    log.error(JSON.stringify({ event: "benchmark_static_skip", reason: "misconfigured" }));
    return { written: [], reason: "misconfigured" };
  }
  const written = [];
  for (const group of PUBLIC_GROUPS) {
    let rows;
    try {
      rows = await runQuery(BENCHMARK_SQL, [group, CACHE_VERSION]);
    } catch (error) {
      log.error(
        JSON.stringify({
          event: "benchmark_static_skip",
          group,
          reason: "query_error",
          message: redact(error?.message ?? error),
        })
      );
      continue;
    }
    const body = buildBenchmark(group, Array.isArray(rows) ? rows : []);
    if (body.companies.length === 0) {
      log.error(JSON.stringify({ event: "benchmark_static_skip", group, reason: "empty" }));
      continue;
    }
    const iconCount = await attachIcons({ companies: body.companies, env, runQuery, log });
    try {
      await bucket.put(`${prefix}${group}.json`, JSON.stringify(body), {
        httpMetadata: { contentType: CONTENT_TYPE, cacheControl: CACHE_CONTROL },
      });
    } catch (error) {
      log.error(
        JSON.stringify({
          event: "benchmark_static_put_error",
          group,
          message: redact(error?.message ?? error),
        })
      );
      throw error;
    }
    log.log(
      JSON.stringify({
        event: "benchmark_static_written",
        group,
        count: body.companies.length,
        icons: iconCount,
      })
    );
    written.push(group);
  }
  return { written };
}

// 会社に icon_url を足す（無い会社は null。REST の attachIconURLs と同じ）。付けた件数を返す。
// アイコンは付加情報。ベース URL 未設定・クエリ失敗でも本体は書く。
async function attachIcons({ companies, env, runQuery, log }) {
  for (const company of companies) company.icon_url = null;
  const baseUrl = env.BENCHMARK_ICON_BASE_URL;
  if (!baseUrl) {
    log.error(JSON.stringify({ event: "benchmark_static_icons_skip", reason: "misconfigured" }));
    return 0;
  }
  let rows;
  try {
    rows = await runQuery(ICON_SQL, [companies.map((c) => c.code)]);
  } catch (error) {
    log.error(
      JSON.stringify({
        event: "benchmark_static_icons_skip",
        reason: "query_error",
        message: redact(error?.message ?? error),
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
  for (const company of companies) {
    const key = keys.get(company.code);
    if (key) {
      company.icon_url = iconPublicUrl(baseUrl, key);
      count += 1;
    }
  }
  return count;
}
