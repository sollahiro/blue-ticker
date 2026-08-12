# blt-server ロードマップ

現在地と次の意思決定の索引。手順は `deploy.md` / `operations.md`、構成のスナップショットは `architecture.md`、完了履歴は Git。

## 現在地（2026-08-09）

| 項目 | 状態 |
|---|---|
| 本番 | Fly.io (nrt) + Neon + Cloudflare Access/Tunnel。`api.sollahiro.com` 稼働。main push（CI 成功後）で自動デプロイ |
| CLI | 配布 `ticker` **廃止済み**。開発用は配布しない `TickerDev`。運用は `blt-server` sync/ingest |
| sync | 同期済み（~3,944 社）。launchd が日次増分 sync |
| facts | スキーマあり・**取り込み停止中**（issue #22。512MB 対策。`--with-facts` で再開可） |
| financials | バックフィル継続中。ユニバース ~3,944 社。現行版・read 床は `.agents/rules/project/versioning.md`（定数一覧）参照。cache_version 別件数はカバレッジクエリ（下記）で確認 |
| filing-sections | バックフィル継続中。現行版・read 床は `.agents/rules/project/versioning.md` 参照 |
| breakdowns | 日経225限定。business/geography 両軸ともNeon ingest・REST/MCP公開済み。cache_version は軸別（現在値は `versioning.md`）。employees/research_and_development軸は新設済みだが未公開（REST/MCP解禁は別途確認）。goodwill軸はStage1実装のみ（抽出・正規化・smoke11社中4社=ニチレイ/オークマ/三井住友/三菱UFJで実データ一致golden化済み。**ingest/DB/REST/MCP未配線**）。既知の残課題: 電通型 geography `not_found`（issue #163）。詳細は `docs/breakdown-normalization-concept.md` |
| statements | 日経225限定。DB/ingest/REST/MCP 配線済み（`statement-v1`）。**BS/PL/CF/SS**（SS=合計列のみ・`order` 付き・期首→変動→期末）。区分(`section`)・`is_total`/`components` 対応。US-GAAP は HTML 本表経路（当期優先・キヤノン型 `components`）。golden: トヨタ等＋smoke 9社（BS/PL/CF と SS）＋US-GAAP2社（富士フイルム/キヤノン）。PL 利益段階ラベリングはスコープ外。**本番 Neon の `company_statements` は 558 行・227 社（全件 `statement-v1`、2026-08-11 ingest 完了）**。`get_statement` はMCP経由で実データ配信を実機確認済み。**`company_statement_notes` は依然 0 行**（statement-notes ingest 未実施） |
| 定期ジョブ | ローカル launchd `com.sollahiro.blt-sync`（4h おき）。Fly は read 専用（ingest は OOM するためローカル） |
| MCP | **Phase 1・Phase 2 とも完了**（2026-07-12）。`blt-server`（Vapor）にルートパス（`POST /`）として埋め込み。8 ツール（`search_companies`・`get_waterfall`・`get_statement` 等。`docs/feature-tiers.md`「Summary / Waterfall の境界」参照）。`api.<domain>`（Phase 1・SSO 経由）に加え、新規サブドメイン `mcp.<domain>` に Managed OAuth for Access を有効化し、Claude.ai / ChatGPT 等 OAuth 2.1 前提のリモートクライアントにも対応（origin コード変更なし）。Claude Desktop での接続・ツール呼び出しまで実機確認済み。手順は `deploy.md`「MCP（Managed OAuth）」参照。ChatGPT plugin Phase 1 メタデータ（tool title/annotations/outputSchema・server instructions・`structuredContent` 準拠）は完了 |

カバレッジは Neon の `cache_version` 別件数で確認する（例: `SELECT cache_version, count(*) FROM company_financials GROUP BY 1`）。

## 方針: サーバー集約とクライアント面

到達点は「**Blue Ticker はサーバーで動く。クライアントは同じ REST 契約（とそれを写す MCP）経由でデータへアクセスする**」。

