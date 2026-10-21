# 免責事項およびプライバシーポリシー

App Store 用の公開ページは Cloudflare Worker `workers/legal/`（静的 HTML）。これはアプリ **有報LAB** の免責事項・プライバシーポリシー・利用規約で、ページ上のアプリ名は「有報LAB」。利用規約には、本アプリがブルーティッカーAPI（Blue Ticker API）を利用して作られていることを書く。名称の使い分けは `ios-client.md` の「名称（アプリと API）」。

公開 URL（`blt-legal` の Custom Domain `yuholab.com`）:

- 免責事項およびプライバシーポリシー（問い合わせ欄あり）: https://yuholab.com
- プライバシーポリシー: https://yuholab.com/privacy
- 利用規約: https://yuholab.com/terms

問い合わせ先は `support@yuholab.com`（iCloud+）。旧 `blueticker@sollahiro.com` は有報LAB 1.2.0 のリリースまで受信し、リリース後に止める。

App Store Connect のプライバシーポリシー URL は `https://yuholab.com/privacy`、サポート URL は `https://yuholab.com`。

旧 URL は `sollahiro.com` に残し、次の 6 パスだけを対応する `yuholab.com` のページへ **301 で直接**（1 回で）リダイレクトする。公開済み 1.1.x の App Store ページとアプリが旧 URL を参照しているため。

| 旧 URL（`sollahiro.com`） | 転送先 |
|---|---|
| `/blue-ticker`・`/yuholab` | `https://yuholab.com/` |
| `/blue-ticker/privacy`・`/yuholab/privacy` | `https://yuholab.com/privacy` |
| `/blue-ticker/terms`・`/yuholab/terms` | `https://yuholab.com/terms` |

リダイレクトするのは上の 6 パスの完全一致だけで、`/blue-ticker/` 配下を前方一致でまとめて飛ばさない。ブルーティッカーAPI 自体の規約などが要るときは、アプリのページとは別に `sollahiro.com/blue-ticker/` 配下の上記以外のパス（例 `/blue-ticker/api/terms`）に置く。`/yuholab/...` は置き場所には使わず、リダイレクト元としてだけ残す。

yuholab.com への移行をデプロイするまでは、従来どおり `sollahiro.com/blue-ticker/privacy`・`/blue-ticker/terms`（`/` · `/blue-ticker` · workers.dev も同じ本文）で配信している。

App Store / PrivacyInfo は公開ページと揃える（`PrivacyInfo.xcprivacy` も同じ種類）。

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
- App Attest: challenge は 5 分、消費後およそ 1 時間で削除。attestation / assertion 本体は保存しない。`attested_keys`（key_id・公開鍵・sign_count）は期限なし。key_id は広告識別子ではなく、不正防止の証明用識別子（App Store 申告は Device ID）
- トークン TTL 約 1 時間。JWT は D1 に置かない
- consumer JWT と App Attest 鍵レコードは端末の Keychain。アプリ削除後も OS / 利用者が消すまで残ることがある
- リストと保有情報は SwiftData + CloudKit（`iCloud.com.sollahiro.BlueTicker`）。ブルーティッカーAPI（HAPIS / blt-server）には送らない
