# blt-server ロードマップ

現在地と次の意思決定の索引。手順は `deploy.md` / `operations.md`、構成のスナップショットは `architecture.md`、完了履歴は Git。

## 現在地（2026-07-27）

| 項目 | 状態 |
|---|---|
| 本番 | Fly.io (nrt) + Neon + Cloudflare Access/Tunnel。`api.sollahiro.com` 稼働。main push（CI 成功後）で自動デプロイ |
| CLI | 配布 `ticker` **廃止済み**。開発用は配布しない `TickerDev`。運用は `blt-server` sync/ingest |
| sync | 同期済み（~3,944 社）。launchd が日次増分 sync |
| facts | スキーマあり・**取り込み停止中**（issue #22。512MB 対策。`--with-facts` で再開可） |
| financials | バックフィル継続中。`company_financials` 合計 3,876 行（`fin-v4` 3,829・`fin-v3` 29・`fin-v2` 18）。ユニバース ~3,944 社 |
| financials read 床 | **`companyFinancialsMinServableVersion = 2`**（`fin-v2` 以上を 200。`fin-v1` は 404）。明示定数・機械オフセットではない |
| filing-sections | `sections-v4` へバンプ済み（2026-07-27、geography 非流動資産表除外＋収益の分解フォールバック）。Neon 側はまだ旧版のみ（`sections-v3` 1,299・`v2` 1,711・`v1` 1,459、合計 4,469）。次回 ingest から `v4` へ収束見込み |
| filing-sections read 床 | **`filingSectionsMinServableVersion = 1`**（`sections-v1` 以上を 200）。明示定数 |
| breakdowns | 日経225限定。business/geography 両軸ともNeon ingest・REST/MCP公開済み（2026-07-27、225/225社）。cache_version は軸別（`breakdown-business-v7`/`breakdown-geography-v8`）。既知の残課題: 電通型 geography `not_found`（issue #163）。詳細は `docs/breakdown-normalization-concept.md` |
| statements | 日経225限定でスタート（2026-07-29）。DB/ingest/REST/MCP 配線済み。表示順(`order`)・区分(`section`)・合計行構成要素(`is_total`/`components`)まで対応（`statement-v1`）。PL の利益段階ラベリングはスコープ外（financials 領域）。本番 Neon への日経225全社 ingest は未実施 |
| statements read 床 | **`statementMinServableVersion = 1`**（`statement-v1` 以上を 200）。明示定数 |
| 定期ジョブ | ローカル launchd `com.sollahiro.blt-sync`（4h おき）。Fly は read 専用（ingest は OOM するためローカル） |
| MCP | **Phase 1・Phase 2 とも完了**（2026-07-12）。`blt-server`（Vapor）にルートパス（`POST /`）として埋め込み。8 ツール（`search_companies`・`get_waterfall`・`get_statement` 等。`docs/feature-tiers.md`「Summary / Waterfall の境界」参照）。`api.<domain>`（Phase 1・SSO 経由）に加え、新規サブドメイン `mcp.<domain>` に Managed OAuth for Access を有効化し、Claude.ai / ChatGPT 等 OAuth 2.1 前提のリモートクライアントにも対応（origin コード変更なし）。Claude Desktop での接続・ツール呼び出しまで実機確認済み。手順は `deploy.md`「MCP（Managed OAuth）」参照 |

カバレッジは Neon の `cache_version` 別件数で確認する（例: `SELECT cache_version, count(*) FROM company_financials GROUP BY 1`）。

## 方針: サーバー集約とクライアント面

到達点は「**Blue Ticker はサーバーで動く。クライアントは同じ REST 契約（とそれを写す MCP）経由でデータへアクセスする**」。

| 区分 | 対象 | 扱い |
|---|---|---|
| 残す | Core（`Analysis/`＋`Services/`）・Unit Test・**開発用 CLI**（`TickerDev`）・**運用 CLI**（`blt-server` sync/ingest） | 維持 |
| 切済み | **ユーザー向けローカル分析 CLI**（`backend=local`） | 2026-07-16 実施（下記ゲート） |
| 切済み | **配布 `ticker`**（Homebrew / release / remote CLI） | 廃止済み。構想は `docs/public-api-concept.md` |
| ユーザー接点 | **REST（契約の正）** / MCP（追従） / 将来 GUI・iOS | MCP は一過性のプロトコル面とみなす。新機能は REST 先 |

