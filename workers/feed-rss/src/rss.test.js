// rss.js / query.js の単体テスト。Worker 入口（index.js）は import しない
// （@neondatabase/serverless 無しで node --test を回せるようにするため）。

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import {
  EDINET_VIEWER_URL_BASE,
  buildRss,
  edinetDocumentUrl,
  escapeXml,
  jstToRfc822,
  utcToRfc822Jst,
} from "./rss.js";
import {
  docTypeLabel,
  feedCutoffDateString,
  listedTickerCode,
  toFeedItem,
} from "./query.js";

describe("escapeXml", () => {
  test("5 つの予約文字をエスケープする", () => {
    assert.equal(
      escapeXml(`&<>"'`),
      "&amp;&lt;&gt;&quot;&apos;"
    );
  });

  test("日本語の会社名はそのまま残す", () => {
    assert.equal(
      escapeXml("A&B <ホールディングス>"),
      "A&amp;B &lt;ホールディングス&gt;"
    );
  });

  test("XML 1.0 で不正な制御文字は除去する", () => {
    assert.equal(escapeXml("a\u0001b\u001fc\td\ne"), "abc\td\ne");
  });

  test("null / undefined は空文字", () => {
    assert.equal(escapeXml(null), "");
    assert.equal(escapeXml(undefined), "");
  });
});

describe("jstToRfc822", () => {
  test("分までの提出日時", () => {
    assert.equal(
      jstToRfc822("2026-10-09 15:30"),
      "Fri, 09 Oct 2026 15:30:00 +0900"
    );
  });

  test("UTC では前日になる早朝 JST でも JST の日付のまま", () => {
    assert.equal(
      jstToRfc822("2026-01-01 08:00"),
      "Thu, 01 Jan 2026 08:00:00 +0900"
    );
  });

  test("秒つきと T 区切りを受け付ける", () => {
    assert.equal(
      jstToRfc822("2026-10-09 15:30:45"),
      "Fri, 09 Oct 2026 15:30:45 +0900"
    );
    assert.equal(
      jstToRfc822("2026-10-09T15:30:00"),
      "Fri, 09 Oct 2026 15:30:00 +0900"
    );
  });

  test("日付だけは 00:00 とみなす", () => {
    assert.equal(
      jstToRfc822("2026-10-09"),
      "Fri, 09 Oct 2026 00:00:00 +0900"
    );
  });

  test("パースできない入力は null", () => {
    assert.equal(jstToRfc822("bogus"), null);
    assert.equal(jstToRfc822(""), null);
    assert.equal(jstToRfc822(null), null);
    assert.equal(jstToRfc822("2026/10/09 15:30"), null);
  });
});

describe("utcToRfc822Jst", () => {
  test("UTC の絶対時刻を JST 表記へ", () => {
    assert.equal(
      utcToRfc822Jst(new Date("2026-10-10T10:15:00Z")),
      "Sat, 10 Oct 2026 19:15:00 +0900"
    );
  });
});

describe("edinetDocumentUrl", () => {
  test("EDINET 提出書類内容照会画面の URL になる", () => {
    assert.equal(
      edinetDocumentUrl("S100AAA"),
      "https://disclosure2.edinet-fsa.go.jp/WZEK0040.aspx?S100AAA"
    );
  });

  test("doc_id は URL エスケープされる", () => {
    assert.equal(
      edinetDocumentUrl("S100 A&B"),
      `${EDINET_VIEWER_URL_BASE}S100%20A%26B`
    );
  });
});

describe("listedTickerCode", () => {
  test("5 桁・末尾 0 は 4 桁コード", () => {
    assert.equal(listedTickerCode("72030"), "7203");
    assert.equal(listedTickerCode("477A0"), "477A");
  });

  test("00000 と形式外は null", () => {
    assert.equal(listedTickerCode("00000"), null);
    assert.equal(listedTickerCode("7203"), null);
    assert.equal(listedTickerCode("72031"), null);
    assert.equal(listedTickerCode(null), null);
    assert.equal(listedTickerCode(undefined), null);
  });
});

describe("feedCutoffDateString", () => {
  test("7 日窓は今日を含めて 6 日前が下限", () => {
    assert.equal(
      feedCutoffDateString(7, new Date("2026-10-10T10:15:00Z")),
      "2026-10-04"
    );
  });

  test("月またぎ", () => {
    assert.equal(
      feedCutoffDateString(7, new Date("2026-03-02T00:00:00Z")),
      "2026-02-24"
    );
  });
});

describe("docTypeLabel", () => {
  test("既知コードはラベル、未知は docDescription へフォールバック", () => {
    assert.equal(docTypeLabel("120", "有価証券報告書－第100期"), "有価証券報告書");
    assert.equal(docTypeLabel("999", "その他の書類"), "その他の書類");
  });
});

