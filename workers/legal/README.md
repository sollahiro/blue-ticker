# Legal page Worker

App Store 用の免責とプライバシー方針。静的 HTML だけ。認証もトークンも無い。

**この Worker を `api.*` / `mcp.*` の前段に置かない。** Tunnel + Access はそのまま。

公開 URL（workers.dev）: https://blt-legal.sollahiro.workers.dev/  
同じ本文は `/privacy` でも出る。独自ドメイン（例: `legal.sollahiro.com`）は Cloudflare の Custom Domain で後から足せる。

正本は `workers/legal/public/index.html`。

## デプロイ

`main` では `.github/workflows/legal-worker.yml` が出す。GitHub secrets は Feed Trend と同じ `CLOUDFLARE_API_TOKEN` · `CLOUDFLARE_ACCOUNT_ID`。

手動:

```bash
cd workers/legal
npx wrangler@4 deploy
```
