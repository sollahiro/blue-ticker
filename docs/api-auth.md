# REST / MCP 認証の住み分け（段階 A）

| 項目 | 内容 |
|---|---|
| 本番 `api.*` の programmatic | **Access Service Token**（Client ID + Secret） |
| origin APIキー | 持たない（機械課金は x402。`public-api.md`） |
| origin | 方式A・エッジのみ検証。blt-server は見ない |
| 旧 `BLT_AUTH_TOKEN` | **復活させない** |

## クライアント別

| クライアント | ホスト | 認証 |
|---|---|---|
| curl / CI | `api.*` | Service Token |
| ブラウザで api | `api.*` | SSO / OTP |
| MCP（開発用） | `mcp.*` | Managed OAuth |
| ローカル | `127.0.0.1` | 無認証（`CF_ACCESS_TEAM_DOMAIN` 未設定） |
| 第三者 REST | `api.*` | 段階 B / x402 |
| iOS | loopback / `api.sollahiro.com` | 開発は loopback / http 無認証。実機プレビューで `https://api.sollahiro.com` を叩くときだけ Access SSO の短命 JWT（`CF_Authorization`）。Service Token は埋め込まない |

`api.*` は同一 Access アプリで **SSO Allow OR Service Auth**。

面分離: REST 機械入口＝Service Token。MCP＝Managed OAuth（開発専用。ChatGPT Apps は凍結。ホストは解体しない）。機能単位の有料マスクは採らない。段階 B の x402 は第三者向け REST のみ。x402 導入後に Access との併存を解消するなら短い移行窓のみ。

手順: `.agents/skills/deploy/SKILL.md`「REST Service Token」。

## 関連

`public-api.md` · `ios-client.md` · `architecture.md` · `.agents/skills/deploy/SKILL.md`
