# blt-server デプロイ手順

`Dockerfile` から同一イメージを作り、Fly.io（クラウド）と self-host（任意の Docker ホスト）の双方で動かす。設計の背景は `blt-server-roadmap.md`「クラウド構成」を参照。

## 環境変数

| 変数 | 役割 | デプロイでの扱い |
|---|---|---|
| `BLT_HOST` / `BLT_PORT` | bind（既定 `0.0.0.0:8080`） | Dockerfile 既定。通常変更不要 |
| `BLUE_TICKER_ASSETS_PATH` | EDINET コード CSV の場所（既定 `/app/assets`） | Dockerfile 既定 |
| `BLUE_TICKER_USER_DATA_PATH` | キャッシュ・設定の永続先（既定 `/data`） | Volume をここにマウント |
| `BLT_EDINET_API_KEY` | EDINET API キー | **secret**（必須） |
| `BLT_AUTH_TOKEN` | Bearer トークン。設定時のみ `/v1` を保護 | **secret**（self-host で公開時は必須） |
| `CF_ACCESS_TEAM_DOMAIN` | 設定時は Cloudflare Access モード（方式A・エッジ信頼）。origin は JWT 検証せず Tunnel + Access に委ねる | **secret**（Cloudflare 本番時。`BLT_AUTH_TOKEN` とは排他） |
| `CLOUDFLARE_TUNNEL_TOKEN` | cloudflared サイドカーの Tunnel トークン。設定時のみコンテナ内で cloudflared を起動 | **secret**（Cloudflare 本番時） |
| `DATABASE_URL` | Neon Postgres 接続文字列 | **secret**（未設定なら DB なしのステートレス動作） |

`/healthz` は認証不要で `{"status":"ok","cache_versions":{...}}` を返す（ヘルスチェック用）。`cache_versions` はイメージが今話している derived キャッシュバージョン（`xbrl_facts`・`company_financials`・`company_financials_min_servable`・`company_half_financials`・`filing_sections`・`filing_sections_min_servable`）で、キャッシュバージョンバンプ後に `fly deploy` を忘れていないか curl 一発で確認できる。`*_min_servable` は各 read の床（明示定数。現行版との完全一致ではない）。

認証モードは `/v1` 配下で起動時に env から1つ選ばれる（優先順）: ① `CF_ACCESS_TEAM_DOMAIN` → Cloudflare Access、② `BLT_AUTH_TOKEN` → 静的 Bearer、③ どちらも無し → 無認証（ローカル開発専用・起動時 warning）。本番（Cloudflare）手順は「Cloudflare Access（本番認証・方式A）」を参照。

## Fly.io

```bash
# 1. 初回のみアプリ作成（fly.toml の app 名が重複する場合はここで変更）
fly launch --no-deploy --copy-config --name blt-server --region nrt

# 2. シークレット注入
fly secrets set \
  BLT_EDINET_API_KEY=xxxxx \
  BLT_AUTH_TOKEN=$(openssl rand -hex 32) \
  DATABASE_URL='postgres://...neon.tech/...?sslmode=require'

# 3. 永続 Volume（/data）。nrt に作成
fly volumes create blt_data --region nrt --size 1

# 4. デプロイ
fly deploy

# 5. 初回データ同期（Stage 1 書類一覧 → Neon）。稼働マシン上で実行
fly ssh console -C "/app/blt-server sync --from 2024-01-01"

# 6. 取り込み（Stage 3 数値 fact ＋ Stage 4 計算済み財務サマリ → Neon）。--limit で分割推奨
fly ssh console -C "/app/blt-server ingest --limit 50"
```

`ingest` は Stage 3（XBRL 数値 fact → `edinet_xbrl_facts`）に続けて Stage 4（計算済み財務サマリ → `company_financials`）を実行する。Stage 4 計算は HTML 依存抽出・waterfall を含みメモリを使うため、shared-cpu-1x/1gb の Fly 上で大量に走らせると OOM しうる。**重い初回バックフィルはローカル（または余裕のあるマシン）から `DATABASE_URL` を Neon に向けて実行する**運用を推奨（下記「Neon 接続の E2E 検証」と同手順）。REST サーバー（Fly）は `company_financials` を読むだけなので financials は OOM しない。

ヘルスチェック・HTTPS・証明書は `fly.toml` と Fly が処理する。独自ドメインは `fly certs add <domain>`。

### GitHub Actions の repo secrets

CI から使う secrets（`fly secrets` とは別物。`gh secret set` で登録する）。

