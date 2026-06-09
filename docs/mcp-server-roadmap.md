# MCP サーバーと backend 移行ロードマップ

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **local CLI** | なし | CLI | 現行稼働中 |
| **remote (self-host)** | 同一マシン | blt-server | 基盤実装済み・設定待ち |
| **remote (cloud)** | リモートサーバー | blt-server | 将来検討 |

`blt-server` は `poetry install --with server && blt-server` で起動。self-hosted MCP の基盤実装は完了済み。

blt-server には 2 種類のクライアントが接続できる。デプロイモード（上表）はサーバーの配置場所を表すもので、クライアント種別とは独立した軸。

| クライアント | 接続方法 | ユースケース |
|---|---|---|
| **remote CLI** | MCP プロトコル（HTTP transport） | OAuth 認証のみで利用可能・EDINET API キー管理不要 |
| **AI チャット（MCP）** | MCP プロトコル（HTTP transport） | Claude.ai 等の AI ツールから財務データをツール呼び出し |

remote CLI と AI チャットはどちらも MCP プロトコルで統一する。カスタム REST API は実装しない。

## ゴール

- local CLI は blt-server 不要の独立モードとして維持する。
- remote デプロイにより、remote CLI と AI チャット（MCP）が共通の blt-server を通じて財務データにアクセスできるようにする。

## 非ゴール

- **ローカル MCP サーバーは実装しない。** AI エージェントは Skills 経由で CLI を直接操作する。
- **カスタム REST API は実装しない。** remote CLI も MCP プロトコルで統一する。
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

- [x] `poetry install --with server` を実行する
- [x] `blt-server` 起動確認済み（2026-06-03）
- [ ] サーバーマシンの `settings_store` に EDINET API キーを設定する
- [ ] `sync_document_list` ツールで書類一覧を初回同期する

### 近期（Stage 1 安定化）

- [ ] `sync_document_list` の定期実行を launchd で設定する
- [x] `status.json` 追加（`analysis_cache/external/edinet/stage1_status.json`）
- [x] `CacheManager.set()` を atomic write（temp file + rename）に修正済み

### 中期（remote CLI 採用を決断した場合）

- [x] `ticker config set edinet-backend remote` のサポート実装済み
- [ ] `services/data_service.py` の取得部分と計算部分を分割する
- [ ] CLI を MCP ツール呼び出しの薄いレンダラーへ移行する（カスタム REST API は作らない）

### 将来

- [ ] Stage 2〜4 実装（データパイプライン拡張、上表参照）
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM によるセグメント別売上の構造化抽出（仮: `get_segment_revenue`）
- [ ] LLM による抽出値の抜き打ち整合評価（XBRL 生データとサーバー保存データを突き合わせ、乖離があれば警告）
- [ ] OAuth 認証の追加

---

## 未決事項

- OAuth フローとトークン保存場所
- remote cache 削除ポリシー
- remote backend 利用時の `ticker cache status` 表示内容
- remote XBRL artifact をローカルにどれくらい保持するか（サーバー別マシン化時）
- local / remote 間で分析結果キャッシュ `derived/` を共有するか、backend ごとに分けるか

---

## 将来: Python blt-server → Swift への置き換え

Swift 移行 Phase 5 で、Python `blt-server`（FastMCP）を Swift MCP サーバー（HTTP transport）に置き換える予定。  
実装言語が変わるだけで、このドキュメントのデプロイモード・データパイプライン・未決事項はそのまま引き継ぐ。  
詳細: `docs/swift-migration-feasibility.md` の Phase 5。

---

## 関連ドキュメント

- `docs/swift-migration-feasibility.md` — Swift 移行計画（Phase 5 で blt-server を置き換え）
- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — アーキテクチャ依存ルール
