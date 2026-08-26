import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync(new URL("./sankey_prototype.html", import.meta.url), "utf8");
const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, "inline script must exist");

const context = vm.createContext({ console, Intl });
vm.runInContext(
  script.replace(/\binitialize\(\);\s*$/, "")
    + "\nglobalThis.sankeyTest = { state, buildFlow, formatValue, availableEarningDimensions, plBridge };",
  context
);

const payload = JSON.parse(
  fs.readFileSync(new URL("./sankey_prototype_expected.json", import.meta.url), "utf8")
);
const { state, buildFlow, formatValue, availableEarningDimensions, plBridge } = context.sankeyTest;

function sum(values) {
  return values.reduce((total, value) => total + value, 0);
}

function assertConserved(flow) {
  for (const stage of flow.stages) {
    assert.equal(sum(stage.nodes.map(node => node.value)), flow.total);
  }
  for (let boundary = 0; boundary < flow.stages.length - 1; boundary++) {
    assert.equal(
      sum(flow.links.filter(link => link.from[0] === boundary).map(link => link.value)),
      flow.total
    );
    assert.equal(
      sum(flow.links.filter(link => link.to[0] === boundary + 1).map(link => link.value)),
      flow.total
    );
  }
  assert.ok(flow.links.every(link => Math.abs(link.from[0] - link.to[0]) === 1));
}

assert.equal(payload.schema_version, 2);

for (const prototypeCase of payload.cases) {
  assert.equal(prototypeCase.cross_axis_links_available, false);
  assert.ok(Array.isArray(prototypeCase.dimensions));
  assert.equal(prototypeCase.axes, undefined);
  for (const dimension of prototypeCase.dimensions) {
    assert.notEqual(dimension.id, "pl");
    const counted = dimension.items
      .filter(item => item.row_kind === "segment" || item.row_kind === "reconciling")
      .reduce((total, item) => total + item.value, 0);
    assert.equal(counted, dimension.total);
  }
}

const sales = payload.cases.find(item => item.metric === "sales");
assert.ok(sales);
assert.ok(Array.isArray(sales.bridges));
assert.equal(sales.dimensions.some(item => item.id === "pl"), false);
const pl = sales.bridges.find(item => item.id === "profit_and_loss");
assert.ok(pl);
assert.equal(pl.accounting_standard, "us_gaap");
for (const stage of pl.stages) {
  assert.equal(sum(stage.items.map(item => item.value)), stage.conserved_total);
  const residualRatio = Math.abs(sum(stage.items.map(item => item.value)) - stage.conserved_total)
    / stage.conserved_total;
  assert.ok(residualRatio <= 0.05);
}
assert.equal(
  pl.stages.some(stage => stage.items.some(item => /経常|特別/.test(item.label))),
  false,
  "US-GAAP Canon must not invent 経常利益/特別損益"
);
assert.equal(Object.hasOwn(sales, "left_axis"), false);
assert.equal(Object.hasOwn(sales, "right_axis"), false);
assert.equal(Object.hasOwn(sales, "default_layout"), false);

state.selected = payload.cases.find(item => item.metric === "total_assets");
for (const mode of ["assets", "equity", "rd"]) {
  state.flowMode = mode;
  assertConserved(buildFlow());
}

state.selected = sales;
state.flowMode = "sales";
assert.deepEqual(
  availableEarningDimensions().map(item => item.id).sort(),
  ["business", "geography"]
);
assert.equal(plBridge().id, "profit_and_loss");

for (const earningId of ["business", "geography"]) {
  for (const bridgeView of ["operating", "gross"]) {
    state.earningDimensionId = earningId;
    state.bridgeView = bridgeView;
    const flow = buildFlow();
    assertConserved(flow);
    assert.equal(flow.stages.length, 3);
    assert.equal(flow.stages[1].label, "売上高");
    assert.equal(
      flow.stages[0].label,
      sales.dimensions.find(item => item.id === earningId).label
    );
    assert.match(flow.stages[2].label, /PL bridge/);
  }
}

for (const mode of ["gross_profit", "pretax_profit"]) {
  state.flowMode = mode;
  assertConserved(buildFlow());
}

assert.equal(formatValue(4_624_727_000_000), "4.624727兆円");
console.log("Sankey HTML flow tests passed");
