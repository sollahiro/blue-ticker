# blt-server ロードマップ

現在地と次の意思決定の索引。手順は `deploy.md` / `operations.md`、構成のスナップショットは `architecture.md`、完了履歴は Git。

## 現在地（2026-07-09）

| 項目 | 状態 |
|---|---|
| 本番 | Fly.io (nrt) + Neon + Cloudflare Access/Tunnel。`api.sollahiro.com` 稼働。main push で自動デプロイ |
| CLI 既定 | `backend=remote`（`ticker login` で SSO） |
| Stage 1 | 同期済み（~3,944 社）。launchd が日次増分 sync |
| Stage 3 | スキーマあり・**取り込み停止中**（issue #22。512MB 対策。`--with-facts` で再開可） |
| Stage 4 | **バックフィル進行中**。`company_financials` 合計 2,288 行（うち `fin-v4` 307）。ユニバース ~3,944 社 |
| Stage 4 read 床 | **`companyFinancialsMinServableVersion = 2`**（`fin-v2` 以上を 200。`fin-v1` は 404）。明示定数・機械オフセットではない |
| Stage 4-half | 進行中。issue #73 の半期報告書マッチング修正で `half-v2` へバンプ（`half-v1` 行は全件 stale・再計算対象）。read 床 `companyHalfFinancialsMinServableVersion = 1` を新規導入し `half-v1` 行も引き続き 200 |
| Stage 5 | 進行中。`sections-v2` 150 / 旧 `sections-v1` 1,574（stale 消化中） |
| Stage 5 read 床 | **`filingSectionsMinServableVersion = 1`**（`sections-v1` 以上を 200）。明示定数 |
| 定期ジョブ | ローカル launchd `com.sollahiro.blt-sync`（4h おき）。Fly は read 専用（ingest は OOM するためローカル） |
| MCP | **Phase 1・Phase 2 とも完了**（2026-07-12）。`blt-server`（Vapor）に `POST /mcp` を埋め込み。6 ツール（`search_companies` 等）。`api.<domain>/mcp`（Phase 1・SSO 経由）に加え、新規サブドメイン `mcp.<domain>` に Managed OAuth for Access を有効化し、Claude.ai / ChatGPT 等 OAuth 2.1 前提のリモートクライアントにも対応（origin コード変更なし）。discovery・未認証ブロックとも実機確認済み。手順は `deploy.md`「MCP（Managed OAuth）」参照 |

カバレッジは Neon の `cache_version` 別件数で確認する（例: `SELECT cache_version, count(*) FROM company_financials GROUP BY 1`）。

## 方針: サーバー集約とローカル CLI 廃止

到達点は「**Blue Ticker はサーバーで動く。CLI / GUI / MCP は REST クライアント相当の経路で同じデータへアクセスする**」。

| 区分 | 対象 | 扱い |
|---|---|---|
| 残す | Core（`Analysis/`＋`Services/`）・Unit Test・**開発用 CLI**（デバッグ・テスト・フィクスチャ） | 維持 |
| 切る | **ユーザー向けローカル分析 CLI**（`backend=local`） | **全銘柄が read 床以上で servable になったら廃止**（下記ゲート） |
| ユーザー接点 | remote CLI / GUI / MCP | REST API、または `blt-server` に同居する MCP プロトコル経由 |

- Core はサーバー専用にしない（Dev CLI・Unit Test と共有）。
- **方針転換（2026-07-11）**: 「旧 MCP プロトコルサーバーは復活させない」という非ゴールは撤回した。`blt-server`（Vapor）に `POST /mcp` を埋め込む形で MCP プロトコルサーバーを再構築した（`Sources/BltMcpServerCore/` + `Sources/BltServerCore/MCPRoute.swift`）。旧実装（`Sources/BlueTicker/MCPServer/`、Vapor 導入前の生 swift-nio）とは異なり、ツールディスパッチは `Routes.swift` の DB 読み取り共通関数を REST と共有し、ロジックの重複はない。詳細は `docs/architecture.md`「MCP」節を参照
- オンデマンド ingest は非同期（404 → 将来 202＋キュー。公開スキーマ追加のため実装前に確認）。

