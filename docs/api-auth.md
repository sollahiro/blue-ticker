# REST / MCP 認証の住み分け

段階 A が現行。段階 B の公開入口は HAPIS（`public-api.md`）。blt-server origin はどちらの段階でもトークンを検証しない（エッジ / ゲートウェイ信頼）。

| 項目 | 段階 A（現行） | 段階 B（HAPIS 着地後） |
|---|---|---|
| 公開扉 | Cloudflare Access（`api.*`） | HAPIS。上流 BLT は非公開 |
| programmatic | Access Service Token | 機械 / エンドポイント直叩きは x402 |
| iOS | プレビューだけ Access 短命 JWT（`CF_Authorization`） | HAPIS 短命匿名トークン + 本番 App Attest。任意 Bearer は有料 / ウォッチ同期が要るときだけ |
| origin APIキー | 持たない | 持たない |
| origin | 方式A・エッジのみ検証。blt-server は見ない | ゲートウェイ信頼。blt-server は見ない（API 認証・Attest・短命トークン・レート制限・課金アカウントは持たない） |
| 旧 `BLT_AUTH_TOKEN` | **復活させない** | **復活させない** |

## 段階 A（現行）

`api.*` は同一 Access アプリで **SSO Allow OR Service Auth**。

| クライアント | ホスト | 認証 |
|---|---|---|
| curl / CI | `api.*` | Service Token |
| ブラウザで api | `api.*` | SSO / OTP |
| MCP（開発用） | `mcp.*` | Managed OAuth |
| ローカル | `127.0.0.1` / LAN `http` | 無認証（`CF_ACCESS_TEAM_DOMAIN` 未設定） |
| 第三者 REST | `api.*` | 段階 B / HAPIS + x402（`public-api.md`） |
| iOS | loopback / `api.sollahiro.com` | 開発は loopback / http 無認証。実機プレビューで `https://api.sollahiro.com` を叩くときだけ Access SSO の短命 JWT（`CF_Authorization`）。Service Token は埋め込まない |

面分離: REST 機械入口＝Service Token。MCP＝Managed OAuth（開発専用。ChatGPT Apps は凍結。ホストは解体しない）。機能単位の有料マスクは採らない。

手順: `.agents/skills/deploy/SKILL.md`「REST Service Token」。

## 段階 B（HAPIS 着地後）

公開 REST の認証は階層ではなく併存する（詳細は `public-api.md`）。

- iOS アカウント不要: HAPIS が短命匿名トークンを発行。本番は App Attest 必須。iOS プレビューの Access JWT は段階 A のまま。段階 B で HAPIS 短命 + Attest に移る。**現行クライアント: Debug は stub mint、Release は App Attest を sessions に載せる。本番制御面の `ATTEST_MODE=enforce` はまだオフ**（制御面 `https://hapis.sollahiro.workers.dev`、ゲートウェイ `https://hapis-blue-ticker-production.sollahiro.workers.dev`。詳細は `ios-client.md`）
- 任意 Bearer: 顧客アカウントは有料機能・ウォッチリスト同期が要るときだけ
- 機械 / エンドポイント直叩き: x402
- Web: 当面、アカウント不要の無料枠は出さない
- MCP: Access OTP（開発）。HAPIS の中核依存にしない
- iOS にトークン / Service Token を埋め込まない

HAPIS v0 は Cloudflare Access を転送してよい。段階 B 認証は v0 のあと。

**開発例外:** `http://127.0.0.1` と LAN `http` は無認証・Attest なし（現行どおり）。

**内部退避:** staging ホストは Access を残す。段階 B 着地後の本番公開扉は HAPIS のみ（本番公開ゲートウェイに Access を置かない）。

blt-server は ingest / serve REST に閉じる。トークン検証・Attest・レート制限はゲートウェイ側。

## 関連

`public-api.md` · `ios-client.md` · `architecture.md` · `.agents/skills/deploy/SKILL.md`
