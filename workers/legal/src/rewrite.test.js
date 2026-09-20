import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { assetPathFor } from "./index.js";

const publicDir = join(dirname(fileURLToPath(import.meta.url)), "../public");

test("privacy aliases rewrite to /", () => {
  assert.equal(assetPathFor("/privacy"), "/");
  assert.equal(assetPathFor("/privacy/"), "/");
  assert.equal(assetPathFor("/blue-ticker"), "/");
  assert.equal(assetPathFor("/blue-ticker/"), "/");
  assert.equal(assetPathFor("/blue-ticker/privacy"), "/");
  assert.equal(assetPathFor("/blue-ticker/privacy/"), "/");
});

test("terms aliases rewrite to /terms.html", () => {
  assert.equal(assetPathFor("/terms"), "/terms.html");
  assert.equal(assetPathFor("/terms/"), "/terms.html");
  assert.equal(assetPathFor("/blue-ticker/terms"), "/terms.html");
  assert.equal(assetPathFor("/blue-ticker/terms/"), "/terms.html");
});

test("root and unknown paths pass through", () => {
  assert.equal(assetPathFor("/"), "/");
  assert.equal(assetPathFor("/terms.html"), "/terms.html");
  assert.equal(assetPathFor("/no-such-page"), "/no-such-page");
});

test("privacy pages name the operator Sorahiro Shuto", () => {
  const index = readFileSync(join(publicDir, "index.html"), "utf8");
  const privacy = readFileSync(join(publicDir, "privacy.html"), "utf8");
  assert.match(index, /運営: Sorahiro Shuto/);
  assert.match(privacy, /運営: Sorahiro Shuto/);
  assert.doesNotMatch(index, /個人開発/);
  assert.doesNotMatch(privacy, /個人開発/);
});

test("terms page is auxiliary to the original filing", () => {
  const html = readFileSync(join(publicDir, "terms.html"), "utf8");
  assert.match(html, /運営: Sorahiro Shuto/);
  assert.match(html, /利用者は必ず原本も合わせて見てください/);
  assert.match(html, /本サービスは有価証券報告書の原本の補助です/);
  assert.match(html, /補助である以上/);
  assert.match(html, /表示を参考にして行った投資の結果について、運営者は損害を補填しません/);
  assert.match(html, /原本との違いから生じた損害も同様です/);
  assert.match(html, /本サービスは投資の勧誘ではありません/);
  assert.match(html, /これは、本サービスが原本の補助にすぎず/);
  assert.doesNotMatch(html, /要確認/);
  assert.doesNotMatch(html, /対価の範囲/);
});