| 区分 | 対象 | 扱い |
|---|---|---|
| 残す | Core（`Analysis/`＋`Services/`）・Unit Test・**開発用 CLI**（`TickerDev`）・**運用 CLI**（`blt-server` sync/ingest） | 維持 |
| 切済み | **ユーザー向けローカル分析 CLI**（`backend=local`） | 2026-07-16 実施（下記ゲート） |
| 切済み | **配布 `ticker`**（Homebrew / release / remote CLI） | 廃止済み。構想は `docs/public-api-concept.md` |
| ユーザー接点 | **REST（契約の正）** / MCP（追従） / 将来 GUI | MCP は一過性のプロトコル面とみなす。新機能は REST 先 |

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

2026-07-16 実施。トリガーはユニバース全銘柄の `company_financials` が financials read 床以上（servable）。実測 servable 3,872 / 実質対象ユニバース 3,874 社 = **99.9%**（残り2社は新規上場で初回有報未提出のため一時的 failed、提出後に自然解消見込み）。EDINET 直叩きロジックは配布しない `TickerDev`（`Sources/BlueTicker/DevCLI/`）からのみ呼べる形へ移設済み（構成は `AGENTS.md`「ターゲット構成と依存ルール」参照）。経緯・実施手順は Git 履歴参照。

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
- [ ] **financials（Summary）と正本の分離** — EPS/発行済株式を notes 正本からのパススルー化。breakdown の financials 依存解消は将来ステップ。構想は `docs/financials-summary-separation-concept.md`

### 将来

