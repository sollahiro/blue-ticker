# MCP サーバーと backend 移行ロードマップ

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **local CLI** | なし | CLI | 現行 |
| **remote (self-host)** | 同一マシン | blt-server | Phase 2/3 以降 |
| **remote (cloud)** | リモートサーバー | blt-server | 将来検討 |

Phase 4（self-hosted MCP 暫定稼働）完了。`blt-server` は `poetry install --with server && blt-server` で起動。

## ゴール

- local CLI は blt-server 不要の独立モードとして維持する。
- remote (cloud) により AI チャットボットおよび CLI が共通の blt-server を通じて財務データにアクセスできるようにする。

## 非ゴール

- `ticker analyze` 等の各サブコマンドに backend 選択オプションを増やさない。
- `CacheManager` と EDINET external cache を無理に単一抽象へ統合しない。
- ローカルキャッシュを「レガシー」として扱わない。

---

## TODO

### 必須（blt-server を使い始める前に）

- [x] `poetry install --with server` を実行する
- [x] `blt-server` 起動確認済み（2026-06-03）
- [ ] サーバーマシンの `settings_store` に EDINET API キーを設定する
- [ ] `sync_document_list` ツールで書類一覧を初回同期する

### 近期（Stage 1 安定化）

- [ ] `sync_document_list` の定期実行を launchd で設定する
- [x] Stage 1 に `status.json` を追加（`analysis_cache/external/edinet/stage1_status.json`）
- [x] `CacheManager.set()` を atomic write（temp file + rename）に修正済み

### 中期（remote CLI 採用を決断した場合）

- [x] Phase 2: `ticker config set edinet-backend remote` のサポート実装済み
- [ ] `services/data_service.py` の取得部分と計算部分を分割する（Phase 3 の前提）
- [ ] CLI を `get_financial_summary` / `get_filings` の薄いレンダラーへ移行する（Phase 3）

### 将来（パイプライン拡張）

- [ ] Stage 2: XBRL ダウンロードの事前取得バッチ
- [ ] Stage 3: XBRL 数値抽出の事前取得バッチ
- [ ] Stage 4: 財務指標計算の事前取得バッチ
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM によるセグメント別売上の構造化抽出（仮: `get_segment_revenue`）
- [ ] OAuth 認証の追加

---

## 未決事項

- OAuth フローとトークン保存場所
- remote cache 削除ポリシー
- remote backend 利用時の `ticker cache status` 表示内容
- remote XBRL artifact をローカルにどれくらい保持するか（サーバー別マシン化時）
- local / remote 間で分析結果キャッシュ `derived/` を共有するか、backend ごとに分けるか

---

## 関連ドキュメント

- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — アーキテクチャ依存ルール
