import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import worker, { assetPathFor, redirectLocationFor } from "./index.js";

const publicDir = join(dirname(fileURLToPath(import.meta.url)), "../public");

test("privacy aliases rewrite to /", () => {
  assert.equal(assetPathFor("/privacy"), "/");
  assert.equal(assetPathFor("/privacy/"), "/");
});

test("terms aliases rewrite to /terms", () => {
  assert.equal(assetPathFor("/terms"), "/terms");
  assert.equal(assetPathFor("/terms/"), "/terms");
});

const OLD_URLS = [
  ["/blue-ticker", "https://yuholab.com/"],
  ["/blue-ticker/privacy", "https://yuholab.com/privacy"],
  ["/blue-ticker/terms", "https://yuholab.com/terms"],
  ["/yuholab", "https://yuholab.com/"],
  ["/yuholab/privacy", "https://yuholab.com/privacy"],
  ["/yuholab/terms", "https://yuholab.com/terms"],
];

test("old sollahiro.com paths redirect to yuholab.com, trailing slash ignored", () => {
  for (const [path, location] of OLD_URLS) {
    assert.equal(redirectLocationFor(path), location, path);
    assert.equal(redirectLocationFor(`${path}/`), location, `${path}/`);
  }
});

test("only the six old paths redirect (no prefix match)", () => {
  for (const path of [
    "/",
    "/privacy",
    "/terms",
    "/blue-ticker/api",
    "/blue-ticker/privacy/extra",
    "/yuholab/other",
    "/blue-tickerx",
  ]) {
    assert.equal(redirectLocationFor(path), null, path);
  }
});

// ASSETS はリクエストされたパスを返すだけのフェイク。
function fakeEnv() {
  const fetched = [];
  return {
    fetched,
    ASSETS: {
      async fetch(request) {
        fetched.push(new URL(request.url).pathname);
        return new Response("asset", { status: 200 });
      },
    },
  };
}

test("sollahiro.com old URLs answer one 301 straight to yuholab.com", async () => {
  for (const [path, location] of OLD_URLS) {
    const env = fakeEnv();
    const response = await worker.fetch(new Request(`https://sollahiro.com${path}`), env);
    assert.equal(response.status, 301, path);
    assert.equal(response.headers.get("Location"), location, path);
    assert.equal(env.fetched.length, 0, path);
    // 転送先は配信対象で、さらに転送されない（1 回で届く）。
    assert.equal(redirectLocationFor(new URL(location).pathname), null, location);
  }
});

test("yuholab.com serves /, /privacy and /terms from assets", async () => {
  const cases = [
    ["/", "/"],
    ["/privacy", "/"],
    ["/terms", "/terms"],
  ];
  for (const [path, assetPath] of cases) {
    const env = fakeEnv();
    const response = await worker.fetch(new Request(`https://yuholab.com${path}`), env);
    assert.equal(response.status, 200, path);
    assert.deepEqual(env.fetched, [assetPath], path);
  }
});

test("root and unknown paths pass through", () => {
  assert.equal(assetPathFor("/"), "/");
  assert.equal(assetPathFor("/terms.html"), "/terms.html");
  assert.equal(assetPathFor("/no-such-page"), "/no-such-page");
});

test("privacy pages name the operator Sorahiro Shuto", () => {
  const index = readFileSync(join(publicDir, "index.html"), "utf8");
  const privacy = readFileSync(join(publicDir, "privacy.html"), "utf8");
  assert.equal(index, privacy);
  assert.match(index, /運営: Sorahiro Shuto/);
  assert.doesNotMatch(index, /個人開発/);
});