- [ ] MCP/REST 速度改善（Cloudflare Tunnel/Access 区間のレイテンシ調査）— issue #84
- [ ] 生 XBRL 中央永続化（目標 A）＋ financials のデータ源見直し（タグ系→facts）
- [ ] ストレージ強化の方式選定（#22 本丸）
- [ ] REST API の第三者公開（段階 B）— 段階 A のあと。レート制限・外部ドキュメント等。`docs/public-api-concept.md`
- [ ] Cloudflare Monetize Gateway 連携検討（機能の無料/有料は `docs/feature-tiers.md`。面別メーター（REST / MCP）を理想とする。origin APIキー要否もここで再判断。情報未公開のため詳細設計は保留）
- [ ] filing-sections 拡張: 半期報告書(160)のセクション本文抽出（有報と同等のフルセクション抽出を想定。新規セクションキー設計・`filingSectionsCacheVersion` バンプ要否の検討が必要・未着手）
- [~] breakdowns: 事業別・地域別売上の正規化（企業間比較用）。日経225は business/geography 両軸ともNeon ingest・REST/MCP公開済み（2026-07-27）。残課題は電通型 geography `not_found`（issue #163）。構想は `docs/breakdown-normalization-concept.md`「今後の検討事項」
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM による抽出値の抜き打ち整合評価
- [~] statements: Statement（財務諸表 BS/PL/CF/SS 完全正規化）。日経225限定で実装済み、本番 Neon への日経225全社 ingest 完了（2026-08-11・558行/227社・現在地参照）。実装方針は `docs/statement-normalization-concept.md`
- [~] **US-GAAP Statement HTML 経路**（2026-08-10）。`USGAAPStatementHtml` で連結 HTML→行を決定論抽出（富士フイルム S100W3XJ / キヤノン S100XTLJ）。金額は当期優先（入れ子は左列、`－`=0）。キヤノン型 `components`（合計直後の内訳が親と一致）を付与。富士フイルムは内訳が合計前のため同規則では `components` なし。golden: `RealXbrlStatementTests` + `USGAAPStatementHtmlTests`。取れない場合のみ `notApplicable(us_gaap_unsupported)`。`borrowings_schedule` は同 reason で対象外のまま。financials/IBD の `USGAAPHtml` は現行 summary 用として別。`statement-v1` のまま
- [ ] statements 母集団拡大（日経225限定→全銘柄）。LLM 不要でコスト制約はないが、銀行・保険等特殊タクソノミでの実データ検証未実施のため段階展開する（`docs/statement-normalization-concept.md`「未検証事項」）
- [x] statements に SS計算書（持分変動計算書／株主資本等変動計算書）を追加（2026-08-09）。`StatementSectionType.changesInEquity`、レスポンス `changes_in_equity`。合計列のみ（資本構成員別の行列展開はしない）。CF と同型で期首/期末 Instant を受理し、`order` は期首→変動→期末。連結での個別SS由来 `ProfitLoss` 混入を除外。golden: トヨタ＋smoke 9社。`statement-v1` のまま（本番ingest済み・現在地参照）。`dividendSs`（financials）と `dividends` note_type は別概念のまま
- [~] statement-notes: 実装済み・main反映済み（PR #172）。note_type に `lease_liabilities` を追加（2026-08-12）: IFRS リース注記 TextBlock（`IFRSLease`）から決定論抽出。**BS構造化タグ・BS HTMLはstatementsと責務重複のため不採用**（同じ値をnotesに引っ張らない。タグがある場合は`available_via_statement`）。smoke 11社: 味の素は「支払期日が1年以内／1年超」＝流動・非流動の帳簿価額（成分合算40,706、開示合計セル40,707は丸め差）、クボタは現在価値合計83,336＋満期バケット（割引前CF・表単位で貸手と分離。ROU合計87,946は別表で対象外）、スズキは帳簿価額合計32,539＋満期バケット（同様）、ニチレイ/AZplanning/US-GAAP2社は`available_via_statement`、オークマ/東邦レマック/銀行2社は`not_found`（オークマのリース債務は`borrowings_schedule`側・PPE不可）。`notes-lease-liabilities-v3`。note_type は従来8種＋leaseで拡充（`research_and_development` は 2026-08-11 に breakdown 軸へ集約・note 廃止）、REST `GET /v1/companies/{code}/statement/notes`・MCP `get_statement_notes`で決定論のみ配信。**本番Neonの`company_statement_notes`は依然0行**（`company_statements`は2026-08-11にingest完了・558行/227社。statement-notesは別ステージでingest未実施。実データ検証はDevCLIローカルキャッシュのオフライン結果であり本番配信データではない）。sga_breakdownは実装済みだが配信見送り（非連結限定のためresolver/テストのみ残置）。treasury_stock_acquisitionはnote_typeから廃止（Statement本体の持分変動計算書側で対応する方針。SS合計列の自己株式取得行は取得可能）。borrowings_schedule（旧名`borrowings_schedule_cf_supplement`）は日経225 224社中214社解決（残10件はnotApplicable: 米国会計基準6社は対応見送り、注記自体に明細なし4社）。property_plant_equipment_scheduleはIFRS連結企業限定（意図的な設計判断、2026-08-12）。非IFRS企業は会計基準で理由が分かれる: J-GAAP6社はStatement本体の連結/個別BSに区分別タグが構造化済みのため`available_via_statement`、US-GAAP2社（富士フイルム・キヤノン）は`ix:nonFraction`が無く構造化タグで判定できずStatementでも会社ごとに取得可否が割れる（富士フイルムはBS本表に内訳あり、キヤノンはBS本表が合計1行のみで内訳は別注記のみ）ため`us_gaap_unsupported`。smoke固定11社で実データ検証済み（`PropertyPlantEquipmentScheduleOracleFormatTests.swift`）。goodwill_and_intangiblesは同型resolver（IFRS連結限定）。smoke固定11社で実データレビュー済み（2026-08-12）: IFRS3社中、味の素・クボタはresolvedで開示HTML（のれん帳簿価額増減表）と完全一致・golden化。スズキは`GoodwillIFRS`タグ自体が存在せず`not_found`が正当（役割名バリアント対応は見送り、ユーザー判断）。非IFRS8社は`not_found`のまま（reason細分化はPPEと違い保留中・優先度低）。うち4社（ニチレイ・オークマ・三井住友・三菱UFJ）は新設breakdown軸`goodwill`（Stage1・未配線）でセグメント別に取得可能、うち3社（ニチレイ・三井住友・三菱UFJ）＋キヤノンはStatement本体のBSにも同じ合計が乗る（`get_statement`で取得可能）。`GoodwillAndIntangiblesOracleFormatTests.swift`・`RealXbrlGoodwillBreakdownTests.swift`参照。抽出ロジックの詳細な分岐根拠は `BorrowingsSchedule.swift` 等のコード内コメント参照（実データ検証済みの会社名・日付付き）。**smoke企業11社での借入金突合（2026-08-08、PR #182）**で追加バグ4件を修正・golden拡張（三菱UFJのpadding-left小計除外、クボタのbare「計」＋流動/非流動並記、ニチレイの値なし見出し欠落、東邦レマックの単体版タグフォールバック。整合4社もgolden化）。**リース債務**: IFRSで借入金注記とリース注記が分離する会社について、`borrowings_schedule` note_typeへ別注記リースを合流させるのは別スコープ（有利子負債IBD側は既存の`field_parser+lease_textblock`で加算済み）。オンバランスのリース負債残高は `lease_liabilities` note_type で取得する。**capital_expenditures_overview のsmoke検証（2026-08-10）**: smoke固定11社で実施し、表形式の揺れで4社（ニチレイ=単位表が別テーブル＋colspan見出し、アズ企画設計=千円単位、富士フイルム=個別設備一覧の混入、クボタ=前/当期2段見出し）がセグメント表を見逃して単一値フォールバックしていた問題と、オークマが個別設備一覧（会社名・所在地列を持つ抜粋表）を誤読していた問題を修正。ヘッダー文言による列分類（当/前/％/金額/名称/内容）＋`gridRows`のcolspan展開＋個別設備一覧の除外で対応し、golden 5件追加（`RealXbrlStatementNotesTests.swift`）。11社すべてresolved（US-GAAP・金融・非連結・連結開始境界の各次元で欠落なし）。数値はユーザー全件目視確認済みで、残り6社（味の素・スズキ・キヤノン・東邦レマック・三菱UFJ・三井住友）もgolden化し smoke 11社すべてを回帰対象にした（金融2社は子会社別開示のため総額タグ単一値を契約として固定）。設備投資の総額はStatement（CF）の`PurchaseOfPropertyPlantAndEquipmentInvCF`とは別概念（現金支出ベース vs 投資実行ベース）で一致しないため、本note_typeはStatementでは代替不可。**残**: 本番ingest実施（PPE・goodwill_and_intangibles・lease_liabilities含む）、goodwill breakdown軸のingest/DB/REST/MCP配線と日経225規模でのタグ揺れ検証、employees/research_and_development軸（breakdowns副産物）の公開可否確認、`assets/taxonomy`（~105MB）を本番バンドルするかの判断（現状PPE/のれん明細等の標準タグはlabel=null配信）。設計方針は `docs/statement-normalization-concept.md`。将来構想（Allocation、配分構造のサンキー図可視化）は `docs/allocation-concept.md` 参照


## 関連ドキュメント

- `docs/architecture.md` — 構成スナップショット
- `docs/public-api-concept.md` — REST 本線化（段階 A）と第三者公開（段階 B）
- `docs/api-auth.md` — REST / MCP 認証の住み分け（段階 A）
- `docs/api-compatibility.md` — REST 互換ポリシー（段階 A）
- `docs/deploy.md` — デプロイ・定期同期・E2E
- `docs/operations.md` — 外部サービス結合と定常運用
- `docs/breakdown-normalization-concept.md` — breakdowns 正規化構想（比較・推移）
- `.agents/rules/project/caching.md` / `versioning.md` / `dependencies.md`
