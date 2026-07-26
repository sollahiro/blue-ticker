# blt-server デプロイ手順

`Dockerfile` から同一イメージを作り、Fly.io（クラウド）と self-host（任意の Docker ホスト）の双方で動かす。設計の背景は `blt-server-roadmap.md`「クラウド構成」を参照。

## 環境変数

| 変数 | 役割 | デプロイでの扱い |
|---|---|---|
| `BLT_HOST` / `BLT_PORT` | bind（既定 `0.0.0.0:8080`） | Dockerfile 既定。通常変更不要 |
| `BLUE_TICKER_ASSETS_PATH` | EDINET コード CSV の場所（既定 `/app/assets`） | Dockerfile 既定 |
| `BLUE_TICKER_USER_DATA_PATH` | キャッシュ・設定の永続先（既定 `/data`） | Volume をここにマウント |
| `BLT_EDINET_API_KEY` | EDINET API キー | **secret**（必須） |
| `CF_ACCESS_TEAM_DOMAIN` | 設定時は Cloudflare Access モード（方式A・エッジ信頼）。origin は JWT 検証せず Tunnel + Access に委ねる | **secret**（公開デプロイでは必須。未設定だと `/v1`・MCP は無認証になる） |
| `CLOUDFLARE_TUNNEL_TOKEN` | cloudflared サイドカーの Tunnel トークン。設定時のみコンテナ内で cloudflared を起動 | **secret**（Cloudflare 本番時） |
| `DATABASE_URL` | Neon Postgres 接続文字列 | **secret**（未設定なら DB なしのステートレス動作） |

`/healthz` は認証不要で `{"status":"ok","cache_versions":{...}}` を返す（ヘルスチェック用）。`cache_versions` はイメージが今話している derived キャッシュバージョン（`xbrl_facts`・`company_financials`・`company_financials_min_servable`・`company_half_financials`・`filing_sections`・`filing_sections_min_servable`・`breakdown`・`breakdown_min_servable`）で、キャッシュバージョンバンプ後に `fly deploy` を忘れていないか curl 一発で確認できる。`*_min_servable` は各 read の床（明示定数。現行版との完全一致ではない）。

認証モードは `/v1` 配下で起動時に env から1つ選ばれる: ① `CF_ACCESS_TEAM_DOMAIN` 設定時 → Cloudflare Access、② 未設定 → 無認証（ローカル開発専用・起動時 warning）。**公開デプロイは常に `CF_ACCESS_TEAM_DOMAIN` を設定すること**（Bearer トークンによる self-host 認証は廃止済み）。本番（Cloudflare）手順は「Cloudflare Access（本番認証・方式A）」を参照。

## Fly.io

```bash
# 1. 初回のみアプリ作成（fly.toml の app 名が重複する場合はここで変更）
fly launch --no-deploy --copy-config --name blt-server --region nrt

# 2. シークレット注入（公開デプロイの認証は下記「Cloudflare Access」節の B で別途設定する）
fly secrets set \
  BLT_EDINET_API_KEY=xxxxx \
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

### GitHub Actions のワークフロー

| ワークフロー | 役割 |
|---|---|
| `ci.yml` | macOS / Linux の `swift test`、`Package.swift` の product が `blt-server` のみであることのガード、`fly.toml` serviceless 検証（`repo-invariants`） |
| `deploy.yml` | CI 成功後の Fly 自動デプロイ（`blt-server` の唯一の出荷経路。`v*` タグでは起動しない） |
| `edge-security-smoke.yml` | 本番 Access / serviceless の外形監視 |

旧 `release.yml`（配布 `ticker` の codesign・Homebrew Formula 更新・GitHub Release）は削除済み。

### GitHub Actions の repo secrets

CI から使う secrets（`fly secrets` とは別物。`gh secret set` で登録する）。

| secret | 役割 | 使用箇所 |
|---|---|---|
| `BLT_EDINET_API_KEY` | macOS CI のスモークテストが不足 XBRL を EDINET から取得する鍵。未設定（fork PR 等）では該当テストが SKIP | `.github/workflows/ci.yml`（`swift-macos`） |
| `FLY_API_TOKEN` | `flyctl deploy` の認証（`fly tokens create deploy` で発行したデプロイ専用トークンを推奨） | `.github/workflows/deploy.yml`（main の CI 成功後の自動デプロイ） |
| `BLT_API_DOMAIN` | 外形監視が無認証アクセスを試す本番ホスト名（現在 `api.sollahiro.com`。値自体は公開ホスト名で秘匿情報ではない）。secret にするのはホスト切り替え時に secret 更新だけで済み、ワークフロー本体の変更が要らないようにするため | `.github/workflows/edge-security-smoke.yml`（Cloudflare Access 生存確認） |

配布 CLI 廃止後に不要な旧 release 用 secrets（残っていれば削除してよい）: `DEVID_CERT_P12_BASE64` / `DEVID_CERT_PASSWORD` / `KEYCHAIN_PASSWORD` / `CODESIGN_IDENTITY` / `HOMEBREW_TAP_TOKEN`。

## self-host（Docker）

`/v1`・MCP の認証は `CF_ACCESS_TEAM_DOMAIN`（Cloudflare Access）のみ対応する。未設定のまま公開ネットワークへ晒すと無認証になるため、社内ネットワーク限定などアクセス経路自体で保護できる場合を除き、公開する際は Cloudflare Tunnel + Access を前段に置くこと（手順は下記「Cloudflare Access」節）。

```bash
# ビルド
docker build -t blt-server .