| secret | 役割 | 使用箇所 |
|---|---|---|
| `FLY_API_TOKEN` | `flyctl deploy` の認証（`fly tokens create deploy` で発行したデプロイ専用トークンを推奨） | `.github/workflows/deploy.yml`（main push 時の自動デプロイ） |
| `BLT_API_DOMAIN` | 外形監視が無認証アクセスを試す本番ホスト名（現在 `api.sollahiro.com`。値自体は CLI のビルド時既定値として上記「環境変数」節や `blt-server-roadmap.md` に既出で秘匿情報ではない）。secret にするのは値を隠すためではなく、ホスト切り替え時に secret 更新だけで済み、ワークフロー本体の変更が要らないようにするため | `.github/workflows/edge-security-smoke.yml`（Cloudflare Access 生存確認） |

## self-host（Docker）

```bash
# ビルド
docker build -t blt-server .

# 起動（キャッシュ永続化のため /data をボリュームマウント）
docker run -d --name blt-server -p 8080:8080 \
  -e BLT_EDINET_API_KEY=xxxxx \
  -e BLT_AUTH_TOKEN=xxxxx \
  -e DATABASE_URL='postgres://...' \
  -v blt_data:/data \
  blt-server

# 初回同期 + Stage 3 取り込み
docker exec blt-server /app/blt-server sync --from 2024-01-01
docker exec blt-server /app/blt-server ingest --limit 50
```

## Cloudflare Access（本番認証・方式A）

クラウド本番は **Cloudflare Access**（Zero Trust リバースプロキシ）をエッジに置き IdP で認証する。origin（Fly.io）は **Cloudflare Tunnel** 経由でのみ到達可能にし公開ポートを閉じる。origin は **JWT 検証をしない（方式A・エッジ信頼）**ため新規依存ゼロ。安全性は「Tunnel + 公開ポート閉鎖 + Access ポリシー」の3点セットで初めて成立する（ポートが開いていると Cloudflare 経路に対し無検証で素通りになる）。設計の背景・方式B への移行トリガーは `blt-server-roadmap.md`「認証」節を参照。

> **常駐前提**: cloudflared が常時 outbound 接続を維持して Tunnel が成立するため、Fly マシンは **always-on**（scale-to-zero 不可）になる。「Phase 2」で fly.toml を常駐化する。

### A. Cloudflare 側（Zero Trust ダッシュボード）

1. **前提**: ドメイン（zone）が Cloudflare 管理下にあること（未移管なら zone 追加が先）。
2. **Tunnel 作成**（Networks → Tunnels → Cloudflared）→ **トークン**を取得。Public hostname を1本追加: `api.<domain>` → サービス `http://localhost:8080`（コンテナ内 blt-server）。token モードのためルーティングはダッシュボードが保持し、コンテナ内に config/credentials ファイルは不要。
3. **Access アプリ作成**（Access → Applications → Self-hosted）= `api.<domain>`。
4. **Access ポリシー**（Access → Applications → 当該アプリ → Policies）: **SSO / IdP**（decision = *Allow*・rule = emails / group）を1本作成。CLI（`ticker login`）・iOS とも同じ SSO 経路を使う。
5. **IdP 接続**（Settings → Authentication）でログイン方式（Google / OIDC 等）を追加。

### B. origin（Fly）側 secrets

```bash
fly secrets set \
  CF_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com \
  CLOUDFLARE_TUNNEL_TOKEN=<tunnel-token>
# Cloudflare Access モードでは BLT_AUTH_TOKEN は設定しない（排他・前者が優先）
```

### C. Dockerfile に cloudflared サイドカーを同梱（実装済み）

runtime ステージ（`swift:6.1-slim` / debian）に cloudflared を入れ、ENTRYPOINT を `scripts/entrypoint.sh` に置き換えている。`CLOUDFLARE_TUNNEL_TOKEN` 未設定なら blt-server のみ起動するので self-host 互換は保たれる（`docker build`＋`docker run` で無トークン／トークンありの両分岐を確認済み）。

