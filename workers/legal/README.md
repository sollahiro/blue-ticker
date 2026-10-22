# Legal page Worker

iOS アプリ「有報LAB」の免責・プライバシー方針および利用規約（App Store のプライバシーポリシー URL・サポート URL の先）。静的 HTML だけ。認証もトークンも無い。ブルーティッカーAPI 自体の規約ページが要るときは、別ページとして `sollahiro.com/blue-ticker/...` に置く。

**この Worker を `api.*` / `mcp.*` の前段に置かない。** Tunnel + Access はそのまま。

公開 URL（Custom Domain `yuholab.com`）:

- https://yuholab.com （免責・プライバシー、問い合わせ）
- https://yuholab.com/privacy （同じ内容）
- https://yuholab.com/terms
- https://blt-legal.sollahiro.workers.dev/

問い合わせ先は `support@yuholab.com`（iCloud+）。

## 旧 URL のリダイレクト

Custom Domain `sollahiro.com` も残し、次の 6 パスだけを `yuholab.com` の対応ページへ 301 で直接飛ばす（`src/index.js` の `REDIRECTS`。末尾スラッシュの有無は問わない）。前方一致にはしないので、`sollahiro.com/blue-ticker/...` の他のパスは将来ブルーティッカーAPI のページに使える。

| 旧 URL（sollahiro.com） | 転送先 |
|---|---|
| `/blue-ticker`・`/yuholab` | `https://yuholab.com/` |
| `/blue-ticker/privacy`・`/yuholab/privacy` | `https://yuholab.com/privacy` |
| `/blue-ticker/terms`・`/yuholab/terms` | `https://yuholab.com/terms` |

公開ページの本文は `workers/legal/public/index.html`（`privacy.html` も同じ）。利用規約は `workers/legal/public/terms.html`。

## デプロイ

`main` では `.github/workflows/legal-worker.yml` が出す（`workers/legal/**` の変更で起動。マージ＝公開）。`yuholab.com` の Custom Domain は Cloudflare に `yuholab.com` のゾーンがあることが前提。GitHub secrets は Feed Trend と同じ `CLOUDFLARE_API_TOKEN` · `CLOUDFLARE_ACCOUNT_ID`。

手動:

```bash
cd workers/legal
npx wrangler@4 deploy
```

`workers_dev` は必ず `true`（ルートだけだと workers.dev が消える）。