### Stage 4 / Stage 5 read 床（min servable）

financials / filing-content の REST read は現行版との完全一致ではなく、**明示した最低世代以上**を返す。half は単一版のため床未導入（`half-v2` 時に同型追加）。

| 定数 | 役割 |
|---|---|
| `companyFinancialsCacheVersion`（いま `fin-v4`） | Stage 4 ingest の書き込み・stale 判定 |
| `companyFinancialsMinServableVersion`（いま `2`） | financials read の最低 N（`fin-vN`） |
| `filingSectionsCacheVersion`（いま `sections-v2`） | Stage 5 ingest の書き込み・stale 判定 |
| `filingSectionsMinServableVersion`（いま `1`） | filing-content read の最低 N（`sections-vN`） |

- 比較は `*-vN` を数値パースして行う（文字列辞書順は使わない）。
- 床の引き上げは、該当旧版の stale 消化完了後に行う（引き上げで servable 穴を作らない）。
- `/healthz` の `company_financials_min_servable` / `filing_sections_min_servable` で現行床を確認できる。

### ローカル CLI 廃止ゲート（2026-07-09 確定）

**トリガー**: ユニバース全銘柄が **Stage 4 read 床以上（servable）** の `company_financials` 行を持つ。

完了の定義:

- `edinet_documents` から導出できる証券コードについて、`company_financials.cache_version` が床以上（いま `fin-v2`+）
- 残欠は恒久 failed（財務報告書なし等）として切り分け済みで、定期 ingest の Stage 4 **missing** が実質ゼロ（床未満だけの行は「空白一巡」に数えない）

補足:

- 現行版（`fin-v4`）への揃えは**削除の必須条件にしない**（床以上なら remote は 200。stale 版アップグレードは同ジョブが継続）
- Stage 4-half / Stage 5 の全社 drain も必須条件にしない（Stage 5 は床=1 で旧行も読める）
- 床を後で引き上げるときは、引き上げ後もゲート条件（全銘柄 servable）を満たすこと

完了後の手順:

1. `backend=local` を deprecation（警告＋ドキュメント）
2. 次の破壊的バージョンでユーザー向け local 経路を削除（Dev CLI・Core・Unit Test は残す）
3. remote 未格納／床未満は 404（または実装済みなら 202＋キュー）のまま。local フォールバックは戻さない
4. 削除直前に、その時点の床での servable カバレッジを再測定する

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **local CLI** | なし | CLI | 互換のため残存。servable 一巡後にユーザー向け廃止 |
| **remote (self-host)** | 同一マシン | blt-server | 基盤実装済み |
| **remote (cloud)** | Fly | blt-server | **本番** |

## データパイプライン

| ステージ | 保存先 | 状態 |
|---|---|---|
| Stage 1 | DB `edinet_documents` / `edinet_sync_state` | 同期済み・定期 sync |
| Stage 2 | ローカル / Fly Volume（生 XBRL） | 保持継続。R2 退避は容量問題化まで延期 |
| Stage 3 | DB `edinet_xbrl_facts` | 停止中（#22） |
| Stage 4 | DB `company_financials` | **バックフィル中（廃止ゲート＝床以上 servable）**。read は床以上・未格納/床未満 404 |
| Stage 4-half | DB `company_half_financials` | バックフィル中 |
| Stage 5 | DB `company_filing_sections` | バックフィル中。read は床以上（いま `sections-v1`+）・未格納/床未満 404 |

重い ingest はローカル→Neon。Fly serving は read-only（ライブ計算フォールバックなし）。

### オンデマンド ingest（設計確定・未実装）

