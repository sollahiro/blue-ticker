# REST / MCP 認証の住み分け（段階 A）

| 項目 | 内容 |
|---|---|
| 本番 `api.*` の programmatic | **Access Service Token**（Client ID + Secret） |
| origin APIキー | 先送り（Gateway 後） |
| origin | 方式A・エッジのみ検証。blt-server は見ない |
| 旧 `BLT_AUTH_TOKEN` | **復活させない** |

## クライアント別

| クライアント | ホスト | 認証 |
|---|---|---|
| curl / CI | `api.*` | Service Token |
| ブラウザで api | `api.*` | SSO / OTP |
| Claude / ChatGPT（MCP） | `mcp.*` | Managed OAuth |
| ローカル | `127.0.0.1` | 無認証（`CF_ACCESS_TEAM_DOMAIN` 未設定） |
| 第三者 REST | `api.*` | 段階 B / Gateway 後 |

`api.*` は同一 Access アプリで **SSO Allow OR Service Auth**。

面分離: REST 機械入口＝Service Token、MCP＝Managed OAuth。Gateway 後に併存を解消するなら短い移行窓のみ。

手順: `deploy.md`「REST Service Token」。

## 関連

`public-api-concept.md` · `feature-tiers.md` · `deploy.md` · `operations.md`
