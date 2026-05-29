# MCP サーバー計画：現状と TODO

作成日: 2026-05-30
最終更新: 2026-05-30

このドキュメントは `docs/remote-mcp-cache-roadmap.md` の上流計画を受けて、
MCP サーバーの具体的なアーキテクチャ決定・実装状況・今後の TODO を記録する。

---

## 背景

blue-ticker を以下の 2 本立てで使う構成を目指す。

| 利用形態 | クライアント | アクセス方法 |
|---|---|---|
| AI エージェント（Claude Code など） | blue-ticker CLI | シェルコマンドを直接実行 |
| AI チャットボット（Claude.ai など） | — | リモート MCP ツールを呼び出し |

どちらも同じ**サーバー上のデータストア**を読む。EDINET への直接通信はサーバーが担い、
ユーザーは API キーを管理しない。

---

## アーキテクチャ決定事項

### 1. 通信モデル：共有データストア方式

```
[MCP サーバー]  書き込み →  データストア（ファイル）
[CLI]           読み込み ←  データストア（ファイル）
[チャットボット] MCP ツール → [MCP サーバー] → データストア
```

**自己ホスト（現行）**: CLI は MCP サーバーへ HTTP 通信せず、同一マシン上のデータストアをローカルファイルとして直接読む。
`mcp` パッケージは CLI バイナリには含めない。

**将来（サーバー別マシン化後）**: CLI は `remote` backend 経由でサーバーへ HTTP 通信する（Phase 3 対応時）。
`mcp-server-plan.md` の「CLI を `get_financial_summary` / `get_filings` の結果を受け取る形へ移行」はこの段階を指す。

**理由**: 自己ホスト前提ではファイル共有が最もシンプル。CLI バイナリの容量増大を避けられる。

### 2. API キー管理

EDINET API キーはサーバー側の `settings_store` で管理する（`ticker config set edinet-key`）。
ユーザー（クライアント側）は API キーを持たなくてよい。

### 3. 依存パッケージ

`mcp` パッケージは `server` dependency group にのみ追加する。
CLI のビルド・インストールには含まれない。

```toml
[dependency-groups]
server = [
    "mcp>=1.0.0,<2.0.0",
]
```

### 4. トランスポート

`streamable-http`（FastMCP デフォルト）で起動する。
初期は認証なし・自己ホスト・ローカルネットワーク前提。OAuth は将来対応。

### 5. 計算ロジックの置き場所

財務指標計算（YoY、ROE、ROIC、WACC など）は**サーバー側**で行い、MCP ツールが算出済みデータを返す。
CLI は受け取ったデータを整形・表示するレンダラーとして特化する。

現在の `services/analyzer.py` は `data_service.get_raw_analysis_data()` 経由でサーバーが呼ぶ。
CLI は将来的にサーバーの `get_financial_summary` ツール相当を呼ぶ形へ移行する。

---

## データパイプライン（ステージ設計）

書類一覧からXBRL解析まで、4 段階のパイプラインとして整理する。
各ステージは独立してスケジュール・拡張できる。

```
Stage 1  書類一覧同期   EDINET API → analysis_cache/external/edinet/documents_by_date/
                                      analysis_cache/external/edinet/document_indexes/
Stage 2  XBRL取得       書類一覧 → analysis_cache/external/edinet/xbrl/{doc_id}/
Stage 3  XBRL数値抽出   xbrl → analysis_cache/derived/xbrl_numeric_index/{doc_id}.json
Stage 4  財務指標計算   xbrl_numeric_index → analysis_cache/derived/analysis/{code}.json
```

各ステージに `status.json` を持たせ「どこまで処理したか」を管理する。
後ろのステージは前のステージの出力を読むだけで、疎結合を維持する。

### 現在の実装状況

| ステージ | 状況 | 備考 |
|---|---|---|
| Stage 1 | **実装済み** | `sync/document_list.py`。既存 `cache catchup` と同等ロジック |
| Stage 2 | 未実装 | 将来拡張 |
| Stage 3 | 未実装 | 将来拡張 |
| Stage 4 | 未実装（オンデマンド動作） | `get_financial_summary` 呼び出し時にオンデマンドで実行・キャッシュ |

---

## MCP ツール一覧

| ツール | データ源 | 状況 |
|---|---|---|
| `search_companies(query)` | マスターデータ | 実装済み |
| `search_by_sector(sector, limit)` | マスターデータ | 実装済み |
| `get_filings(code, max_years)` | Stage 1（書類一覧） | 実装済み |
| `get_financial_summary(code, years)` | Stage 4（オンデマンド） | 実装済み |
| `get_filing_content(code, doc_id, sections)` | オンデマンド | 実装済み |
| `sync_document_list(years)` | — | 実装済み（管理用） |

