# blt-server ロードマップ

現在地と次の意思決定の索引。手順は `deploy.md` / `operations.md`、構成のスナップショットは `architecture.md`、完了履歴は Git。

## 現在地（2026-07-21）

| 項目 | 状態 |
|---|---|
| 本番 | Fly.io (nrt) + Neon + Cloudflare Access/Tunnel。`api.sollahiro.com` 稼働。main push（CI 成功後）で自動デプロイ |
| CLI | 配布 `ticker` **廃止済み**。開発用は配布しない `TickerDev`。運用は `blt-server` sync/ingest |
| Stage 1 | 同期済み（~3,944 社）。launchd が日次増分 sync |
| Stage 3 | スキーマあり・**取り込み停止中**（issue #22。512MB 対策。`--with-facts` で再開可） |
| Stage 4 | **バックフィル進行中**。`company_financials` 合計 2,288 行（うち `fin-v4` 307）。ユニバース ~3,944 社 |
| Stage 4 read 床 | **`companyFinancialsMinServableVersion = 2`**（`fin-v2` 以上を 200。`fin-v1` は 404）。明示定数・機械オフセットではない |
| Stage 4-half | 進行中。issue #73 の半期報告書マッチング修正で `half-v2` へバンプ（`half-v1` 行は全件 stale・再計算対象）。read 床 `companyHalfFinancialsMinServableVersion = 1` を新規導入し `half-v1` 行も引き続き 200 |
| Stage 5 | 進行中。issue #86, #93 対応で `sections-v3` へバンプ（2026-07-20）。旧版行は stale 消化中 |
| Stage 5 read 床 | **`filingSectionsMinServableVersion = 1`**（`sections-v1` 以上を 200）。明示定数 |
| 定期ジョブ | ローカル launchd `com.sollahiro.blt-sync`（4h おき）。Fly は read 専用（ingest は OOM するためローカル） |
| MCP | **Phase 1・Phase 2 とも完了**（2026-07-12）。`blt-server`（Vapor）にルートパス（`POST /`）として埋め込み。8 ツール（`search_companies`・`get_analysis`・`get_half_analysis` 等。`docs/feature-tiers.md`「Summarize / Analyze の境界」参照）。`api.<domain>`（Phase 1・SSO 経由）に加え、新規サブドメイン `mcp.<domain>` に Managed OAuth for Access を有効化し、Claude.ai / ChatGPT 等 OAuth 2.1 前提のリモートクライアントにも対応（origin コード変更なし）。Claude Desktop での接続・ツール呼び出しまで実機確認済み。手順は `deploy.md`「MCP（Managed OAuth）」参照 |

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

### Stage 4 / Stage 5 read 床（min servable）

financials / filing-content の REST read は現行版との完全一致ではなく、**明示した最低世代以上**を返す。half は単一版のため床未導入（`half-v2` 時に同型追加）。

| 定数 | 役割 |
|---|---|
| `companyFinancialsCacheVersion`（いま `fin-v4`） | Stage 4 ingest の書き込み・stale 判定 |
| `companyFinancialsMinServableVersion`（いま `2`） | financials read の最低 N（`fin-vN`） |
| `filingSectionsCacheVersion`（いま `sections-v3`） | Stage 5 ingest の書き込み・stale 判定 |
| `filingSectionsMinServableVersion`（いま `1`） | filing-content read の最低 N（`sections-vN`） |

- 比較は `*-vN` を数値パースして行う（文字列辞書順は使わない）。
- 床の引き上げは、該当旧版の stale 消化完了後に行う（引き上げで servable 穴を作らない）。
- `/healthz` の `company_financials_min_servable` / `filing_sections_min_servable` で現行床を確認できる。

### ローカル CLI 廃止ゲート（2026-07-09 確定・2026-07-16 実施）

**トリガー**: ユニバース全銘柄が **Stage 4 read 床以上（servable）** の `company_financials` 行を持つ。

