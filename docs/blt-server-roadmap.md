# blt-server ロードマップ

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **local CLI** | なし | CLI | 現行稼働中 |
| **remote (self-host)** | 同一マシン | blt-server | 基盤実装済み・設定待ち |
| **remote (cloud)** | リモートサーバー | blt-server | **Fly.io に確定**（後述「クラウド構成」） |

`blt-server` は `swift run blt-server`（または `swift build -c release` 後に `.build/release/blt-server`）で起動。

## 確定済みアーキテクチャ（2026-06）

iOS app / remote CLI を実際に作る方針が固まり、blt-server 開発に着手。主要な技術選定は以下で確定済み。

| 項目 | 確定内容 | 状態 |
|---|---|---|
| compute / TLS / secrets / scheduler | **Fly.io**（`primary_region = "nrt"`）。自作サーバー(self-host)も同一 Docker イメージで可 | 確定 |
| DB | **Neon（serverless Postgres）** | 確定（旧「Fly Postgres / Neon 要確定」を解決） |
| サーバースタック | **Vapor + Fluent** | 確定（旧「素 NIO vs Vapor 要確定」を解決） |
| ターゲット構成 | Server を `BltServerCore` へ分離し CLI から Web/DB 依存を排除 | **実装済み**（下記） |

### サーバーターゲット分離（実装済み）

Vapor + Fluent を足す前段として、Server を独立ターゲットへ切り出した。狙いは Web/DB 依存（NIO・将来の Vapor/Fluent）を CLI バイナリへ漏らさないこと。

- **`BlueTickerCore`**（`Sources/BlueTicker/`）: NIO 非依存の共有ライブラリ。`Server/BltServerFacade.swift` に REST ファサード（`BltServerContext` struct ＋ `BltServerResponse` enum ＋ `makeBltServerContext()`）のみを置く。計算ロジック（`Analysis/`＋`Services/`）は internal のまま。
- **`BltServerCore`**（`Sources/BltServerCore/`）: NIO トランスポート（`HTTPApp` / `RESTRouter` / `BltServerEntry`）。`BlueTickerCore` のファサードを呼ぶ。依存方向は `BltServerCore` → `BlueTickerCore` のみ（逆流不可）。
- 効果（実測）: `ticker` の NIO シンボル 27,635 → 0、バイナリ 20.8MB → 10.4MB に半減。REST API の挙動は不変（監査確認済み）。

### 構築順序（残タスク）

1. ~~Server 独立ターゲット分離~~ → **完了**
2. ~~Vapor + Fluent を `BltServerCore` に追加~~ → **完了**（トランスポートを Vapor へ置換。Fluent は DATABASE_URL 条件付き配線。下記「Vapor + Fluent 移行」）
3. ~~共通基盤: bind 可変化 / `/healthz` / Bearer 認証 / EDINET キーを env から~~ → **完了**（下記「共通基盤（env 設定・ヘルスチェック・認証）」）
4. Neon 接続 ＋ Stage 1/3 スキーマ設計（Fluent マイグレーション） — **Stage 1・Stage 3 スキーマ完了**（下記「Stage 1 DB 配線」「Stage 3 DB スキーマ」）。残りは Stage 3 の実パース取り込み（Stage 2 とセット）
5. ~~financials レスポンスの公開契約 ＋ schema version 確定~~ → **完了**: flatten 形を公開契約として確定し、top-level に `schema_version`（`Api.financialsSchemaVersion`、blueTickerVersion 非連動）を追加。**v2** で単一 Codable 契約型へ統一＋remote CLI 用フィールド追加（下記「remote CLI 実装」）
6. ~~Dockerfile（2段ビルド）＋ `fly.toml` ＋ 自作デプロイ手順~~ → **完了**（下記「デプロイ（Dockerfile / Fly.io / self-host）」）

### Stage 1 DB 配線（実装済み）

書類一覧（Stage 1）を Postgres へ取り込む経路を実装した。

