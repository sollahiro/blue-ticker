# blt-server ロードマップ

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **local CLI** | なし | CLI | 現行稼働中 |
| **remote (self-host)** | 同一マシン | blt-server | 基盤実装済み・設定待ち |
| **remote (cloud)** | リモートサーバー | blt-server | **Fly.io に確定**（後述「クラウド構成」） |

`blt-server` は `swift run blt-server`（または `swift build -c release` 後に `.build/release/blt-server`）で起動。

## 方針転換（2026-06-28 確定）: サーバー集約とローカル CLI 段階廃止

サーバーデプロイが実用域に入ったため、**ユーザー向けの実行環境を blt-server（remote/cloud）へ一本化**する。到達点は「**Blue Ticker はサーバーで動く。CLI / GUI / MCP はそれを操作するクライアント**」。

| 区分 | 対象 | 扱い |
|---|---|---|
| 残す | Core（`BlueTickerCore` の `Analysis/`＋`Services/`）・Unit Test・**開発用 CLI**（デバッグ・テスト・フィクスチャ） | 維持 |
| 切る | **ユーザー向けローカル分析 CLI**（`backend=local`） | **段階的に廃止**（deprecation 告知 → バージョンを定めて削除。即時削除しない） |
| ユーザー接点 | remote CLI / GUI / MCP | すべて **REST API 経由**で blt-server を呼ぶ（`クライアント → API → Server`） |

- **Core はサーバー専用にしない**: サーバー・Dev CLI・Unit Test が同一 Core を共有し実装を一元化する。これは既存ターゲット構成（`BlueTickerCore` は Vapor/Fluent 非依存）で構造的に担保済み。
- **MCP の位置づけ**: 旧 MCP（サーバーが MCP プロトコルを直接話す方式）は廃止のまま。将来復活させる MCP は remote CLI / GUI と同じ **REST API クライアント**として実装する（`MCP → API → Server`。プロトコルサーバーは復活させない）。
- **オンデマンド ingest は非同期**: 未 ingest 銘柄の取得はリクエスト経路に重い処理を持ち込まず、未充足リクエストをキューに記録して既存 ingest バッチが消化する（下記「オンデマンド ingest（非同期）」）。
- **バックフィル範囲**: 当面は「人気銘柄＋オンデマンド」、ゆくゆく全銘柄 ingest へ拡大。

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
4. Neon 接続 ＋ Stage 1/3/4 スキーマ設計（Fluent マイグレーション） — **Stage 1・Stage 3・Stage 4 スキーマ＋取り込み（`blt-server ingest`）＋ Stage 4 DB 読み配線 完了**（下記「Stage 1 DB 配線」「Stage 3 DB スキーマ＋取り込み」「Stage 4 DB 配線」）。残りは実 Neon E2E 検証
5. ~~financials レスポンスの公開契約 ＋ schema version 確定~~ → **完了**: flatten 形を公開契約として確定し、top-level に `schema_version`（`Api.financialsSchemaVersion`、blueTickerVersion 非連動）を追加。**v2** で単一 Codable 契約型へ統一＋remote CLI 用フィールド追加（下記「remote CLI 実装」）
6. ~~Dockerfile（2段ビルド）＋ `fly.toml` ＋ 自作デプロイ手順~~ → **完了**（下記「デプロイ（Dockerfile / Fly.io / self-host）」）

### Stage 1 DB 配線（実装済み）

書類一覧（Stage 1）を Postgres へ取り込む経路を実装した。

- **スキーマ**（`BltServerCore/Models`・`Migrations`）: `edinet_documents`（書類1件=1行、docID PK、EDINET メタ。`edinet_code`/`sec_code` に索引）＋ `edinet_sync_state`（単一行、`synced_through` で同期高水位）。`DATABASE_URL` 設定時のみ `autoMigrate` で適用（未設定なら従来どおり DB なしのステートレス動作）。
- **同期コマンド**: `blt-server sync [--from YYYY-MM-DD] [--to YYYY-MM-DD]`（ワンショット。`to` 既定は UTC 当日、`from` は 明示 > `synced_through` > エラー）。取得・正規化は `BlueTickerCore` のファサード `fetchDocumentsForSync`（seed 種別 `Api.stage1SyncDocTypes` に限定・docID 重複排除）、DB upsert は docID 単位の find-or-create（冪等）。
- スキーマは公開契約ではなくサーバー内部（公開契約は financials レスポンス側）。raw(jsonb) は持たず明示カラムのみ。

### Stage 3 DB スキーマ＋取り込み（実装済み）

XBRL 数値 RAW（パース済み fact インデックス）の格納先スキーマと、実パース取り込み（Stage 2 取得 → パース → 格納）を実装した。なお Stage 4（下記）は `edinet_xbrl_facts` を消費せず計算結果を別途格納する設計のため、本テーブルは現状 RAW アーカイブ（タグ横断クエリが実需要化したら正規化投影の派生元）。

- **スキーマ**: `edinet_xbrl_facts`（書類1件=1行、docID PK）。`facts` カラムに書類単位の fact インデックス（tag → contextRef → fact）を **JSONB 1 セル**で格納（Postgres=JSONB / SQLite=TEXT）。`cache_version` で書類単位の staleness 照合（`xbrlFactsCacheVersion` 不一致なら再パース）。`xbrlFactsCacheVersion` は `blueTickerVersion` と独立し、パース／RAW スキーマ変更時のみバンプする（月内 Micro バンプで高コストな再 ingest を走らせないため）。
- **格納粒度（A）**: fact 1件=1行の正規化ではなく書類単位 JSONB。理由は唯一の消費者 Stage 4 が書類単位に全 fact をまとめ読みするため。タグ横断クエリが実需要化したら**保存済み JSONB から正規化投影を派生**できる（EDINET 再取得・再パース不要）。
- 格納用 Codable DTO（`XbrlFactRecord`／`XbrlFactIndexPayload`）は `BlueTickerCore`（Foundation のみ依存）に置き、内部型 `XbrlFact` を露出させない。Fluent モデル・マイグレーションは `BltServerCore`。
- Stage 3 RAW は公開しない（サーバー内部の中間生成物）。`doc_id` は `edinet_documents` への論理参照（硬い FK は張らず取り込み順を非結合）。

