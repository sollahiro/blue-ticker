# REST / MCP 認証の住み分け（段階 A）

## 判断（2026-07-23）

| 項目 | 内容 |
|---|---|
| 段階 A の programmatic（本番 `api.*`） | **Cloudflare Access Service Token**（Client ID + Client Secret） |
| origin 発行 APIキー | **先送り**。Monetize Gateway 公開後に再判断（第三者・課金・面×機能例外向け） |
| origin コード | 方式Aのまま。Service Token 検証は **エッジのみ**（blt-server は見ない） |
| 旧 CLI Service Token / `BLT_AUTH_TOKEN` | **復活させない**。配布 `ticker` は廃止まで SSO。機械向けは curl 等から Service Token を直接付与 |

目的: 本番 REST をブラウザなしで叩き、製品の機械入口にする。学習・契約固めは同じ入口＋ docs。本格課金は Gateway 後。

## クライアント別ケース

| クライアント | ホスト | 認証 | 備考 |
|---|---|---|---|
| curl / 自社スクリプト / CI | `api.*` | **Service Token** | 段階 A で開く主用途 |
| ~~配布 `ticker`~~ | — | **廃止済み** | Homebrew / remote CLI 削除。代替は curl + Service Token または MCP |
| ブラウザで api を直接 | `api.*` | SSO / OTP | 既存 |
| 将来 iOS | `api.*` | ユーザー SSO 系（OIDC+PKCE 想定） | アプリに Service Token を焼かない |
| Claude Desktop / ChatGPT / Cursor（MCP） | `mcp.*` | Managed OAuth | Cursor は DCR 時に `cursor://` コールバックも送るため、許可 redirect URI への追加が必要（`docs/deploy.md`） |
| Claude Code 等 api 上の remote MCP | `api.*` | 当面 SSO | 任意で後から Token も可だが必須ではない |
| Cursor（OAuth 不可時の暫定） | `api.*` | Service Token（`headers`） | `mcp.json` の `headers` に `CF-Access-Client-Id` / `CF-Access-Client-Secret`。本線は `mcp.*` OAuth |
| 第三者 REST アプリ | `api.*` | 段階 B / Gateway 後 | 案2または Gateway |
| ローカル開発 | `127.0.0.1` | 無認証（`CF_ACCESS_TEAM_DOMAIN` 未設定） | 既存 |

## `api.*` ポリシーの同居

同一 Access アプリで **OR**:

1. **Allow（SSO / OTP）** — ユーザー介在クライアント（既存）
2. **Service Auth（Service Token）** — curl / スクリプト / CI（新規）

人間用と機械用を「人間か機械か」ではなく **どのクライアントか** で選ぶ。

## MCP との面分離

- REST 機械入口の識別子 = Service Token（`api.*`）
- MCP 入口の識別子 = Managed OAuth クライアント（`mcp.*`）
- 面別メーター・「MCP Analyze だけ無料」等は、Gateway / 案2 検討時にこの分離を前提にする

## 案2への移行（必要なとき）

恒久併存は避ける。Gateway 後に origin APIキー等が要ると判断したら短い移行窓だけ併存し、Service Auth を外す（SSO は残してよい）。

## 運用手順

発行・ポリシー・curl 例は `docs/deploy.md`「REST Service Token（段階 A）」を参照。

## 関連

- `docs/public-api-concept.md`
- `docs/feature-tiers.md`
- `docs/deploy.md`
- `docs/operations.md`