- Core はサーバー専用にしない（Dev CLI・Unit Test と共有）。
- MCP は `blt-server` のルートパス（`POST /`）に同居。ツールディスパッチは `Routes.swift` の DB 読み取り共通関数を REST と共有（`Sources/BltMcpServerCore/` + `Sources/BltServerCore/MCPRoute.swift`）。詳細は `docs/architecture.md`「MCP」節。
- オンデマンド ingest は非同期（404 → 将来 202＋キュー。公開スキーマ追加のため実装前に確認）。
- **REST 本線（段階 A）→ 第三者公開（段階 B）** の判断と着手順は `docs/public-api-concept.md`。段階 A の機械認証は Access Service Token（`docs/api-auth.md`）。origin APIキーは Monetize Gateway 公開後に再判断。

### financials / filing-sections read 床（min servable）

financials / filing-content の REST read は現行版との完全一致ではなく、**明示した最低世代以上**を返す。

| 定数 | 役割 |
|---|---|
| `companyFinancialsCacheVersion`（いま `fin-v4`） | financials ingest の書き込み・stale 判定 |
| `companyFinancialsMinServableVersion`（いま `2`） | financials read の最低 N（`fin-vN`） |
| `filingSectionsCacheVersion`（いま `sections-v4`） | filing-sections ingest の書き込み・stale 判定 |
| `filingSectionsMinServableVersion`（いま `1`） | filing-content read の最低 N（`sections-vN`） |

- 比較は `*-vN` を数値パースして行う（文字列辞書順は使わない）。
- 床の引き上げは、該当旧版の stale 消化完了後に行う（引き上げで servable 穴を作らない）。
- `/healthz` の `company_financials_min_servable` / `filing_sections_min_servable` で現行床を確認できる。

### ローカル CLI 廃止（完了）

2026-07-16 実施。トリガーはユニバース全銘柄の `company_financials` が financials read 床以上（servable）。実測 servable 3,872 / 実質対象ユニバース 3,874 社 = **99.9%**（残り2社は新規上場で初回有報未提出のため一時的 failed、提出後に自然解消見込み）。EDINET 直叩きロジックは配布しない `TickerDev`（`Sources/BlueTicker/DevCLI/`）からのみ呼べる形へ移設済み（構成は `CLAUDE.md`「ターゲット構成」参照）。経緯・実施手順は Git 履歴参照。

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **開発用ローカル解析（`TickerDev`）** | なし | `TickerDev` | 配布しない。デバッグ・テスト・フィクスチャ専用 |
| **remote (self-host)** | 同一マシン | blt-server | 基盤実装済み |
| **remote (cloud)** | Fly | blt-server | **本番** |

## データパイプライン

| 取り込み対象 | 保存先 | 状態 |
|---|---|---|
| sync | DB `edinet_documents` / `edinet_sync_state` | 同期済み・定期 sync |
| (生 XBRL) | ローカル / Fly Volume（生 XBRL） | 保持継続。R2 退避は容量問題化まで延期 |
| facts | DB `edinet_xbrl_facts` | 停止中（#22） |
| financials | DB `company_financials` | **バックフィル中（廃止ゲート＝床以上 servable）**。read は床以上・未格納/床未満 404 |
| filing-sections | DB `company_filing_sections` | バックフィル中。read は床以上（いま `sections-v1`+）・未格納/床未満 404 |

重い ingest はローカル→Neon。Fly serving は read-only（ライブ計算フォールバックなし）。

### オンデマンド ingest（設計確定・未実装）

未格納の `GET .../financials` を 404 のままにせず、未充足コードをキュー記録して `202`、既存 ingest バッチが消化する。公開スキーマ追加のため実装前にユーザー確認。

## クライアントと計算の責務

| クライアント | 計算 | データ源 | 位置づけ |
|---|---|---|---|
| `TickerDev`（開発用・配布しない） | in-process | `Services/` 直呼び（`DevCLI/` facade 経由） | 開発専用・維持 |
| REST `/v1` | しない | blt-server DB read | **契約の正・本線** |
| MCP `POST /` | しない | REST と同じ serve 関数 | 追従面（一過性とみなす） |
| ~~`ticker`（配布 CLI）~~ | — | — | **廃止済み** |
| iOS（将来） | しない | REST | 予定 |
| blt-server | **唯一の計算者** | ingest ＋ DB read | サーバー |