#### 取り込みコマンド（`blt-server ingest`）

- **コマンド**: `blt-server ingest [--limit N]`（ワンショット。`--limit` は新規取り込み件数の上限。XBRL ダウンロードが 9MB/件と重いためバッチ分割用）。
- **対象選定**: `edinet_documents` を提出日時降順（新しい順）に走査し、`edinet_xbrl_facts` が無い or `cache_version != xbrlFactsCacheVersion` の書類のみ取り込む。最新版でパース済みは skip（derived キャッシュと同思想の staleness 判定）。
- **取得・パース**: Core ファサード `parseXbrlFactIndex(docID:)` が `downloadDocument`（Stage 2）→ `collectAllNumericFacts`（`nilAsZero: false`、Stage 4 と同条件）→ `XbrlFactRecord` 写経を行う。DB upsert（find-or-create・冪等）は `BltServerCore/Stage3Ingest.swift`。取得失敗・fact 0 件は failed としてスキップ（戻り値パターン）。
- **テスト**: DB ロジック（候補選定・skip・再パース・limit・upsert）はパーサ closure 注入でネットワーク非依存に検証（`Stage3IngestTests`）。
- **Stage 2 保持ポリシー**: 生 XBRL は**ローカル保持継続**（`external/edinet/xbrl` キャッシュ／Fly Volume）。Stage 4 が HTML 依存抽出（US-GAAP・IFRSリース・セグメント・粗利）のため生ディレクトリを必要とするため即削除は不可。Cloudflare R2 退避はクラウド実運用で容量が問題化してから（延期）。

### Stage 4 DB 配線（実装済み）

financials の REST 応答を、毎リクエストのライブ計算（EDINET 取得 → XBRL 9MB DL → パース）から **Neon 格納済みの計算結果の読み取り**へ切り替えた。Fly の小メモリ機（shared-cpu-1x/1gb）でも financials が OOM しない。

- **なぜ facts 読みではないか**: 計算（`processDocument`）は数値 fact だけでなく **生 XBRL 内の HTML を直接パースする抽出器**（US-GAAP 連結 P/L・BS、IFRS 粗利／IBD／支払利息の TextBlock フォールバック）に依存する。`edinet_xbrl_facts`（数値のみ）からは再現できないため、**計算結果（公開契約 `FinancialsResponse`）を企業単位で格納**する方式を採る。HTML 解決・waterfall は ingest 時（生ディレクトリがある所）で完了させる。
- **スキーマ**: `company_financials`（証券コード 4 桁を PK、`response` JSONB に `FinancialsResponse`、`cache_version`＝`companyFinancialsCacheVersion`、`requested_years`、`updated_at`）。Stage 4 derived だが `cache_version` は **`blueTickerVersion` 非連動の専用定数 `companyFinancialsCacheVersion`**（`Models/FinancialsContract.swift`、現在 `"fin-v2"`）。Stage 3 と同じく再生成が高コスト（XBRL 再 DL＋HTML 依存抽出の再計算）なため、月内 Micro バンプで全社再計算を強制しない。計算ロジック／契約型変更時のみバンプ（`versioning.md`）。公開契約は `response` 中身であり本テーブルは内部スキーマ。
- **取り込み**: `blt-server ingest` が Stage 3 の後に Stage 4 を実行する。`edinet_documents` の secCode から distinct な企業（4 桁コード）を導出し、未計算 or `cache_version` 不一致 or `requested_years` 不足の企業のみ Core ファサード `computeFinancials(code:years:)`（既定 6 年）で計算・upsert。`--limit` は新規計算件数の上限。staleness skip は derived キャッシュと同思想。
- **read 経路（DB 専用・ライブ計算フォールバックなし）**: `GET /v1/companies/{code}/financials` は `company_financials` に現行バージョン & 要求年数を満たす行があれば `trimmed(toYears:)` して返す（DL・パースなし）。無い・古い・年数不足は **404**、DB 非接続は **503**。**ライブ計算へはフォールバックしない**（`loadStoredFinancials` / `Routes.swift`）。理由: フォールバックは 1 リクエストでサーバー全体を OOM 落ちさせる地雷で、warm でも years 整合がずれると毎回発火し得た（half で実害化、下記）。重い計算は ingest（ローカル→Neon）に閉じ込め、serving は read-only を保つ。
- **運用**: 計算はメモリを使うため、**重い初回バックフィルはローカル等から `DATABASE_URL` を Neon に向けて ingest** する（Fly 上で大量に走らせると ingest 自体が OOM しうる）。Fly サーバーは読むだけ。
- **テスト**: DB ロジック（企業選定・重複排除・staleness・年数不足・limit・upsert）と read 経路（バージョン／年数ゲート・trim）を計算器 closure 注入でネットワーク非依存に検証（`Stage4IngestTests`）。

### オンデマンド ingest（非同期・設計確定／未実装）

「人気銘柄＋オンデマンド」運用での cold path（未 ingest 銘柄を叩かれたとき）を **非同期**で扱う。serving は read-only を保ち、OOM を起こす重い処理（9MB DL＋XBRL パース）をリクエスト経路に持ち込まない。

