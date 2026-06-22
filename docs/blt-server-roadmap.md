# blt-server ロードマップ

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **local CLI** | なし | CLI | 現行稼働中 |
| **remote (self-host)** | 同一マシン | blt-server | 基盤実装済み・設定待ち |
| **remote (cloud)** | リモートサーバー | blt-server | 将来検討 |

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

| ステージ | 処理内容 | 状態 |
|---|---|---|
| Stage 1 | 書類一覧取得（`sync_document_list`） | 実装済み・設定待ち |
| Stage 2 | XBRL ダウンロードの事前取得バッチ | 未着手 |
| Stage 3 | XBRL 数値抽出の事前取得バッチ | 未着手 |
| Stage 4 | 財務指標計算の事前取得バッチ | 未着手 |

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

- [ ] `MCPServer/` ディレクトリから MCP プロトコル実装を削除し、REST API サーバーに一本化する
- [ ] `Package.swift` から `swift-sdk`（MCP）・`swift-log` への依存を削除する
- [ ] CLAUDE.md のターゲット構成・依存ルールを更新する（`MCPServer/` → `Server/` 等）

### 近期（remote CLI）

- [x] `ticker config set edinet-backend remote` のサポート実装済み
- [ ] CLI の remote モードで REST API を呼ぶ実装を追加する（現状は未実装）

### 将来

- [ ] Stage 2〜4 実装（データパイプライン拡張、上表参照）
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM によるセグメント別売上の構造化抽出（仮: `get_segment_revenue`）
- [ ] LLM による抽出値の抜き打ち整合評価（XBRL 生データとサーバー保存データを突き合わせ、乖離があれば警告）
- [ ] OAuth 認証の追加（iOS app ログイン）

---

## 未決事項

- remote cache 削除ポリシー
- remote backend 利用時の `ticker cache status` 表示内容
- remote XBRL artifact をローカルにどれくらい保持するか（サーバー別マシン化時）
- local / remote 間で分析結果キャッシュ `derived/` を共有するか、backend ごとに分けるか

---

## 関連ドキュメント

- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — アーキテクチャ依存ルール