# 起動（キャッシュ永続化のため /data をボリュームマウント）
docker run -d --name blt-server -p 8080:8080 \
  -e BLT_EDINET_API_KEY=xxxxx \
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
4. **Access ポリシー**（Access → Applications → 当該アプリ → Policies）: **SSO / IdP**（decision = *Allow*）を1本以上作成。`api.<domain>` の実運用では2ポリシーを併存させている（OR条件）— ①本人メール限定・長期セッション（ユーザー介在クライアント / 将来 iOS 用）、②One-Time PIN 経由なら誰でも許可・短期セッション（不特定多数への公開用、2026-07-12〜）。
5. **IdP 接続**（Settings → Authentication）: 現状は **One-Time PIN**（メールにコード送信、外部設定不要）と、Cloudflare アカウントメンバー限定の組み込み IdP（`type: cloudflare`）の2つ。Google/Apple 等の外部 IdP は未接続（Googleは要 Google Cloud Console 側OAuthクライアント作成、Appleは汎用OIDCで代替可だがClient SecretがJWTで最長6ヶ月ごとの再生成が必要、といった追加コストがあり今回は見送り）。

### B. origin（Fly）側 secrets

```bash
fly secrets set \
  CF_ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com \
  CLOUDFLARE_TUNNEL_TOKEN=<tunnel-token>
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

### E. レート制限（エッジ・実装済み／要検討）

`api.<domain>` / `mcp.<domain>` を One-Time PIN で不特定多数に開放したため、ゾーンの Rate Limiting Rules（`http_ratelimit` フェーズ）で IP 単位の簡易レート制限を設定済み（`http.host in {"api.<domain>" "mcp.<domain>"}` → block）。

**検討事項（後日）**: ゾーンが Cloudflare **Free プラン**のため、`period`（集計期間）・`mitigation_timeout`（ブロック時間）とも **10秒固定**しか使えない（60秒や10分を指定すると `not entitled` で拒否される）。現状のルールは5リクエスト/10秒・ブロック10秒というごく緩い制限に留まる。origin（blt-server）側にもレート制限・クォータは無いため、実際の悪用が観測された場合は Pro プラン以上へのアップグレード（長い period/timeout が使える）を検討する。

### クライアント設定（ブラウザ SSO・参考）

ユーザー介在クライアント向けの Cloudflare Access SSO（ブラウザログイン）は引き続き利用できる。機械向け REST は Service Token（下記）を使う。配布 CLI `ticker login` は廃止済み。

SSO 成功後のリクエストは `Cookie: CF_Authorization=<jwt>` を付与する（`Cf-Access-Jwt-Assertion` ヘッダーでは Access のログイン画面へ 302 されるだけで通らないことを実機検証済み）。origin（方式A）は JWT を検証しないため、安全性は「Tunnel + 公開ポート閉鎖 + Access ポリシー」に依存する。

### REST Service Token（段階 A・機械向け）

方針・クライアント別住み分けは `docs/api-auth.md`。origin への Service Token 実装は行わない（方式A・エッジのみ。旧 CLI Bearer は復活させない）。

**ダッシュボード手順（未適用なら実施）**:

1. Zero Trust → Access controls → Service credentials → **Service Tokens** → Create。名前例: `blt-rest-dev`。Client ID / Client Secret を控える（Secret は再表示不可）。
2. `api.<domain>` の Access アプリにポリシーを **追加**（既存 SSO/OTP の Allow は残す）:
   - Action = **Service Auth**（Allow に Token を混ぜない。機械は Service Auth が必要）
   - Include → Service Token → 作成したトークン
3. 疎通:

```bash
# 無認証 → Access にブロック（302/403）
curl -si "https://api.<domain>/v1/companies/7203/financials?years=1" | head -n1

