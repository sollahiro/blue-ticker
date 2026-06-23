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
2. **Vapor + Fluent を `BltServerCore` に追加**（下記「Vapor + Fluent 移行」）
3. 共通基盤: bind 可変化 / `/healthz` / Bearer 認証 / EDINET キーを env から
4. Neon 接続 ＋ Stage 1/3 スキーマ設計（Fluent マイグレーション）
5. financials レスポンスの公開契約 ＋ schema version 確定
6. Dockerfile（2段ビルド）＋ `fly.toml` ＋ 自作デプロイ手順

## クライアント

主要クライアントは CLI と iOS app の 2 種。いずれも REST API で blt-server と通信する。

| クライアント | 接続方法 | ユースケース |
|---|---|---|
| **CLI (local)** | Services 層を直接呼ぶ | オフライン・EDINET API キー直接管理 |
| **CLI (remote)** | REST API | blt-server 経由・API キー管理不要 |
| **iOS app** | REST API | `analyze` の数値をビジュアル化（URLSession + Codable） |

CLI は `ticker config set edinet-backend remote` で local/remote を切り替える。

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

- 載せるメトリクスは `analyze --json`（`MetricsResult`）と同等だが、レスポンスの形は別。現行 `getFinancials` は `RawData`／`CalculatedData` をフラットな snake_case に展開し（`BltServerFacade.flattenYearEntry`）、`code`/`name`/`sector`/`market`/`currency`/`unit` を付与した独自スキーマを返す。**`MetricsResult` 直シリアライズか flatten 形かは確定形 TODO で決める**（下記 schema version とセット）。
- レスポンスに **schema version** を持たせ、クライアントのデコード版と整合判定する（derived キャッシュの `_cache_version` の発想を公開契約面へ拡張）。
- Stage 3 RAW（XBRL 数値インデックス）はサーバー内部の中間生成物であり、公開しない。

### 将来クライアント計算へ移す場合

iOS が対話的な再計算（係数を変えた what-if 等）を要求し、計算式変更のたびのサーバー再デプロイが実コストになった段階で、`Analysis/` を独立ターゲット化してクライアント計算へ移す。`YearEntry` が `RawData`（Stage 3）と `CalculatedData`（Stage 4）に分かれており移行の分割線は既にあるため、要求が出てから対応すれば足りる（先行して切り出さない）。

## REST API エンドポイント（`/v1/`）

| エンドポイント | パラメーター | 説明 |
|---|---|---|
| `GET /v1/companies?q={query}` | `q`: 検索クエリ | 企業名・銘柄コード検索 |
| `GET /v1/sectors/{sector}/companies?limit=20` | `sector`: 業種名、`limit` | 業種別銘柄一覧 |
| `GET /v1/companies/{code}/filings?max_years=5` | `max_years` | 書類一覧 |
| `GET /v1/companies/{code}/financials?years=5` | `years` | 財務サマリー（年度別） |
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
| Stage 1 | 書類一覧取得（EDINET インデックス） | **DB** | 実装済み・設定待ち |
| Stage 2 | XBRL ファイル取得 | **一時ファイル（Stage 3 完了後に削除 or オブジェクトストレージへ退避）** | 未着手 |
| Stage 3 | XBRL パース（RAW データ構造化） | **DB（マスターデータ）** | 未着手 |
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

- レスポンスに **schema version** を持たせ、クライアントのデコード版と整合判定する（derived キャッシュの `_cache_version` の発想を公開契約面へ拡張）。

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

### サーバースタック（Vapor + Fluent 確定）

DB（Fluent ORM）と認証ミドルウェアが必要なため **Vapor + Fluent を採用**（2026-06 ユーザー確認済み。`dependencies.md` の大型依存追加確認をクリア）。素の swift-nio 手書きだと Postgres ドライバ・SQL・マイグレーション・コネクションプール・認証を全て自前実装することになり、自前 DB 層がバグの温床になるため。

#### Vapor + Fluent 移行の内容

前段の Server ターゲット分離は完了済み。Vapor/Fluent は **`BltServerCore` ターゲットにのみ**追加し、`BlueTickerCore`（＝CLI）には一切波及させない。

1. **`Package.swift` 依存追加**（`BltServerCore` のみ）
   - `vapor/vapor`（HTTP・ルーティング・ミドルウェア）
   - `vapor/fluent` ＋ `vapor/fluent-postgres-driver`（ORM ＋ Neon 接続）
   - 既存の素 NIO 依存（`NIOCore`/`NIOPosix`/`NIOHTTP1`）は Vapor が内包するため整理（Vapor 経由に一本化）。
2. **トランスポート層を Vapor へ置換**（`BltServerCore` 内）
   - `HTTPApp`（手書き NIO HTTP）→ Vapor の `Application` / `routes`。
   - `RESTRouter` のパスルーティング → Vapor のルート定義。ハンドラは引き続き `BlueTickerCore` の `BltServerContext` ファサードを呼ぶ（**ファサード境界は不変**。Core 側は無改修）。
   - `RESTResult` → Vapor の `Response`。`BltServerResponse`（ok/notFound/upstreamFailure）→ HTTP ステータス変換は Vapor の `Abort` / `ResponseEncodable` へ移す。