describe("toFeedItem", () => {
  const baseRow = {
    doc_id: "S100TEST",
    sec_code: "72030",
    filer_name: "テスト株式会社",
    doc_type_code: "120",
    period_end: "2026-03-31",
    submit_date_time: "2026-10-09 15:30",
    doc_description: "有価証券報告書－第100期",
  };

  test("listed 行のマッピング（fy_end は先頭 7 文字）", () => {
    assert.deepEqual(toFeedItem(baseRow), {
      code: "7203",
      name: "テスト株式会社",
      doc_id: "S100TEST",
      doc_type: "120",
      doc_type_label: "有価証券報告書",
      fy_end: "2026-03",
      submitted_at: "2026-10-09 15:30",
    });
  });

  test("未知書類種別は doc_description にフォールバック", () => {
    const item = toFeedItem({ ...baseRow, doc_type_code: "999", doc_description: "その他" });
    assert.equal(item.doc_type_label, "その他");
  });

  test("period_end が短い・null のとき", () => {
    assert.equal(toFeedItem({ ...baseRow, period_end: "2026" }).fy_end, "2026");
    assert.equal(toFeedItem({ ...baseRow, period_end: null }).fy_end, "");
  });

  test("非上場・府令 010 以外は null", () => {
    assert.equal(toFeedItem({ ...baseRow, sec_code: "72031" }), null);
    assert.equal(toFeedItem({ ...baseRow, ordinance_code: "020" }), null);
  });
});

describe("buildRss", () => {
  const items = [
    {
      code: "7203",
      name: "A&B <ホールディングス>",
      doc_id: "S100AAA",
      doc_type: "120",
      doc_type_label: "有価証券報告書",
      fy_end: "2026-03",
      submitted_at: "2026-10-09 15:30",
    },
    {
      code: "477A",
      name: "サンプル商事",
      doc_id: "S100BBB",
      doc_type: "160",
      doc_type_label: "半期報告書",
      fy_end: "2026-03",
      submitted_at: "not-a-date",
    },
  ];
  const xml = buildRss({
    items,
    now: new Date("2026-10-10T10:15:00Z"),
    feedUrl: "https://feed.sollahiro.com/blue-ticker/edinet-filings.xml",
  });

  test("XML 宣言とチャネル要素", () => {
    assert.ok(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
    assert.ok(xml.includes('<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">'));
    assert.ok(xml.includes("<title>Blue Ticker — EDINET 提出書類（上場）</title>"));
    assert.ok(xml.includes("<link>https://sollahiro.com/blue-ticker/</link>"));
    assert.ok(xml.includes("<language>ja</language>"));
    assert.ok(xml.includes("<lastBuildDate>Sat, 10 Oct 2026 19:15:00 +0900</lastBuildDate>"));
    assert.ok(xml.includes("<ttl>1440</ttl>"));
    assert.ok(
      xml.includes(
        '<atom:link href="https://feed.sollahiro.com/blue-ticker/edinet-filings.xml" rel="self" type="application/rss+xml"/>'
      )
    );
  });

  test("item の数と内容", () => {
    assert.equal((xml.match(/<item>/g) ?? []).length, 2);
    // タイトルは `{name}（{code}） {doc_type_label}`
    assert.ok(
      xml.includes("<title>A&amp;B &lt;ホールディングス&gt;（7203） 有価証券報告書</title>")
    );
    assert.ok(xml.includes('<guid isPermaLink="false">S100AAA</guid>'));
    assert.ok(xml.includes("<pubDate>Fri, 09 Oct 2026 15:30:00 +0900</pubDate>"));
    // category は書類種別と証券コードの 2 つ
    assert.ok(xml.includes('<category domain="edinet:doc_type">120</category>'));
    assert.ok(xml.includes('<category domain="jp:sec_code">7203</category>'));
    assert.ok(xml.includes("<description>決算期: 2026-03 / 証券コード: 7203</description>"));
  });

  test("item の link は EDINET 提出書類内容照会画面", () => {
    assert.ok(
      xml.includes(
        "<link>https://disclosure2.edinet-fsa.go.jp/WZEK0040.aspx?S100AAA</link>"
      )
    );
    assert.ok(
      xml.includes(
        "<link>https://disclosure2.edinet-fsa.go.jp/WZEK0040.aspx?S100BBB</link>"
      )
    );
  });

  test("会社ページのプレースホルダ URL は出力に含まれない", () => {
    assert.ok(!xml.includes("sollahiro.com/blue-ticker/companies"));
  });

  test("pubDate がパースできない item は pubDate 要素を出さない", () => {
    const second = xml.slice(xml.indexOf("S100BBB"));
    assert.ok(!second.includes("<pubDate>"));
  });

  test("アイコン・画像は出さない", () => {
    assert.ok(!xml.includes("<enclosure"));
    assert.ok(!xml.includes("<image"));
  });
});
