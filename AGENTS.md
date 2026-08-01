# AGENTS.md

エージェント向けの作業合意。ビルド・ターゲット正本は `CLAUDE.md`、運用ルールは `.agents/rules/`、アーキテクチャは `docs/`。

## 原理原則

- **コンテキスト**: 最も希少な資源。認知負荷と情報量を最小化し、指針・本ファイル自身も短く保つ。
- **実データ・実測**: モックや推測より EDINET / Neon / 本番 read の実データと件数で判断する。ゲートは計測してから次へ。
- **Git First**: Git が唯一の Source of Truth。永続判断は Git か memory、一時情報は残さない。履歴詳細は Git に委ねる。
- **責務分離**: ロジック／サービスは入れ替え可能なモジュールに。Core は Vapor/Fluent 非依存、Web/DB は `BltServerCore` に閉じる（詳細は `CLAUDE.md`）。
- **開発**: 機能追加 → 抽象化 → 単純化。抽象化は重複が実際に出てから。コードは少なく、必要振る舞いは満たす。要求前の拡張機構は作らない。
- **テスト**: 仕様＝振る舞いを検証する。境界値・異常系を重視し、呼び出し順や内部構造は見ない。

## 機能の実装サイクル

新機能・Stage 拡張は次の順。**バンプ**は Neon `cache_version` のみ（`blueTickerVersion` ではない → `versioning.md`）。**公開範囲**（REST/MCP 解禁など）は機能ごとに都度確認。

| # | 段階 | 書き込み先 | バンプ |
|---|---|---|---|
| 1 | 日経225限定で本番へ初期投入（最新年度を埋める。探索的試し書き禁止） | 本番 write | しない |
| 2 | 最新年度 100% 後にロジック改善（母数＝最新有報が取れた社。欠測は正当か不具合か確認） | — | しない |
| 3 | 改善結果を使い捨てで検証 | 使い捨て | しない |
| 4 | 問題なければ公開（都度確認）し、225 **全件**を本番へ揃える | 本番 write | しない |
| 5 | 全件を見たうえでのロジック改善 | — | しない |
| 6 | 不審フラグ（`needs_review`・あいまい失敗・異常欠測など）は手動 ingest | 本番 write | しない |
| 7 | 225 全体で問題なければ全銘柄へ拡張 | 本番 write | しない |
| 8 | 全銘柄展開に伴うロジック定着 | 本番 write | **する** |

- **母集団**: breakdowns/statements は `assets/nikkei225.csv` / `priorityIngestCodes()` で対象限定。financials/filing-sections は同 CSV が処理順の優先のみ → 225 に閉じるなら `--codes` 等で明示。
- **接続**: 使い捨て＝`DATABASE_URL`、本番 read＝`BLT_PROD_DATABASE_URL`（SELECT のみ）、本番 write＝`DATABASE_URL="$BLT_PROD_WRITE_DATABASE_URL" blt-server ...`（コマンド単位。既定の差し替え禁止）。RO は WRITE 親ブランチの子（自動同期なし）→ ingest 後は `scripts/neon-reset-ro-from-parent.sh` で揃える。

## 監査レビューとモデル分担

大幅変更・リファクタ・効率化の後は、実装セッション以外の主体に監査させ是々非々で判断する（単一ファイルでも対象）。

- **渡すもの**: 仕様（契約）と diff のみ。結論へ誘導しない。
- **問い**: 仕様を満たすか／既存を壊していないか。
- **タイミング**: main マージ前（ブランチ高度＝品質ゲート）。
- **手段**: `Agent` / `Task` のみ（Cursor CLI 不使用）。

| 作業 | モデル |
|---|---|
| 本体（対話・設計・実装） | Grok 4.5 |
| 監査レビュー | Grok 4.5、または難易度に応じて上位 |
| 実装サブエージェント | Composer 2.5 |
| 探索・並列調査 | Grok 4.5 |

対象作業は表のモデルへ委譲する（本体セッションや Cloud でも同じ）。

## Cursor Cloud

Linux（Ubuntu 24.04）+ swiftly。詳細背景はリンク先。

- **build/test**: `-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility` 必須（`.agents/rules/project/dependencies.md`、`.github/workflows/ci.yml` の `swift-linux`）。
- **起動**: 非空 `BLT_EDINET_API_KEY`（ダミー可）。既定 `127.0.0.1:3000`。`DATABASE_URL` なし＝ステートレス、`CF_ACCESS_TEAM_DOMAIN` なし＝無認証。例: `BLT_EDINET_API_KEY=dev-local-dummy ./.build/debug/blt-server` → `curl -s http://127.0.0.1:3000/healthz`（認証は `docs/api-auth.md`）。
- **テスト SKIP**: `BLT_TEST_POSTGRES_URL` / 実 EDINET 鍵 / `XAI_API_KEY` 未設定時（Neon Secrets とは別）。

### Neon Secrets

アプリが読むのは `DATABASE_URL` のみ。本番系は明示オプトイン（上表の書き込み先）。

| Secret | 用途 | 禁止 |
|---|---|---|
| `DATABASE_URL` | 使い捨て（schema only 可）。探索・検証・スキーマやり直し | 本番を指させない |
| `BLT_PROD_DATABASE_URL` | 本番 SELECT / 件数（WRITE の **子ブランチ**接続。作成／reset 時点のコピー） | 書き込み・`DROP`・これを `DATABASE_URL` にして起動（`autoMigrate`） |
| `BLT_PROD_WRITE_DATABASE_URL` | サイクル上の本番 ingest／ユーザー明示の書き込み（**親＝大元ブランチ**） | 既定差し替え・`DROP`・未検証の探索 ingest。未設定なら追加案内して停止（RO へ書かない） |
| `NEON_API_KEY` | RO を親へ reset する Neon API 認証 | リポジトリへ書かない |
| `NEON_PROJECT_ID` | Neon project id | — |
| `NEON_WRITE_BRANCH_ID` | WRITE 親の `br-…`（`source_branch_id`） | 接続 URL の `ep-…` や `postgresql://` を流用しない |
| `NEON_RO_BRANCH_ID` | RO 子の `br-…`（reset 対象） | 同上 |

**RO 同期**: WRITE への書き込みは RO に流れない。`scripts/neon-reset-ro-from-parent.sh`（Neon Restore API＝GUI の Reset from parent 相当）で RO を親 HEAD に上書きする。定期 sync（`blt-scheduled-sync.sh`）は上記 4 変数が揃っているとき ingest 後に自動実行（欠ける／失敗しても ingest 成否には影響させない）。手動: 同スクリプトをそのまま実行。

**42P07**（使い捨てのみ）: テーブルあり・`_fluent_migrations` 空で起動失敗 → 空確認のうえ `psql "$DATABASE_URL" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'`。本番では不可。