cloudflared は `latest` ではなくバージョン固定＋sha256 検証で取得する（サプライチェーン変化を防ぐため）。ダウンロード後 curl は runtime イメージから削除する（不要な攻撃面を残さない）。更新時は Dockerfile の `CLOUDFLARED_VERSION`/`CLOUDFLARED_SHA256` を [cloudflared releases](https://github.com/cloudflare/cloudflared/releases) の新バージョンで書き換える。実装は `Dockerfile`・`scripts/entrypoint.sh` を参照。

cloudflared は接続断を内部で自動再接続する。blt-server が落ちればコンテナが終了し Fly が再起動する（単一テナント前提の最小構成）。

### D. fly.toml の段階カットオーバー

公開ポート閉鎖は **Cloudflare 側が動作確認できてから**でなければ origin に到達不能になる。2 段で進める。

- **Phase 1（ポートは開けたまま検証）**: 上記 secrets を設定し、サイドカー入りイメージを `fly deploy`。`https://api.<domain>`（tunnel 経由）で疎通を確認し、**Access が効いていること**を検証する。

  ```bash
  # SSO Cookie 付き → 200（<jwt> は `cloudflared access token -app=<url>` で取得）
  curl -s https://api.<domain>/v1/companies/7203/financials?years=3 \
    -H "Cookie: CF_Authorization=<jwt>" | jq '.schema_version'
  # 無認証 → Access のログイン画面 or 403（=ポリシーが効いている）
  curl -si https://api.<domain>/v1/companies/7203/financials | head -n1
  ```

- **Phase 2（公開ポート閉鎖・経路を tunnel に一本化・適用済み）**: Phase 1 を確認後にのみ実施。`fly.toml` から `[http_service]`（＝公開 LB・ポート 80/443）を**丸ごと撤去**する。サービスが1つも無くなることで Fly の auto-stop 対象から外れ、マシンは **always-on**（Tunnel 維持に必須）になる（`min_machines_running` はサービスブロック内の field なので `[http_service]` 撤去後は置き場が無い。serviceless＝常駐が正しい機構）。`/healthz` の Fly HTTP チェックも service 撤去で失われるため可用性は Tunnel + Access に委ねる。再 `fly deploy` 後、`https://blt-server.fly.dev` への直アクセスが到達不能・`api.<domain>` のみ生存を確認する。

### クライアント設定（CLI・SSO ログイン・実装済み）

CLI は `ticker login` でブラウザ経由の SSO ログインができる。内部的には `cloudflared`（要インストール。`brew install cloudflared` 等）の `access login` / `access token` を呼び出す薄いラッパーで、JWT 自体の保管・更新は cloudflared に委ねる（blue_ticker 側は `config.json` に「SSO 有効」フラグのみ持つ）。AI エージェント経由での利用も、その場にいる人間が初回ログイン時にブラウザ操作を行う想定（Service Token は廃止済み。ブラウザ操作できない完全無人の自動化には非対応）。

**`backend`（既定 remote）・`server-url`（既定 `Api.defaultRemoteServerURL`、現在 `https://api.sollahiro.com`）は CLI にビルド時の既定値として組み込まれている**（local モードのユーザー向け分析 CLI 段階的廃止方針のため。`architecture.md` 参照）。そのため新規インストール後は `config set` 不要で以下だけで使い始められる。

```bash
ticker login   # ブラウザが開き、Access のログイン画面（IdP）で認証
```

既定と異なるサーバー・self-host 等を使う場合のみ `ticker config set --server-url <url>`（や `--backend local`）で上書きする。

ログイン成功後は remote 経路のリクエストのたびに `cloudflared access token -app=<server-url>` を呼び、`Cookie: CF_Authorization=<jwt>` として付与する。**`Cf-Access-Jwt-Assertion` ヘッダーでは Access のログイン画面へ 302 されるだけで通らない**ことを実機検証で確認済み（そのヘッダーは Access が認証済みリクエストを origin へ転送する際に付与するものであり、クライアントが未認証状態で送っても意味を持たない）。前提として Access アプリに **SSO（Allow）ポリシー**（上記 A-4）が当該ユーザーのメールに対して設定されている必要がある。無効化は `ticker config set --disable-sso`。

セッションが失効した場合（Access の Session Duration 経過後など）は `ticker login` を再実行する。origin（方式A）は JWT を検証しないため、この機構の安全性は引き続き「Tunnel + 公開ポート閉鎖 + Access ポリシー」に依存する。

## 定期同期

`blt-server sync` / `ingest` はワンショット。定期実行は Fly スケジューラ（`fly machine run ... --schedule`）または self-host の cron / launchd で回す。`sync`（引数なし＝前回 `synced_through` から当日まで）→ `ingest`（未取り込み・旧バージョン書類のみ）の順に実行する。

**重い ingest（Stage 3/4）は Fly 上で OOM する**ため、計算はローカル Mac の launchd で実行し Fly は読むだけにする。Fly スケジュールマシンへの移行は issue #34 で OOM により打ち止め（issue #35 参照）。

### 定期同期（ローカル launchd）

ラッパースクリプト `scripts/blt-scheduled-sync.sh` が `.env` を読み込み、リリースビルド済みバイナリで `sync`→`ingest` を実行してログ（`.build/blt-scheduled.log`）に追記する。`ingest` はステージ別に分けて実行し、既定値は `Stage 4=80` / `Stage 4-half=80` / `Stage 5=50`（空白解消優先・Mac 負荷抑制）。上書きは env `BLT_INGEST_LIMIT_STAGE4` / `BLT_INGEST_LIMIT_STAGE4_HALF` / `BLT_INGEST_LIMIT_STAGE5` を使う。`BLT_INGEST_LIMIT` は後方互換として「3ステージの共通既定値」として扱う。plist はテンプレートから生成する共有ファイル（`scripts/launchd/com.sollahiro.blt-sync.plist.template`）のため、マシン固有のチューニング値は `.env` 側に置く。

> **長時間ランは transient な接続エラーで巻き戻る**: `ingest` をステージ別に分けていても、limit を大きくしすぎると 1 ランが長くなり途中で Neon 接続がリセット（PSQLError）される。完走率を優先し、まずは既定（4=80 / 4-half=80 / 5=50）から始め、必要なら `.env` の stage 別 limit を下げる。

各ステージには実行時間の上限（既定 5400 秒＝90 分）を設けており、Mac のスリープ等で Neon 接続がハングして超過した場合は SIGTERM→SIGKILL で強制終了し次のステージへ進む。上書きは `.env` の `BLT_STAGE_TIMEOUT_SECONDS` を使う。また実行中は `caffeinate -i -s -w $$` でシステム/アイドルスリープを抑止する（スクリプト終了時に自動解除）。

```bash
# 1. リリースビルド（コード変更後は再実行が必須）
#    旧バイナリは新しく配線したステージ（例: Stage 4-half）を黙って飛ばし、
#    ログにそのステージの完了行が出ないまま該当テーブルが埋まらない。
swift build -c release --product blt-server

# 2. .env を作成（キー名は .env.example を参照。DATABASE_URL / BLT_EDINET_API_KEY が必須）

# 3. plist をテンプレートから生成して登録（再登録も同じコマンドで bootout→bootstrap）
./scripts/install-launchd.sh

# 4. 手動実行（検証・即時 drain）
launchctl kickstart gui/$(id -u)/com.sollahiro.blt-sync
tail -f .build/blt-scheduled.log
```

plist はリポジトリの絶対パスを埋め込む必要があるためマシン固有＝Git 非管理（テンプレートは `scripts/launchd/com.sollahiro.blt-sync.plist.template`、Git 管理下）。新しい Mac へ移行する場合も `git clone` → 上記手順だけで再構築できる。

初回バックフィル中（全 ~3,944 社）は本ジョブが少しずつ `company_financials`（および Stage 4-half の `company_half_financials`）を埋める（1 日 4 回・6 時間おき、既定 limit は Stage 4=80 / Stage 4-half=80 / Stage 5=50）。`sync` は初回のみ `synced_through` から当日までの catch-up で重くなるが、以後は増分。`computeFinancials` のロジック・契約変更で `companyFinancialsCacheVersion` をバンプした後は Fly 側イメージの更新が必要だが、main への push で自動反映される（`operations.md`「定常運用の保守ポイント」）。財務系 read はライブ計算フォールバックを持たない（DB 専用・未格納 404・DB 非接続 503）ため、サーバーが重い計算で OOM することはない。

## EDINET マスタデータ（コードリスト CSV）の更新

企業マスタ（証券コード⇔企業名⇔業種⇔上場区分、`assets/EdinetcodeDlInfo.csv`）の正本は Neon（`edinet_master_snapshot`、単一行）に一本化する。更新するときは必ず両方を同時に行う:

```bash
# 1. git 側（ローカル開発・フォールバック用に同一内容を保つ）
#    assets/EdinetcodeDlInfo.csv を差し替えてコミット・push（通常の docs/コード変更と同様）

# 2. Neon 側（本番反映。DATABASE_URL を Neon に向けて実行、ローカルから可）
DATABASE_URL=... .build/release/blt-server master-data-upload assets/EdinetcodeDlInfo.csv
```

稼働中の Fly サーバーは `updated_at` を 30 分間隔でポーリングし（`Api.masterDataPollIntervalSeconds`）、変更を検知すると自動でローカルファイルへ反映してリロードする（**再起動不要**）。

> **注意（drift）**: Neon に一度でも行が入ると、以後は **Neon 側が優先**される。ポーリングのたびに Neon の内容でローカルファイルを上書きするため、`assets/EdinetcodeDlInfo.csv` を git 側だけ更新して再デプロイしても、次のポーリングで Neon の（古い）内容に巻き戻る。**CSV を更新する際は必ず `master-data-upload` もセットで実行する**。Neon にまだ行が無い場合のみ、イメージ焼き込み済み CSV がそのまま使われる（フォールバック）。

## Neon 接続の E2E 検証

実 DB に対する検証は 2 段で行う。CI/ユニットテストはインメモリ SQLite までのため、Postgres 固有挙動（`.json`→JSONB・索引・String PK）と実パイプラインは別途確認する。

### 1. Postgres スキーマ検証（ローカル Docker・EDINET 不要）

マイグレーション・JSONB round-trip・索引を実 Postgres で検証する統合テスト（`PostgresIntegrationTests`）。ローカルでは `BLT_TEST_POSTGRES_URL` 未設定なら skip。CI（`.github/workflows/ci.yml` の `postgres-integration`）では Postgres 16 サービスコンテナ付きで常時実行する。

```bash
docker run -d --name blt-pg -e POSTGRES_PASSWORD=blt -e POSTGRES_DB=blt -p 55432:5432 postgres:16-alpine
BLT_TEST_POSTGRES_URL='postgres://postgres:blt@localhost:55432/blt?sslmode=disable' \
  swift test --filter PostgresIntegrationTests
docker rm -f blt-pg
```

期待: `facts` カラムが `jsonb`、`idx_edinet_documents_edinet_code`/`_sec_code` が存在、Stage 1 冪等 upsert・Stage 3 JSONB round-trip・staleness skip が緑。

### 2. 実 Neon フルパイプライン（要シークレット・EDINET ネットワーク）

`DATABASE_URL`（Neon・`?sslmode=require`）と `BLT_EDINET_API_KEY` をシェルに載せ、ローカルバイナリで sync→ingest→financials を通す。**手動実行でも `.env` をロードすること**（定期同期の launchd と同じ単一ソース）。`sync`/`ingest`/サーバー起動は `BLT_EDINET_API_KEY` 環境変数のみで EDINET API キーを解決する（keychain へはフォールバックしない。blt-server はヘッドレスなサーバープロセスのため）。env 未設定のまま叩くとキーは解決されずエラー終了する。

```bash
# 機密は .env（リポジトリ直下・Git 非管理）に集約し、そこからロードする
set -a; . ./.env; set +a
# （.env が無い環境では export DATABASE_URL=... / export BLT_EDINET_API_KEY=... で代替）

# 起動時に autoMigrate がスキーマを適用（DATABASE_URL があれば自動）
swift run blt-server sync --from 2025-04-01   # Stage 1: 書類一覧 → edinet_documents
swift run blt-server ingest --limit 5         # Stage 3 数値 fact → edinet_xbrl_facts ＋ Stage 4 計算済み → company_financials

# DB に入ったことを確認（psql）
psql "$DATABASE_URL" -c "SELECT count(*) FROM edinet_documents;"
psql "$DATABASE_URL" -c "SELECT doc_id, cache_version, jsonb_typeof(facts) FROM edinet_xbrl_facts LIMIT 5;"
psql "$DATABASE_URL" -c "SELECT code, cache_version, requested_years FROM company_financials LIMIT 5;"

# financials 読み取り（Stage 4 格納済みなら DB から 200。未格納/古い/年数不足は 404・DB 非接続は 503。ライブ計算フォールバックなし。公開契約は不変）
swift run blt-server &                          # ローカル起動（既定 127.0.0.1:3000）
curl -s 'http://127.0.0.1:3000/v1/companies/7203/financials?years=3' | jq '.schema_version, .years[0].fy_end'
```

期待: `edinet_documents`/`edinet_xbrl_facts` に行が入り、`facts` が `jsonb`、financials が 200 + `schema_version=2`。Neon は東京リージョン外（片道 ~100ms）だが書き込みはバッチ・読み取りはキャッシュ＋計算済み JSON のため許容（`blt-server-roadmap.md`「クラウド構成」）。