- **スキーマ**（`BltServerCore/Models`・`Migrations`）: `edinet_documents`（書類1件=1行、docID PK、EDINET メタ。`edinet_code`/`sec_code` に索引）＋ `edinet_sync_state`（単一行、`synced_through` で同期高水位）。`DATABASE_URL` 設定時のみ `autoMigrate` で適用（未設定なら従来どおり DB なしのステートレス動作）。
- **同期コマンド**: `blt-server sync [--from YYYY-MM-DD] [--to YYYY-MM-DD]`（ワンショット。`to` 既定は UTC 当日、`from` は 明示 > `synced_through` > エラー）。取得・正規化は `BlueTickerCore` のファサード `fetchDocumentsForSync`（seed 種別 `Api.stage1SyncDocTypes` に限定・docID 重複排除）、DB upsert は docID 単位の find-or-create（冪等）。
- スキーマは公開契約ではなくサーバー内部（公開契約は financials レスポンス側）。raw(jsonb) は持たず明示カラムのみ。

### Stage 3 DB スキーマ（実装済み・取り込みは未着手）

XBRL 数値 RAW（パース済み fact インデックス）の格納先スキーマを実装した。実パース取り込み（Stage 2 取得 → パース → 格納）は未着手。

- **スキーマ**: `edinet_xbrl_facts`（書類1件=1行、docID PK）。`facts` カラムに書類単位の fact インデックス（tag → contextRef → fact）を **JSONB 1 セル**で格納（Postgres=JSONB / SQLite=TEXT）。`cache_version` で書類単位の staleness 照合（`blueTickerVersion` 不一致なら再パース）。
- **格納粒度（A）**: fact 1件=1行の正規化ではなく書類単位 JSONB。理由は唯一の消費者 Stage 4 が書類単位に全 fact をまとめ読みするため。タグ横断クエリが実需要化したら**保存済み JSONB から正規化投影を派生**できる（EDINET 再取得・再パース不要）。
- 格納用 Codable DTO（`XbrlFactRecord`／`XbrlFactIndexPayload`）は `BlueTickerCore`（Foundation のみ依存）に置き、内部型 `XbrlFact` を露出させない。Fluent モデル・マイグレーションは `BltServerCore`。
- Stage 3 RAW は公開しない（サーバー内部の中間生成物）。`doc_id` は `edinet_documents` への論理参照（硬い FK は張らず取り込み順を非結合）。

## クライアント

主要クライアントは CLI と iOS app の 2 種。いずれも REST API で blt-server と通信する。

| クライアント | 接続方法 | ユースケース |
|---|---|---|
| **CLI (local)** | Services 層を直接呼ぶ | オフライン・EDINET API キー直接管理 |
| **CLI (remote)** | REST API | blt-server 経由・API キー管理不要 |
| **iOS app** | REST API | `analyze` の数値をビジュアル化（URLSession + Codable） |

CLI は `ticker config set --backend remote` で local/remote を切り替える。

### remote CLI 実装（実装済み）

`backend=remote` のとき、CLI は EDINET を直接叩かず blt-server の REST API を呼び、**計算済み JSON をローカルと同じ整形で表示**する（計算はサーバー集約）。

- **対象コマンド**: `search` / `filings` / `filing` / `analyze` / `summarize`（REST 5 エンドポイントに対応）。各コマンドは `run()` 冒頭で `RemoteBackend.clientIfEnabled()` を呼び、非 nil なら remote 経路、nil ならローカル経路（Services 直呼び）を実行する。
- **整形の再現**: `RemoteAPIClient`（`API/RemoteAPIClient.swift`）が応答を `StockSearchResult` / `RemoteFilings` / `FinancialsResponse` / セクション辞書へデコードし、`FinancialsResponse.toMetricsResult()` で内部 `MetricsResult` に復元して**既存レンダラをそのまま使う**。`filing` のセグメント表は `SegmentResult(dictionary:)` で復元。
- **接続設定**: `ticker config set --server-url <url> --auth-token <token>`。解決順位は env（`BLT_SERVER_URL` / `BLT_AUTH_TOKEN`）> config。`auth-token` は keychain 保存（`edinetApiKey` と同様）、`server-url` は config ファイル。`config show` は token をマスク表示。
- **境界**: `sector`（全 33 業種一覧）は対応する REST が無く、CSV からオフライン算出するため常にローカル。`analyze`/`summarize` の `--half`（半期）は REST 未提供のため remote では非対応エラー。
- 失敗は throw せず `RemoteOutcome`（ok / notFound / failure）で表現し、CLI 層が stderr へ出して終了する（戻り値パターン）。

## 計算の責務（client / server）

**計算はサーバーに集約する。クライアントは表示専念**（iOS は計算済みメトリクスのビジュアル化、remote CLI は計算済み JSON の整形表示）。