### `get_filings` の返却フィールド

```json
{
  "code": "9984",
  "name": "ソフトバンクグループ株式会社",
  "filings": [
    {
      "doc_id": "S100VXJA",
      "doc_type": "120",
      "doc_type_label": "有価証券報告書",
      "fy_end": "2025-03",
      "submitted_at": "2025-06-20"
    }
  ]
}
```

### `get_financial_summary` の返却フィールド

金額は百万円（JPY）、比率は %、株主指標は円。

```json
{
  "code": "9984",
  "name": "ソフトバンクグループ株式会社",
  "sector": "情報・通信業",
  "market": "プライム",
  "currency": "JPY",
  "unit": "百万円",
  "years": [
    {
      "fy_end": "2025-03",
      "financial_period": "FY",
      "doc_id": "S100VXJA",
      "sales": 18500000,
      "gross_profit": 3200000,
      "gross_profit_margin": 17.3,
      "operating_profit": 450000,
      "operating_margin": 2.4,
      "net_profit": 950000,
      "cfo": 1200000,
      "cfi": -800000,
      "cfc": 400000,
      "eps": 456.7,
      "bps": 3210.5,
      "dividends_per_share": 150.0,
      "payout_ratio": 32.1,
      "total_assets": 45000000,
      "net_assets": 12000000,
      "interest_bearing_debt": 18000000,
      "roe": 12.3,
      "roic": 5.1,
      "wacc": 6.2,
      "employees": 80000
    }
  ]
}
```

---

## 実装済みファイル

```
blue_ticker/mcp_server/
  __init__.py
  server.py                   ← FastMCP エントリポイント。全ツール登録 + main()
  tools/
    __init__.py
    search.py                 ← search_companies, search_by_sector
    filings.py                ← get_filings
    financial.py              ← get_financial_summary（YearEntry のフラット化）
    filing_content.py         ← get_filing_content
  sync/
    __init__.py
    document_list.py          ← sync_document_list（Stage 1 バッチ）

pyproject.toml
  [dependency-groups].server  ← mcp>=1.0.0,<2.0.0
  [project.scripts].blt-server ← blue_ticker.mcp_server.server:main
```

起動コマンド: `blt-server`（streamable-http、デフォルトポート 8000）

---

## TODO

### 必須（使い始める前に）

- [ ] `poetry lock` を実行する（`pyproject.toml` に `[dependency-groups].server` は追加済み）
- [ ] サーバーマシンの `settings_store` に EDINET API キーを設定する
- [ ] `blt-server` で起動確認し、`sync_document_list` ツールで書類一覧を初回同期する

### 近期（Stage 1 安定化）

- [ ] `sync_document_list` の定期実行を cron または launchd で設定する（例: 毎朝 7:00）
- [ ] `tests/test_dependency_rules.py` に `mcp_server` レイヤーのルールを追加する
  - `mcp_server` → `app` のインポートを禁止するテストケース

### 中期（CLI のサーバー化対応）

- [ ] `services/data_service.py` の「取得部分」と「計算部分」を分割する
  - 取得部分（EDINET 通信・XBRL 展開）: サーバー側で完結
  - 計算部分（YoY 差分・比率計算）: `get_financial_summary` ツールが担う
- [ ] CLI を `get_financial_summary` / `get_filings` の結果を受け取る薄いレンダラーへ移行する
  - `analyze` コマンド: `get_financial_summary` → 整形出力
  - `filings` コマンド: `get_filings` → 整形出力
- [ ] `ticker config set edinet-backend remote` のサポート（`remote-mcp-cache-roadmap.md` Phase 2）

### 将来（パイプライン拡張）

- [ ] Stage 2: XBRL ダウンロードの事前取得バッチ（対象銘柄リストを設定で管理）
- [ ] Stage 3: XBRL 数値抽出の事前取得バッチ
- [ ] Stage 4: 財務指標計算の事前取得バッチ（`get_financial_summary` をオンデマンドから事前計算へ）
- [ ] 各ステージの `status.json` 管理（処理済みリストと更新日時）
- [ ] OAuth 認証の追加（複数ユーザー・外部公開が必要になった場合）

---

## 関連ドキュメント

- `docs/remote-mcp-cache-roadmap.md` — 上流の移行ロードマップ（Phase 1〜5）
- `docs/architecture-status.md` — コードベース現状評価
- `.agents/rules/project/caching.md` — キャッシュ設計規約
- `.agents/rules/project/dependencies.md` — 依存方向ルール
