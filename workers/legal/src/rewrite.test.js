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
  assert.match(html, /App Store から入手して使用する利用者を対象とします/);
  assert.match(html, /必ず金融庁の EDINET 等で公式な原本を直接確認してください/);
  assert.match(html, /有価証券報告書等の原本を補完・閲覧しやすくするための補助ツール/);
  assert.match(html, /売上高や営業利益などの一般化された項目名に正規化/);
  assert.match(html, /画面上の項目名が各発行体の公式な科目名と一致しないことがあります/);
  assert.match(html, /表示内容を参考に利用した結果生じた一切の損害（投資損失等を含む）について、運営者は補償を行いません/);
  assert.match(html, /金融商品取引法上の金融商品取引業者（投資助言・代理業等）の登録を受けておらず/);
  assert.match(html, /投資勧誘や金融商品の売買・助言を目的としたものではありません/);
  assert.match(html, /必要と判断した場合に本規約を変更することができます/);
  assert.doesNotMatch(html, /わかりやすい説明/);
  assert.doesNotMatch(html, /要確認/);
  assert.doesNotMatch(html, /対価の範囲/);
  assert.doesNotMatch(html, /13歳/);
  assert.doesNotMatch(html, /MCP/);
  assert.doesNotMatch(html, /ChatGPT/);
  assert.doesNotMatch(html, /TestFlight/);
  assert.doesNotMatch(html, /必要と判断したした場合/);
});