| クライアント | 計算 | やること | データ源 |
|---|---|---|---|
| CLI (local) | in-process（従来通り） | 計算して表示 | `Services/` 直呼び |
| CLI (remote) | しない | 計算済みを受信して表示 | REST API |
| iOS app | しない | 計算済みを受信してグラフ化 | REST API |
| blt-server | **する（唯一の計算者）** | Stage 1-4 を実行し計算済み JSON を返す | — |

- 計算ロジックの単一の真実源は `BlueTickerCore` の `Analysis/`＋`Services/`。サーバーが実行し、local CLI も同一バイナリ内で同じコードを in-process 実行する（二重メンテにならない）。
- iOS は分析せず分析結果を描画するため、`Analysis/` 層をクライアントへ共有する必要はない。`analyze --json` と同じメトリクス（`MetricsResult` の `RawData`＋`CalculatedData`）を載せた財務サマリ JSON を受け取って描画する。
- 転送量・計算負荷はクライアント計算とサーバー計算で実質中立（詳細1社で数 KB・四則演算数十回）。したがって判断軸は性能ではなく「計算ロジックの所在とメンテコスト」であり、受益者（計算するクライアント）が現状いないためサーバー集約とする。

### 公開契約は financials レスポンス

Stage 4 をサーバー計算にしたため、**公開インターフェースは financials API のレスポンス（計算済み JSON）**。remote CLI・iOS はこの 1 スキーマだけを見る。変更時はユーザー確認・バージョニングを行う。

- 載せるメトリクスは `analyze --json`（`MetricsResult`）と同等だが、レスポンスの形は別。**flatten 形で確定**。公開契約は**単一の Codable 型 `FinancialsResponse`／`FinancialsYear`**（`Models/FinancialsContract.swift`）に統一し、サーバー出力（`buildFinancialsResponse`）と remote CLI のデコードを同一型から導出する（キー定義を 1 か所に集約しドリフトを防ぐ）。`MetricsResult` 直シリアライズは採用しない（内部モデルから公開 API を疎結合）。`jsonObject()` が欠落値を null 補完し「全キー存在」を維持する。
- レスポンス top-level に **`schema_version`** を持たせ、クライアントのデコード版と整合判定する。採番は `Api.financialsSchemaVersion`（独立した整数・現在 **2**・破壊的変更時のみ +1。blueTickerVersion 非連動）。**v2** で remote CLI のローカル同等表示のため flatten に約20項目を追加（ラベル `op_label`/`sales_label`/`gross_profit_label`、`sga`/`nopat`/`effective_tax_rate`/`interest_expense`、`current_assets`/`non_current_assets`/`current_liabilities`/`non_current_liabilities`/`ppe_total`/`net_de`、`capex`/`buyback`/`rd`/`cf_treasury_stock`/`dividend_ss`/`dividend_paid_cf`/`cur_per_type`）。URL の `/v1` とは別レイヤー。
- Stage 3 RAW（XBRL 数値インデックス）はサーバー内部の中間生成物であり、公開しない。

### 将来クライアント計算へ移す場合

iOS が対話的な再計算（係数を変えた what-if 等）を要求し、計算式変更のたびのサーバー再デプロイが実コストになった段階で、`Analysis/` を独立ターゲット化してクライアント計算へ移す。`YearEntry` が `RawData`（Stage 3）と `CalculatedData`（Stage 4）に分かれており移行の分割線は既にあるため、要求が出てから対応すれば足りる（先行して切り出さない）。

## REST API エンドポイント（`/v1/`）

| エンドポイント | パラメーター | 説明 |
|---|---|---|
| `GET /v1/companies?q={query}` | `q`: 検索クエリ | 企業名・銘柄コード検索 |
| `GET /v1/sectors/{sector}/companies?limit=20` | `sector`: 業種名、`limit` | 業種別銘柄一覧 |
| `GET /v1/companies/{code}/filings?max_years=5` | `max_years` | 書類一覧 |
| `GET /v1/companies/{code}/financials?years=5` | `years` | 財務サマリー（年度別、flatten 形＋`schema_version`） |
| `GET /v1/companies/{code}/filing-content?doc_id=...&sections=a,b` | `doc_id`（省略可）、`sections`（省略可） | 書類セクションテキスト |

- 成功: HTTP 200 + `application/json`
- エラー: HTTP 4xx/5xx + `{"error": "...", "status": N}`

## ゴール

