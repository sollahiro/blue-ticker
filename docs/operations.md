# 外部サービス依存と運用保守

採用中の外部サービス（Neon / Fly.io / Cloudflare）について、(1) コード・設定上の結合点と代替可能性、(2) 定常運用で保守すべきポイント、(3) Git の外にある状態、を棚卸しする。デプロイ手順そのものは `deploy.md`、全体構成は `architecture.md` を参照。

## 大前提: データはすべて EDINET から再導出可能

Neon の全テーブル（Stage 1 書類一覧・Stage 3 RAW fact・Stage 4/4-half 財務サマリ・Stage 5 セクション本文）と Fly Volume の内容（EDINET 取得キャッシュ）は、いずれも **EDINET API から `sync` → `ingest` で再構築できる導出データ**であり、真実源は EDINET にある。したがってどのサービスの移行・障害でも「失われて困る一次データ」は存在しない。ただし全社バックフィルは数日〜1週間規模かかるため、実移行では dump/restore（後述）で時間を買うのが現実的。

## サービス別の結合点と代替可能性

### Neon（DB）— 代替容易

| 観点 | 内容 |
|---|---|
| 結合点 | `DATABASE_URL` 環境変数 1 本のみ（`BltServerCore/Database.swift`）。SQL は Fluent + `fluent-postgres-driver` 経由の標準 Postgres で、Neon 固有 API・拡張への依存はない |
| Neon 前提の実装 | `withDbRetry`（`DbRetry.swift`）は scale-to-zero によるコールドスタート切断への対策だが、汎用の再接続リトライであり他の Postgres でも無害 |
| 下限要件 | **Postgres であること**（JSONB・String PK を使用。テストの SQLite は代替にならない）。TLS は接続 URL の `?sslmode=` で解決 |
| 代替先の例 | 任意の managed / self-host Postgres 16+（RDS、Supabase、Fly Postgres、Docker 等） |
| 切り替え手順の骨子 | ① `pg_dump` → 新 DB へ `pg_restore`（スキーマは起動時 `autoMigrate` でも再作成される）② `DATABASE_URL` secret を差し替え ③ ローカル launchd ジョブの `.env` 側も同時に差し替え。dump を省略して全社再 ingest でもよい（時間コストのみ） |

### Fly.io（compute）— 代替容易

| 観点 | 内容 |
|---|---|
| 結合点 | `fly.toml`・Fly Volume（`/data`）・`fly secrets`・`fly deploy` 等の CLI 操作のみ。**アプリ本体は素の Docker イメージ**で、self-host 手順が `deploy.md` に併記済み |
| 構造上の利点 | 方式A（serviceless + Cloudflare Tunnel）のため、Fly の LB・TLS・DNS・公開ポートに**依存していない**。origin はどこで動いていても `cloudflared` の outbound 接続だけで到達可能になる |
| 代替先の例 | 任意の Docker ホスト（VPS、自宅サーバー、他 PaaS） |
| 切り替え手順の骨子 | ① 新ホストで同一イメージを起動（`deploy.md` self-host 節）② secrets を env として注入 ③ `/data` は EDINET キャッシュのためコピー不要（再取得で埋まる）④ Tunnel トークンはそのまま使える（Cloudflare 側の設定変更不要）。DNS 切り替えすら発生しない |

### Cloudflare（エッジ認証 + Tunnel）— 切り替え予定なし・撤退経路なし（Bearer 認証は廃止済み）

切り替えは想定しない（ユーザー方針）。ただし構造上のロックイン範囲は以下に限定されている。

| 観点 | 内容 |
|---|---|
| 結合点 | ① `cloudflared` サイドカー（`Dockerfile` の ARG 固定 + `entrypoint.sh` の env ゲート）② 認証モード `CF_ACCESS_TEAM_DOMAIN`（`Routes.swift`）③ CLI 側の SSO 付与（`RemoteAPIClient.swift`・`LoginCommand.swift`）: `ticker login` → `CF_Authorization` Cookie。ローカルの `cloudflared` インストールに依存（Service Token は v26.7.2 で廃止済み）④ Zero Trust ダッシュボード上の Tunnel / Access アプリ / ポリシー / IdP 設定 |
| 撤退経路 | **なし**。静的 Bearer（`BLT_AUTH_TOKEN`）モードは廃止済み（`Routes.swift`・`ticker` CLI 双方から削除）。Cloudflare Access を撤退する場合は代替の認証機構をコードから再実装する必要がある |
| 不変条件 | 方式A は origin が JWT を検証しない。安全性は「**Tunnel 経由限定 + 公開ポート閉鎖 + Access ポリシー**」の 3 点セットで成立する。**どれか 1 つでも欠けると無認証素通りになる**ため、fly.toml へのサービスブロック追加・ポート公開は単独で行ってはならない |

