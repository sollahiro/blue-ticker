// 取り込み状況の集計と RSS 組み立て。テーブルごとに cache_version 別の行数と更新時刻を読む。
// 銘柄コードの一覧は出さない（集計件数だけ）。

// 集計するステージ。table は固定の許可リスト（SQL に埋め込むので外部入力にしない）。
export const STAGES = [
  { key: "financials", label: "財務サマリー", table: "company_financials" },
  { key: "statements", label: "財務諸表", table: "company_statements" },
  { key: "filing_sections", label: "有報の文章", table: "company_filing_sections" },
  { key: "breakdowns", label: "内訳", table: "company_breakdowns" },
  { key: "industry_kpis", label: "業種KPI", table: "industry_kpi_facts" },
];

// 最終更新がこの時間より古いと遅延とみなす（鮮度チェックの既定と同じ 36 時間）。
export const STALE_HOURS = 36;
export const RECENT_HOURS = 24;

// cache_version 別の行数・直近 24 時間に更新された行数・最終更新。
export function stageSql(table) {
  if (!STAGES.some((stage) => stage.table === table)) {
    throw new Error(`unknown table: ${table}`);
  }
  return `SELECT cache_version,
       count(*)::int AS rows,
       (count(*) FILTER (WHERE updated_at > now() - interval '${RECENT_HOURS} hours'))::int AS recent,
       max(updated_at) AS last_updated
FROM ${table}
GROUP BY cache_version`;
}

// "fin-v24" のような版の末尾の数字。数字が無ければ -1。
export function versionNumber(version) {
  const match = /(\d+)\s*$/.exec(String(version ?? ""));
  return match ? Number(match[1]) : -1;
}

function toDate(value) {
  if (value === null || value === undefined) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

// 1 ステージ分の集計。rows は stageSql の結果。
export function summarizeStage(stage, rows, now = new Date()) {
  const list = Array.isArray(rows) ? rows : [];
  const versions = list
    .map((row) => ({
      version: String(row.cache_version ?? ""),
      rows: Number(row.rows) || 0,
      recent: Number(row.recent) || 0,
      last: toDate(row.last_updated),
    }))
    .sort((a, b) => versionNumber(b.version) - versionNumber(a.version) || (a.version < b.version ? 1 : -1));
  const total = versions.reduce((sum, v) => sum + v.rows, 0);
  const recent = versions.reduce((sum, v) => sum + v.recent, 0);
  const lastUpdated = versions.reduce((max, v) => (v.last && (!max || v.last > max) ? v.last : max), null);
  const newest = versions[0] ?? null;
  const stale =
    lastUpdated === null || now.getTime() - lastUpdated.getTime() > STALE_HOURS * 3600 * 1000;
  return {
    key: stage.key,
    label: stage.label,
    total,
    recent,
    newestVersion: newest ? newest.version : null,
    newestRows: newest ? newest.rows : 0,
    newestPct: total > 0 && newest ? Math.round((newest.rows / total) * 1000) / 10 : 0,
    versions,
    lastUpdated,
    stale,
  };
}

const pad2 = (n) => String(n).padStart(2, "0");
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function jstParts(date) {
  return new Date(date.getTime() + 9 * 3600 * 1000);
}

export function rfc822Jst(date) {
  const j = jstParts(date);
  return (
    `${WEEKDAYS[j.getUTCDay()]}, ${pad2(j.getUTCDate())} ${MONTHS[j.getUTCMonth()]} ${j.getUTCFullYear()} ` +
    `${pad2(j.getUTCHours())}:${pad2(j.getUTCMinutes())}:${pad2(j.getUTCSeconds())} +0900`
  );
}

export function jstDateString(date) {
  const j = jstParts(date);
  return `${j.getUTCFullYear()}-${pad2(j.getUTCMonth() + 1)}-${pad2(j.getUTCDate())}`;
}

function jstDateTime(date) {
  const j = jstParts(date);
  return `${jstDateString(date)} ${pad2(j.getUTCHours())}:${pad2(j.getUTCMinutes())}`;
}

// eslint-disable-next-line no-control-regex
const INVALID_XML_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/g;

export function escapeXml(value) {
  return String(value ?? "")
    .replace(INVALID_XML_CHARS, "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

const fmt = (n) => Number(n).toLocaleString("en-US");

// 記事の本文（プレーンテキスト）。ステージごとに 1 ブロック。
export function describeStages(summaries) {
  return summaries
    .map((s) => {
      const head = `${s.label}${s.stale ? "【遅延】" : ""}`;
      if (s.total === 0) return `${head}: 行なし`;
      const newest = `最新の版 ${s.newestVersion}: ${fmt(s.newestRows)} 件（${s.newestPct}%）`;
      const others = s.versions
        .slice(1)
        .map((v) => `${v.version} ${fmt(v.rows)}`)
        .join(" / ");
      const parts = [
        `${head}: 全 ${fmt(s.total)} 件、直近${RECENT_HOURS}時間に更新 ${fmt(s.recent)} 件`,
        newest,
        others ? `ほか ${others}` : "",
        `最終更新 ${s.lastUpdated ? jstDateTime(s.lastUpdated) : "なし"}（JST）`,
      ];
      return parts.filter(Boolean).join("\n");
    })
    .join("\n\n");
}

// 1 日 1 件の記事。guid は JST の日付で固定し、同じ日に再実行したら同じ記事を更新する。
export function buildStatusRss({ summaries, now = new Date(), feedUrl }) {
  const staleLabels = summaries.filter((s) => s.stale).map((s) => s.label);
  const day = jstDateString(now);
  const title =
    staleLabels.length > 0
      ? `【遅延】取り込み状況 ${day}（${staleLabels.join("・")}）`
      : `取り込み状況 ${day}`;
  const lines = [];
  lines.push('<?xml version="1.0" encoding="UTF-8"?>');
  lines.push('<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">');
  lines.push("  <channel>");
  lines.push("    <title>有報LAB — 取り込み状況</title>");
  lines.push("    <link>https://yuholab.com</link>");
  lines.push(
    "    <description>有報LAB のデータ取り込みの状況です。ステージごとの件数と最終更新を、" +
      `毎日 19:30（JST）に配信します。最終更新が${STALE_HOURS}時間より古いと「遅延」と表示します。` +
      "</description>"
  );
  lines.push("    <language>ja</language>");
  lines.push(`    <lastBuildDate>${rfc822Jst(now)}</lastBuildDate>`);
  lines.push("    <ttl>1440</ttl>");
  lines.push(`    <atom:link href="${escapeXml(feedUrl)}" rel="self" type="application/rss+xml"/>`);
  lines.push("    <item>");
  lines.push(`      <title>${escapeXml(title)}</title>`);
  lines.push(`      <guid isPermaLink="false">${escapeXml(`ingest-status-${day}`)}</guid>`);
  lines.push(`      <pubDate>${rfc822Jst(now)}</pubDate>`);
  lines.push(`      <description>${escapeXml(describeStages(summaries))}</description>`);
  lines.push("    </item>");
  lines.push("  </channel>");
  lines.push("</rss>");
  return lines.join("\n") + "\n";
}
