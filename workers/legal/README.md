# Legal page Worker

App Store 用の免責・プライバシー方針および利用規約。静的 HTML だけ。認証もトークンも無い。

**この Worker を `api.*` / `mcp.*` の前段に置かない。** Tunnel + Access はそのまま。

公開 URL:

- https://sollahiro.com/blue-ticker/privacy
- https://sollahiro.com/blue-ticker/terms
- https://blt-legal.sollahiro.workers.dev/

公開ページの本文は `workers/legal/public/index.html`（`privacy.html` も同じ）。利用規約は `workers/legal/public/terms.html`。

## デプロイ

`main` では `.github/workflows/legal-worker.yml` が出す。GitHub secrets は Feed Trend と同じ `CLOUDFLARE_API_TOKEN` · `CLOUDFLARE_ACCOUNT_ID`。

手動:

```bash
cd workers/legal
npx wrangler@4 deploy
```

`workers_dev` は必ず `true`（ルートだけだと workers.dev が消える）。