- **フロー**: `GET /v1/companies/{code}/financials` が DB に無い → serving は重い処理をせず、当該コードを **未充足リクエストとして記録**し `202`（準備中）を返す → 既存 ingest バッチ（launchd / 将来ワーカー）がそのキューを消化 → 次回リクエストで DB から即返る。
- **同期にしない理由**: 同期パースはリクエストを握ったまま OOM し、serving インスタンスごと落として無関係なリクエストを巻き込む。Stage 4 DB 配線で勝ち取った「serving=read-only / ingest=別バッチ」の分離を逆行させない。
- **UX**: クライアントは「準備中」を表示、または裏でポーリングしてスピナー表示する（**サーバーはリクエストを握らない**点が同期と決定的に違う）。
- **新規要素**: 未充足リクエストの記録テーブル（小さな Neon テーブル 1 枚）。**公開スキーマの追加に当たるため実装前にユーザー確認**（`workflow.md` 公開インターフェース保護）。
- 状態: **設計確定・未実装**。現状の未格納銘柄は同期 404（ライブ計算フォールバックは撤去済み＝serving は read-only を達成）。本節は「404 を 202＋キュー記録に変えて UX を改善する」将来案であり、記録テーブルは未充足リクエストの公開スキーマ追加に当たるため実装前にユーザー確認。

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
- **`--half` の remote 対応（実装済み・実 Fly E2E 検証済み 2026-06-28）**: `analyze --half` / `summarize --half` は `GET /v1/companies/{code}/half-financials` を呼び、ローカルと同一整形（半期 5 ブロック増減分析・水準値テーブル）で表示する。通期と同型の DB 専用経路（`company_half_financials`、ingest で計算格納、read は DB のみ・未格納は 404）。**read は要求年数を半期上限 `Api.halfMaxYears`(=5) へクランプ**する。半期は FY/2Q から H1/H2 を導出する都合で最大 5 年しか作れず、CLI 既定 `analyzeDefaultYears`=6 のままでは read guard `requested_years(5) >= years(6)` が常に偽になり DB を空振り→旧ライブ計算フォールバックで Fly を OOM させていた（実機で再現・修正済み）。クランプで years=6 でも warm read（200）を返す。
- **残る制約**: `sector`（全 33 業種一覧）は対応する REST が無く CSV からオフライン算出するため remote でも常にローカルで動作する（機能欠落ではない）。REST 化は一貫性のための polish で未着手。
- 失敗は throw せず `RemoteOutcome`（ok / notFound / failure）で表現し、CLI 層が stderr へ出して終了する（戻り値パターン）。

#### 稼働状況（2026-06-28 実機検証・Fly `blt-server.fly.dev`）

remote の各コマンドを実 Fly に対して検証した結果と、残る配線ギャップ。

| コマンド | remote 稼働 | 備考 |
|---|---|---|
| `search` | ✅ | CSV マスターで軽量 |
| `analyze` / `summarize`（通期・`--half`） | ✅ | Stage 4 / 4-half とも DB 専用 read。warm 0.3s。**未バックフィル銘柄は 404**（ライブ計算フォールバック撤去済み＝OOM しない）。`--half` の years=6 は read クランプで warm read |
| `filings` / `filing` | ✅（DB 読み配線済み・実 Fly 検証待ち） | Stage 1 read 配線を実装（下記）。DB 同期済み銘柄は `edinet_documents` を読み OOM を回避。未同期銘柄のみライブ探索へフォールバック（filings は軽量なので維持） |

- **Stage 1 read 配線（実装済み）**: `filings` エンドポイントを `EdinetDiscovery.buildDocumentIndexForCode` のライブ探索から **`edinet_documents`（Neon 同期済み）の DB 読み**へ切り替えた（Stage 4 financials と同型: DB 読み優先＋未同期/DB 非接続はライブフォールバック）。`Routes.swift` が `loadStoredFilingRecords`（secCode 前方一致クエリ）で当該銘柄の行を引き、ファサード `getFilingsFromRecords` が応答を組み立てる。応答スキーマは不変。
  - **簡易セマンティクス（確定・ライブ探索との意図的差分）**: DB 経路は各書類の `period_end` をそのまま `fy_end` とする自己完結ビュー。主要 doc type の有報(120)・半期(160) は period_end が通期期末のためライブと**完全一致**。一方、旧四半期(140) は 2Q 末、訂正(130) は親有報リンク（`edinet_documents` に `parentDocID` 列なし）を再現できないため、ライブ経路の「親 FY 末への正規化／親リンク書類のみ採用」は再現せず、自身の period_end・窓内全件で返す。完全パリティには schema 変更（parent_doc_id 追加＋再 sync）が要るが、140 は概ね廃止・130 の差は軽微のため**簡易セマンティクスを採用**（schema 変更回避）。`filingsList` の doc コメント・`FilingsListTests` で固定。
- バックフィルが進むほど `analyze` / `analyze --half` の remote 対応銘柄が広がる（未格納は 404＝即時。サーバーで重い計算はしない）。

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
| `GET /v1/companies/{code}/half-financials?years=3` | `years` | 半期財務サマリー（H1/H2、flatten 形＋`schema_version`） |
| `GET /v1/companies/{code}/filing-content?doc_id=...&sections=a,b` | `doc_id`（省略可）、`sections`（省略可） | 書類セクションテキスト |

- 成功: HTTP 200 + `application/json`
- エラー: HTTP 4xx/5xx + `{"error": "...", "status": N}`

## ゴール

- **ユーザー向け実行環境を blt-server（remote/cloud）へ集約**し、remote CLI / GUI / MCP が共通の REST API 経由で財務データへアクセスできるようにする（`方針転換` 参照）。
- **ユーザー向けローカル分析 CLI（`backend=local`）は段階的に廃止**する（deprecation → 削除）。Core・Unit Test・開発用 CLI は維持する。

## 非ゴール

- 旧 MCP（サーバーが MCP プロトコルを直接話す方式）の復活。将来の MCP は REST API クライアントとして実装する（プロトコルサーバーは復活させない）。
- `ticker analyze` 等の各サブコマンドに backend 選択オプションを増やさない。
- `CacheManager` と EDINET external cache を無理に単一抽象へ統合しない。
- ユーザー向けローカル CLI を**即時**削除する（互換維持期間を置く段階的廃止であり、いきなり消さない）。

---

## データパイプライン

blt-server 上で書類一覧取得から財務指標計算まで段階的に事前処理を行う構成。
階層ごとに実行タイミングをずらし、負荷に応じて可変に動かす。

