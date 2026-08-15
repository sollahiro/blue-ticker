# AGENTS.md

エージェント向けの作業合意。ビルド・ターゲット境界の正本は本ファイル、運用ルールは `.agents/rules/`、アーキテクチャは `docs/`。
`.agents/rules/` は毎回読まない。日付・バンプ・キャッシュ・XBRL・訂正など、該当作業のときだけ同名ファイルを読む。

## 原理原則

- **コンテキスト**: 最も希少な資源。認知負荷と情報量を最小化し、指針・本ファイル自身も短く保つ。
- **実データ・実測**: モックや推測より EDINET / Neon / 本番 read の実データと件数で判断する。ゲートは計測してから次へ。XBRL注記等の抽出ロジック実装時は、元のHTML（開示書類）と抽出結果を必ず照らし合わせて確認する。
- **タグ透明性**: statement・notes・breakdown の配信契約は値の由来を示す実際の XBRL タグ名を可能な限り載せる。`"company_financials"` のような固定文字列プレースホルダーは、実タグが解決できない場合のみのフォールバックとする（実データ検証の起点を残すため）。
- **Git First**: Git が唯一の Source of Truth。永続判断は Git か memory、一時情報は残さない。履歴詳細は Git に委ねる。
- **責務分離**: ロジック／サービスは入れ替え可能なモジュールに。Core は Vapor/Fluent 非依存、Web/DB は `BltServerCore` に閉じる（詳細は下記「ターゲット構成と依存ルール」）。
- **Region × Source**: モノレポ。市場は `JP`↔`EU`、開示系は `EDINET`↔`ESEF`（同階層の対）。パス・新規モジュールはこの対応で命名する（`.agents/rules/project/regions.md`、`docs/architecture.md`）。
- **開発**: 機能追加 → 抽象化 → 単純化。抽象化は重複が実際に出てから。コードは少なく、必要振る舞いは満たす。要求前の拡張機構は作らない。
- **テスト**: 仕様＝振る舞いを検証する。境界値・異常系を重視し、呼び出し順や内部構造は見ない。golden回帰（`RealXbrl*Tests.swift`）とsmoke（`SmokeTests.swift`）は役割が別（詳細は `docs/xbrl-parsing.md` §6）: smokeは会計基準・決算期移行境界・連結有無など「次元」を意図して選んだ固定企業セットで既存ロジックの最低品質を継続的に守る床、goldenは個別ロジックの実装・改善時に見つけたエッジケース企業をその都度蓄積する深さ方向の回帰。smoke 床の対象は基本財務諸表抽出器（BS/PL/CF/GP/IBD）に加え **`borrowings_schedule`・`capital_expenditures_overview`・`per_share_information`・`issued_shares_and_capital`・`policy_holding_securities`・`dividends`・`goodwill_and_intangibles` note_type**、および **breakdown の `business` / `geography` 軸**（外出しオラクル。`policy_holding_securities` のみ SMFG(8316) を対象外とした固定10社。breakdown の LLM 経路は渡す前の tables を突合）。`statement`（Statement 取り込み本体）は `SmokeTests.swift` 自体は通らないが、smoke 固定11社中 US-GAAP2社を除く9社全件の golden を `RealXbrlStatementTests.swift` に追加済み（US-GAAP2社は同ファイルの HTML 経路 golden）。他 note_type の決定論ロジックはまだ床に含めていない。ロジックが固まったら同様に床を広げる。テストを「言語非依存で残る資産（オラクル・不変条件・契約・政策）」と「実装に紐づく部分」に分けて考える指針は `docs/test-spec-assets.md`。

## ビルド・テスト

```bash
swift build                          # blt-server / TickerDev バイナリを生成
swift test                           # 全テスト（Swift Testing）
.build/debug/blt-server --help       # ローカル実行（要 BLT_EDINET_API_KEY 等）
swift run TickerDev waterfall <code>   # 開発用ローカル解析（配布しない。要 BLT_EDINET_API_KEY）
```

**サーバー動作確認はローカル優先**: 外部クライアント（ChatGPT 等）の実接続確認を含め、挙動を1回ごとに見て試行錯誤する段階は `BLT_EDINET_API_KEY=dev-local-dummy ./.build/debug/blt-server`（`127.0.0.1:3000`）で行う。外部から到達させる必要がある場合は `cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate` 等の一時トンネルを使う。PR → CI → デプロイの待ちは1周が数分かかり、本番へも影響しうる。ローカルは秒単位で再現でき、失敗させても本番に影響しない。ロジックが固まってから通常のブランチ運用（PR・CI・レビュー・マージ）に進む。

