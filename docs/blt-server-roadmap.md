# blt-server ロードマップ

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **local CLI** | なし | CLI | 現行稼働中 |
| **remote (self-host)** | 同一マシン | blt-server | 基盤実装済み・設定待ち |
| **remote (cloud)** | リモートサーバー | blt-server | **Fly.io に確定**（後述「クラウド構成」） |

`blt-server` は `swift run blt-server`（または `swift build -c release` 後に `.build/release/blt-server`）で起動。

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

- 載せるメトリクスは `analyze --json`（`MetricsResult`）と同等だが、レスポンスの形は別。現行 `getFinancials` は `RawData`／`CalculatedData` をフラットな snake_case に展開し（`RESTRouter.flattenYearEntry`）、`code`/`name`/`sector`/`market`/`currency`/`unit` を付与した独自スキーマを返す。**`MetricsResult` 直シリアライズか flatten 形かは確定形 TODO で決める**（下記 schema version とセット）。
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
| DB | **Fly Postgres または Neon**（要確定） | Stage 1/3 の保存先。Fluent 採用なら Postgres |
| オブジェクトストレージ | **Cloudflare R2**（egress 無料） | Stage 2 生 XBRL の退避先 |
| DNS | **Cloudflare** | `fly certs add` で証明書 |
| 監視 | 当面 Fly ログ（Sentry / Better Stack は保留） | |

### サーバースタック（要確定）

現行 `Server/` は素の **swift-nio** 手書き（Vapor 不使用）。DB（Fluent ORM）と認証ミドルウェアが必要になるため **Vapor + Fluent 採用に傾ける**が、Package.swift の大型依存追加であり既存 `Server/` 4ファイルを捨てる判断を伴う。`dependencies.md` に従い変更前にユーザー確認する。

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

- [ ] **Stage 1/3 の DB スキーマ設計**（Stage 3 はサーバー内部スキーマ。公開契約は financials レスポンス側に schema version を持たせる）
- [ ] DB 選定の確定（Fly Postgres / Neon）
- [ ] サーバースタック確定（素 NIO 維持 vs Vapor + Fluent 採用 → Package.swift 変更は要確認）
- [ ] Stage 2 保持ポリシー確定（即削除 vs R2 退避＋再パース）
- [x] Stage 4 計算の所在確定 → **サーバー計算に集約**（クライアントは表示専念。「計算の責務」節を参照）

### クラウド公開前の必須（コード側）

- [ ] bind 可変化（`BLT_HOST`/`BLT_PORT`、Fly では `0.0.0.0:8080`）
- [ ] `/healthz` ヘルスチェック追加（Fly `[checks]` 用）
- [ ] Bearer トークン認証を `HTTPApp` に追加（トークンは Fly secrets 経由）
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

- DB の確定（Fly Postgres / Neon）
- サーバースタックの確定（素 NIO 維持 vs Vapor + Fluent）
- Stage 2 生 XBRL の保持ポリシー（即削除 vs R2 退避）
- financials レスポンスの公開契約スキーマの確定形（schema version の持たせ方）
- remote backend 利用時の `ticker cache status` 表示内容

---

## 関連ドキュメント

- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — アーキテクチャ依存ルール
