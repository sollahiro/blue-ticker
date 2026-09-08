# REST 第三者公開（段階 B）

段階 A（自社向け REST 本線・Service Token・配布 CLI 廃止）は達成済み。達成済みの契約は次に委譲する（本ファイルに再叙述しない）:

- 認証の住み分け → `api-auth.md`
- 互換ポリシー → `api-compatibility.md`
- クライアント面の現構成 → `architecture.md`

ロック: 2026-09-09 Sorahiro。HAPIS v0 は Cloudflare Access を転送してよい。以下の段階 B 認証は v0 のあと。

## 定義

素性不明の第三者が自分のアプリに組み込める API へ移ること。3軸:

| 軸 | 内容 |
|---|---|
| 公開入口 | **HAPIS** が公開ゲートウェイ。上流 BLT origin は HAPIS の後ろに閉じ、公開しない。blt-server は ingest / serve REST に閉じ、API 認証・Attest・短命トークン・レート制限・課金アカウントは持たない |
| 契約の安定化 | 後方互換の約束を厳格化（段階 B で deprecation 期間等を足す） |
| 利用制御 | レート制限は HAPIS。機械の従量は x402 |

機能単位の有料マスクは採らない。**段階 B の機械 REST は x402**。MCP は開発専用のため段階 B の x402 対象外であり、HAPIS の中核依存にもしない。

iOS のアカウント不要パス（短命匿名トークン + App Attest）はゲートウェイ責務であり、blt-server の責務ではない。

土台（バックフィル・ストレージ）が未成熟なうちに不特定多数へ開放しない。着手順・公開判断は Linear Team `blue-ticker`。定義の索引は `blt-server-roadmap.md`。

## 公開 REST の認証（階層ではなく併存）

origin API キーは持たない。iOS にトークン / Service Token を埋め込まない。

| 経路 | 認証 |
|---|---|
| iOS（アカウント不要） | HAPIS が短命の匿名トークンを発行。本番は App Attest 必須。blt-server は見ない |
| 任意 Bearer | 有料機能・ウォッチリスト同期が要るときだけ顧客アカウント |
| 機械 / エンドポイント直叩き | x402 |
| Web | 当面、アカウント不要の無料枠は出さない |
| MCP | Access OTP（開発）。HAPIS の中核依存にしない |

## 具体ロック

1. **開発例外:** `http://127.0.0.1` と LAN `http` は無認証・Attest なし（現行どおり）
2. **内部退避:** staging ホストは Access を残す。段階 B 着地後の本番公開扉は HAPIS のみ（本番公開ゲートウェイに Access を置かない）
3. **初期レート制限**（後で調整）: 軽い read 約 60/min、重い（filing-content）約 10/min、合算約 10k/day
4. **トークン:** TTL 約 1 時間。期限の約 5 分前にサイレント refresh
5. **Attest / トークン失敗:** 2〜3 回自動リトライのあと、キャッシュ表示 + 柔らかい「一時的に更新できない」。ハードブロックしない。Attest なしの緊急トークンは出さない

## 公開バー

既存の servable / min 床に合わせる。新しいカバレッジバーは作らない。servable 床は latest `cache_version` の全行と同義ではない。
