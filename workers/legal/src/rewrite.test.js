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

test("terms aliases rewrite to /terms", () => {
  assert.equal(assetPathFor("/terms"), "/terms");
  assert.equal(assetPathFor("/terms/"), "/terms");
  assert.equal(assetPathFor("/blue-ticker/terms"), "/terms");
  assert.equal(assetPathFor("/blue-ticker/terms/"), "/terms");
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
  assert.match(html, /有価証券報告書の原本の補助/);
  assert.match(html, /売上高、営業利益その他の一般的な項目名に正規化/);
  assert.match(html, /開示上の科目名と一致しないことがあります/);
  assert.match(html, /表示内容を参考にして行った投資活動により生じた損害を、運営者は補填しません/);
  assert.match(html, /原本との差異により生じた損害も、同様に補填しません/);
  assert.match(html, /金融商品取引法上の金融商品取引業者、投資助言・代理業その他の登録を受けていません/);
  assert.match(html, /本サービスは投資の勧誘ではありません/);
  assert.doesNotMatch(html, /わかりやすい説明/);
  assert.doesNotMatch(html, /要確認/);
  assert.doesNotMatch(html, /対価の範囲/);
  assert.doesNotMatch(html, /13歳/);
  assert.doesNotMatch(html, /MCP/);
  assert.doesNotMatch(html, /ChatGPT/);
});
