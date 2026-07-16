# REST API の公開 API 化構想

現時点の判断: **不要（優先度低）**。今後の方向性の一つとして、判断根拠と再検討時の着手順を残す。

## 「公開API化」の定義

信頼済みの既知クライアント（自社 `ticker` CLI・自社 iOS アプリ・Claude 向け MCP）だけが使う内部APIから、素性を知らない第三者が自分のアプリ/サービスに組み込んで使えるAPIへ移行すること。3軸に分解できる。

| 軸 | 内容 |
|---|---|
| 認証の主体転換 | 「人間が都度SSOログインする」前提から「開発者が自分のアプリに組み込める、機械的に発行・失効できる鍵/トークン」前提へ |
| 契約の安定化 | 実装都合（`cache_version` 等）を漏らさず、後方互換を保つ「約束」として固定。breaking change時の扱い（バージョン番号・deprecation・移行期間）を明文化 |
| 利用制御 | 不特定多数からの濫用・過負荷を防ぐレート制限・クォータ |

## 現状の実態（2026-07-17 コード調査）

`docs/blt-server-roadmap.md` の TODO 記述（「スキーマ安定化・レート制御」）は実態とややズレがあった。

| 項目 | 実態 | 根拠 |
|---|---|---|
| 認証 | Cloudflare Access の**人間ブラウザSSOログインのみ**。`cloudflared` バイナリのローカル実行が前提。Service Token / Bearer 認証は v26.7.2 で全面廃止済み。**第三者アプリから叩けるprogrammatic認証手段が皆無** | `Sources/BlueTicker/Infrastructure/CloudflaredAccess.swift`、memory `project_service_token_removal.md` |
| レート制御 | 独自実装ゼロ。Cloudflare Free プランの固定値のみに依存 | `Sources/BltServerCore/` 内に rate limit 系ミドルウェア0件（grep確認） |
| スキーマバージョニング | `schema_version` フィールドは実装済み。足りないのは互換保証・非互換変更時の運用ポリシーの明文化のみ | `Sources/BlueTicker/Models/FinancialsContract.swift` / `HalfFinancialsContract.swift` |
| CORS | 未設定。ブラウザからの他オリジン呼び出しは現状不可 | `Sources/BltServerCore/Routes.swift`（`BltErrorMiddleware` のみ登録） |
| API ドキュメント | 外部開発者向け OpenAPI / リファレンスは存在しない | `docs/` は社内向けのみ |
| エラー契約 | `{"error":...,"status":N}` に統一済み。公開品質として問題なし | 同上 |

最も手前でブロックしているのは認証軸（programmatic 認証の不在）であり、ロードマップの記述はこれに触れていなかった。

## 現時点で不要と判断する理由

1. **需要が実在しない** — 想定クライアントは自分自身（`ticker` CLI・iOS・MCP）のみで、外部第三者からの要求は出ていない
2. **土台が未成熟** — Stage 3 は512MB制約で ingest 停止中（issue #22）、Stage 4/4-half/5 のバックフィルも進行中、ストレージ強化方針も未決定。この段階で不特定多数に開放すると、まだ枯れていないバックエンド（EDINET取得・Neon）が濫用・過負荷に晒されるリスクだけが先に立つ

先に着手すべきは issue #22（ストレージ方式決定）とバックフィル完了。

## 再検討が必要になったときの着手順

需要が具体化した時点で、以下の順で着手する（現状把握が前提の暫定順）。

1. **programmatic 認証の追加**（APIキー or OAuth client credentials）— 一番手前のブロッカー
2. **レート制御の実装**
3. **CORS**（ブラウザ経由の第三者利用を想定するなら）
4. **外部向け API ドキュメント**（OpenAPI 等）
5. **スキーマ互換ポリシーの明文化**（`schema_version` の運用ルール。実装済みのため文書化のみ）

## 関連

- `docs/blt-server-roadmap.md`「将来」TODO
- `Sources/BlueTicker/Infrastructure/CloudflaredAccess.swift`
- `Sources/BltServerCore/Routes.swift`
