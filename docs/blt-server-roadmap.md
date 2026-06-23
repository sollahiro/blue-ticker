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
| **iOS app** | REST API | 財務データ閲覧 UI（URLSession + Codable） |

CLI は `ticker config set edinet-backend remote` で local/remote を切り替える。

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
| Stage 4 | TICKER 計算（財務指標・増減分析） | **クライアント計算** | 未着手 |

### 実測データ量（2026-06 時点・手元キャッシュ232書類）

スキーマ設計とモバイル転送量の判断材料。

| 段階 | 1書類あたり | 合計 | 備考 |
|---|---|---|---|
| Stage 2 生 XBRL（展開後） | 約 9MB（4.8〜11MB） | 2.0GB | `external/edinet/xbrl` |
| Stage 3 パース済み数値インデックス | 約 800KB（JSON） | 182MB | `derived/xbrl_numeric_index`（232件） |

- Stage 3 をそのままモバイルへ流すのは重い（1社×5年 ≈ 4MB）。**単社オンデマンドは許容、一覧/スキャンでのまとめ取りは破綻**する。
- よって Stage 3 の API は「書類まるごと」ではなく**指標/フィールド単位で絞って返せる形**が前提。これはそのままスキーマ設計の制約になる。

### Stage 3 スキーマは公開契約

Stage 4 をクライアント計算にしたため、**Stage 3 のスキーマ＝サーバー↔CLI↔iOS の公開インターフェース**になる。
内部実装ではなく公開契約として扱い、変更時はユーザー確認・バージョニングを行う。

- Stage 3 出力に **schema version** を持たせ、クライアントの計算ロジック版と整合判定する（derived キャッシュの `_cache_version` の発想を契約面へ拡張）。

### Stage 4 をクライアントに置く設計

| 観点 | 内容 |
|---|---|
| 利点 | 計算ロジック変更にサーバーデプロイ不要。`Analysis` 層を BlueTickerCore から CLI / iOS で共有できる |
| 注意1 | クライアント間の計算バージョン差 → Stage 3 schema version と計算版の整合管理が必要 |
| 注意2 | 一覧/スキャン系が高コスト化（多数社ぶん Stage 3 を引いて端末計算） |

**純化しすぎない方針**：詳細画面はクライアント計算、一覧/スキャンはサーバー側で計算済みサマリを返すハイブリッドにし、UX が崩れないようにする。

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

- [ ] **Stage 1/3 の DB スキーマ設計**（Stage 3 は公開契約・指標単位取得・schema version 込み）
- [ ] DB 選定の確定（Fly Postgres / Neon）
- [ ] サーバースタック確定（素 NIO 維持 vs Vapor + Fluent 採用 → Package.swift 変更は要確認）
- [ ] Stage 2 保持ポリシー確定（即削除 vs R2 退避＋再パース）
- [ ] Stage 4 の純度確定（フル client vs 一覧だけサーバー計算のハイブリッド）

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
- Stage 3 スキーマの確定形（公開契約・指標単位取得・schema version）
- remote backend 利用時の `ticker cache status` 表示内容
- local / remote 間で分析結果キャッシュ `derived/` を共有するか、backend ごとに分けるか

---

## 関連ドキュメント

- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — アーキテクチャ依存ルール
