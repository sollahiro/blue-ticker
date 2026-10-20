// mergeFeedRows（窓の行 + 有報の直近行）の単体テスト。
import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { mergeFeedRows } from "./query.js";

const row = (doc_id, submit_date_time, doc_type_code = "160") => ({
  doc_id,
  submit_date_time,
  doc_type_code,
});

describe("mergeFeedRows", () => {
  test("重複を除き、提出日時の降順・doc_id 降順に並べる", () => {
    const merged = mergeFeedRows(
      [row("A", "2026-10-20 10:00"), row("B", "2026-10-20 10:00"), row("C", "2026-10-19 09:00", "120")],
      [row("C", "2026-10-19 09:00", "120"), row("D", "2026-09-30 15:00", "120")],
      200
    );
    assert.deepEqual(
      merged.map((r) => r.doc_id),
      ["B", "A", "C", "D"]
    );
  });

  test("上限を超えたら有報の直近行以外を古い方から落とす", () => {
    const windowRows = [
      row("W1", "2026-10-20 12:00"),
      row("W2", "2026-10-20 11:00"),
      row("W3", "2026-10-20 10:00"),
    ];
    const annualRows = [row("Y1", "2026-10-20 11:30", "120"), row("Y2", "2026-10-01 09:00", "120")];
    const merged = mergeFeedRows(windowRows, annualRows, 3);
    assert.deepEqual(
      merged.map((r) => r.doc_id),
      ["W1", "Y1", "Y2"]
    );
  });

  test("有報の直近行が無ければ窓の行そのまま", () => {
    const windowRows = [row("W1", "2026-10-20 12:00"), row("W2", "2026-10-20 11:00")];
    assert.deepEqual(mergeFeedRows(windowRows, [], 200), windowRows);
  });
});
