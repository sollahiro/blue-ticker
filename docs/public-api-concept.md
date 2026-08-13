# REST API 本線化と公開 API 化構想

| 段階 | 到達点 | 状態 |
|---|---|---|
| **A** | REST を契約の正に。機械到達は Access Service Token。配布 `ticker` 廃止 | 達成 |
| **B** | 第三者向け公開 API | 未着手。Monetize Gateway 後に認証・課金を再判断 |

段階 A の programmatic は **Access Service Token**（`api.*`）。住み分けは `api-auth.md`。origin APIキーは先送り。

## 「公開API化」（段階 B）

| 軸 | 内容 |
|---|---|
| 認証の主体転換 | 機械発行・失効できる鍵/トークン |
| 契約の安定化 | 後方互換の約束（`api-compatibility.md`） |
| 利用制御 | レート制限・クォータ |

## クライアント面

| 面 | 役割 |
|---|---|
| REST `/v1` | 契約の正 |
| MCP `POST /` | REST の追従面。新機能は REST 先 |
| Access SSO | ユーザー介在（ブラウザ） |
| Access Service Token | `api.*` の機械向け |
| `TickerDev` / `blt-server` ops | 開発・運用（配布対象外） |

## 現状

| 項目 | 実態 |
|---|---|
| 認証 | SSO / MCP OAuth ＋ Service Token。旧 Bearer は復活しない |
| レート | Cloudflare Free ゾーン制限のみ |
| `schema_version` | 実装済。ポリシーは `api-compatibility.md` |
| CORS | 未設定（demo のみ許可） |
| 外部向け API 文書 | なし。エージェント案内は `/v1/skills` |
| エラー | `{"error":...,"status":N}` |

## 段階 B の着手順（暫定）

1. Gateway 後の課金・識別子（origin APIキー要否）
2. レート・クォータ
3. CORS（必要なら）
4. 外部向け OpenAPI 等
5. 第三者鍵の発行・失効手順

土台（バックフィル・ストレージ）が未成熟なうちに不特定多数へ開放しない。

## 関連

`api-auth.md` · `api-compatibility.md` · `architecture.md` · `feature-tiers.md` · `deploy.md` · `blt-server-roadmap.md`