test("privacy disclaimer matches product facts without overbroad liability", () => {
  const html = readFileSync(join(publicDir, "index.html"), "utf8");
  assert.match(html, /閲覧補助アプリ/);
  assert.match(
    html,
    /金融商品取引法上の金融商品取引業者（投資助言・代理業者等）の登録を受けていません/,
  );
  assert.match(html, /生成AI等による要約/);
  assert.match(html, /有効期限の短い匿名トークン/);
  assert.match(
    html,
    /運営者のデータベースにIPアドレスを永続的に保存することはありません/,
  );
  assert.match(html, /href="mailto:support@yuholab.com">support@yuholab.com</);
  assert.match(html, /href="\/terms">有報LAB 利用規約</);
  assert.match(html, /<title>有報LAB 免責事項およびプライバシーポリシー<\/title>/);
  assert.match(html, /<h1>有報LAB 免責事項およびプライバシーポリシー<\/h1>/);
  assert.match(html, /「アカウントのストレージを管理」から有報LAB のデータを削除してください/);
  assert.match(html, /ブルーティッカーAPI（Blue Ticker API）から取得します/);
  assert.doesNotMatch(html, /blueticker@sollahiro\.com/);
  assert.doesNotMatch(html, /\/blue-ticker\//);
  assert.doesNotMatch(html, /Blue Ticker の|Blue Ticker 免責|Blue Ticker 利用規約/);
  assert.match(
    html,
    /iOSのKeychainに保存された匿名トークンやApp Attestの記録は、アプリ削除だけでは消えない場合があります/,
  );
  assert.match(html, /広告用識別子ではなく/);
  assert.equal((html.match(/広告[用]?識別子/g) || []).length, 1);
  assert.doesNotMatch(html, /正本/);
  assert.doesNotMatch(html, /いたしかねます/);
  assert.doesNotMatch(html, /お知らせいたします/);
  assert.doesNotMatch(html, /運営者は保証を行いません/);
  assert.doesNotMatch(
    html,
    /App Attestの鍵は、正規アプリからのアクセス確認と不正利用防止のための証明用であり、広告識別子ではありません/,
  );
  assert.doesNotMatch(html, /Crashlytics/);
  assert.doesNotMatch(html, /Firebase/);
  assert.doesNotMatch(html, /Sentry/);
  assert.doesNotMatch(html, /TelemetryDeck/);
  assert.doesNotMatch(html, /13 歳未満/);
  assert.doesNotMatch(html, /一切の責任を負/);
  assert.doesNotMatch(html, /TestFlight/);
  assert.doesNotMatch(html, /MCP/);
  assert.doesNotMatch(html, /ChatGPT/);
  assert.doesNotMatch(html, /2026-09-19/);
  assert.doesNotMatch(html, /端末を識別できない/);
  assert.doesNotMatch(
    html,
    /端末内のデータや認証情報は、アプリをアンインストールすることで消去されます/,
  );
});

test("terms page is auxiliary to the original filing", () => {
  const html = readFileSync(join(publicDir, "terms.html"), "utf8");
  assert.match(html, /運営: Sorahiro Shuto/);
  assert.match(html, /App Store から入手して使用する利用者を対象とします/);
  assert.match(html, /必ず金融庁の EDINET や当該企業が開示する公式情報・原本を直接確認してください/);
  assert.match(html, /有価証券報告書等の原本を補完・閲覧しやすくするための補助ツール/);
  assert.match(html, /自動処理や生成AI等により再構成/);
  assert.match(html, /App Attest 等による安全確認・認証が正常に完了しない場合/);
  assert.match(html, /運営者が定める一定の表示基準・閾値に達していない項目/);
  assert.match(html, /EDINET 等で開示される原本の完全な再現や、全銘柄・全年度の完全な網羅を提供するものではありません/);
  assert.match(html, /売上高や営業利益などの一般化された項目名に正規化/);
  assert.match(html, /画面上の項目名が各発行体の公式な科目名と一致しないことがあります/);
  assert.match(html, /表示内容を参考に利用した結果生じた一切の損害（投資損失等を含む）について、運営者は補償を行いません/);
  assert.match(html, /金融商品取引法上の金融商品取引業者（投資助言・代理業等）の登録を受けておらず/);
  assert.match(html, /投資勧誘や金融商品の売買・助言を目的としたものではありません/);
  assert.match(html, /必要と判断した場合に本規約を変更することができます/);
  assert.match(html, /<title>有報LAB 利用規約<\/title>/);
  assert.match(html, /<h1>有報LAB 利用規約<\/h1>/);
  assert.match(html, /「本アプリ」：運営者が配布する iOS アプリケーション「有報LAB」をいいます/);
  assert.match(html, /本アプリは、運営者が運営するブルーティッカーAPI（Blue Ticker API）を利用して作られています/);
  assert.match(html, /最終更新: 2026-10-22/);
  assert.match(html, /href="mailto:support@yuholab.com">support@yuholab.com</);
  assert.match(html, /<a href="\/privacy">https:\/\/yuholab.com\/privacy<\/a>/);
  assert.doesNotMatch(html, /blueticker@sollahiro\.com/);
  assert.doesNotMatch(html, /\/blue-ticker\//);
  assert.doesNotMatch(html, /サービス「Blue Ticker」|アプリケーション「Blue Ticker」|Blue Ticker 利用規約/);
  assert.doesNotMatch(html, /わかりやすい説明/);
  assert.doesNotMatch(html, /要確認/);
  assert.doesNotMatch(html, /対価の範囲/);
  assert.doesNotMatch(html, /13歳/);
  assert.doesNotMatch(html, /MCP/);
  assert.doesNotMatch(html, /ChatGPT/);
  assert.doesNotMatch(html, /TestFlight/);
  assert.doesNotMatch(html, /必要と判断したした場合/);
});