- local CLI は blt-server 不要の独立モードとして維持する。
- remote デプロイにより、CLI（remote モード）・iOS app が共通の blt-server を通じて財務データにアクセスできるようにする。

## 非ゴール

- MCP プロトコルによるサーバー公開（廃止）
- `ticker analyze` 等の各サブコマンドに backend 選択オプションを増やさない。
- `CacheManager` と EDINET external cache を無理に単一抽象へ統合しない。
- ローカルキャッシュを「レガシー」として扱わない。

---

## データパイプライン

blt-server 上で書類一覧取得から財務指標計算まで段階的に事前処理を行う構成。
階層ごとに実行タイミングをずらし、負荷に応じて可変に動かす。

| ステージ | 処理内容 | 保存先 | 状態 |
|---|---|---|---|
| Stage 1 | 書類一覧取得（EDINET インデックス） | **DB**（`edinet_documents`/`edinet_sync_state`） | スキーマ・同期コマンド（`blt-server sync`）実装済み・初回同期待ち |
| Stage 2 | XBRL ファイル取得 | **一時ファイル（Stage 3 完了後に削除 or オブジェクトストレージへ退避）** | 未着手 |
| Stage 3 | XBRL パース（RAW データ構造化） | **DB（`edinet_xbrl_facts`、書類単位 JSONB）** | スキーマ実装済み・実パース取り込みは未着手（Stage 2 とセット） |
| Stage 4 | TICKER 計算（財務指標・増減分析） | **サーバー計算**（現行 `getFinancials` 実装済み） | 実装済み |

### 実測データ量（2026-06 時点・手元キャッシュ232書類）

スキーマ設計とモバイル転送量の判断材料。

| 段階 | 1書類あたり | 合計 | 備考 |
|---|---|---|---|
| Stage 2 生 XBRL（展開後） | 約 9MB（4.8〜11MB） | 2.0GB | `external/edinet/xbrl` |
| Stage 3 パース済み数値インデックス | 約 800KB（JSON） | 182MB | `derived/xbrl_numeric_index`（232件） |

- Stage 3 数値インデックスを**そのまま**モバイルへ流すのは重い（全 fact で 1社×5年 ≈ 4MB）。ただし公開するのは Stage 3 RAW ではなく**計算済み財務サマリ**（`analyze` 相当のメトリクスを載せた JSON）であり、こちらは詳細1社×5年で数 KB に収まる。
- 一覧/スキャンは**表示する指標だけをサーバー計算サマリとして返す**（材料となる RAW をクライアントへまとめ取りさせない）。詳細は1社分の計算済みサマリをオンデマンドで返す。

### 公開契約は financials レスポンス（計算済み JSON）

計算をサーバーへ集約したため、**公開インターフェースは financials API のレスポンス（計算済み JSON）**。載せるメトリクスは `analyze --json`（`MetricsResult`）と同等だがレスポンスの形は別（現行は `flattenYearEntry` の独自スキーマ）。Stage 3 RAW スキーマは公開しない（サーバー内部の中間生成物）。詳細は冒頭「計算の責務（client / server）」を参照。

- レスポンス top-level に **`schema_version`**（`Api.financialsSchemaVersion`=2、独立採番）を持たせ、クライアントのデコード版と整合判定する。**実装済み**（上記「公開契約は financials レスポンス」参照）。

### Stage 2 の保持ポリシー

即削除は本プロジェクトでは危険。抽出ロジックの修正が頻繁（IFRS 契約資産タグ等）で、**生 XBRL を消すとパーサ改善のたびに EDINET から全件再取得**になる（Stage 2 は 9MB/件、再取得はレート制限・時間コスト大）。

- 推奨：即削除せず、**生 XBRL をオブジェクトストレージ（Cloudflare R2 / B2）へ安価に退避**し、再パースをローカル I/O で回せるようにする。再取り込みジョブとセットで設計する。

---

## クラウド構成（Fly.io 確定）

| カテゴリ | 採用 | メモ |
|---|---|---|
| compute / TLS / Volume / secrets / scheduler | **Fly.io**（`primary_region = "nrt"`） | TLS・cron・シークレットを内包し外部サービス数を最小化 |
| DB | **Neon（serverless Postgres）確定** | Stage 1/3 の保存先。scale-to-zero・ブランチ機能・Postgres 互換で将来 Fly Managed Postgres へ移行可。接続は `DATABASE_URL` env（Fly secrets / 自作サーバーは `.env`） |
| オブジェクトストレージ | **Cloudflare R2**（egress 無料） | Stage 2 生 XBRL の退避先 |
| DNS | **Cloudflare** | `fly certs add` で証明書 |
| 監視 | 当面 Fly ログ（Sentry / Better Stack は保留） | |

