import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import worker, { assetPathFor, redirectLocationFor } from "./index.js";

const publicDir = join(dirname(fileURLToPath(import.meta.url)), "../public");

test("privacy aliases rewrite to /privacy", () => {
  assert.equal(assetPathFor("/privacy"), "/privacy");
  assert.equal(assetPathFor("/privacy/"), "/privacy");
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
    ["/privacy", "/privacy"],
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

test("privacy page names the operator Sorahiro Shuto", () => {
  const privacy = readFileSync(join(publicDir, "privacy.html"), "utf8");
  assert.match(privacy, /運営: Sorahiro Shuto/);
  assert.doesNotMatch(privacy, /個人開発/);
});

test("landing page links legal pages and avoids advice or old names", () => {
  const html = readFileSync(join(publicDir, "index.html"), "utf8");
  assert.match(html, /<title>有報LAB/);
  assert.match(html, /href="\/privacy"/);
  assert.match(html, /href="\/terms"/);
  assert.match(html, /href="mailto:support@yuholab\.com"/);
  assert.match(html, /EDINET閲覧（提出）サイト/);
  assert.match(html, /投資の勧誘・助言を目的としたものではありません/);
  assert.match(html, /運営: Sorahiro Shuto/);
  assert.doesNotMatch(html, /Blue Ticker|ブルーティッカー|ChatGPT|TestFlight/);
  assert.doesNotMatch(html, /\/blue-ticker\//);
});

test("privacy disclaimer matches product facts without overbroad liability", () => {
  const html = readFileSync(join(publicDir, "privacy.html"), "utf8");
  assert.match(html, /閲覧補助サービス/);
  // 公開コネクタ（HAPIS mcp/）の章: 識別子はハッシュのみ、会話本文は届かない、出典表示。
  assert.match(html, /<h2>3\. 有報LAB コネクタ（AI アシスタント向け）<\/h2>/);
  assert.match(html, /一方向のハッシュ値だけを保存します/);
  assert.match(html, /会話の本文、ファイル、AI アシスタントに登録した利用者の情報は、コネクタには届きません/);
  assert.match(html, /コネクタでは、この端末の確認ができません/);
  assert.match(html, /個別の削除の依頼には原則として応じられません/);
  assert.match(html, /出典：<a href="https:\/\/disclosure2\.edinet-fsa\.go\.jp\/">EDINET閲覧（提出）サイト<\/a>/);
  assert.match(html, /公共データ利用規約（第1\.0版）/);
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
  assert.match(html, /有報LAB API（YuhoLAB API）から取得します/);
  assert.doesNotMatch(html, /blueticker@sollahiro\.com/);
  assert.doesNotMatch(html, /\/blue-ticker\//);
  assert.doesNotMatch(html, /Blue Ticker|ブルーティッカー/);
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
  // チャット機能は削除済み。質問をサーバー・外部 AI へ送る記述を戻さない。
  assert.doesNotMatch(html, /チャットで送る質問|OpenRouter/);
  assert.doesNotMatch(html, /Crashlytics/);
  assert.doesNotMatch(html, /Firebase/);
  assert.doesNotMatch(html, /Sentry/);
  assert.doesNotMatch(html, /TelemetryDeck/);
  assert.doesNotMatch(html, /13 歳未満/);
  assert.doesNotMatch(html, /一切の責任を負/);
  assert.doesNotMatch(html, /TestFlight/);
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
  assert.match(html, /本アプリは、運営者が運営する有報LAB API（YuhoLAB API）を利用して作られています/);
  assert.match(html, /最終更新: 2026-11-08/);
  assert.match(html, /第9条（データの利用および免責）/);
  assert.match(html, /個人的または商業的な目的を問わず、自由に利用、複製、加工、再配布および第三者への提供を行うことができます/);
  assert.match(html, /出典（「有報LAB」および EDINET）を表示し、加工されたものである旨を示すよう努めるものとします/);
  assert.match(html, /正確性、完全性、最新性、有用性または特定の目的への適合性を保証しません/);
  assert.match(html, /「本コネクタ」：運営者が提供する、AI サービスから本 API のデータを読み出すための接続先/);
  assert.match(html, /AI サービスによる要約、解釈、計算その他の回答の内容について責任を負いません/);
  assert.match(html, /href="mailto:support@yuholab.com">support@yuholab.com</);
  assert.match(html, /<a href="\/privacy">https:\/\/yuholab.com\/privacy<\/a>/);
  assert.doesNotMatch(html, /blueticker@sollahiro\.com/);
  assert.doesNotMatch(html, /\/blue-ticker\//);
  assert.doesNotMatch(html, /Blue Ticker|ブルーティッカー/);
  assert.doesNotMatch(html, /わかりやすい説明/);
  assert.doesNotMatch(html, /要確認/);
  assert.doesNotMatch(html, /対価の範囲/);
  assert.doesNotMatch(html, /13歳/);
  assert.doesNotMatch(html, /ChatGPT/);
  assert.doesNotMatch(html, /TestFlight/);
  assert.doesNotMatch(html, /必要と判断したした場合/);
});

test("English pages are translations of the Japanese pages", () => {
  const privacy = readFileSync(join(publicDir, "en/privacy.html"), "utf8");
  const terms = readFileSync(join(publicDir, "en/terms.html"), "utf8");
  assert.match(privacy, /<html lang="en">/);
  assert.match(terms, /<html lang="en">/);
  assert.match(privacy, /<h1>YuhoLAB Disclaimer and Privacy Policy<\/h1>/);
  assert.match(terms, /<h1>YuhoLAB Terms of Use<\/h1>/);
  // 日本語版との相互リンクと、事実の記述が同じであること。
  assert.match(privacy, /href="\/privacy">日本語</);
  assert.match(terms, /href="\/terms">日本語</);
  assert.match(privacy, /Individual deletion requests therefore cannot, in principle, be accommodated/);
  assert.match(privacy, /Source: <a href="https:\/\/disclosure2\.edinet-fsa\.go\.jp\//);
  assert.match(privacy, /Public Data License \(Version 1\.0\)/);
  assert.match(privacy, /you sign in with a Google account/);
  assert.match(terms, /Osaka District Court/);
  assert.match(terms, /shall endeavor to credit the source/);
  assert.match(terms, /Article 9 \(Use of data and disclaimer\)/);
  assert.match(terms, /Last updated: 2026-11-08/);
  assert.match(terms, /support@yuholab\.com/);
  assert.doesNotMatch(privacy, /OpenRouter|Sign in with Apple/);
  for (const html of [privacy, terms]) {
    assert.doesNotMatch(html, /[ぁ-んァ-ヶ]/, "no kana in the English page");
  }
  const ja = readFileSync(join(publicDir, "privacy.html"), "utf8");
  assert.match(ja, /href="\/en\/privacy">English</);
});