| ステージ | 処理内容 | 保存先 | 状態 |
|---|---|---|---|
| Stage 1 | 書類一覧取得（EDINET インデックス） | **DB**（`edinet_documents`/`edinet_sync_state`） | 同期済み（3,944 社）。定期 `sync` は launchd `com.sollahiro.blt-sync` で 1 日 3 回 |
| Stage 2 | XBRL ファイル取得 | **ローカル保持**（`external/edinet/xbrl` キャッシュ／Fly Volume。R2 退避は延期） | `ingest` から `downloadDocument` で取得・保持。R2 退避は未着手 |
| Stage 3 | XBRL パース（RAW データ構造化） | **DB（`edinet_xbrl_facts`、書類単位 JSONB）** | スキーマ・取り込み（`blt-server ingest`）実装済み（RAW アーカイブ。Stage 4 は別途計算結果を格納） |
| Stage 4 | TICKER 計算（財務指標・増減分析） | **DB（`company_financials`、企業単位 JSONB）＋サーバー計算** | 計算・DB 格納（ingest）・DB 専用 read 配線 実装済み。fin-v2・506/3,944 社格納・launchd で drain 中（未格納は **404**。ライブ計算フォールバック撤去済み） |
| Stage 4-half | 半期計算（H1/H2 増減分析） | **DB（`company_half_financials`、企業単位 JSONB）＋サーバー計算** | 計算・DB 格納（ingest が Stage 4 の後に実行）・DB 専用 read 配線（half-v1・years を `Api.halfMaxYears` にクランプ）。E2E 検証済み（2026-06-28）。**バックフィル進行中（9 社、2026-06-28 夜に release 再ビルドで drain 再開）**。同 launchd ingest が Stage 4-half も実行するため通期と並行して drain される |

### 実測データ量（2026-06 時点・手元キャッシュ232書類）

スキーマ設計とモバイル転送量の判断材料。

| 段階 | 1書類あたり | 合計 | 備考 |
|---|---|---|---|
| Stage 2 生 XBRL（展開後） | 約 9MB（4.8〜11MB） | 2.0GB | `external/edinet/xbrl` |
| Stage 3 パース済み数値インデックス | 約 800KB（JSON） | 182MB | `derived/xbrl_numeric_index`（232件） |

- Stage 3 数値インデックスを**そのまま**モバイルへ流すのは重い（全 fact で 1社×5年 ≈ 4MB）。ただし公開するのは Stage 3 RAW ではなく**計算済み財務サマリ**（`analyze` 相当のメトリクスを載せた JSON）であり、こちらは詳細1社×5年で数 KB に収まる。
- 一覧/スキャンは**表示する指標だけをサーバー計算サマリとして返す**（材料となる RAW をクライアントへまとめ取りさせない）。詳細は1社分の計算済みサマリをオンデマンドで返す。

#### 全件スケール投影（2026-06・Neon 実測ベース）

書類総数 **21,250 / 3,944 社**（`edinet_documents`）。Neon 実測テーブルサイズから全件を投影する。

| データ | 1書類 | 全 21,250 件 | 置き場所 / 制約 |
|---|---|---|---|
| 数値 facts JSONB（Stage 3） | ~33KB（実測 20MB/613件） | **~700MB** | 現状 Postgres。**branch logical size 上限 512MB を超える見込み⚠️** |
| 生 XBRL（展開後） | ~9MB | ~191GB | 保存対象外 |
| 生 XBRL（EDINET ZIP） | ~2MB | **~42GB** | オブジェクトストレージ（Postgres 不可） |
| .xbrl＋honbun .htm のみ圧縮 | ~0.7MB | **~15GB** | オブジェクトストレージ（最小案） |
| 計算済み financials（Stage 4） | ~5KB | ~20MB | Postgres（小さい） |

→ 容量の制約は **Postgres 側（512MB）**にある。生 XBRL は Postgres に入れず**オブジェクトストレージ**に置けば容量問題にならない（~15〜42GB＝月 $1 未満規模）。一方、数値 facts だけでも全件 ~700MB で 512MB を超えるため、Neon プラン拡張 or facts のオブジェクトストレージ退避が**先に**必要になる。

### 公開契約は financials レスポンス（計算済み JSON）

計算をサーバーへ集約したため、**公開インターフェースは financials API のレスポンス（計算済み JSON）**。載せるメトリクスは `analyze --json`（`MetricsResult`）と同等だがレスポンスの形は別（現行は `flattenYearEntry` の独自スキーマ）。Stage 3 RAW スキーマは公開しない（サーバー内部の中間生成物）。詳細は冒頭「計算の責務（client / server）」を参照。

- レスポンス top-level に **`schema_version`**（`Api.financialsSchemaVersion`=2、独立採番）を持たせ、クライアントのデコード版と整合判定する。**実装済み**（上記「公開契約は financials レスポンス」参照）。

### Stage 2 の保持ポリシー（ローカル保持で確定）

即削除は本プロジェクトでは危険。抽出ロジックの修正が頻繁（IFRS 契約資産タグ等）で、**生 XBRL を消すとパーサ改善のたびに EDINET から全件再取得**になる（Stage 2 は 9MB/件、再取得はレート制限・時間コスト大）。さらに Stage 4 の HTML 依存抽出（US-GAAP・IFRSリース・セグメント・粗利）が生ディレクトリを必要とするため、即削除は機能的にも不可。

- **確定**: 生 XBRL は**ローカル保持継続**（`external/edinet/xbrl` キャッシュ＝ self-host／ローカルはローカルディスク、Fly では永続 Volume `/data`）。`blt-server ingest` も `downloadDocument` 経由で同キャッシュに保持する。
- **R2 退避は延期**: Cloudflare R2（egress 無料）への退避は、クラウド実運用で Volume 容量（全 EDINET ユニバースで数十 GB 規模）が問題化してから着手する。S3 互換クライアントの新規外部依存追加が必要なため、実需要が出るまで持ち込まない（YAGNI）。退避時は再取り込みジョブとセットで設計する。

### 取得→抽出→計算の分離とストレージ方針（将来・方針整理 2026-06）

