import test from "node:test";
import assert from "node:assert/strict";
import {
  parseIngestBody,
  parseTrendQuery,
  tickerCode,
  clipQuery,
  sqlString,
  QUERY_MAX_LENGTH,
  bearerOk,
  timingSafeEqualString,
} from "./validate.js";

test("tickerCode accepts 4-character JP codes", () => {
  assert.equal(tickerCode("7203"), "7203");
  assert.equal(tickerCode("477a"), "477A");
  assert.equal(tickerCode(" 6758 "), "6758");
  assert.equal(tickerCode("72030"), "");
  assert.equal(tickerCode("12"), "");
  assert.equal(tickerCode("7203!"), "");
});

test("parseIngestBody allowlists surface and tool", () => {
  const ok = parseIngestBody({
    surface: "rest",
    tool: "search_companies",
    q: "トヨタ",
  });
  assert.deepEqual(ok.event, {
    surface: "rest",
    tool: "search_companies",
    code: "",
    q: "トヨタ",
  });
  assert.equal(parseIngestBody({ surface: "rest", tool: "get_feed_trend" }).error, "tool が不正です");
  assert.equal(parseIngestBody({ surface: "web", tool: "search_companies" }).error, "surface が不正です");
});

test("search_companies sets code when q is a ticker", () => {
  const parsed = parseIngestBody({
    surface: "mcp",
    tool: "search_companies",
    q: "7203",
  });
  assert.equal(parsed.event.code, "7203");
  assert.equal(parsed.event.q, "7203");
});

test("non-search tools drop q", () => {
  const parsed = parseIngestBody({
    surface: "rest",
    tool: "get_financial_summary",
    code: "7203",
    q: "should-not-store",
  });
  assert.equal(parsed.event.code, "7203");
  assert.equal(parsed.event.q, "");
});

test("clipQuery caps length", () => {
  assert.equal(clipQuery("  abc  "), "abc");
  assert.equal(clipQuery("x".repeat(QUERY_MAX_LENGTH + 10)).length, QUERY_MAX_LENGTH);
});

test("parseTrendQuery clamps and validates code", () => {
  const ranking = parseTrendQuery(new URLSearchParams(""));
  assert.equal(ranking.days, 7);
  assert.equal(ranking.limit, 50);
  assert.equal(ranking.code, "");
  const filtered = parseTrendQuery(new URLSearchParams("days=1&limit=3&code=7203"));
  assert.deepEqual(filtered, { days: 1, limit: 3, code: "7203" });
  assert.equal(parseTrendQuery(new URLSearchParams("code=72030")).error, "code は4桁の銘柄コードです");
  assert.equal(parseTrendQuery(new URLSearchParams("days=999&limit=999")).days, 90);
  assert.equal(parseTrendQuery(new URLSearchParams("days=999&limit=999")).limit, 100);
});

test("sqlString escapes quotes", () => {
  assert.equal(sqlString("7203"), "'7203'");
  assert.equal(sqlString("a'b"), "'a''b'");
});

test("bearerOk compares tokens without accepting missing prefix", () => {
  assert.equal(bearerOk("Bearer secret", "secret"), true);
  assert.equal(bearerOk("Bearer secretx", "secret"), false);
  assert.equal(bearerOk("secret", "secret"), false);
  assert.equal(bearerOk("Bearer secret", ""), false);
  assert.equal(bearerOk("Bearer secret", undefined), false);
});

test("timingSafeEqualString rejects different lengths and values", () => {
  assert.equal(timingSafeEqualString("ab", "ab"), true);
  assert.equal(timingSafeEqualString("ab", "abc"), false);
  assert.equal(timingSafeEqualString("ab", "ac"), false);
});
