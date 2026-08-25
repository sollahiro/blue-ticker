import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync(new URL("./sankey_prototype.html", import.meta.url), "utf8");
const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, "inline script must exist");

const context = vm.createContext({ console, Intl });
vm.runInContext(
  script.replace(/\binitialize\(\);\s*$/, "")
    + "\nglobalThis.sankeyTest = { state, buildFlow, formatValue };",
  context
);

const payload = JSON.parse(
  fs.readFileSync(new URL("./sankey_prototype_expected.json", import.meta.url), "utf8")
);
const { state, buildFlow, formatValue } = context.sankeyTest;

function sum(values) {
  return values.reduce((total, value) => total + value, 0);
}

function assertConserved(flow) {
  for (const stage of flow.stages) {
    assert.equal(sum(stage.nodes.map(node => node.value)), flow.total);
  }
  const hubIncoming = sum(flow.links.filter(link => link.to[0] === 1).map(link => link.value));
  const hubOutgoing = sum(flow.links.filter(link => link.from[0] === 1).map(link => link.value));
  assert.equal(hubIncoming, flow.total);
  assert.equal(hubOutgoing, flow.total);
  assert.ok(flow.links.every(link => Math.abs(link.from[0] - link.to[0]) === 1));
}

state.selected = payload.cases.find(item => item.metric === "total_assets");
assertConserved(buildFlow());

state.selected = payload.cases.find(item => item.metric === "sales");
for (const mode of ["business", "pl_gross", "pl_operating"]) {
  state.rightAxisMode = mode;
  const flow = buildFlow();
  assertConserved(flow);
  assert.equal(flow.stages[0].label, "地域別");
  assert.equal(flow.stages[1].label, "売上高");
}

assert.equal(formatValue(4_624_727_000_000), "4.624727兆円");
console.log("Sankey HTML flow tests passed");
