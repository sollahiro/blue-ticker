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

`/healthz` は認証不要で `{"status":"ok"}` を返す（ヘルスチェック用）。

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
4. **Access ポリシー 2 本**:
   - **Service Token**（CLI / MCP 用・decision = *Service Auth*）: Service Token を発行（Access → Service Auth → Service Tokens）→ **Client ID / Client Secret** を取得し、ポリシーで当該トークンを許可。ブラウザ不要で非対話。
   - **SSO / IdP**（iOS 等の人間用・decision = *Allow*・rule = emails / group）。配布アプリに共有シークレットを埋められないため Service Token 不可。
5. **IdP 接続**（Settings → Authentication）でログイン方式（Google / OIDC 等）を追加。

### B. origin（Fly）側 secrets

```bash
fly secrets set \
  CF_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com \
  CLOUDFLARE_TUNNEL_TOKEN=<tunnel-token>
# Cloudflare Access モードでは BLT_AUTH_TOKEN は設定しない（排他・前者が優先）
```

### C. Dockerfile に cloudflared サイドカーを同梱

runtime ステージ（`swift:6.1-slim` / debian）に cloudflared を入れ、ENTRYPOINT を小さな起動スクリプトに置き換える。`CLOUDFLARE_TUNNEL_TOKEN` 未設定なら blt-server のみ起動するので self-host 互換は保たれる。

```dockerfile
# runtime ステージに追加（Fly は x86_64）
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared \
 && chmod +x /usr/local/bin/cloudflared \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/entrypoint.sh /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]
```

```sh
#!/bin/sh
# scripts/entrypoint.sh
set -e
if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
  cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN" &
fi
exec ./blt-server
```

cloudflared は接続断を内部で自動再接続する。blt-server が落ちればコンテナが終了し Fly が再起動する（単一テナント前提の最小構成）。

### D. fly.toml の段階カットオーバー

公開ポート閉鎖は **Cloudflare 側が動作確認できてから**でなければ origin に到達不能になる。2 段で進める。

- **Phase 1（ポートは開けたまま検証）**: 上記 secrets を設定し、サイドカー入りイメージを `fly deploy`。`https://api.<domain>`（tunnel 経由）で疎通を確認し、**Access が効いていること**を検証する。

  ```bash
  # Service Token 2 ヘッダ付き → 200
  curl -s https://api.<domain>/v1/companies/7203/financials?years=3 \
    -H "CF-Access-Client-Id: <client-id>" \
    -H "CF-Access-Client-Secret: <client-secret>" | jq '.schema_version'
  # 無認証 → Access のログイン画面 or 403（=ポリシーが効いている）
  curl -si https://api.<domain>/v1/companies/7203/financials | head -n1
  ```

- **Phase 2（公開ポート閉鎖・経路を tunnel に一本化）**: Phase 1 を確認後にのみ実施。`fly.toml` から `[http_service]`（＝公開 LB）を撤去し、`min_machines_running = 1` ＋ `auto_stop_machines`/`auto_start_machines` を外して **always-on** にする（Tunnel 維持に必須）。`/healthz` の Fly HTTP チェックは service 撤去で失われるため可用性は Tunnel + Access に委ねる。再 `fly deploy` 後、Fly 公開 IP への直アクセスが到達不能・`api.<domain>` のみ生存を確認する。

### クライアント設定（CLI・実装済み）

remote backend の CLI は Service Token を keychain に保持し、remote 経路で 2 ヘッダを自動付与する。

```bash
ticker config set --cf-access-client-id <id> --cf-access-client-secret <secret>
# env 上書き: CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET（env > keychain）
```

## 定期同期

`blt-server sync` / `ingest` はワンショット。定期実行は Fly スケジューラ（`fly machine run ... --schedule`）または self-host の cron / launchd で回す。`sync`（引数なし＝前回 `synced_through` から当日まで）→ `ingest`（未取り込み・旧バージョン書類のみ）の順に実行する。

**重い ingest（Stage 3/4）は Fly(1GB) で走らせると OOM する**ため、計算はローカル（または余裕あるマシン）で実行し Fly は読むだけにする。現状はローカル launchd で回す（将来クラウドスケジューラへ移行予定）。

### 定期同期（ローカル launchd）

