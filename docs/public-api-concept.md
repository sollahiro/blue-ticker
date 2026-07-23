# REST API 本線化と公開 API 化構想

## 現時点の判断（2026-07-23）

| 段階 | 到達点 | 状態 |
|---|---|---|
| **A（いま）** | 自社向けに REST を契約の正・主クライアント面にする。配布 `ticker` 廃止。本番機械到達は Access Service Token | **認証疎通済み・配布 CLI 削除** |
| **B（ゆくゆく）** | 素性を知らない第三者が組み込める公開 API | 未着手。A の契約土台の上で再開。origin APIキー等は Monetize Gateway 公開後に再判断 |

段階 A の programmatic 認証は **Cloudflare Access Service Token**（`api.*`）。クライアント別の住み分け・ポリシー同居は `docs/api-auth.md`。origin 発行 APIキーは先送り。

## 「公開API化」（段階 B）の定義

信頼済みの既知クライアントだけが使う内部APIから、素性が不明な第三者が自分のアプリ/サービスに組み込んで使えるAPIへ移行すること。3軸に分解できる。

| 軸 | 内容 |
|---|---|
| 認証の主体転換 | 「人間が都度SSOログインする」前提に加え、「開発者が自分のアプリに組み込める、機械的に発行・失効できる鍵/トークン」を用意する |
| 契約の安定化 | 実装都合（`cache_version` 等）を漏らさず、後方互換を保つ「約束」として固定。breaking change時の扱い（バージョン番号・deprecation・移行期間）を明文化 |
| 利用制御 | 不特定多数からの濫用・過負荷を防ぐレート制限・クォータ |

段階 A では主に「契約の安定化」とクライアント面の整理を進め、認証・利用制御の本実装は方式決定後。

## クライアント面の方針

| 面 | 役割 |
|---|---|
| **REST `/v1`** | 契約の正。自社クライアント（将来の iOS 等）・段階 B の第三者向けの本線 |
| **MCP `POST /`** | REST を写す薄い追従面。プロトコル自体は一過性とみなす。新機能は REST 先・MCP は写経 |
| **配布 `ticker`** | **廃止済み**（Homebrew / release / `CLI/` 削除）。`TickerDev` と `blt-server` 運用 CLI は残す |
| **Cloudflare Access SSO** | ユーザー介在クライアント向け（ブラウザ・将来 iOS）。リモート MCP（Managed OAuth）もブラウザ経由は想定内 |
| **Access Service Token** | 本番 `api.*` の機械向け programmatic（curl / CI）。手順は `docs/api-auth.md` / `deploy.md` |

## 現状の実態（認証・制御・契約）

| 項目 | 実態 |
|---|---|
| 認証 | SSO / MCP OAuth ＋ **Service Token（`api.*`・疎通済み）**。origin 非検証・エッジ。旧 CLI Bearer は復活しない。詳細 `docs/api-auth.md` |
| レート制御 | 独自実装ゼロ。Cloudflare Free のゾーン制限のみ |
| スキーマバージョニング | 応答の `schema_version` は実装済み。互換ポリシーは `docs/api-compatibility.md`（段階 A） |
| CORS | 未設定 |
| API ドキュメント | 外部向け OpenAPI / リファレンスなし（`docs/` は運営・開発向け） |
| エラー契約 | `{"error":...,"status":N}` に統一済み |

## 段階 A の着手順（暫定）

方式未決の項目は選定後に実装へ落とす。

1. ~~**方針ドキュメント固定**（本ファイル・roadmap・architecture）~~
2. ~~**スキーマ互換ポリシーの明文化**~~ — `docs/api-compatibility.md`
3. ~~**programmatic 認証の方式選定・疎通**~~ — Service Token（`docs/api-auth.md` / `deploy.md`）
4. ~~**配布 `ticker` の廃止**~~ — product / Homebrew / release / `CLI/` 削除済み。`TickerDev`・`blt-server` ops は残置
5. （必要なら）内部向け OpenAPI 下書き — 段階 B の外部公開ドキュメントの下地

## 段階 B で追加する着手順（暫定）

1. Monetize Gateway 公開後の課金・識別子再設計（origin APIキー要否をここで判断）
2. レート制御・クォータ
3. CORS（ブラウザ経由の第三者利用を想定するなら）
4. 外部向け API ドキュメント（OpenAPI 等）
5. 第三者向け鍵の発行・失効・サポート手順

段階 B を急がない理由（変更なし）: バックフィル・ストレージ（#22）など土台が未成熟なうちに不特定多数へ開放すると、濫用・過負荷リスクが先に立つ。

## 関連

- `docs/api-auth.md` — 認証の住み分け（段階 A）
- `docs/api-compatibility.md` — REST 互換ポリシー（段階 A）
- `docs/blt-server-roadmap.md`「クライアント面」「将来」TODO
- `docs/architecture.md`
- `docs/feature-tiers.md`
- `docs/deploy.md`
- `Sources/BlueTicker/Infrastructure/CloudflaredAccess.swift`
- `Sources/BltServerCore/Routes.swift`