完了の定義（当初）:

- `edinet_documents` から導出できる証券コードについて、`company_financials.cache_version` が床以上（いま `fin-v2`+）
- 残欠は恒久 failed（財務報告書なし等）として切り分け済みで、定期 ingest の Stage 4 **missing** が実質ゼロ（床未満だけの行は「空白一巡」に数えない）

**実施時点の実測**（2026-07-16、Neon `company_financials` 直接集計）: servable 3,870 / ユニバース 3,944 = **98.1%**。

**未格納 73 社の切り分け完了**（2026-07-17）: 71 社は EDINET マスタで上場廃止・外国法人に該当し `listedCodes` フィルタで恒久的に対象外（設計通り。ウエルシアHD(3141)・イオンモール(8905) 等は実在の上場廃止・株式交換による完全子会社化を実データで確認済み）。残り 2 社（436A・441A）は新規上場で初回有報未提出のため一時的に failed（提出後に自然解消見込み）。ユニバース分母（3,944）は過去に書類提出歴のある全銘柄の延べ数で、実質対象ユニバースは ~3,874 社（servable 3,872 / 3,874 = **99.9%**）。追加対応不要。

補足:

- 現行版（`fin-v4`）への揃えは**削除の必須条件にしない**（床以上なら remote は 200。stale 版アップグレードは同ジョブが継続）
- Stage 4-half / Stage 5 の全社 drain も必須条件にしない（Stage 5 は床=1 で旧行も読める）
- 床を後で引き上げるときは、引き上げ後もゲート条件（全銘柄 servable）を満たすこと

完了後の手順（実施済み）:

1. ~~`backend=local` を deprecation（警告＋ドキュメント）~~ → 経由せず直接撤去（2026-07-16 時点で `backend=local` の実利用報告なし）
2. `ticker`（配布 CLI）からユーザー向け local 経路を削除。EDINET 直叩きロジックは `Sources/BlueTicker/DevCLI/`（`BlueTickerCore` 内・internal）へ移設し、配布しない新ターゲット `TickerDev`（`Package.swift` の `products` 非搭載）からのみ呼べる。詳細は `docs/architecture.md`「ターゲット構成と依存方向」
3. remote 未格納／床未満は 404 のまま。local フォールバックは戻さない
4. 未格納 73 社は切り分け済み（上記参照）。本ゲートの遂行条件から除外して実施し、追加対応は不要と判断

## デプロイモード

| モード | blt-server | EDINET を叩くのは | 状態 |
|---|---|---|---|
| **開発用ローカル解析（`TickerDev`）** | なし | `TickerDev` | 配布しない。デバッグ・テスト・フィクスチャ専用 |
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

| クライアント | 計算 | データ源 | 位置づけ |
|---|---|---|---|
| `TickerDev`（開発用・配布しない） | in-process | `Services/` 直呼び（`DevCLI/` facade 経由） | 開発専用・維持 |
| REST `/v1` | しない | blt-server DB read | **契約の正・本線** |
| MCP `POST /` | しない | REST と同じ serve 関数 | 追従面（一過性とみなす） |
| ~~`ticker`（配布 CLI）~~ | — | — | **廃止済み** |
| iOS（将来） | しない | REST | 予定 |
| blt-server | **唯一の計算者** | ingest ＋ DB read | サーバー |

公開契約は financials / half-financials 等の REST レスポンス（`schema_version` 独立採番）。Stage 3 RAW は非公開。人間向け Access SSO は維持（CLI 廃止後もブラウザ・MCP OAuth 用）。

`sector` は REST 化済み（`GET /v1/sectors`）。CLI 配布物からも `EdinetcodeDlInfo.csv` の同梱を撤去した。

## ゴール / 非ゴール

**ゴール**

- ユーザー向け実行環境を blt-server（remote/cloud）へ集約する（達成）
- 全銘柄が Stage 4 read 床以上で servable になったらユーザー向け `backend=local` を廃止する（2026-07-16 実施。servable 98.1%・未格納 74 社は既知残欠として許容）

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