> Neon は東京リージョン非対応（最寄り ap-southeast、片道 ~100ms）。ただし書き込みは Stage 1/3 のバッチ取り込み、読み取りはキャッシュ＋計算済み JSON で DB を連打しないため許容。同期おしゃべりクエリが増えたら Fly Managed Postgres（同 nrt）へ移行検討。

### デプロイ（Dockerfile / Fly.io / self-host）（実装済み）

クラウド・self-host で同一イメージを使うデプロイ成果物を追加した（構築順序ステップ6）。具体的なコマンド手順は `docs/deploy.md`。

- **`Dockerfile`**: swift:6.1 の 2 段ビルド。ビルド段で `blt-server` のみリリースビルド（MemberImportVisibility 無効化フラグ付き）、ランタイム段は `swift:6.1-slim`（Swift ランタイム内包で堅牢・追加コピー不要）。サーバーバイナリと `EdinetcodeDlInfo.csv` のみ収録（`assets/taxonomy` 約 105MB はソース未参照のため除外）。実行時 env のデフォルト（`BLT_HOST=0.0.0.0`/`BLT_PORT=8080`/assets・data パス）を内包し、self-host も `fly.toml` なしで動く。Fly Volume が root マウントのため root 実行（entrypoint chown を避ける最小構成）。
- **`.dockerignore`**: ビルドコンテキストから `.build`/`.git`/`SwiftTests`/`assets/taxonomy` 等を除外。
- **`fly.toml`**: `primary_region = "nrt"`、`internal_port = 8080`、`/healthz` チェック、`/data` Volume（`blt_data`）、`shared-cpu-1x`/1gb。実行時 env は Dockerfile 側に集約し重複を避ける。機密（`BLT_EDINET_API_KEY`/`BLT_AUTH_TOKEN`/`DATABASE_URL`）は `fly secrets` で注入。
- 検証: macOS で `blt-server` リリースビルド成功。Linux 実ビルドは `docker build`（swift:6.1 → slim）で確認。

### サーバースタック（Vapor + Fluent 確定）

DB（Fluent ORM）と認証ミドルウェアが必要なため **Vapor + Fluent を採用**（2026-06 ユーザー確認済み。`dependencies.md` の大型依存追加確認をクリア）。素の swift-nio 手書きだと Postgres ドライバ・SQL・マイグレーション・コネクションプール・認証を全て自前実装することになり、自前 DB 層がバグの温床になるため。

#### Vapor + Fluent 移行の内容（実装済み）

前段の Server ターゲット分離は完了済み。Vapor/Fluent は **`BltServerCore` ターゲットにのみ**追加し、`BlueTickerCore`（＝CLI）には一切波及させない。

1. ~~**`Package.swift` 依存追加**（`BltServerCore` のみ）~~ → **完了**
   - `vapor/vapor` 4.121 / `vapor/fluent` / `vapor/fluent-postgres-driver` 2.12 を追加。
   - 素 NIO 依存（`NIOCore`/`NIOPosix`/`NIOHTTP1`）は Vapor が内包するため削除（Vapor 経由に一本化）。
2. ~~**トランスポート層を Vapor へ置換**（`BltServerCore` 内）~~ → **完了**
   - `HTTPApp`（手書き NIO HTTP）→ Vapor の `Application`（`BltServerEntry.swift`）。
   - `RESTRouter` のパスルーティング → Vapor のルート定義（`Routes.swift`）。ハンドラは引き続き `BlueTickerCore` の `BltServerContext` ファサードを呼ぶ（**ファサード境界は不変**。Core 側は無改修）。
   - `RESTResult` → Vapor の `Response`。エラー封筒 `{"error":"...","status":N}` は `BltErrorMiddleware`（カスタム）で維持。
   - 既知の挙動差: 不正メソッドの応答は旧 405 → Vapor 既定の 404（エラー封筒は不変）。`Content-Type` に `; charset=utf-8` が付与される。