**背景**: 抽出・計算ロジックを変えたとき（例: 借入金等明細表からの IBD 抽出追加で `companyFinancialsCacheVersion` を fin-v2 にバンプ）、全件再 ingest で生 XBRL の再ダウンロードが走り重い。「取得は一度きり、抽出・計算だけ回したい」が要件。

**現状の事実整理**:

- バージョンは既に3層で分離済み（**取得=非連動 / 抽出facts=`xbrlFactsCacheVersion` / 計算=`companyFinancialsCacheVersion`**）。fin-v バンプは計算結果のみ無効化し、**生 XBRL キャッシュは無効化しない**。
- それでも再 DL が起きるのは、**生 XBRL の中央（永続・共有）保存先が無い**ため。保存しているのは ① マシンごとの一時ファイルキャッシュ（ローカル `~/.config` / Fly `/data`）と ② Neon の**数値 facts のみ（HTML TextBlock を含まない）**。
- Stage 4 の `computeFinancials` は Neon の facts を読まず `IndividualAnalyzer` 経由で**生 XBRL を読み直す**。HTML 依存抽出（IBD リース・借入金等明細表・US-GAAP HTML・セグメント等）は数値 facts に無い TextBlock を必要とするため、生 XBRL が必須。
- 重い再 DL の実態は fin-v ではなく、**バックフィルを生 XBRL 未取得のローカル（~228件のみ）で回している**こと。Fly `/data`（既取得分が温かい）で回せば既取得分は再 DL しない（が計算が OOM するため現状ローカル運用）。

**目標アーキテクチャ A（生 XBRL の中央永続化）**:

1. オブジェクトストレージ（Neon Object Storage / Cloudflare R2 / S3 互換）に `edinet/xbrl/<docID>`（生 ZIP または蒸留版 .xbrl＋honbun .htm）を write-through 保存。容量は ~15〜42GB で月 $1 未満規模（上記「全件スケール投影」）。
2. `EdinetCacheStore` の取得経路を **ローカル → オブジェクトストレージ → EDINET（取得したら書き戻し）** の3段フォールバックに。
3. 再計算（fin-v バンプ）は EDINET を叩かずオブジェクトストレージから生 XBRL を読んで再抽出 → 「取得は一度きり」を実現。

**着手順（A の前段に容量対策が必要）**:

- **A1. Postgres 512MB 対策**: 数値 facts だけで全件 ~700MB 見込み（512MB 超）。Neon プラン拡張 or facts JSONB のオブジェクトストレージ退避（Postgres には docID→キー索引のみ）を先に決める。
- **A2. オブジェクトストレージ＋3段フォールバック**を設計・実装（上記「R2 退避は延期」の発火条件が容量で満たされ次第）。S3 互換クライアントの外部依存追加はここで判断する。

**計算バージョンの粒度は「出典別」でなく「抽出方式別」が妥当**:

- 計算ロジックの変更を細かくバージョン分割したくなるが、**PL/BS/CF/SS の出典別に割るのは ROI が低い**。これらは同一書類の別セクションで大半は同じタグベース抽出（FieldParser）であり、SS には専用抽出器も無い。出典という粒度に乗らない。
- 再 ingest の支配的コストは**取得(DL)で抽出ではない**。出典別に計算バージョンを割っても、変わった部分の再計算には結局その書類の生 XBRL が要るため DL は減らない。`company_financials` は 1社=1行の単一 JSONB＋単一 cache_version であり、部分無効化はバージョン列多重化／部分再計算／マージで複雑化する。
- 意味があるのは**抽出方式（データ源）軸**。これは「再計算に何が要るか」を決める：

  | 抽出方式 | 例 | 再計算に必要 | コスト |
  |---|---|---|---|
  | タグベース（数値 XBRL tag / FieldParser） | PL/BS/CF の大半 | Neon の数値 facts のみ | 生 XBRL 不要・激安 |
  | HTML パース（TextBlock/本文 HTML） | IBD リース・借入金等明細表・US-GAAP HTML・セグメント | 生 XBRL（TextBlock/HTML） | 目標 A の中央ストア必須 |

- 理想は「**タグ由来ロジックを直した→ Neon facts から再計算（DL ゼロ）／ HTML 由来を直した→生 XBRL を読む**」。ただし現状 Stage 4 は全部を生 XBRL から読み直す実装のため、**目標 A ＋ Stage 4 のデータ源見直し（タグ系は facts 消費へ）とセットで初めて効く**。
- **当面は単一 `companyFinancialsCacheVersion` のまま**（単純さ優先）。粒度分割は A 着手時に「抽出方式別」で再検討する。

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
4. ~~**認証ミドルウェア追加**: Bearer トークン（CLI remote）~~ → **完了**（下記「共通基盤」）。本番認証は Cloudflare Access + IdP へ発展（下記「認証」）。
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

### 認証（Cloudflare Access + IdP・2026-06-28 確定）

クラウド本番は **Cloudflare Access**（Zero Trust リバースプロキシ）をエッジに置き、IdP で認証する。origin（Fly.io）は **Cloudflare Tunnel** 経由でのみ到達可能にし公開ポートを閉じる。

認証方式はクライアント種別で2経路に分かれる。分岐軸は「人間か AI か」ではなく「クライアント内にブラウザのログイン操作が挟まるか」。

| クライアント | 操作者 | 認証方式 | 備考 |
|---|---|---|---|
| CLI（人間/AI 半々）・MCP（AI） | 無人 or 非対話 | **Service Token**（`CF-Access-Client-Id` / `CF-Access-Client-Secret`） | ブラウザ不要。鍵ペアをクライアントが保持して毎リクエストに付与 |
| iOS（**他人配布あり**） | 人間 | **SSO（IdP 連携）** | Cloudflare Access を OIDC プロバイダとし、`ASWebAuthenticationSession` で認可コード+PKCE。配布アプリに共有シークレットを埋められないため Service Token 不可 |
| self-host / dev | — | 既存 **Bearer**（`BLT_AUTH_TOKEN`）/ 無認証 | Cloudflare 非依存で立てられるよう温存 |