## ターゲット構成と依存ルール

| ターゲット | 内容 |
|---|---|
| `BlueTickerCore`（`Sources/BlueTicker/`） | XBRL解析・サービス・REST ファサード（`Server/`）・開発用ローカル解析（`DevCLI/`）を含む共有ライブラリ。**Vapor/Fluent には依存しない** |
| `BltMcpServerCore`（`Sources/BltMcpServerCore/`） | MCP プロトコル層（ツールカタログ・`MCP.Server` ファクトリ）。ビジネスロジック・DB は持たない。**Vapor/Fluent には依存しない** |
| `BltServerCore`（`Sources/BltServerCore/`） | REST サーバーのトランスポート層（Vapor）と DB 層（Fluent）。`BlueTickerCore` のファサードと `BltMcpServerCore` を呼ぶ。MCP はルートパス（`POST /`）として配線。Web/DB 依存をここに閉じ込める |
| `BltServer`（`Sources/BltServer/`） | `blt-server` のエントリポイントのみ（唯一の配布 executable product） |
| `TickerDev`（`Sources/TickerDevMain/`） | 開発用ローカル解析 CLI のエントリポイントのみ。**`Package.swift` の `products` に含めない**（`swift run TickerDev` でのみ実行） |

ターゲット間の依存方向: `BltServerCore` → `BlueTickerCore` / `BltMcpServerCore` は可。逆は不可（Core は Vapor/Fluent を参照しない）。

`BlueTickerCore` 内のディレクトリ責務（同一モジュールのため import 方向はコンパイラで強制されない。レビューで担保する）:

- `Services/` は `DevCLI/` のコマンド型を参照してはならない
- `Analysis/` / `API/` / `Infrastructure/` / `Utils/` は `Services/`・`Server/`・`DevCLI/` を参照してはならない
- `Server/` は REST サーバーの **ファサード**（`BltServerContext`・`BltServerResponse`・`makeBltServerContext`、breakdowns 取り込み結果を表す `BreakdownResolveResult` 等）のみを置く。Vapor トランスポート・Fluent DB 層は `BltServerCore` ターゲットに置く
- `DevCLI/` は `TickerDev` ターゲット向けの **ファサード**。公開面は `DevCLIEntry` の1点のみ。ローカル解析コマンド実装は internal のまま置き、新たに public 化しない

## 機能の実装サイクル

新機能・Stage 拡張は次の順。**バンプ**は Neon `cache_version` のみ（`blueTickerVersion` ではない → `versioning.md`）。**公開範囲**（REST/MCP 解禁など）は機能ごとに都度確認。

| # | 段階 | 書き込み先 | バンプ |
|---|---|---|---|
| 1 | 実装初期は smoke 固定企業セット（`docs/xbrl-parsing.md` §6）で検証し、ロジックをブラッシュアップする | ローカル | しない |
| 2 | smoke だけでは拾えない個別の失敗事例は、見つかり次第 golden（`RealXbrl*Tests.swift`）へ追加して蓄積する | ローカル | しない |
| 3 | ロジックが安定したら日経225限定で使い捨てへ投入して確認し、問題なければ本番へ初期投入（最新年度を埋める。探索的試し書き禁止）。不審フラグ（`needs_review`・あいまい失敗・異常欠測など）はこの段階でも手動 ingest で解消する | 使い捨て→本番 write | しない |
| 4 | 最新年度 100% 後にロジック改善（母数＝最新有報が取れた社。欠測は正当か不具合か確認） | — | しない |
| 5 | 改善結果を使い捨てで検証 | 使い捨て | しない |
| 6 | 問題なければ公開（都度確認）し、225 **全件**を本番へ揃える | 本番 write | しない |
| 7 | 全件を見たうえでのロジック改善 | — | しない |
| 8 | 不審フラグ（`needs_review`・あいまい失敗・異常欠測など）は手動 ingest | 本番 write | しない |
| 9 | 225 全体で問題なければ全銘柄へ拡張 | 本番 write | しない |
| 10 | 全銘柄展開に伴うロジック定着 | 本番 write | **する** |

