// Ingest / query の入力正規化。Swift `feedTrendRecordedTools` とツール集合を揃える。

export const ALLOWED_SURFACES = new Set(["rest", "mcp"]);

export const ALLOWED_TOOLS = new Set([
  "search_companies",
  "get_filings",
  "get_financial_summary",
  "get_waterfall",
  "get_filing_content",
  "get_breakdown",
  "get_statement",
  "get_statement_notes",
]);

export const QUERY_MAX_LENGTH = 128;
export const DAYS_DEFAULT = 7;
export const DAYS_MAX = 90;
export const LIMIT_DEFAULT = 50;
export const LIMIT_MAX = 100;

const TICKER = /^[0-9A-Za-z]{4}$/;

export function tickerCode(raw) {
  if (typeof raw !== "string") return "";
  const trimmed = raw.trim();
  if (!TICKER.test(trimmed)) return "";
  return trimmed.toUpperCase();
}

export function clipQuery(raw) {
  if (typeof raw !== "string") return "";
  const trimmed = raw.trim();
  if (!trimmed) return "";
  return trimmed.length <= QUERY_MAX_LENGTH
    ? trimmed
    : trimmed.slice(0, QUERY_MAX_LENGTH);
}

export function parseIngestBody(value) {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    return { error: "body は JSON オブジェクトです" };
  }
  const surface = typeof value.surface === "string" ? value.surface.trim() : "";
  const tool = typeof value.tool === "string" ? value.tool.trim() : "";
  if (!ALLOWED_SURFACES.has(surface)) {
    return { error: "surface が不正です" };
  }
  if (!ALLOWED_TOOLS.has(tool)) {
    return { error: "tool が不正です" };
  }
  const code = tickerCode(value.code);
  const q = tool === "search_companies" ? clipQuery(value.q) : "";
  const resolvedCode = tool === "search_companies" ? code || tickerCode(q) : code;
  return {
    event: {
      surface,
      tool,
      code: resolvedCode,
      q,
    },
  };
}

export function clampInt(raw, fallback, min, max) {
  const n = typeof raw === "number" ? raw : Number.parseInt(String(raw ?? ""), 10);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(Math.max(n, min), max);
}

export function parseTrendQuery(searchParams) {
  const days = clampInt(searchParams.get("days"), DAYS_DEFAULT, 1, DAYS_MAX);
  const limit = clampInt(searchParams.get("limit"), LIMIT_DEFAULT, 1, LIMIT_MAX);
  const rawCode = searchParams.get("code");
  if (rawCode != null && rawCode.trim() !== "") {
    const code = tickerCode(rawCode);
    if (!code) return { error: "code は4桁の銘柄コードです" };
    return { days, limit, code };
  }
  return { days, limit, code: "" };
}

export function sqlString(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}