公開契約は financials 等の REST レスポンス（`schema_version` 独立採番）。facts RAW は非公開。人間向け Access SSO は維持（CLI 廃止後もブラウザ・MCP OAuth 用）。

## ゴール / 非ゴール

**ゴール**

- ユーザー向け実行環境を blt-server（remote/cloud）へ集約する（達成）
- 全銘柄が financials read 床以上で servable になったらユーザー向け `backend=local` を廃止する（2026-07-16 実施。servable 99.9%、残 2 社は既知残欠として許容）

**非ゴール**

- 各サブコマンドへの backend 選択オプション追加
- servable 一巡前のユーザー向け local 即時削除
- 床を「現行から N つ前」の機械オフセットにすること（明示定数のみ）
- 削除ゲート達成のために現行版へ全社揃えすること（床以上で足りる。stale 消化は別途継続）
- `CacheManager` と EDINET external cache の無理な単一抽象化

## ストレージ（将来・未決）

- **暫定（#22）**: facts 蓄積停止で Neon 512MB 到達を先送り
- **未決**: 強化方式は **(a) Neon プラン拡張** vs **(b) 生 XBRL / facts のオブジェクトストレージ（R2 等）＋3段フォールバック**。目標 A（タグ系は facts 消費・HTML 系は生 XBRL）着手時に決める。A2（中央永続化）が先なら Postgres に facts 全件を持つ必要は薄れる
- 当面の `companyFinancialsCacheVersion` は単一のまま。抽出方式別の粒度分割は A 着手時に再検討

## TODO

issue があるものは番号ポインタのみ（詳細は issue 正本）。

### 進行中

- [~] financials 現行版への stale 消化 / filing-sections — 同ジョブが継続

### 次（優先度順）

- [~] **REST 本線化（段階 A）** — 互換・Service Token 疎通・配布 `ticker` 廃止まで完了。任意で OpenAPI 下書き。構想は `docs/public-api-concept.md`
- [ ] **オンデマンド ingest（非同期）** — 未充足キュー＋202。公開スキーマ追加のため着手前に確認

### 将来