- **母集団**: statements と breakdowns の employees/rd/goodwill は `assets/nikkei225.csv` / `priorityIngestCodes()` で対象限定。breakdowns の business/geography と financials/filing-sections は上場全体（同 CSV は処理順の優先のみ）→ 225 に閉じるなら `--codes` 等で明示。
- **接続**: 使い捨て＝`DATABASE_URL`、本番 read＝`BLT_PROD_DATABASE_URL`（SELECT のみ）、本番 write＝`DATABASE_URL="$BLT_PROD_WRITE_DATABASE_URL" blt-server ...`（コマンド単位。既定の差し替え禁止）。RO は WRITE 親ブランチの子（自動同期なし）→ ingest 後は `scripts/neon-reset-ro-from-parent.sh` で揃える。
- **訂正有報 (130)**: 自動マージしない。手動確認し、見た docID は原本準拠でも Git に残す（`.agents/rules/project/amendments.md`）。不審フラグと同じく手動 ingest（段階 3・8）。

## 監査レビューとモデル分担

大幅変更・リファクタ・効率化の後は、実装セッション以外の主体に監査させ是々非々で判断する（単一ファイルでも対象）。

- **渡すもの**: 仕様（契約）と diff のみ。結論へ誘導しない。
- **問い**: 仕様を満たすか／既存を壊していないか。
- **タイミング**: main マージ前（ブランチ高度＝品質ゲート）。
- **手段**: `Agent` / `Task`、または `pi` 非対話（Cursor CLI 不使用）。
- **pi 経由の timeout**: 10〜15 分程度を確保する（短すぎると思考中に打ち切られる）。

| 作業 | モデル |
|---|---|
| 本体（対話・設計・実装） | Grok 4.5 |
| 監査レビュー | Grok 4.5、または難易度に応じて上位 |
| 実装サブエージェント | Composer 2.5 |
| 探索・並列調査 | Grok 4.5 |

対象作業は表のモデルへ委譲する（本体セッションや Cloud でも同じ）。

## Cursor Cloud

Linux（Ubuntu 24.04）+ swiftly。詳細背景はリンク先。

- **build/test**: `-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility` 必須（`.github/workflows/ci.yml` の `swift-linux`）。
- **起動**: 非空 `BLT_EDINET_API_KEY`（ダミー可）。既定 `127.0.0.1:3000`。`DATABASE_URL` なし＝ステートレス、`CF_ACCESS_TEAM_DOMAIN` なし＝無認証。例: `BLT_EDINET_API_KEY=dev-local-dummy ./.build/debug/blt-server` → `curl -s http://127.0.0.1:3000/healthz`（認証は `docs/api-auth.md`）。
- **テスト SKIP**: `BLT_TEST_POSTGRES_URL` / 実 EDINET 鍵 / `XAI_API_KEY` 未設定時（Neon Secrets とは別）。

### Neon Secrets

アプリが読むのは `DATABASE_URL` のみ。本番系は明示オプトイン（上表の書き込み先）。

| Secret | 用途 | 禁止 |
|---|---|---|
| `DATABASE_URL` | 使い捨て（schema only 可）。探索・検証・スキーマやり直し | 本番を指させない |
| `BLT_PROD_DATABASE_URL` | 本番 SELECT / 件数（WRITE の **子ブランチ**接続。作成／reset 時点のコピー） | 書き込み・`DROP`・これを `DATABASE_URL` にして起動（`autoMigrate`） |
| `BLT_PROD_WRITE_DATABASE_URL` | サイクル上の本番 ingest／ユーザー明示の書き込み（**親＝大元ブランチ**） | 既定差し替え・`DROP`・未検証の探索 ingest。未設定なら追加案内して停止（RO へ書かない） |
| `NEON_API_KEY` | RO を親へ reset する Neon API 認証 | リポジトリへ書かない |
| `NEON_PROJECT_ID` | Neon project id | — |
| `NEON_WRITE_BRANCH_ID` | WRITE 親の `br-…`（`source_branch_id`） | 接続 URL の `ep-…` や `postgresql://` を流用しない |
| `NEON_RO_BRANCH_ID` | RO 子の `br-…`（reset 対象） | 同上 |

**RO 同期**: WRITE への書き込みは RO に流れない。`scripts/neon-reset-ro-from-parent.sh`（Neon Restore API＝GUI の Reset from parent 相当）で RO を親 HEAD に上書きする。ingest 後に上記 4 変数が揃っていれば実行（欠ける／失敗しても ingest 成否には影響させない）。

**42P07**（使い捨てのみ）: テーブルあり・`_fluent_migrations` 空で起動失敗 → 空確認のうえ `psql "$DATABASE_URL" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'`。本番では不可。
