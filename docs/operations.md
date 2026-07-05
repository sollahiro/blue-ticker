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

### Cloudflare（エッジ認証 + Tunnel）— 切り替え予定なし・撤退経路は実装済み

切り替えは想定しない（ユーザー方針）。ただし構造上のロックイン範囲は以下に限定されている。

| 観点 | 内容 |
|---|---|
| 結合点 | ① `cloudflared` サイドカー（`Dockerfile` の ARG 固定 + `entrypoint.sh` の env ゲート）② 認証モード `CF_ACCESS_TEAM_DOMAIN`（`Routes.swift`）③ CLI 側の認証付与（`RemoteAPIClient.swift`）: Service Token 2 ヘッダ（非対話・AI エージェント用）と `ticker login` SSO（`CF_Authorization` Cookie。ローカルの `cloudflared` インストールに依存）④ Zero Trust ダッシュボード上の Tunnel / Access アプリ / ポリシー / IdP 設定 |
| 撤退経路（実装済み） | 認証モード②の静的 Bearer（`BLT_AUTH_TOKEN`）へ切り替え + `fly.toml` に `[http_service]` を復活させて公開ポートを開ける。コード変更不要・env と toml のみ |
| 不変条件 | 方式A は origin が JWT を検証しない。安全性は「**Tunnel 経由限定 + 公開ポート閉鎖 + Access ポリシー**」の 3 点セットで成立する。**どれか 1 つでも欠けると無認証素通りになる**ため、fly.toml へのサービスブロック追加・ポート公開は単独で行ってはならない |

R2（Stage 2 生 XBRL 退避）は延期中で、現時点でコード上の結合はない。

## 定常運用の保守ポイント

- **launchd ingest ジョブが単一 Mac 依存**: 重い ingest（Stage 3/4/4-half/5）はローカル Mac の launchd で回している（Fly 1GB では OOM）。Mac が止まるとデータ鮮度が止まる（read 配信は影響なし）。plist・`.env` は Git 非管理＝このマシンにしかない。将来はクラウドスケジューラへ移行予定（`deploy.md`「定期同期」）。
- **キャッシュバージョンバンプと Fly デプロイの同期**: `fin-v*` 等（`versioning.md`）をバンプしたら **必ず `fly deploy` で Fly 側イメージも更新**する。古いイメージは新バージョンで格納された行を stale 拒否し、未格納と同じ 404 になる（そのデータが「見えなくなる」）。
- **cloudflared のバージョン固定更新**: `Dockerfile` の `CLOUDFLARED_VERSION` / `CLOUDFLARED_SHA256` は固定値。セキュリティ更新は自動で入らないため、数ヶ月に一度 releases を確認して両方を書き換える。
- **Cloudflare 認証クレデンシャルの失効**: 人間の対話利用は `ticker login`（SSO）に移行済みで、Access の Session Duration 経過で失効したら `ticker login` を再実行するだけ（保守作業なし）。Service Token は非対話用途（AI エージェント・自動化）に残置しており、こちらは有効期限（既定 1 年）で失効すると突然 403 になる。期限前にローテーションし、クライアント側は `ticker config set --cf-access-client-id/--cf-access-client-secret` で更新する。
- **Fly serviceless の再起動挙動**: `[http_service]` が無いため `fly deploy` 後にマシンが stopped のままになることがある。`--restart always` 設定 + `fly machine start` を確認する（Tunnel 常駐に必須）。
- **Neon 無料プランの scale-to-zero（5 分固定）**: コールドスタート切断は `withDbRetry`（ingest 側）と HTTP read 4 ルートのリトライで吸収済み。プラン変更・別 Postgres への移行時はこの前提（suspend が起きる/起きない）を再確認する。
- **Linux ビルドの一時回避策**: swift-nio の `MemberImportVisibility` 回避フラグ（`ci.yml`・`Dockerfile`）は swift-nio 修正後に除去する（`dependencies.md`）。

## Git の外にある状態（棚卸し）

リポジトリと EDINET だけでは復元できない・手で再設定が必要なもの。障害復旧やマシン移行時はここを確認する。

| 置き場所 | 状態 | 復旧手段 |
|---|---|---|
| Fly secrets | `BLT_EDINET_API_KEY` / `DATABASE_URL` / `CF_ACCESS_TEAM_DOMAIN` / `CLOUDFLARE_TUNNEL_TOKEN` | 各サービスで再発行・`fly secrets set`（`deploy.md` 環境変数表） |
| Neon | 全テーブルのデータ | dump/restore または EDINET から再 ingest |
| Cloudflare ダッシュボード | Tunnel 定義・Access アプリ / ポリシー / Service Token・IdP 接続・zone | `deploy.md`「Cloudflare Access」A 節の手順で再作成 |
| ローカル Mac | launchd plist・`scripts/blt-scheduled-sync.sh` 用 `.env`・keychain（EDINET キー / Service Token）・cloudflared の SSO ログイン状態 | plist は `deploy.md`「定期同期」から再作成、キーは再発行、SSO は `ticker login` |
| Fly Volume `/data` | EDINET 取得キャッシュ | 再取得（コピー不要） |