**origin の検証方針 = 方式 A（エッジ信頼）**。Tunnel + Access がエッジで認証済みのため、origin は Cloudflare 経路に対し**追加の JWT 検証をしない**（新規依存ゼロ。`vapor/jwt` 不要）。

- **A の安全要件**: A のセキュリティは「origin が非公開であること」に全面依存する。**Tunnel + 公開ポート閉鎖 + Access ポリシー適用**の3点セットで初めて成立する。ポートが開いていると Cloudflare 経路に対し無検証で素通りになる。
- **B（多層防御）へ移るトリガー**: origin が**ユーザー単位の処理**を始めるとき（ユーザー別クォータ／データ／email 付き監査）。そのとき `vapor/jwt` を足し `Cf-Access-Jwt-Assertion` を JWKS（`https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`）で検証して identity を取り出す。現状は全員に同じ公開財務データを返すだけなので A で十分。

#### 実装ステップ

1. ~~**origin 認証ミドルウェアの env 分岐**（`Routes.swift`、依存ゼロ）~~ → **完了**（下記「共通基盤」の認証モード表）
2. ~~**CLI の Service Token 対応**（config/keychain スキーマ追加）: `CF-Access-Client-Id` / `CF-Access-Client-Secret` を保持し2ヘッダ付与~~ → **完了**。鍵ペアを keychain（専用キー `cfAccessClientId` / `cfAccessClientSecret`）に保存し、remote 経路で2ヘッダを付与。設定: `ticker config set --cf-access-client-id <id> --cf-access-client-secret <secret>`。env 上書きは `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET`（env > keychain）。authToken（Bearer）とは独立に付与され、将来の SSO トークンも別キーで横付けできる
3. **Dockerfile**: `cloudflared` サイドカー同梱
4. **fly.toml**: 公開ポートを閉じ cloudflared の outbound 限定に
5. **docs/deploy.md**: Cloudflare 側手順（zone 移管 → Tunnel → Access アプリ + ポリシー + Service Token 発行 + IdP 接続）

### 共通基盤（env 設定・ヘルスチェック・認証）

クラウド（Fly.io）／self-host 双方で同一バイナリを使うため、起動時設定を環境変数へ寄せた（構築順序ステップ3）。

| 環境変数 | 役割 | デフォルト |
|---|---|---|
| `BLT_HOST` | bind ホスト。クラウドでは `0.0.0.0` | `127.0.0.1` |
| `BLT_PORT` | bind ポート | `3000` |
| `BLT_EDINET_API_KEY` | EDINET API キー（keychain 非搭載の Linux サーバー向け） | （未設定なら settingsStore へフォールバック） |
| `CF_ACCESS_TEAM_DOMAIN` | 設定時は Cloudflare Access モード（エッジ信頼）。origin は検証せず Tunnel + Access に委ねる | （未設定） |
| `BLT_AUTH_TOKEN` | 静的 Bearer トークン。Cloudflare Access モードでないときに設定すると `/v1` を保護 | （未設定なら無認証） |
| `DATABASE_URL` | Neon Postgres 接続文字列（既存。Fluent 配線） | （未設定なら DB なし） |

- **bind**: 解決順位は CLI 引数（`--host`/`--port`）> env > デフォルト。
- **EDINET キー**: env（`BLT_EDINET_API_KEY`）優先、未設定時のみ `settingsStore`（keychain/config）へフォールバック。両方とも空なら起動時に exit(1)。
- **`GET /healthz`**: 認証不要。`{"status":"ok"}` を 200 で返す（Fly.io／LB のヘルスチェック用）。`/v1` の認証グループ外に登録。
- **認証モード（`/v1` 配下・起動時に env から決定）**: 優先順位で1つを選ぶ。`/healthz` は常に認証不要。
  1. `CF_ACCESS_TEAM_DOMAIN` 設定 → **Cloudflare Access モード**（エッジ信頼 / 方式 A）。origin は検証せず Tunnel + Access に委ねる。起動ログに前提（Tunnel 経由・公開ポート閉鎖）を notice 出力。
  2. `BLT_AUTH_TOKEN` 設定 → **静的 Bearer**。`Authorization: Bearer <token>` を定数時間比較で検証し、不一致・未提示は 401（エラー封筒 `{"error":...,"status":401}`）。
  3. どちらも無し → **無認証**（ローカル開発専用）。`/v1` 無防備のため起動時に warning を出す。

---

## TODO

### 必須（blt-server を使い始める前に）

- [x] サーバーマシンに EDINET API キーを設定する（Fly secret `BLT_EDINET_API_KEY`・ローカル `.env` とも設定済み）
- [x] `blt-server sync` で書類一覧を初回同期する（実 Neon に 3,944 社同期済み）

### 近期（Stage 1 安定化）

- [x] **定期 sync＋ingest を launchd で自動化（設定済み・稼働中）** — `com.sollahiro.blt-sync`（リポジトリ管理の `scripts/blt-scheduled-sync.sh`）が**毎日 08:00 / 14:00 / 20:00** に `sync`（Stage 1）→`ingest --limit 200`（Stage 3/4）をローカルから `DATABASE_URL`=Neon に向けて実行。Stage 4 計算は Fly(1GB) で OOM するためローカルで回し Fly は読むだけ。同一ラベルのため launchd が前回実行中の重複起動を抑止。手順は `docs/deploy.md`「定期同期（ローカル launchd）」。**コード変更後は `swift build -c release --product blt-server` の再ビルドが必須**（バイナリが古いと旧ロジックで計算される）。Mac 起動中のみ進行。
- [~] **バックフィル（進行中・上記定期ジョブが消化中）**: company_financials **506/3,944 社格納**（2026-06-28 夜時点）。fin-v2 再デプロイで fin-v1 行はサーバーが stale 扱い（フォールバック撤去後は 404）になるが、**drain が stale を最優先で消化**（`Stage4Ingest.distinctCompanyCodes` 走査順で既存社が先頭）→ 残り fin-v1 は次回 ingest で解消。その後に新規社へカバレッジ拡大。Fly は読むだけ（未格納は 404＝OOM しない）。
  - **半期（company_half_financials）も同 ingest が Stage 4-half として埋める**。**2026-06-28 夜に 5→9 社へ前進**。半期が長く 5 社で止まっていた真因は **launchd の release バイナリが Stage 4-half 配線より古かった**こと（定期ランのログに「Stage 4-half 取り込み完了」行が出ていなかった）。release 再ビルドで解消し、手動 ingest で Stage 4-half 到達を確認。半期 read は `Api.halfMaxYears`(=5) クランプ＋未格納 404 で OOM しない。
  - **長時間ランの transient PSQLError 対策**: limit を大きくすると 1 ラン数時間に及び、途中の Neon 接続リセットで Stage 4 / Stage 4-half がまとめて巻き戻る（最後に走る Stage 4-half が完走しにくい）。バックフィル中は `BLT_INGEST_LIMIT=75` に下げて完走率を優先（全社 drain 後は既定 200 に戻してよい）。詳細は `docs/deploy.md`「定期同期（ローカル launchd）」。
  - 補足: Stage 3 のバッチで failed が出る（例 attempted=200 stored=183 failed=17）。財務報告書以外や DL 一時失敗のスキップで、ブロッカーではない（次回 ingest で再試行）。Stage 3 は facts-v1 一致を skip（再パースしない。例 skipped=373）。
