/**
 * 有報LAB（iOS アプリ）の免責・プライバシー・利用規約。
 * 配信: yuholab.com の / （ランディングページ）、/privacy（免責・プライバシー）、/terms（利用規約）。workers.dev も同じ。
 * sollahiro.com の旧 URL 6 パスの 301 は、sollahiro.com を持つ別 Worker（sollahiro-home、リポジトリ外）が担う。
 */
const trimTrailingSlash = (pathname) => pathname.replace(/\/+$/, "") || "/";

export function assetPathFor(pathname) {
  const path = trimTrailingSlash(pathname);
  if (path === "/privacy" || path === "/terms" || path === "/connector") {
    // Assets は /privacy.html・/terms.html を拡張子なしへ 307 するため、.html に書き換えない。
    return path;
  }
  return pathname;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const rewritten = assetPathFor(url.pathname);
    if (rewritten !== url.pathname) {
      url.pathname = rewritten;
      return env.ASSETS.fetch(new Request(url.toString(), request));
    }
    return env.ASSETS.fetch(request);
  },
};
