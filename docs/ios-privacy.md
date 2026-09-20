# 免責とプライバシー方針

App Store 用の公開ページは Cloudflare Worker `workers/legal/`（静的 HTML）。

公開 URL:

- 免責とプライバシー方針: https://sollahiro.com/blue-ticker/privacy
- 利用規約: https://sollahiro.com/blue-ticker/terms

`blt-legal` の Custom Domain が `sollahiro.com`。プライバシーの同じ本文は `/` · `/blue-ticker` · workers.dev でも出る。利用規約は `/terms` · `/blue-ticker/terms`。

正本は公開 HTML。App Store Connect の App Privacy は、次と揃える（`PrivacyInfo.xcprivacy` も同じ種類）。

| 種類 | 申告 | 用途 | リンク / 追跡 |
|---|---|---|---|
| Product Interaction | する | 銘柄・財務の表示リクエスト | 非リンク / 非追跡 |
| Search History | する | 検索語 `q` | 非リンク / 非追跡 |
| Device ID | する | App Attest の鍵識別子 | 非リンク / 非追跡。機能 + 不正防止 |
| IP Address | する | HTTP 通信と Cloudflare Workers Logs | 非リンク / 非追跡。機能 + 不正防止 |
| Other User Content | する | リストに入れた銘柄（iCloud / CloudKit） | **リンク**（Apple ID）/ 非追跡。機能 |
| Other Financial Info | する | 保有株数・単価・証券会社・口座（iCloud / CloudKit） | **リンク**（Apple ID）/ 非追跡。機能 |
| Crash / Analytics SDK | **しない** | Crashlytics / Sentry / TelemetryDeck / Firebase なし | — |

実装の根拠（方針文と矛盾させない）:

- HAPIS は運営者自身の Cloudflare Workers（制御面 `hapis`、ゲートウェイ `hapis-blue-ticker-production`）。外部銘柄ベンダーではない
- 制御面・ゲートウェイとも `observability.enabled`、全件サンプリング。Logpush 先は無い。Workers Logs の保持は Cloudflare プラン（無料 3 日 / 有料 7 日）
- HAPIS D1 に IP は保存しない。ゲートウェイは `cf-connecting-ip` / `x-forwarded-for` を上流へ転送しない
- App Attest: challenge は 5 分、消費後およそ 1 時間で削除。attestation / assertion 本体は保存しない。`attested_keys`（key_id・公開鍵・sign_count）は期限なし
- トークン TTL 約 1 時間。JWT は D1 に置かない
- リストと保有情報は SwiftData + CloudKit（`iCloud.com.sollahiro.BlueTicker`）。HAPIS / blt-server には送らない
