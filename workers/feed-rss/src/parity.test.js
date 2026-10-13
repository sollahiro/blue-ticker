// Swift ↔ JS パリティテスト。
// test-fixtures/feed-parity.json を正本に、JS 側の定数・マッピングと
// Swift 側の実装（ソースを直接パース）が一致することを両方向で検証する。
// Swift 側の関数実装そのものは SwiftTests/BlueTickerTests/FeedRssParityFixtureTests.swift が
// 同じ fixture で検証する。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, test } from "node:test";

import {
  DOC_TYPE_LABELS,
  FEED_DOC_TYPES,
  FEED_SQL,
  ORDINANCE_COMPANY_DISCLOSURE,
  listedTickerCode,
  toFeedItem,
} from "./query.js";

const fixture = JSON.parse(
  readFileSync(new URL("../test-fixtures/feed-parity.json", import.meta.url), "utf8")
);

// このテストファイルは workers/feed-rss/src/ にある。リポジトリルートは 3 つ上。
const swiftSource = (path) =>
  readFileSync(new URL(`../../../${path}`, import.meta.url), "utf8");

const facadeSwift = swiftSource("Sources/BlueTicker/Server/BltServerFacade.swift");
const apiSwift = swiftSource("Sources/BlueTicker/Constants/Api.swift");
const feedServeSwift = swiftSource("Sources/BltServerCore/FeedServe.swift");

// Swift の `func NAME(...) ...` 本体を切り出す（先頭の `func NAME` から、
// 行頭が `}` の最初の行まで。トップレベル関数前提）。
function swiftFunctionBody(source, name) {
  const start = source.indexOf(`func ${name}(`);
  assert.notEqual(start, -1, `Swift ソースに func ${name} が見つからない`);
  const end = source.indexOf("\n}", start);
  assert.notEqual(end, -1, `func ${name} の終端が見つからない`);
  return source.slice(start, end);
}

describe("docTypeLabels パリティ", () => {
  test("JS DOC_TYPE_LABELS は fixture と一致する", () => {
    assert.deepEqual(DOC_TYPE_LABELS, fixture.docTypeLabels);
  });

  test("Swift docTypeLabel(_:) の switch 分岐は fixture と一致する", () => {
    const body = swiftFunctionBody(facadeSwift, "docTypeLabel");
    const swiftLabels = {};
    for (const match of body.matchAll(/case "(\d{3})": return "([^"]+)"/g)) {
      swiftLabels[match[1]] = match[2];
    }
    assert.deepEqual(swiftLabels, fixture.docTypeLabels);
  });
});

describe("書類種別・府令パリティ", () => {
  // Api.swift の `static let docTypeXxx = "NNN"` を名前 → コードで集める。
  function swiftDocTypeConstants() {
    const constants = {};
    for (const match of apiSwift.matchAll(/static let (docType\w+) = "(\d{3})"/g)) {
      constants[match[1]] = match[2];
    }
    return constants;
  }

  test("Swift documentSyncDocTypes（= feedAllowedDocTypes）は fixture / JS と一致する", () => {
    const constants = swiftDocTypeConstants();
    const start = apiSwift.indexOf("documentSyncDocTypes: Set<String> = [");
    assert.notEqual(start, -1, "Api.swift に documentSyncDocTypes が見つからない");
    const end = apiSwift.indexOf("]", start);
    const memberNames = [...apiSwift.slice(start, end).matchAll(/docType\w+/g)].map(
      (match) => match[0]
    );
    const codes = memberNames
      .map((name) => {
        assert.ok(constants[name], `Api.swift に定数 ${name} が見つからない`);
        return constants[name];
      })
      .sort();
    assert.deepEqual(codes, [...fixture.feedDocTypes].sort());
    assert.deepEqual([...FEED_DOC_TYPES].sort(), [...fixture.feedDocTypes].sort());
  });

  test("会社開示府令 010 は fixture / Swift / JS で一致する", () => {
    const match = /let ordinanceCompanyDisclosure = "(\d{3})"/.exec(apiSwift);
    assert.ok(match, "Api.swift に ordinanceCompanyDisclosure が見つからない");
    assert.equal(match[1], fixture.ordinanceCompanyDisclosure);
    assert.equal(ORDINANCE_COMPANY_DISCLOSURE, fixture.ordinanceCompanyDisclosure);
  });

  test("FEED_SQL の listed 条件は Swift feedListedQuery の生 SQL と揃う", () => {
    assert.ok(FEED_SQL.includes("ordinance_code = '010'"));
    assert.ok(FEED_SQL.includes("sec_code LIKE '____0'"));
    assert.ok(FEED_SQL.includes("sec_code <> '00000'"));
    assert.ok(
      feedServeSwift.includes("sec_code LIKE '____0' AND sec_code <> '00000'"),
      "FeedServe.swift に listed 判定の生 SQL が見つからない"
    );
  });
});

describe("listedTickerCode パリティ", () => {
  for (const { secCode, code } of fixture.listedTickerCode) {
    test(`secCode ${JSON.stringify(secCode)} → ${JSON.stringify(code)}`, () => {
      assert.equal(listedTickerCode(secCode), code);
    });
  }
});

describe("toFeedItem パリティ", () => {
  // fixture のレコード（Swift EdinetDocumentRecord 相当）を DB 行（snake_case）へ写す。
  // FEED_SQL が SELECT する列と対応させる（ordinance_code も SELECT 済み）。
  function toRow(record) {
    return {
      doc_id: record.docID,
      sec_code: record.secCode,
      filer_name: record.filerName,
      doc_type_code: record.docTypeCode,
      ordinance_code: record.ordinanceCode,
      period_end: record.periodEnd,
      submit_date_time: record.submitDateTime,
      doc_description: record.docDescription,
    };
  }

  for (const { record, item } of fixture.feedItems) {
    test(`${record.docID}（docType ${record.docTypeCode}）`, () => {
      assert.deepEqual(toFeedItem(toRow(record)), item);
    });
  }
});
