# REST API 互換ポリシー（段階 A）

自社向け REST 本線化（段階 A）の契約ルール。第三者公開（段階 B）では deprecation 期間などを足す前提で、いまはゆるく運用する。

構想全体は `docs/public-api.md`（段階 B）。段階 A の契約は本ファイルと `api-auth.md` / `feature-tiers.md`。内部の Neon `cache_version` / read 床は本ポリシーの対象外（`.agents/rules/project/versioning.md`）。

## 原則

1. **普段は追加中心** — 既存クライアントが知らなくてよいフィールド・エンドポイントの追加は互換
2. **たまってから明示付きで再編** — 削除・改名・型変更・意味変更はまとめて行い、breaking として版を上げる
3. **契約の正は REST** — MCP は REST を写す。互換判断も REST 応答を基準にする

## 互換対象（段階 A）

| 対象 | 段階 A の扱い |
|---|---|
| 成功レスポンス JSON のフィールド（形・型・意味） | **厳格な互換対象** |
| URL パスの大きな再編 | breaking 時のみ `/v2` 等（下記） |
| クエリ名、HTTP ステータスの意味、エラーボディ形 | **努力目標**（意図なく壊さない。厳格対象外） |

## 互換 / breaking の判定

| 変更 | 分類 | 対応 |
|---|---|---|
| フィールド・エンドポイントの追加 | 互換 | `schema_version` 据え置き可。changelog に一言 |
| フィールドの削除・改名 | breaking | 該当契約の `schema_version` を上げる |
| 型の変更（例: number → string） | breaking | 同上 |
| 意味の変更（例: 千円→円、定義変更） | breaking | 同上（形が同じでも breaking） |
| 値の追加（enum 的な文字列の新値） | 原則互換 | 未知値を落とさず無視できるクライアントを推奨 |
| ルートの統廃合・リソース切り直し | breaking（大きい） | URL メジャー（`/v2`）を検討 |

## バージョンの出し方

### 応答 `schema_version`（主）

- 契約ごと（financials 等）に独立採番する整数
- **フィールド単位の breaking** では、影響する契約の `schema_version` だけを上げる
- URL は `/v1` のままでよい
- 現行値の定義箇所例: `Api.financialsSchemaVersion`（`Sources/BlueTicker/Constants/Api.swift`）

### URL メジャー（例外）

- パス構造の再編など、`schema_version` だけではクライアント切替が分かりにくいときに使う
- 普段のフィールド再編では使わない

### 移行の望ましい形（必須ではない）

breaking 再編時は可能な範囲で:

1. 新旧キーをしばらく併存（この間は互換として扱えることが多い）
2. changelog で旧キー廃止予定を書く
3. 旧キー削除時に `schema_version` を上げる

段階 A では固定の「N 日 / N リリース併存」は定めない。段階 B で期間を足す。

## 対象外・混同しないもの

| もの | 理由 |
|---|---|
| Neon `cache_version`（`fin-v4` 等）・min servable 床 | ingest / 配信世代の内部制御。公開契約に漏らさない |
| `blueTickerVersion`（配布物バージョン） | CLI / キャッシュ用。REST `schema_version` とは独立 |
| facts RAW | 非公開 |

## 変更時の運用（段階 A）

- breaking なら該当 `schema_version` 定数を上げ、PR / コミットで分かるようにする
- 互換追加も含め、契約に触る変更は短いメモを残す（PR 説明または関連 docs）
- MCP ツール入出力を変える場合は、先に REST 契約を決め、MCP は追従させる

## 段階 B で足す予定

- 第三者向けの deprecation 期間（日数またはリリース数）
- 外部向け changelog / OpenAPI との突合
- クエリ・ステータス・エラー形を厳格対象に上げるかの再検討