- [x] **fin-v2 再デプロイ（2026-06-28）** — IBD 借入金等明細表抽出（computeFinancials の HTML 依存抽出）追加で `companyFinancialsCacheVersion` を fin-v1→**fin-v2** にバンプ。`fly deploy --remote-only` で fin-v2 イメージへ更新（fin-v1 サーバーは fin-v2 行を stale 拒否してしまうため必須）。fin-v2 銘柄が **warm 0.31s** で 200 read を確認。
- [x] **Stage 4 キャッシュバージョンの分離（2026-06-27）** — `company_financials.cache_version` を `blueTickerVersion` 連動から専用定数 `companyFinancialsCacheVersion`（`Models/FinancialsContract.swift`）へ分離（Stage 3 `xbrlFactsCacheVersion` と同思想）。CLI バンプで全社 re-ingest が走らなくなり、**Fly サーバーを CLI リリースタグから独立して `fly deploy` 可能**に。あわせて discovery の docID 重複クラッシュ（`Dictionary(uniqueKeysWithValues:)`）を `fix:` で修正。
- [x] **Fly secret `BLT_EDINET_API_KEY` の正否確認** — 解消（2026-06-27）。破損の正体は値を囲むシングルクォート（ローカル `.env` が `'32hex'`＝34文字。`docker run --env-file`/env ファイル経由だとクォートをはがさず生値に混入する）。正規 32hex が EDINET API で 200 OK を返すことを直接確認し、Fly secret をクォートなし 32hex で再設定（rolling deploy 成功）。ローカル `.env` も裸書きに修正。blt-server 自体は `.env` を読まず `ProcessInfo.environment` を読む（dotenv パーサなし）ため、クォート害は env ファイル経由の消費時のみ。
- [x] 実 Neon への接続・同期の E2E 検証 — Postgres スキーマ/JSONB/索引/Stage1・3 書き込みは opt-in 統合テスト `PostgresIntegrationTests`（ローカル Docker Postgres、`BLT_TEST_POSTGRES_URL` で有効化）で検証済み。実 Neon フルパイプライン（sync→ingest→financials）の runbook は `docs/deploy.md`「Neon 接続の E2E 検証」。実 Neon で `sync`(Stage1) 書き込み・`ingest`(Stage3/4) バックフィル・`computeFinancials` を実データで確認済み（`ingest --limit 10` で Stage3/4 とも stored=10 failed=0）。<br>**過去の `stored=0 failed=5` ブロッカーは解消済み**: 真因は汚染された空キャッシュディレクトリ。キー破損期に EDINET が JSON エラー封筒をバイナリとして返し、`extractZip` が dest 作成後に throw → 空ディレクトリ残留 → 以後 `hasXbrlDir` が「取得済み」と誤判定し再取得されず facts=0。`hasXbrlDir` が空ディレクトリを拒否（自己修復）＋ `storeXbrlZip` が展開失敗時に dest 削除、で修正。
- [x] `status.json` 追加（`analysis_cache/external/edinet/stage1_status.json`）
- [x] `CacheManager.set()` を atomic write（temp file + rename）に修正済み

### 近期（MCP 廃止）

- [x] `MCPServer/` を `Server/` にリネームし、MCP プロトコル実装を削除して REST API サーバーに一本化した
- [x] `Package.swift` から `swift-sdk`（MCP）・`swift-log` への依存を削除した
- [x] CLAUDE.md のターゲット構成・依存ルールを更新した（`MCPServer/` → `Server/`）

### 近期（remote CLI）

- [x] `ticker config set edinet-backend remote` のサポート実装済み
- [x] CLI の remote モードで REST API を呼ぶ実装を追加する（下記「remote CLI 実装」）
- [x] **Stage 1 read 配線**: `filings` を `EdinetDiscovery` ライブ探索から `edinet_documents`（DB）読みへ切り替え（`loadStoredFilingRecords`＋`getFilingsFromRecords`、未同期/DB 非接続はライブフォールバック）。簡易セマンティクス採用（140/130 はライブと意図的差分・schema 変更回避）。「稼働状況」参照。**残: 実 Fly での E2E 検証**
- [x] **remote `--half` 対応**: `GET /v1/companies/{code}/half-financials` ＋ DB 格納経路（`company_half_financials`・ingest・DB 専用 read）＋ remote CLI 配線で `analyze --half`/`summarize --half` を remote 対応。**実 Fly E2E 検証済み（2026-06-28、years=6 warm read・未格納 404・OOM なし）**。残: 半期バックフィルの全社 drain（launchd ingest が消化）
- [x] **財務系 read のライブ計算フォールバック撤去（2026-06-28）**: financials / half-financials を DB 専用化（未格納 404・DB 非接続 503・ライブ計算なし）。half read は `Api.halfMaxYears`(=5) へクランプ（CLI 既定 years=6 が DB を空振りしないように）。重複していた半期上限「5」を `Api.halfMaxYears` に集約。Fly 再デプロイ済み（v9）。`company_financials`/`company_half_financials` のスキーマ・cache_version は不変（再 ingest 不要）
  - **レガシー削除済み（2026-06-29）**: 呼び出し元を失った `BltServerFacade.getFinancials/getHalfFinancials`（薄いラッパー）とテスト専用ヘルパー `buildFinancialsResponse` を削除。計算本体 `computeFinancials/computeHalfFinancials`（Stage 4 ingest が使用）は保持。オンデマンド ingest（202＋キュー）を後で実装する際は `compute*` を入口に使う（ラッパー復活は不要）。