R2（Stage 2 生 XBRL 退避）は延期中で、現時点でコード上の結合はない。

## 定常運用の保守ポイント

- **blt-server / ingest のログは JSON 1 行**: `bootstrapBltLogging` が stderr に `{"timestamp","level","logger","message","metadata"}` を出す。ingest 完了は `metadata.event=ingest_summary`（`failed>0` は warning）。DB リトライは `db_retry` / `db_retry_exhausted`。`fly logs` や `.build/blt-scheduled.log` から `jq` / grep で拾える。
- **launchd ingest ジョブが単一 Mac 依存**: 重い ingest（Stage 3/4/4-half/5）はローカル Mac の launchd で回している（Fly 上では OOM・issue #34/#35 参照）。Mac が止まるとデータ鮮度が止まる（read 配信は影響なし）。plist・`.env` は Git 非管理＝このマシンにしかない。外形監視は `scripts/check-ingest-freshness.sh`（`DATABASE_URL` 必須・既定 36h）。`company_financials` / `company_half_financials` / `company_filing_sections` / `edinet_sync_state` の `max(updated_at)` が閾値を超えると exit 1。cron / 手動で回す（Fly `/healthz` では検知できない）。
- **キャッシュバージョンバンプと Fly デプロイの同期（自動化済み・2026-07-05）**: `Sources/**`・`Dockerfile`・`fly.toml`・`Package.*` の変更を含む push が main にマージされると、GitHub Actions（`.github/workflows/deploy.yml`）が `flyctl deploy --remote-only` を自動実行するため、手動 `fly deploy` は不要（`FLY_API_TOKEN` repo secret 必須）。バンプ規則は `versioning.md`「Neon キャッシュバージョン」を参照。`/healthz` の `cache_versions` で今イメージが話しているバージョンを curl 一発で確認できる。
- **cloudflared のバージョン固定更新**: `CLOUDFLARED_VERSION` / `CLOUDFLARED_SHA256` の固定運用は `deploy.md`「C. Dockerfile に cloudflared サイドカーを同梱」を参照。セキュリティ更新は自動で入らないため、数ヶ月に一度 releases を確認して両方を書き換える。
- **Cloudflare SSO セッションの失効**: Access の Session Duration 経過で失効したら `ticker login` を再実行する。手順・完全無人自動化の非対応は `deploy.md`「クライアント設定（CLI・SSO ログイン）」を参照。
- **Fly serviceless の再起動挙動（自動化済み）**: `[http_service]` が無いため `fly deploy` 後にマシンが stopped のままになることがある。`deploy.yml` の「Ensure machine is running」ステップが stopped を検知して `fly machine start` する。
- **Neon 無料プランの scale-to-zero（5 分固定）**: コールドスタート切断は `withDbRetry`（ingest 側）と HTTP read 4 ルートのリトライで吸収済み。プラン変更・別 Postgres への移行時はこの前提（suspend が起きる/起きない）を再確認する。
- **Linux ビルドの一時回避策**: swift-nio の `MemberImportVisibility` 回避フラグ（`ci.yml`・`Dockerfile`）は swift-nio 修正後に除去する（`dependencies.md`）。

## Git の外にある状態（棚卸し）

リポジトリと EDINET だけでは復元できない・手で再設定が必要なもの。障害復旧やマシン移行時はここを確認する。

| 置き場所 | 状態 | 復旧手段 |
|---|---|---|
| Fly secrets | `BLT_EDINET_API_KEY` / `DATABASE_URL` / `CF_ACCESS_TEAM_DOMAIN` / `CLOUDFLARE_TUNNEL_TOKEN` | 各サービスで再発行・`fly secrets set`（`deploy.md` 環境変数表） |
| Neon | 全テーブルのデータ | dump/restore または EDINET から再 ingest |
| Cloudflare ダッシュボード | Tunnel 定義・Access アプリ / ポリシー・IdP 接続・zone | `deploy.md`「Cloudflare Access」A 節の手順で再作成 |
| ローカル Mac | launchd plist・`scripts/blt-scheduled-sync.sh` 用 `.env`・keychain（EDINET キー）・cloudflared の SSO ログイン状態 | plist は `deploy.md`「定期同期」から再作成、キーは再発行、SSO は `ticker login` |
| Fly Volume `/data` | EDINET 取得キャッシュ | 再取得（コピー不要） |
