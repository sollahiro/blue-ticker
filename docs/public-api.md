# REST 第三者公開（段階 B）

段階 A（自社向け REST 本線・Service Token・配布 CLI 廃止）は達成済み。達成済みの契約は次に委譲する（本ファイルに再叙述しない）:

- 認証の住み分け → `api-auth.md`
- 互換ポリシー → `api-compatibility.md`
- 機能・課金境界 → `feature-tiers.md`
- クライアント面の現構成 → `architecture.md`

## 定義

素性不明の第三者が自分のアプリに組み込める API へ移ること。3軸:

| 軸 | 内容 |
|---|---|
| 認証の主体転換 | 機械発行・失効できる鍵/トークン（origin APIキー要否は Gateway 後に判断） |
| 契約の安定化 | 後方互換の約束を厳格化（段階 B で deprecation 期間等を足す） |
| 利用制御 | レート制限・クォータ |

## 着手順（暫定）

1. Monetize Gateway 後の課金・識別子
2. レート・クォータ
3. CORS（必要なら）
4. 外部向け OpenAPI 等
5. 第三者鍵の発行・失効手順

土台（バックフィル・ストレージ）が未成熟なうちに不特定多数へ開放しない。索引は `blt-server-roadmap.md`。
