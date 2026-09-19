/**
 * App Store 用の免責・プライバシー。
 * workers.dev の / と /privacy、sollahiro.com/blue-ticker(/privacy) を同じ HTML にする。
 */
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    if (
      path === "/privacy" ||
      path === "/blue-ticker" ||
      path === "/blue-ticker/privacy"
    ) {
      url.pathname = "/";
      return env.ASSETS.fetch(new Request(url.toString(), request));
    }
    return env.ASSETS.fetch(request);
  },
};