- [ ] MCP/REST 速度改善（Cloudflare Tunnel/Access 区間のレイテンシ調査）— issue #84
- [ ] 生 XBRL 中央永続化（目標 A）＋ financials のデータ源見直し（タグ系→facts）
- [ ] ストレージ強化の方式選定（#22 本丸）
- [ ] REST API の第三者公開（段階 B）— 段階 A のあと。レート制限・外部ドキュメント等。`docs/public-api-concept.md`
- [ ] iOS SSO（OIDC + PKCE・アプリ側プロジェクト）
- [ ] Cloudflare Monetize Gateway 連携検討（機能の無料/有料は `docs/feature-tiers.md`。面別メーター（REST / MCP）を理想とする。origin APIキー要否もここで再判断。情報未公開のため詳細設計は保留）
- [ ] filing-sections 拡張: 半期報告書(160)のセクション本文抽出（有報と同等のフルセクション抽出を想定。新規セクションキー設計・`filingSectionsCacheVersion` バンプ要否の検討が必要・未着手）
- [~] breakdowns: 事業別・地域別売上の正規化（企業間比較用）。日経225は business/geography 両軸ともNeon ingest・REST/MCP公開済み（2026-07-27）。残課題は電通型 geography `not_found`（issue #163）。構想は `docs/breakdown-normalization-concept.md`「今後の検討事項」
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM による抽出値の抜き打ち整合評価
- [~] statements: Statement（財務諸表 BS/PL/CF 完全正規化）。日経225限定で実装済み（現在地参照）。残: 本番 Neon への日経225全社 ingest。実装方針は `docs/statement-normalization-concept.md`
- [ ] statements 母集団拡大（日経225限定→全銘柄）。LLM 不要でコスト制約はないが、銀行・保険等特殊タクソノミでの実データ検証未実施のため段階展開する（`docs/statement-normalization-concept.md`「未検証事項」）
- [ ] statements に SS計算書（株主資本等変動計算書）を追加する構想（未着手）。現行 `StatementSectionType` は BS/PL/CF の3種のみ。dividends note_type 再設計中（2026-08-02）に浮上した論点: `dividendSs`（SS計算書基準）は `dividends` note_type の `dividendEvents`（注記の事業年度帰属基準）と一致しない別概念であり、SS計算書自体の構造化が別途要る
- [~] statement-notes: 実装済み・main反映済み（PR #172、2026-08-02）。note_type 9種を実装・配信（決定論のみ、REST `GET /v1/companies/{code}/statement/notes`・MCP `get_statement_notes`）。dividends/per_share_information/capital_expenditures_overview/issued_sharesは注記からXBRL直接抽出（決議・イベント単位のテーブル等）、research_and_developmentのみ財務取り込み単一値passthrough。treasury_stock_acquisitionはnote_typeごと廃止（自己株式取得は将来Statement本体側で持分変動計算書から取得する方針）。sga_breakdownは実装済みだが配信見送り（非連結のみタグ化されるためユーザー判断で保留、resolver・テストは残置）。property_plant_equipment_schedule/goodwill_and_intangiblesはIFRS連結企業限定でJ-GAAP単体附属明細表は未対応。政策保有株式は決定論実装（実データ4社・181銘柄をgolden化）。副産物としてbreakdownsに`employees`/`research_and_development`軸を追加（実装済み）。**残**: borrowings_schedule_cf_supplementは実データレビュー完了（日経225全224銘柄・単年度、`BLUE_TICKER_USER_DATA_PATH`分離キャッシュで測定）。**204/224解決（notApplicable 20）**。J-GAAP附属明細表・IFRS注記の各種フォールバック（見出しアンカー方式、満期構成ペアテーブル、自社拡張タグ＋rowspan補正、列見出し表記ゆれ「帳簿残高」、セル分割見出し「帳簿 価額」、日付が装飾行を挟んだ2行目ヘッダーに埋め込まれるケース）を実装。golden test 3件（丸紅・日立・ソニーグループ）。残notApplicable20件の内訳: 米国会計基準6社（対応見送り、キヤノン・野村HD・小松製作所・オリックス・オムロン・富士フイルムHD）／注記自体に明細が存在しない10社（キーエンス・ディスコ・ネクソン・トレンドマイクロ・ARCHION=附属明細表に「該当事項はありません」と明記、中外製薬・協和キリン=関連タグ自体が存在しない、三井物産・本田技研工業=注記が定性記述のみで表なし、ファーストリテイリング=前後期比較不可能な非対称開示）／トヨタの日付分割ロールフォワード1社／新しい表構造（移行日・前期・当期を1テーブルに併記する複数期間統合テーブル）で対応未着手3社（三菱重工業・住友金属鉱山・東京海上HD。三菱重工業・住友金属鉱山は当該テーブルが短期借入金/リース負債を欠く不完全な内訳のため、実装しても正確な合計は再現できない）。**内訳確認済み（20/20）**。property_plant_equipment_schedule/goodwill_and_intangiblesの実データ目視レビューは未着手。cache_versionは未公開のためバンプ見送り。breakdowns employees/research_and_development軸の公開可否の正式確認も残タスク。標準タクソノミラベル（`assets/taxonomy`、約105MB）を本番にバンドルするかは別途要検討（現状PPE/のれん明細等の標準タグはラベルnullのまま配信）。将来構想（Allocation、配分構造のサンキー図可視化）は `docs/allocation-concept.md` 参照

## 関連ドキュメント

- `docs/architecture.md` — 構成スナップショット
- `docs/public-api-concept.md` — REST 本線化（段階 A）と第三者公開（段階 B）
- `docs/api-auth.md` — REST / MCP 認証の住み分け（段階 A）
- `docs/api-compatibility.md` — REST 互換ポリシー（段階 A）
- `docs/deploy.md` — デプロイ・定期同期・E2E
- `docs/operations.md` — 外部サービス結合と定常運用
- `docs/breakdown-normalization-concept.md` — breakdowns 正規化構想（比較・推移）
- `.agents/rules/project/caching.md` / `versioning.md` / `dependencies.md`
