/**
 * App Store 用の免責・プライバシー・利用規約。
 * privacy: workers.dev の / と /privacy、sollahiro.com/blue-ticker(/privacy)
 * terms: /terms と /blue-ticker/terms
 */
export function assetPathFor(pathname) {
  const path = pathname.replace(/\/+$/, "") || "/";
  if (
    path === "/privacy" ||
    path === "/blue-ticker" ||
    path === "/blue-ticker/privacy"
  ) {
    return "/";
  }
  if (path === "/terms" || path === "/blue-ticker/terms") {
    return "/terms.html";
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