# Service Token → 200（値は環境変数等に置く。リポジトリに書かない）
curl -s "https://api.<domain>/v1/companies/7203/financials?years=1" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  | jq '.schema_version'
```

SSO 用 curl（Cookie）と Service Token 用 curl は用途が違う。製品の機械入口は後者。

## MCP（Managed OAuth・Claude.ai / ChatGPT 向け）

MCP はルートパス（`POST /`）で公開する（`/mcp` は使わない。理由は後述）。`api.<domain>` は Phase 1 で `/v1` と同じ Access アプリ・SSO ポリシーの配下にある（ブラウザ SSO を自分でハンドリングできるクライアント、例: Claude Code の remote MCP 接続、はこのままで使える）。

Claude.ai / Claude Desktop の Custom Connector・ChatGPT のコネクタのように MCP 認可仕様（OAuth 2.1 + Dynamic Client Registration 前提）でしか繋がらないリモートクライアントに対応するには、Cloudflare の **Managed OAuth for Access** を有効化した専用ホスト `mcp.<domain>` を使う。**origin（blt-server / Vapor）側のコード変更は不要**（discovery エンドポイント・`/authorize`・`/token`・DCR はすべて Cloudflare エッジ側で処理され origin には到達しない。OAuth フロー完了後に origin が受け取るリクエストは既存の SSO 経路と同じ＝エッジ信頼のまま）。**Claude Desktop での接続・OAuth 認可・ツール呼び出しまで実機確認済み**（2026-07-12）。

> **実機で判明した制約**: Managed OAuth は **パス指定のあるドメイン（例: `api.<domain>/mcp`）には設定できない**（`access.api.error.invalid_request: domain can not have a path if oauth is configured`）。Cloudflare Access 自体は同一ホスト名をパス単位で複数アプリに分けられるが、Managed OAuth はホスト名全体（パスなし）のアプリにしか有効化できない。そのため **新規サブドメイン `mcp.<domain>` が必須**（当初検討した「既存ホスト名のパス限定アプリ」案は不採用）。この制約は Cloudflare 側のドメイン保護（Access アプリのスコープ）の話であり、origin 側の URL パスとは独立の話だが、`mcp.<domain>` は MCP 専用サブドメインなのでパスなしで統一した（`Sources/BltServerCore/MCPRoute.swift` 参照）。

### 手順（Zero Trust ダッシュボード・実機検証済み）

1. **Cloudflare Tunnel に Public Hostname を追加**（Networks → Tunnels → 該当 Tunnel → Public Hostname → Add）: `mcp.<domain>` → サービス `http://localhost:8080`（`api.<domain>` と同じ origin・同じポート。MCP ルートは既にこのポートにマウント済みのため Vapor 側の変更は不要）。
2. **Access アプリ作成**（Access controls → Applications → Create new application → **Public DNS**）= `mcp.<domain>`（**パスなし**。ここに path を付けると Managed OAuth が有効化できない）。
3. **Access ポリシー**: 既存 `api.<domain>` アプリとは別のポリシーを作成する（Action = **Allow**。全 Access アプリは deny-by-default のため、Include ルールに一致した相手にのみ許可する）。**現在の確定運用（2026-07-12）は `everyone` 許可 ＋ 許可 IdP を One-Time PIN のみに限定**（下記4b）。「メールを受け取れる不特定多数」への公開を意図した設定であり暫定ではない。導入初期は許可 IdP が Cloudflare アカウントメンバー限定の組み込み IdP しかなく、`everyone` ポリシーでも実質メンバー以外は弾かれていた（Managed OAuth のログイン画面自体は Access の IdP 選択に委譲されるため）。
4. **Managed OAuth 有効化**: 作成したアプリの編集画面 → Advanced settings → **Managed OAuth** をトグル ON。
   - **4b. 許可 IdP を確認**: アプリの `allowed_idps` に **One-Time PIN** を含める（外部クライアントが実際にログインできるようにする必須設定。Cloudflare アカウントメンバー限定の組み込み IdP だけでは不特定多数は入れない）。