3. **DB 層（Fluent）追加**（`BltServerCore`）
   - `DATABASE_URL`（Neon）から `app.databases.use(.postgres(...))`。
   - Stage 1/3 のモデル（`Model` 準拠）＋ `Migration` を定義（スキーマ設計は別タスク）。
   - 接続プール・マイグレーション実行は Vapor のライフサイクルに乗せる。
4. **認証ミドルウェア追加**: Bearer トークン（CLI remote）→ 後続で Sign in with Apple（iOS）。
5. **検証**: `ticker`（CLI）に Vapor/Fluent シンボルが**漏れていない**ことを `nm .build/release/ticker | grep -c Vapor` で確認（分離の回帰検知）。REST API のレスポンス契約が不変であることをテスト。

> 移行は「トランスポートの差し替え」であり、計算ロジックと公開レスポンス契約は変えない。Core の `BltServerContext` ファサードがその防壁になる。

### 認証

| 時期 | 方式 |
|---|---|
| 初期（CLI remote） | Bearer トークン（Web ログイン後に個人アクセストークン発行 → CLI が保持） |
| iOS app | **Sign in with Apple**（JWT 検証は Linux サーバーでも可能） |
| 将来 | **Google OAuth 追加**（CLI ログイン UX の Linux ヘッジ。provider 問わずブラウザ/デバイスコードフローが要る点に注意） |

---

## TODO

### 必須（blt-server を使い始める前に）

- [ ] サーバーマシンの `settings_store` に EDINET API キーを設定する
- [ ] `sync_document_list` ツールで書類一覧を初回同期する

### 近期（Stage 1 安定化）

- [ ] `sync_document_list` の定期実行を launchd で設定する
- [x] `status.json` 追加（`analysis_cache/external/edinet/stage1_status.json`）
- [x] `CacheManager.set()` を atomic write（temp file + rename）に修正済み

### 近期（MCP 廃止）

- [x] `MCPServer/` を `Server/` にリネームし、MCP プロトコル実装を削除して REST API サーバーに一本化した
- [x] `Package.swift` から `swift-sdk`（MCP）・`swift-log` への依存を削除した
- [x] CLAUDE.md のターゲット構成・依存ルールを更新した（`MCPServer/` → `Server/`）

### 近期（remote CLI）

- [x] `ticker config set edinet-backend remote` のサポート実装済み
- [ ] CLI の remote モードで REST API を呼ぶ実装を追加する（現状は未実装）

### 次の検討課題（優先順）

- [x] DB 選定の確定 → **Neon（serverless Postgres）**
- [x] サーバースタック確定 → **Vapor + Fluent 採用**（ユーザー確認済み）
- [x] Server を独立ターゲット（`BltServerCore`）へ分離し CLI から NIO 依存を排除（実測でシンボル 0・サイズ半減）
- [ ] **Vapor + Fluent を `BltServerCore` に追加**（トランスポート置換。「Vapor + Fluent 移行の内容」参照）
- [ ] **Stage 1/3 の DB スキーマ設計**（Stage 3 はサーバー内部スキーマ。公開契約は financials レスポンス側に schema version を持たせる）
- [ ] Stage 2 保持ポリシー確定（即削除 vs R2 退避＋再パース）
- [x] Stage 4 計算の所在確定 → **サーバー計算に集約**（クライアントは表示専念。「計算の責務」節を参照）

### クラウド公開前の必須（コード側）

- [ ] bind 可変化（`BLT_HOST`/`BLT_PORT`、Fly では `0.0.0.0:8080`）
- [ ] `/healthz` ヘルスチェック追加（Fly `[checks]` 用）
- [ ] Bearer トークン認証を追加（Vapor ミドルウェア。トークンは Fly secrets 経由）
- [ ] EDINET API キーの読み元を env（Fly secrets）対応に
- [ ] Dockerfile（swift:6.1 2段ビルド）＋ `fly.toml`、永続 Volume、`fly secrets`

### 将来

- [ ] Stage 2〜4 実装（データパイプライン拡張、上表参照）
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM によるセグメント別売上の構造化抽出（仮: `get_segment_revenue`）
- [ ] LLM による抽出値の抜き打ち整合評価（XBRL 生データとサーバー保存データを突き合わせ、乖離があれば警告）
- [ ] OAuth 認証の追加（Google OAuth・iOS app ログイン）

---

## 未決事項

- Stage 2 生 XBRL の保持ポリシー（即削除 vs R2 退避）
- financials レスポンスの公開契約スキーマの確定形（schema version の持たせ方）
- remote backend 利用時の `ticker cache status` 表示内容

---

## 関連ドキュメント

- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — アーキテクチャ依存ルール