- [ ] **`sector` の REST 化（任意）**: 現状 CSV 算出で remote でも動作するため機能欠落ではない。一貫性のための polish（優先度低）

### 次の検討課題（優先順）

- [x] DB 選定の確定 → **Neon（serverless Postgres）**
- [x] サーバースタック確定 → **Vapor + Fluent 採用**（ユーザー確認済み）
- [x] Server を独立ターゲット（`BltServerCore`）へ分離し CLI から NIO 依存を排除（実測でシンボル 0・サイズ半減）
- [x] **Vapor + Fluent を `BltServerCore` に追加**（トランスポート置換完了。Fluent は DATABASE_URL 条件付き配線。「Vapor + Fluent 移行の内容」参照）
- [x] **Stage 1 の DB スキーマ設計＋同期配線**（`edinet_documents`/`edinet_sync_state`・`blt-server sync`。「Stage 1 DB 配線」参照）
- [x] **Stage 3 の DB スキーマ設計＋取り込み**（`edinet_xbrl_facts`・書類単位 JSONB・`blt-server ingest`。「Stage 3 DB スキーマ＋取り込み」参照）
- [x] **Stage 4 の DB 配線**（`company_financials`・企業単位 JSONB・ingest で計算格納・financials read を DB 優先化。「Stage 4 DB 配線」参照）
- [x] Stage 2 保持ポリシー確定 → **ローカル保持継続**（Stage 4 が生 HTML を必要とするため即削除不可。R2 退避はクラウド実運用で容量問題化してから）
- [x] Stage 4 計算の所在確定 → **サーバー計算に集約**（クライアントは表示専念。「計算の責務」節を参照）

### クラウド公開前の必須（コード側）

- [x] bind 可変化（`BLT_HOST`/`BLT_PORT`、Fly では `0.0.0.0:8080`） — 共通基盤で実装済み
- [x] `/healthz` ヘルスチェック追加（Fly `[checks]` 用） — 共通基盤で実装済み
- [x] Bearer トークン認証を追加（Vapor ミドルウェア。トークンは Fly secrets 経由） — 共通基盤で実装済み
- [x] EDINET API キーの読み元を env（Fly secrets）対応に — 共通基盤で実装済み（`BLT_EDINET_API_KEY`）
- [x] Dockerfile（swift:6.1 2段ビルド）＋ `fly.toml`、永続 Volume、`fly secrets` — 「デプロイ」節・`docs/deploy.md` 参照

### 将来

- [ ] Stage 2〜4 実装（データパイプライン拡張、上表参照）
- [ ] **生 XBRL の中央永続化（目標 A）**: オブジェクトストレージ＋3段フォールバックで「取得は一度きり・抽出/計算だけ再実行」を実現。前段に Postgres 512MB 対策（A1）が必要。詳細は「取得→抽出→計算の分離とストレージ方針」
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM によるセグメント別売上の構造化抽出（仮: `get_segment_revenue`）
- [ ] LLM による抽出値の抜き打ち整合評価（XBRL 生データとサーバー保存データを突き合わせ、乖離があれば警告）
- [x] 認証方式の確定（**Cloudflare Access + IdP**・方式 A エッジ信頼） — 「認証」節参照
- [x] origin 認証ミドルウェアの env 分岐（Cloudflare Access / Bearer / 無認証） — ステップ1 完了
- [ ] CLI の Service Token 対応（ステップ2・config/keychain スキーマ変更・要確認）
- [ ] Cloudflare Tunnel 同梱（Dockerfile）＋ fly.toml 公開ポート閉鎖（ステップ3・4）
- [ ] iOS の SSO（OIDC + PKCE）連携（iOS アプリ側プロジェクト）
- [ ] **REST API の整備（公開 API 化）**: ユーザー接点（remote CLI / GUI / MCP）が依存する公開 API を整える。現行 `/v1` を土台に、スキーマ安定化・認証・レート制御を進める（`方針転換` のユーザー集約に必須）。
- [ ] **オンデマンド ingest（非同期）の実装**: 未充足リクエスト記録テーブル＋既存 ingest バッチでの消化（上記「オンデマンド ingest（非同期）」）。公開スキーマ追加のためユーザー確認後に着手。
- [ ] **ユーザー向けローカル分析 CLI の段階的廃止**: `backend=local` の deprecation 告知 → 廃止バージョンを定めて削除。Dev CLI・Core・Unit Test は残す。
- [ ] **MCP クライアントの復活**: REST API クライアントとして再実装（remote CLI / GUI と同型。プロトコルサーバーは復活させない）。

---

## 未決事項

- ~~Stage 2 生 XBRL の保持ポリシー（即削除 vs R2 退避）~~ → 解決（ローカル保持継続・R2 退避は延期）
- ~~financials レスポンスの公開契約スキーマの確定形（schema version の持たせ方）~~ → 解決（flatten 形＋独立採番 `schema_version`）
- remote backend 利用時の `ticker cache status` 表示内容
- **Postgres 512MB 上限への対策（目標 A の前段 A1）**: 数値 facts 全件 ~700MB 見込みで現プラン上限超過。Neon プラン拡張 or facts JSONB のオブジェクトストレージ退避のどちらにするか未決

---

## 関連ドキュメント

- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — アーキテクチャ依存ルール