3. ~~**DB 層（Fluent）配線**（`BltServerCore`、`Database.swift`）~~ → **完了（接続配線のみ）**
   - `DATABASE_URL`（Neon）があれば `app.databases.use(.postgres(...))`。未設定なら DB なしで起動（ステートレス EDINET プロキシ）。
   - **Stage 1/3 のモデル・`Migration` は未着手**（スキーマ設計＝下記ステップ4。空マイグレーションは置かない方針）。
4. ~~**認証ミドルウェア追加**: Bearer トークン（CLI remote）~~ → **完了**（下記「共通基盤」）。後続で Sign in with Apple（iOS）。
5. ~~**検証**~~ → **完了**: `ticker` に Vapor/Fluent シンボル 0（`nm` 確認、NIO は `union` 等の偽陽性のみ）。全 311 テスト通過。`/v1/companies` 実応答が旧契約（sorted+pretty JSON）と一致。

> 移行は「トランスポートの差し替え」であり、計算ロジックと公開レスポンス契約は変えない。Core の `BltServerContext` ファサードがその防壁になる。

#### Linux ビルドの既知の問題（swift-nio / MemberImportVisibility）

Vapor が引き込む **swift-nio 2.101.x の `_NIOFileSystem/FileInfo.swift`** が Linux（Glibc/Musl）で `import CSystem` を欠いており、swift-nio が全ターゲットに有効化する upcoming feature **`MemberImportVisibility`（SE-0444）** の下で `st_ctim`/`st_dev`/`st_blksize` 等が「未 import モジュールのメンバー」とされ **Swift 6.1+ の Linux でのみコンパイルエラー**になる（macOS は `Darwin` 経由で解決され無傷）。swift-nio 最新 2.101.1 でも未修正。Vapor 追加前は `_NIOFileSystem` 自体が未ビルドだったため顕在化していなかった。

**回避策（一時措置）**: Linux での `swift build` / `swift test` / Docker ビルドに次のフラグを付ける。`-Xswiftc` は全ターゲット（swift-nio 含む）に伝播するため、swift-nio の feature 有効化を上書きできる。

```bash
swift test  -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility
swift build -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility
```

- `ci.yml` の `swift-linux` ジョブに適用済み（`swift:6.1` で全 311 テスト緑を実測確認）。macOS ジョブ・`release.yml`（macOS＋`ticker` のみ）は影響なしのため変更不要。
- **ステップ6 の Dockerfile（Fly.io 用、`swift:6.1` 2 段ビルド）でも同フラグが必須**。
- swift-nio 側が修正されたら本フラグは除去する（一時措置）。

### 認証

| 時期 | 方式 |
|---|---|
| 初期（CLI remote） | Bearer トークン（Web ログイン後に個人アクセストークン発行 → CLI が保持） |
| iOS app | **Sign in with Apple**（JWT 検証は Linux サーバーでも可能） |
| 将来 | **Google OAuth 追加**（CLI ログイン UX の Linux ヘッジ。provider 問わずブラウザ/デバイスコードフローが要る点に注意） |

### 共通基盤（env 設定・ヘルスチェック・認証）

クラウド（Fly.io）／self-host 双方で同一バイナリを使うため、起動時設定を環境変数へ寄せた（構築順序ステップ3）。

| 環境変数 | 役割 | デフォルト |
|---|---|---|
| `BLT_HOST` | bind ホスト。クラウドでは `0.0.0.0` | `127.0.0.1` |
| `BLT_PORT` | bind ポート | `3000` |
| `BLT_EDINET_API_KEY` | EDINET API キー（keychain 非搭載の Linux サーバー向け） | （未設定なら settingsStore へフォールバック） |
| `BLT_AUTH_TOKEN` | Bearer トークン。設定時のみ `/v1` 配下を認証で保護 | （未設定なら認証なし） |
| `DATABASE_URL` | Neon Postgres 接続文字列（既存。Fluent 配線） | （未設定なら DB なし） |

- **bind**: 解決順位は CLI 引数（`--host`/`--port`）> env > デフォルト。
- **EDINET キー**: env（`BLT_EDINET_API_KEY`）優先、未設定時のみ `settingsStore`（keychain/config）へフォールバック。両方とも空なら起動時に exit(1)。
- **`GET /healthz`**: 認証不要。`{"status":"ok"}` を 200 で返す（Fly.io／LB のヘルスチェック用）。`/v1` の認証グループ外に登録。
- **Bearer 認証**: `BLT_AUTH_TOKEN` 設定時のみ有効。`/v1` 配下で `Authorization: Bearer <token>` を定数時間比較で検証し、不一致・未提示は 401（公開契約のエラー封筒 `{"error":...,"status":401}`）。`/healthz` は常に認証不要。未設定なら認証なしで起動（self-host／ローカル開発）。