5. **許可 redirect URI を登録**（DCR で各クライアントが登録するコールバック URL を許可リストに追加しないと `invalid_client_metadata: redirect_uri is not allowed by the account configuration` で失敗する）:
   - `https://claude.ai/api/mcp/auth_callback` — Claude.ai Web / Desktop / モバイル用
   - `http://localhost/callback`・`http://127.0.0.1/callback` — Claude Code 用。**ポート番号やワイルドカード（`:*`）は付けない**こと（`http://localhost:*/callback` は無効な URI として拒否される）。Cloudflare は RFC 8252 のループバック例外を実装しており、ポートなしでこの2つを登録するだけで実際のコールバックの任意ポート（`:54321` 等）を自動的に許可する（実機で確認済み）
   - ChatGPT コネクタが使うコールバック URL は未調査（利用する場合は別途確認する）
6. **疎通確認**:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" https://mcp.<domain>/.well-known/oauth-protected-resource      # 200
   curl -s -o /dev/null -w "%{http_code}\n" https://mcp.<domain>/.well-known/oauth-authorization-server     # 200
   curl -s -o /dev/null -w "%{http_code}\n" -X POST https://mcp.<domain>/ \
     -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'   # 401（未認証で正しくブロック）
   ```

   その後、実クライアント（Claude Desktop の「カスタムコネクタを追加」等）で `https://mcp.<domain>` を登録し、ブラウザでの OAuth 認可 → ツール呼び出しまで確認する。

### 既知の制限

- Managed OAuth は本稿執筆時点で Cloudflare 側の表記が一貫しない（"open beta" 表記のページとそうでないページが混在）。GA 前提の運用にはしない。
- 比較検討した「MCP Server Portal」（複数 MCP サーバーを1エンドポイントに集約する機能）は、本サーバーが1つしかなく集約の要求がないため不採用。Managed OAuth を Access アプリに直接足す方が単純（詳細は `blt-server-roadmap.md`）。
- Claude.ai の Web/モバイル版コネクタでの検証は未実施（Claude Desktop のみ確認済み）。ChatGPT コネクタも未検証。

## 定期同期

`blt-server sync` / `ingest` はワンショット。定期実行は Fly スケジューラ（`fly machine run ... --schedule`）または self-host の cron / launchd で回す。`sync`（引数なし＝前回 `synced_through` から当日まで）→ `ingest`（未取り込み・旧バージョン書類のみ）の順に実行する。

**重い ingest（Stage 3/4）は Fly 上で OOM する**ため、計算はローカル Mac の launchd で実行し Fly は読むだけにする。Fly スケジュールマシンへの移行は issue #34 で OOM により打ち止め（issue #35 参照）。

### 定期同期（ローカル launchd）