- [~] Stage 4 現行版への stale 消化 / Stage 4-half / Stage 5 — 同ジョブが継続

### 次（優先度順）

- [~] **REST 本線化（段階 A）** — 互換・Service Token 疎通・配布 `ticker` 廃止まで完了。任意で OpenAPI 下書き。構想は `docs/public-api-concept.md`
- [ ] **オンデマンド ingest（非同期）** — 未充足キュー＋202。公開スキーマ追加のため着手前に確認

### 将来

- [ ] MCP/REST 速度改善（Cloudflare Tunnel/Access 区間のレイテンシ調査）— issue #84
- [ ] 生 XBRL 中央永続化（目標 A）＋ Stage 4 のデータ源見直し（タグ系→facts）
- [ ] ストレージ強化の方式選定（#22 本丸）
- [ ] REST API の第三者公開（段階 B）— 段階 A のあと。レート制限・外部ドキュメント等。`docs/public-api-concept.md`
- [ ] iOS SSO（OIDC + PKCE・アプリ側プロジェクト）
- [ ] Cloudflare Monetize Gateway 連携検討（機能の無料/有料は `docs/feature-tiers.md`。面別メーター（REST / MCP）を理想とする。origin APIキー要否もここで再判断。情報未公開のため詳細設計は保留）
- [ ] Stage 5 拡張: 半期報告書(160)のセクション本文抽出（有報と同等のフルセクション抽出を想定。新規セクションキー設計・`filingSectionsCacheVersion` バンプ要否の検討が必要・未着手）
- [~] Stage 6: 事業別・地域別売上の正規化（企業間比較用）。business 軸（日経225構成銘柄限定）は抽出・正規化・永続化・ingest(`--stages 6`)/REST(`breakdown`)/MCP(`get_breakdown`)まで実装済み（PR #87/#88/#91 + business軸配線）。銀行・保険の粗利益/営業純益基準、NTT等のタグ一般化、小松製作所の年度ラベルチェーン修正等を2026-07-21〜22に反映。E/F判定（地域のみ・単一セグメント記載省略）の検知結果明示化はDBスキーマ・REST/MCP応答まで反映済み（issue #130/#132、`source="not_applicable"`プレースホルダ行＋404ボディの`reason`フィールド）。html_table経由でLLMがgeography-only等と判定したケースがunknownに落ちる分類漏れも解消済み（issue #135）。オリックス等の巨大単一USGAAP注記でのセグメント当期テーブル抽出（issue #103、PR #126）、ZOZO/ベイカレント/JPXの非収益OperatingSegmentsAxis facts誤判定（issue #137、PR #138）、野村の金融費用控除後分母取り違え（issue #105、PR #109で分母をセグメント表小計へフォールバックする方式で解消済み）、資生堂型の地域facts併存によるE/F誤判定（PR #139）も解消済み。日経225は225/225社が最低1件ingest済み（2026-07-26時点）。**未着手**: geography 軸の ingest 配線。構想と残タスクは `docs/breakdown-normalization-concept.md`「今後の検討事項」
- [ ] 抽出ロジック変更時の差分検証ツール
- [ ] LLM による抽出値の抜き打ち整合評価

## 関連ドキュメント

- `docs/architecture.md` — 構成スナップショット
- `docs/public-api-concept.md` — REST 本線化（段階 A）と第三者公開（段階 B）
- `docs/api-auth.md` — REST / MCP 認証の住み分け（段階 A）
- `docs/api-compatibility.md` — REST 互換ポリシー（段階 A）
- `docs/deploy.md` — デプロイ・定期同期・E2E
- `docs/operations.md` — 外部サービス結合と定常運用
- `docs/breakdown-normalization-concept.md` — Stage 6 正規化構想（比較・推移）
- `.agents/rules/project/caching.md` / `versioning.md` / `dependencies.md`