未格納の `GET .../financials` を 404 のままにせず、未充足コードをキュー記録して `202`、既存 ingest バッチが消化する。公開スキーマ追加のため実装前にユーザー確認。

## クライアントと計算の責務

| クライアント | 計算 | データ源 |
|---|---|---|
| CLI (local) | in-process | `Services/` 直呼び（廃止予定） |
| CLI (remote) | しない | REST |
| iOS | しない | REST |
| blt-server | **唯一の計算者** | ingest ＋ DB read |

公開契約は financials / half-financials レスポンス（`schema_version` 独立採番）。Stage 3 RAW は非公開。

`sector` は REST 未整備のため remote でも CSV オフライン算出（機能欠落ではない・優先度低）。

## ゴール / 非ゴール

**ゴール**

- ユーザー向け実行環境を blt-server（remote/cloud）へ集約する
- 全銘柄が Stage 4 read 床以上で servable になったらユーザー向け `backend=local` を廃止する

**非ゴール**

- 各サブコマンドへの backend 選択オプション追加
- servable 一巡前のユーザー向け local 即時削除
- 床を「現行から N つ前」の機械オフセットにすること（明示定数のみ）
- 削除ゲート達成のために現行版へ全社揃えすること（床以上で足りる。stale 消化は別途継続）
- `CacheManager` と EDINET external cache の無理な単一抽象化

## ストレージ（将来・未決）

- **暫定（#22）**: Stage 3 facts 蓄積停止で Neon 512MB 到達を先送り
- **未決**: 強化方式は **(a) Neon プラン拡張** vs **(b) 生 XBRL / facts のオブジェクトストレージ（R2 等）＋3段フォールバック**。目標 A（タグ系は facts 消費・HTML 系は生 XBRL）着手時に決める。A2（中央永続化）が先なら Postgres に facts 全件を持つ必要は薄れる
- 当面の `companyFinancialsCacheVersion` は単一のまま。抽出方式別の粒度分割は A 着手時に再検討

## TODO

issue があるものは番号ポインタのみ（詳細は issue 正本）。

### 進行中

- [~] **Stage 4 servable 一巡**（廃止ゲート）— missing 優先で空白を埋め、床未満（`fin-v1`）も再計算。床以上の旧版残存はゲート非阻害
- [~] Stage 4 現行版への stale 消化 / Stage 4-half / Stage 5 — 同ジョブが継続（廃止の必須条件ではない）

### ゲート到達後（すぐ）

- [ ] **ユーザー向けローカル分析 CLI 廃止** — servable 一巡完了後。deprecation → 破壊的バージョンで `backend=local` 経路削除。Dev CLI・Core・Unit Test は残す

### 次（優先度順）

- [ ] **オンデマンド ingest（非同期）** — 未充足キュー＋202。公開スキーマ追加のため着手前に確認
- [ ] **`sector` の REST 化**（任意・優先度低）
- [ ] remote 時の `ticker cache status` 表示内容（未決）

### 将来

- [ ] 生 XBRL 中央永続化（目標 A）＋ Stage 4 のデータ源見直し（タグ系→facts）
- [ ] ストレージ強化の方式選定（#22 本丸）
- [ ] REST API の公開 API 化（スキーマ安定化・レート制御）
- [ ] iOS SSO（OIDC + PKCE・アプリ側プロジェクト）
- [ ] Cloudflare Monetize Gateway 連携検討（MCP アクセス単位課金。情報未公開のため詳細設計は保留）
- [ ] Stage 5 拡張（retention / 半期 160 / ユニバース）
- [ ] Stage 6: 事業別・地域別売上の LLM 構造化
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM による抽出値の抜き打ち整合評価

## 関連ドキュメント

- `docs/architecture.md` — 構成スナップショット
- `docs/deploy.md` — デプロイ・定期同期・E2E
- `docs/operations.md` — 外部サービス結合と定常運用
- `.agents/rules/project/caching.md` / `versioning.md` / `dependencies.md`
