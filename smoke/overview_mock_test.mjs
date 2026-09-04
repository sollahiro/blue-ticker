import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync(new URL("./overview_mock.html", import.meta.url), "utf8");
assert.match(html, /overview_mock_expected\.json/);
assert.match(html, /会社説明はまだありません/);
assert.doesNotMatch(html, /\/v1\/companies/);

const payload = JSON.parse(
  fs.readFileSync(new URL("./overview_mock_expected.json", import.meta.url), "utf8")
);

assert.equal(payload.schema_version, 1);
assert.equal(payload.product_path, false);
assert.equal(payload.provider, "openrouter");
assert.equal(payload.input_key, "management_policy");
assert.deepEqual(payload.char_range, [50, 80]);
assert.ok(Array.isArray(payload.findings) && payload.findings.length >= 3);
assert.equal(typeof payload.cost.per_company_usd, "number");
assert.ok(payload.cost.per_company_usd > 0);
assert.ok(payload.cost.universe_usd > 0);

const amountRe = /(?:\d[\d,\.]*)\s*(?:円|億円|兆円|百万円|%|％|倍)/;
let applicable = 0;
let empty = 0;
for (const row of payload.companies) {
  assert.equal(row.input_key, "management_policy");
  assert.equal(row.char_count, row.overview.length);
  if (!row.applicable) {
    empty += 1;
    assert.equal(row.overview, "");
    continue;
  }
  applicable += 1;
  assert.ok(row.overview.length >= 50 && row.overview.length <= 80, row.code);
  assert.equal(amountRe.test(row.overview), false, row.code);
  assert.doesNotMatch(row.overview, /買い推奨|割安/);
}
assert.ok(applicable >= 1);
assert.ok(empty >= 1);

const mufg = payload.companies.find(item => item.code === "8306");
assert.ok(mufg);
assert.equal(mufg.applicable, false);
assert.equal(mufg.input_thin, true);

const context = vm.createContext({ console });
const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, "inline script must exist");
assert.match(script, /showGenerated/);
assert.match(script, /会社説明はまだありません/);
vm.runInContext(script.replace(/\binitialize\(\);\s*$/, ""), context);