---

## TODO

### 必須（blt-server を使い始める前に）

- [ ] サーバーマシンに EDINET API キーを設定する（`BLT_EDINET_API_KEY` env、または `settings_store`）
- [ ] `blt-server sync --from <初回開始日>` で書類一覧を初回同期する（要 `DATABASE_URL`）

### 近期（Stage 1 安定化）

- [ ] `blt-server sync` の定期実行を launchd / Fly スケジューラで設定する
- [ ] 実 Neon への接続・同期の E2E 検証（現状テストはインメモリ SQLite まで）
- [x] `status.json` 追加（`analysis_cache/external/edinet/stage1_status.json`）
- [x] `CacheManager.set()` を atomic write（temp file + rename）に修正済み

### 近期（MCP 廃止）

- [x] `MCPServer/` を `Server/` にリネームし、MCP プロトコル実装を削除して REST API サーバーに一本化した
- [x] `Package.swift` から `swift-sdk`（MCP）・`swift-log` への依存を削除した
- [x] CLAUDE.md のターゲット構成・依存ルールを更新した（`MCPServer/` → `Server/`）

### 近期（remote CLI）

- [x] `ticker config set edinet-backend remote` のサポート実装済み
- [x] CLI の remote モードで REST API を呼ぶ実装を追加する（下記「remote CLI 実装」）

### 次の検討課題（優先順）

- [x] DB 選定の確定 → **Neon（serverless Postgres）**
- [x] サーバースタック確定 → **Vapor + Fluent 採用**（ユーザー確認済み）
- [x] Server を独立ターゲット（`BltServerCore`）へ分離し CLI から NIO 依存を排除（実測でシンボル 0・サイズ半減）
- [x] **Vapor + Fluent を `BltServerCore` に追加**（トランスポート置換完了。Fluent は DATABASE_URL 条件付き配線。「Vapor + Fluent 移行の内容」参照）
- [x] **Stage 1 の DB スキーマ設計＋同期配線**（`edinet_documents`/`edinet_sync_state`・`blt-server sync`。「Stage 1 DB 配線」参照）
- [x] **Stage 3 の DB スキーマ設計**（`edinet_xbrl_facts`・書類単位 JSONB。「Stage 3 DB スキーマ」参照）。残りは実パース取り込み（Stage 2 とセット）
- [ ] Stage 2 保持ポリシー確定（即削除 vs R2 退避＋再パース）
- [x] Stage 4 計算の所在確定 → **サーバー計算に集約**（クライアントは表示専念。「計算の責務」節を参照）

### クラウド公開前の必須（コード側）

- [x] bind 可変化（`BLT_HOST`/`BLT_PORT`、Fly では `0.0.0.0:8080`） — 共通基盤で実装済み
- [x] `/healthz` ヘルスチェック追加（Fly `[checks]` 用） — 共通基盤で実装済み
- [x] Bearer トークン認証を追加（Vapor ミドルウェア。トークンは Fly secrets 経由） — 共通基盤で実装済み
- [x] EDINET API キーの読み元を env（Fly secrets）対応に — 共通基盤で実装済み（`BLT_EDINET_API_KEY`）
- [x] Dockerfile（swift:6.1 2段ビルド）＋ `fly.toml`、永続 Volume、`fly secrets` — 「デプロイ」節・`docs/deploy.md` 参照

### 将来

- [ ] Stage 2〜4 実装（データパイプライン拡張、上表参照）
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM によるセグメント別売上の構造化抽出（仮: `get_segment_revenue`）
- [ ] LLM による抽出値の抜き打ち整合評価（XBRL 生データとサーバー保存データを突き合わせ、乖離があれば警告）
- [ ] OAuth 認証の追加（Google OAuth・iOS app ログイン）

---

## 未決事項

- Stage 2 生 XBRL の保持ポリシー（即削除 vs R2 退避）
- ~~financials レスポンスの公開契約スキーマの確定形（schema version の持たせ方）~~ → 解決（flatten 形＋独立採番 `schema_version`）
- remote backend 利用時の `ticker cache status` 表示内容

---

## 関連ドキュメント

- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — アーキテクチャ依存ルール
