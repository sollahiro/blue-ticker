# Legal page Worker

iOS アプリ「有報LAB」と公開 MCP コネクタ（HAPIS `mcp/`、`https://mcp.yuholab.com/mcp`）の免責・プライバシー方針および利用規約（App Store と Claude の Connectors Directory のプライバシーポリシー URL・サポート URL の先）。静的 HTML だけ。認証もトークンも無い。有報LAB API 自体の規約ページが要るときは、別ページとして `sollahiro.com/blue-ticker/...` に置く。

**この Worker を `api.*` / `mcp.*` の前段に置かない。** Tunnel + Access はそのまま。

公開 URL（Custom Domain `yuholab.com`）:

- https://yuholab.com （ランディングページ。サポート URL の先でもあり、問い合わせ先を載せる）
- https://yuholab.com/privacy （免責・プライバシー）
- https://yuholab.com/terms
- https://yuholab.com/en/privacy ・ https://yuholab.com/en/terms （英語版。日本語版の翻訳で、食い違うときは日本語版が優先。Assets がそのまま配信するので Worker の書き換えは要らない。日本語版を変えたら英語版も合わせる）
- https://blt-legal.sollahiro.workers.dev/

問い合わせ先は `support@yuholab.com`（iCloud+）。

## 旧 URL のリダイレクト

Custom Domain `sollahiro.com` も残し、次の 6 パスだけを `yuholab.com` の対応ページへ 301 で直接飛ばす（`src/index.js` の `REDIRECTS`。末尾スラッシュの有無は問わない）。前方一致にはしないので、`sollahiro.com/blue-ticker/...` の他のパスは将来有報LAB API のページに使える。

| 旧 URL（sollahiro.com） | 転送先 |
|---|---|
| `/blue-ticker`・`/yuholab` | `https://yuholab.com/` |
| `/blue-ticker/privacy`・`/yuholab/privacy` | `https://yuholab.com/privacy` |
| `/blue-ticker/terms`・`/yuholab/terms` | `https://yuholab.com/terms` |

ランディングページは `workers/legal/public/index.html`（アイコンは `logo-white.svg`）。免責・プライバシーは `privacy.html`。利用規約は `workers/legal/public/terms.html`。AI アシスタント向けコネクタの説明（Connectors Directory の資料リンク用）は `connector.html`（`/connector`、英語は `/en/connector`）。ツール一覧は `hapis/catalog.json` の公開分と揃える。
ファビコン一式（`favicon.svg` / `favicon.ico` / `favicon-32.png` / `apple-touch-icon.png` / `icon-192.png`）は iOS アプリアイコンの白い字（`Apps/BlueTicker/BlueTicker/AppIcon.icon/Assets/Group 13-2.svg`）を水色のグラデーションの角丸に載せたもの。全ページの `<head>` から読む。

## デプロイ

`main` では `.github/workflows/legal-worker.yml` が出す（`workers/legal/**` の変更で起動。マージ＝公開）。出す前に同じコミットで `scripts/ci/worker-tests.sh legal` を流し、落ちたらデプロイしない。`yuholab.com` の Custom Domain は Cloudflare に `yuholab.com` のゾーンがあることが前提。GitHub secrets は Feed Trend と同じ `CLOUDFLARE_API_TOKEN` · `CLOUDFLARE_ACCOUNT_ID`。

手動:

```bash
cd workers/legal
npx wrangler@4 deploy
```

`workers_dev` は必ず `true`（ルートだけだと workers.dev が消える）。
