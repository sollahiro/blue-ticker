# REST / MCP 認証の住み分け（段階 A）

| 項目 | 内容 |
|---|---|
| 本番 `api.*` の programmatic | **Access Service Token**（Client ID + Secret） |
| origin APIキー | 持たない（機械課金は x402。`feature-tiers.md` / `public-api.md`） |
| origin | 方式A・エッジのみ検証。blt-server は見ない |
| 旧 `BLT_AUTH_TOKEN` | **復活させない** |

## クライアント別

| クライアント | ホスト | 認証 |
|---|---|---|
| curl / CI | `api.*` | Service Token |
| ブラウザで api | `api.*` | SSO / OTP |
| Apps in ChatGPT（MCP） | `mcp.*` | Managed OAuth |
| ローカル | `127.0.0.1` | 無認証（`CF_ACCESS_TEAM_DOMAIN` 未設定） |
| 第三者 REST | `api.*` | 段階 B / x402 |

`api.*` は同一 Access アプリで **SSO Allow OR Service Auth**。

面分離: REST 機械入口＝Service Token、MCP＝Managed OAuth（**当面 Apps in ChatGPT 専用**）。機能単位の有料マスクは採らない。段階 B の x402 は第三者向け REST のみ（`feature-tiers.md`）。x402 導入後に Access との併存を解消するなら短い移行窓のみ。

手順: `deploy.md`「REST Service Token」。

## 関連

`public-api.md` · `feature-tiers.md` · `deploy.md` · `operations.md`