ラッパースクリプト `scripts/blt-scheduled-sync.sh` が `.env` を読み込み、リリースビルド済みバイナリで `sync`→`ingest` を実行してログ（`.build/blt-scheduled.log`）に追記する。1 回の取り込み件数は env `BLT_INGEST_LIMIT`（既定 200、plist の `EnvironmentVariables` で上書き）で調整。

> **長時間ランは transient な接続エラーで巻き戻る**: `ingest` は 1 プロセスで Stage 3 → Stage 4（通期）→ Stage 4-half の順に流す。limit を大きくすると 1 ラン数時間に及び、途中で Neon 接続がリセット（PSQLError）されるとそのランの **Stage 4 / Stage 4-half がまとめて失われる**（特に最後に走る Stage 4-half は完走しにくい）。完走率を優先し `BLT_INGEST_LIMIT=75` 程度に下げる（バックフィル中の暫定。全社 drain 後は既定に戻してよい）。

```bash
# 1. リリースビルド（コード変更後は再実行が必須）
#    旧バイナリは新しく配線したステージ（例: Stage 4-half）を黙って飛ばし、
#    ログにそのステージの完了行が出ないまま該当テーブルが埋まらない。
swift build -c release --product blt-server

# 2. launchd plist を ~/Library/LaunchAgents に置く（Label: com.sollahiro.blt-sync、
#    ProgramArguments に scripts/blt-scheduled-sync.sh の絶対パス、
#    StartCalendarInterval で 1 日数回。plist はマシン固有のためリポジトリ非管理）

# 3. 登録（再登録は bootout してから bootstrap）
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.sollahiro.blt-sync.plist 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sollahiro.blt-sync.plist

# 4. 手動実行（検証・即時 drain）
launchctl kickstart gui/$(id -u)/com.sollahiro.blt-sync
tail -f .build/blt-scheduled.log
```

初回バックフィル中（全 ~3,944 社）は本ジョブが少しずつ `company_financials`（および Stage 4-half の `company_half_financials`）を埋める（1 回 limit200・1 日 3 回 → 全完了 ~1 週間規模）。`sync` は初回のみ `synced_through` から当日までの catch-up で重くなるが、以後は増分。`computeFinancials` のロジック・契約変更で `companyFinancialsCacheVersion` をバンプした後は、**Fly を `fly deploy` で新バージョンのイメージへ更新する**こと（古いイメージのサーバーは新バージョンで格納された行を stale 扱いで拒否し、**未格納と同じ 404** になる＝そのバージョン分のデータが見えなくなる）。財務系 read はライブ計算フォールバックを持たない（DB 専用・未格納 404・DB 非接続 503）ため、サーバーが重い計算で OOM することはない。

## Neon 接続の E2E 検証

実 DB に対する検証は 2 段で行う。CI/ユニットテストはインメモリ SQLite までのため、Postgres 固有挙動（`.json`→JSONB・索引・String PK）と実パイプラインは別途確認する。

### 1. Postgres スキーマ検証（ローカル Docker・EDINET 不要）

マイグレーション・JSONB round-trip・索引を実 Postgres で検証する opt-in 統合テスト（`PostgresIntegrationTests`、`BLT_TEST_POSTGRES_URL` 未設定なら skip）。

```bash
docker run -d --name blt-pg -e POSTGRES_PASSWORD=blt -e POSTGRES_DB=blt -p 55432:5432 postgres:16-alpine
BLT_TEST_POSTGRES_URL='postgres://postgres:blt@localhost:55432/blt?sslmode=disable' \
  swift test --filter PostgresIntegrationTests
docker rm -f blt-pg
```

期待: `facts` カラムが `jsonb`、`idx_edinet_documents_edinet_code`/`_sec_code` が存在、Stage 1 冪等 upsert・Stage 3 JSONB round-trip・staleness skip が緑。

### 2. 実 Neon フルパイプライン（要シークレット・EDINET ネットワーク）

`DATABASE_URL`（Neon・`?sslmode=require`）と `BLT_EDINET_API_KEY` を設定し、ローカルバイナリで sync→ingest→financials を通す。

```bash
export DATABASE_URL='postgres://...neon.tech/...?sslmode=require'
export BLT_EDINET_API_KEY=xxxxx

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
