/**
 * 有報LAB（iOS アプリ）の免責・プライバシー・利用規約。
 * 配信: yuholab.com の / と /privacy（免責・プライバシー）、/terms（利用規約）。workers.dev も同じ。
 * sollahiro.com の旧 URL 6 パスは yuholab.com の対応ページへ 301 で直接飛ばす。
 * 前方一致にしないのは、sollahiro.com/blue-ticker/... に有報LAB API のページを置けるようにするため。
 */
export const CANONICAL_ORIGIN = "https://yuholab.com";

const REDIRECTS = new Map([
  ["/blue-ticker", "/"],
  ["/blue-ticker/privacy", "/privacy"],
  ["/blue-ticker/terms", "/terms"],
  ["/yuholab", "/"],
  ["/yuholab/privacy", "/privacy"],
  ["/yuholab/terms", "/terms"],
]);

const trimTrailingSlash = (pathname) => pathname.replace(/\/+$/, "") || "/";

// 旧 URL なら yuholab.com の転送先 URL、それ以外は null。末尾スラッシュは無視する。
export function redirectLocationFor(pathname) {
  const target = REDIRECTS.get(trimTrailingSlash(pathname));
  return target === undefined ? null : CANONICAL_ORIGIN + target;
}

export function assetPathFor(pathname) {
  const path = trimTrailingSlash(pathname);
  if (path === "/privacy") {
    return "/";
  }
  if (path === "/terms") {
    // Assets は /terms.html を /terms へ 307 するため、.html に書き換えない。
    return "/terms";
  }
  return pathname;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const location = redirectLocationFor(url.pathname);
    if (location !== null) {
      return Response.redirect(location, 301);
    }
    const rewritten = assetPathFor(url.pathname);
    if (rewritten !== url.pathname) {
      url.pathname = rewritten;
      return env.ASSETS.fetch(new Request(url.toString(), request));
    }
    return env.ASSETS.fetch(request);
  },
};
