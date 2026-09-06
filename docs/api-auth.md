# REST / MCP / iOS 認証

目指す最低限の住み分け。段階 A のいまの実装は下表の「いま」列。一般配布・第三者公開はまだこの表の「目指す形」で、ホスト分割や Access 外しは未着手。

origin は方式 A のまま（エッジで止める。blt-server は見ない）。旧 `BLT_AUTH_TOKEN` は復活させない。Service Token を iOS に埋め込まない。

## クライアント別

| クライアント | 目指す形 | いま |
|---|---|---|
| iOS（人） | **ログインなし**。開いてすぐ使える。一部画面（例: レポート）は IAP（StoreKit）。自前アカウントは持たない | 開発は loopback / http 無認証。https の `api.*` は Access SSO（プレビュー用） |
| ブラウザ / 人手の curl | Access **メール OTP**（`Cookie: CF_Authorization`）。機械の大量 GET を OTP で止める | 同一 Access アプリで SSO / OTP **または** Service Token |
| CI | **Service Token**（OTP は非対話に使えない） | 同じ |
| MCP（開発用） | Access **OTP**（人の門。製品面ではない） | `mcp.*` は Managed OAuth |
| 第三者 REST | **API キー**、またはキーなし **x402**。機能単位の有料マスクはしない | 未開放 |
| ローカル | `127.0.0.1` 無認証 | 同じ |

iOS の匿名と、curl の OTP は **同じ公開 URL では成立しない**。一般配布ではアプリ用の Access なしホスト（レート制限）を足し、`api.*` / `mcp.*` は OTP のままにする。第三者のキー / x402 はさらに別口（または同じ公開口にキー任意・無ければ 402）。

MCP クライアントはブラウザ OTP を踏めない。運用は OTP 後の短命 JWT を渡すか、当面 Managed OAuth を残す。Cursor から常用するなら OAuth を残す方が楽。

手順（いまの Token / OTP）: `.agents/skills/deploy/SKILL.md`。

## 課金の境界

| 面 | 課金 |
|---|---|
| iOS | Apple IAP。レポート等の **画面** を外す。REST のエンドポイント課金にはしない |
| 第三者 REST | キーの台帳、または x402 の従量。IAP とは財布を分けない |
| MCP | 課金しない（開発専用） |

x402 導入後に Access との併存を解消するなら短い移行窓のみ。

## 関連

`public-api.md` · `ios-client.md` · `architecture.md` · `.agents/skills/deploy/SKILL.md`
