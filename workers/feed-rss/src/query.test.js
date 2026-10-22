// selectFeedRows（有報の新しい順の行から、窓か直近 N 件を残す）の単体テスト。
import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { selectFeedRows } from "./query.js";

const row = (doc_id, submit_date_time) => ({ doc_id, submit_date_time, doc_type_code: "120" });

// FEED_SQL と同じ並び（submit_date_time 降順・doc_id 降順）。
function compareRowsDesc(a, b) {
  if (a.submit_date_time !== b.submit_date_time) {
    return a.submit_date_time < b.submit_date_time ? 1 : -1;
  }
  return a.doc_id < b.doc_id ? 1 : a.doc_id > b.doc_id ? -1 : 0;
}

// 1 本化する前の実装（窓のクエリ＋有報の直近行のクエリ＋mergeFeedRows）を、120 だけの行集合に対して再現する。
function legacyTwoQueries(allRows, cutoff, minCount, limit) {
  const sorted = [...allRows].sort(compareRowsDesc);
  const windowRows = sorted.filter((r) => r.submit_date_time >= cutoff).slice(0, limit);
  const annualRows = sorted.slice(0, minCount);
  const byId = new Map();
  for (const r of [...annualRows, ...windowRows]) {
    if (!byId.has(r.doc_id)) byId.set(r.doc_id, r);
  }
  const pinned = new Set(annualRows.map((r) => r.doc_id));
  const merged = [...byId.values()].sort(compareRowsDesc);
  let excess = merged.length - limit;
  if (excess <= 0) return merged;
  const kept = [];
  for (let index = merged.length - 1; index >= 0; index -= 1) {
    if (excess > 0 && !pinned.has(merged[index].doc_id)) {
      excess -= 1;
      continue;
    }
    kept.push(merged[index]);
  }
  return kept.reverse();
}

// 1 本化した実装: FEED_SQL（新しい順に limit 件）→ selectFeedRows。
function singleQuery(allRows, cutoff, minCount, limit) {
  const latest = [...allRows].sort(compareRowsDesc).slice(0, limit);
  return selectFeedRows(latest, cutoff, minCount);
}

describe("selectFeedRows", () => {
  test("窓の行がそろっていれば窓の行だけ（直近 N 件は窓に含まれる）", () => {
    const rows = [
      row("A", "2026-10-20 12:00"),
      row("B", "2026-10-19 12:00"),
      row("C", "2026-10-14 12:00"),
      row("D", "2026-10-13 12:00"),
    ];
    assert.deepEqual(
      selectFeedRows(rows, "2026-10-14", 2).map((r) => r.doc_id),
      ["A", "B", "C"]
    );
  });

  test("窓の行が少なければ窓の外でも直近 N 件まで載せる", () => {
    const rows = [
      row("A", "2026-10-20 12:00"),
      row("B", "2026-09-30 15:00"),
      row("C", "2026-09-01 15:00"),
      row("D", "2026-08-01 15:00"),
    ];
    assert.deepEqual(
      selectFeedRows(rows, "2026-10-14", 3).map((r) => r.doc_id),
      ["A", "B", "C"]
    );
  });

  test("0 件は 0 件", () => {
    assert.deepEqual(selectFeedRows([], "2026-10-14", 10), []);
  });
});

describe("1 本化の同等性（旧: 窓＋有報の直近行＋mergeFeedRows）", () => {
  test("重複・同時刻・窓の内外・上限超過で旧実装と同じ結果", () => {
    const cutoff = "2026-10-14";
    const cases = [
      // 窓内が少ない（閑散期）
      [row("A", "2026-10-20 10:00"), row("B", "2026-10-01 10:00"), row("C", "2026-09-01 10:00")],
      // 同時刻は doc_id 降順
      [row("A", "2026-10-20 10:00"), row("B", "2026-10-20 10:00"), row("C", "2026-10-14 00:00")],
      // 窓の境界（下限日は含む）
      [row("A", "2026-10-14"), row("B", "2026-10-13 23:59"), row("C", "2026-10-14 00:00")],
    ];
    for (const rows of cases) {
      for (const [minCount, limit] of [[1, 200], [2, 200], [2, 2], [10, 3]]) {
        assert.deepEqual(
          singleQuery(rows, cutoff, minCount, limit).map((r) => r.doc_id),
          legacyTwoQueries(rows, cutoff, minCount, limit).map((r) => r.doc_id),
          JSON.stringify({ rows, minCount, limit })
        );
      }
    }
  });

  test("疑似乱数の行集合で旧実装と同じ結果（決算期の上限超過を含む）", () => {
    let seed = 42;
    const next = () => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed;
    };
    for (let round = 0; round < 300; round += 1) {
      const count = next() % 60;
      const rows = [];
      for (let index = 0; index < count; index += 1) {
        const day = 1 + (next() % 31);
        const hour = next() % 3;
        rows.push(row(`S${String(index).padStart(3, "0")}`, `2026-10-${String(day).padStart(2, "0")} 1${hour}:00`));
      }
      const minCount = 1 + (next() % 12);
      const limit = minCount + (next() % 40);
      assert.deepEqual(
        singleQuery(rows, "2026-10-14", minCount, limit).map((r) => r.doc_id),
        legacyTwoQueries(rows, "2026-10-14", minCount, limit).map((r) => r.doc_id),
        `round ${round}`
      );
    }
  });
});