ラッパースクリプト `scripts/blt-scheduled-sync.sh` が `.env` を読み込み、リリースビルド済みバイナリで `sync`→`ingest` を実行してログ（`.build/blt-scheduled.log`）に追記する。`ingest` はステージ別に分けて実行し、既定値は `Stage 4=80` / `Stage 4-half=80` / `Stage 5=50` / `Stage 6=30`（空白解消優先・Mac 負荷抑制。Stage 6 は日経225構成銘柄限定・LLM 呼び出しを伴うためより保守的な既定値）。上書きは env `BLT_INGEST_LIMIT_STAGE4` / `BLT_INGEST_LIMIT_STAGE4_HALF` / `BLT_INGEST_LIMIT_STAGE5` / `BLT_INGEST_LIMIT_STAGE6` を使う。`BLT_INGEST_LIMIT` は後方互換として「4ステージの共通既定値」として扱う。plist はテンプレートから生成する共有ファイル（`scripts/launchd/com.sollahiro.blt-sync.plist.template`）のため、マシン固有のチューニング値は `.env` 側に置く。Stage 6 の LLM 呼び出しには軸別キーが必要: business は `XAI_BUSINESS_API_KEY` / `XAI_BUSINESS_MODEL`（任意で `XAI_BUSINESS_BASE_URL`。未設定時は旧 `XAI_API_KEY` / `XAI_MODEL` / `XAI_BASE_URL` にフォールバック）、geography は `XAI_GEOGRAPHY_API_KEY` / `XAI_GEOGRAPHY_MODEL`（任意で `XAI_GEOGRAPHY_BASE_URL`。旧 `XAI_*` へのフォールバックなし）。未設定でも各軸の xbrl_facts 経路は動くが、html_table 経路は notApplicable（`unknown`・要再試行）になる。`BLT_INGEST_LIMIT_STAGE6` は business / geography 各パスに独立適用される。

> **長時間ランは transient な接続エラーで巻き戻る**: `ingest` をステージ別に分けていても、limit を大きくしすぎると 1 ランが長くなり途中で Neon 接続がリセット（PSQLError）される。完走率を優先し、まずは既定（4=80 / 4-half=80 / 5=50 / 6=30）から始め、必要なら `.env` の stage 別 limit を下げる。

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

初回バックフィル中（全 ~3,944 社。Stage 6 は日経225構成銘柄のみ）は本ジョブが少しずつ `company_financials`（および Stage 4-half の `company_half_financials`）を埋める（1 日 4 回・6 時間おき、既定 limit は Stage 4=80 / Stage 4-half=80 / Stage 5=50 / Stage 6=30）。`sync` は初回のみ `synced_through` から当日までの catch-up で重くなるが、以後は増分。`computeFinancials` のロジック・契約変更で `companyFinancialsCacheVersion` をバンプした後は Fly 側イメージの更新が必要だが、main への push（CI 成功後）で自動反映される（`operations.md`「定常運用の保守ポイント」）。財務系 read はライブ計算フォールバックを持たない（DB 専用・未格納 404・DB 非接続 503）ため、サーバーが重い計算で OOM することはない。

### ingest の優先順位・Stage 6 の対象選定（任意・ローカル専用）

`assets/nikkei225.csv`（証券コード列を含む CSV。日経225等、ユーザーが用意する任意ファイル）を配置すると、Stage 4/4-half/5 の取り込み候補のうちそのコードに一致する企業を候補列の先頭へ寄せる（対象選定ではなく処理順序のみ変える）。`limit` 付きバッチで全社バックフィルが終わっていない間、主要銘柄を優先的に埋めたい場合に使う。

**Stage 6 のみ用途が異なる**: 同じ `assets/nikkei225.csv` を、処理順序ではなく取り込み対象そのものの絞り込みに使う（LLM 呼び出し費用抑制。東証上場全体ではなく当該ファイルに一致する企業のみが Stage 6 の候補になる）。ファイル未配置なら Stage 6 の対象は 0 件（Stage 4/4-half/5 のような「優先なしで全社対象」へのフォールバックはしない）。

指数構成銘柄リストは編集著作物のため、このファイルは `.gitignore` 済み（git 管理・リリース配布物に含めない）。未配置なら従来どおり優先なしで動作する。取得元 CSV のフォーマットが多少崩れていても（Web からのコピペ由来のセクション見出し行・ヘッダー行・改行混入等）、先頭列が証券コード形式（先頭が数字の英数字4文字）の行だけを拾うため実用上問題にならない。

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

マイグレーション・JSONB round-trip・索引を実 Postgres で検証する統合テスト（`PostgresIntegrationTests`）。ローカルでは `BLT_TEST_POSTGRES_URL` 未設定なら skip。CI（`.github/workflows/ci.yml` の `swift-linux`）では Postgres 16 サービスコンテナ付きで常時実行する。

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
