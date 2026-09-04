import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync(new URL("./overview_mock.html", import.meta.url), "utf8");
assert.match(html, /overview_mock_expected\.json/);
assert.match(html, /会社説明はまだありません/);
assert.match(html, /事業の内容/);
assert.match(html, /だ・である/);
assert.match(html, /を提供。/);
assert.match(html, /を手がける。/);
assert.doesNotMatch(html, /\/v1\/companies/);
assert.doesNotMatch(html, /BLT-\d+/);

const payload = JSON.parse(
  fs.readFileSync(new URL("./overview_mock_expected.json", import.meta.url), "utf8")
);

assert.equal(payload.title, "Overview mock");
assert.doesNotMatch(JSON.stringify(payload), /BLT-\d+/);
const source = fs.readFileSync(new URL("./overview_mock.py", import.meta.url), "utf8");
assert.doesNotMatch(source, /BLT-\d+/);
const ios = fs.readFileSync(new URL("../docs/ios-client.md", import.meta.url), "utf8");
const overviewRow = ios.split("\n").find(line => line.startsWith("| 概要 | Summary"));
assert.ok(overviewRow);
assert.doesNotMatch(overviewRow, /BLT-\d+/);

assert.equal(payload.schema_version, 1);
assert.equal(payload.product_path, false);
assert.equal(payload.provider, "openrouter");
assert.equal(payload.input_key, "description_of_business");
assert.equal(payload.section_title, "事業の内容");
assert.equal(payload.xbrl_tag, "DescriptionOfBusinessTextBlock");
assert.deepEqual(payload.char_range, [50, 80]);
assert.ok(Array.isArray(payload.findings) && payload.findings.length >= 3);
assert.match(payload.findings.join("\n"), /事業の内容/);
assert.match(payload.findings.join("\n"), /だ・である/);
assert.match(payload.findings.join("\n"), /を提供。/);
assert.match(payload.findings.join("\n"), /を手がける。/);
assert.equal(typeof payload.cost.per_company_usd, "number");
assert.ok(payload.cost.per_company_usd > 0);
assert.ok(payload.cost.universe_usd > 0);

const amountRe = /(?:\d[\d,\.]*)\s*(?:円|億円|兆円|百万円|%|％|倍)/;
let applicable = 0;
for (const row of payload.companies) {
  assert.equal(row.input_key, "description_of_business");
  assert.equal(row.char_count, row.overview.length);
  if (!row.applicable) {
    assert.equal(row.overview, "");
    continue;
  }
  applicable += 1;
  assert.ok(row.overview.length >= 50 && row.overview.length <= 80, row.code);
  assert.equal(amountRe.test(row.overview), false, row.code);
  assert.doesNotMatch(row.overview, /買い推奨|割安/);
  assert.doesNotMatch(row.overview, /です|ます|でした|ました/, `${row.code} だ・である調`);
}
assert.equal(applicable, payload.companies.length);

const toyota = payload.companies.find(item => item.code === "7203");
assert.ok(toyota);
assert.match(toyota.overview, /自動車|金融/);

const mufg = payload.companies.find(item => item.code === "8306");
assert.ok(mufg);
assert.equal(mufg.applicable, true);
assert.equal(mufg.input_thin, false);
assert.match(mufg.overview, /銀行|信託|証券|金融/);

const context = vm.createContext({ console });
const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, "inline script must exist");
assert.match(script, /showGenerated/);
assert.match(script, /会社説明はまだありません/);
vm.runInContext(script.replace(/\binitialize\(\);\s*$/, ""), context);
