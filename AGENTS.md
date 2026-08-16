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
- **テスト**: 仕様＝振る舞いを検証する。境界値・異常系を重視し、呼び出し順や内部構造は見ない。golden（深さ）と smoke（床）の役割・固定企業・対象 note_type / breakdown 軸は `docs/xbrl-parsing.md` §6。新規 note_type 追加時は床を広げる。言語非依存の資産と実装紐づきの分けは `docs/test-spec-assets.md`。

## ビルド・テスト

```bash
swift build                          # blt-server を生成
swift test                           # 全テスト（Swift Testing）。段階1–2の床
BLT_EDINET_API_KEY=dev-local-dummy ./.build/debug/blt-server   # 使い捨て Neon を使うときは DATABASE_URL に束ねる
.build/debug/blt-server ingest --codes 7203 --stages financials,statements,statement-notes,breakdowns
curl -s 'http://127.0.0.1:3000/v1/companies/7203/financials?years=1'
```

**検証の分担**: 段階1–2は `swift test`（smoke/golden。キャッシュ無しなら EDINET オンライン）。契約・配信の確認は使い捨て Neon へ ingest したうえで `/v1`。サーバー動作確認はローカル優先（`127.0.0.1:3000`）。外部から到達させる場合は `cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate` 等。PR → CI → デプロイの待ちは1周が数分かかり本番へも影響しうる。ロジックが固まってから通常のブランチ運用へ。

## ターゲット構成と依存ルール

詳細図は `docs/architecture.md`。外部パッケージ一覧は `Package.swift` 先頭コメント（`.agents/rules/project/dependencies.md`）。

| ターゲット | 内容 |
|---|---|
| `BlueTickerCore` | XBRL・サービス・REST ファサード。**Vapor/Fluent 非依存** |
| `BltMcpServerCore` | MCP プロトコル層。**Vapor/Fluent 非依存** |
| `BltServerCore` | Vapor トランスポート＋ Fluent DB。MCP は `POST /` |
| `BltServer` | `blt-server` エントリのみ（唯一の配布 product）。`BltServerCore` のみに依存 |

依存方向: `BltServer` → `BltServerCore` → `BlueTickerCore` / `BltMcpServerCore`。逆は不可。

`BlueTickerCore` 内（同一モジュールのためレビューで担保）:

- `Services/` → `Server/` 禁止（ファサードは `Server/` が Services を呼ぶ）
- `Analysis/` / `API/` / `Infrastructure/` / `Utils/` → `Services/`・`Server/` 禁止
- `Server/` はファサードのみ（Vapor/Fluent は `BltServerCore`）
## 機能の実装サイクル

新機能・Stage 拡張は次の順。**バンプ**は Neon `cache_version` のみ（`blueTickerVersion` ではない → `versioning.md`）。**公開範囲**（REST/MCP 解禁など）は機能ごとに都度確認。

表の「バンプ」列は **本番 write への再計算を伴う定着バンプ**（段階10）を指す。一方、smoke〜ロジック確認中の PR では、抽出ロジックまたは契約の意味が変わったときに Contract 定数を上げてよい（次の ingest から新世代。中間の細かい連続バンプはマージ前に1つへまとめてよい）。

| # | 段階 | 書き込み先 | バンプ |
|---|---|---|---|
| 1 | 実装初期は smoke 固定企業セット（`docs/xbrl-parsing.md` §6）で検証し、ロジックをブラッシュアップする | ローカル | しない（PR 内の定数上げは可 → 上注） |
| 2 | smoke だけでは拾えない個別の失敗事例は、見つかり次第 golden（`RealXbrl*Tests.swift`）へ追加して蓄積する | ローカル | しない（PR 内の定数上げは可 → 上注） |
| 3 | ロジックが安定したら日経225限定で使い捨てへ投入して確認し、問題なければ本番へ初期投入（最新年度を埋める。探索的試し書き禁止）。不審フラグ（`needs_review`・あいまい失敗・異常欠測など）はこの段階でも手動 ingest で解消する | 使い捨て→本番 write | しない |
| 4 | 最新年度 100% 後にロジック改善（母数＝最新有報が取れた社。欠測は正当か不具合か確認） | — | しない |
| 5 | 改善結果を使い捨てで検証 | 使い捨て | しない |
| 6 | 問題なければ公開（都度確認）し、225 **全件**を本番へ揃える | 本番 write | しない |
| 7 | 全件を見たうえでのロジック改善 | — | しない |
| 8 | 不審フラグ（`needs_review`・あいまい失敗・異常欠測など）は手動 ingest | 本番 write | しない |
| 9 | 225 全体で問題なければ全銘柄へ拡張 | 本番 write | しない |
| 10 | 全銘柄展開に伴うロジック定着 | 本番 write | **する** |

- **母集団**: statements と breakdowns の employees/rd/goodwill は `assets/nikkei225.csv` / `priorityIngestCodes()` で対象限定。breakdowns の business/geography と financials/filing-sections は上場全体（同 CSV は処理順の優先のみ）→ 225 に閉じるなら `--codes` 等で明示。
- **接続**: 使い捨て＝`BLT_NEON_DISPOSABLE_DATABASE_URL`（手元では `DATABASE_URL` に束ねる）、本番 read＝`BLT_NEON_RO_DATABASE_URL`（SELECT のみ）、本番 write＝`DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" blt-server ...`（コマンド単位。既定の差し替え禁止）。`DATABASE_URL` はプロセスが読む接続スロットのみ。RO は WRITE 親ブランチの子（自動同期なし）→ ingest 後は `scripts/neon-reset-ro-from-parent.sh` で揃える。
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

手元の変数一覧は `.env.example`（コピーして `.env`）。アプリが読むのは `DATABASE_URL` のみ（役割つき URL を束ねるスロット）。本番系は明示オプトイン（下表）。

| Secret | 用途 | 禁止 |
|---|---|---|
| `DATABASE_URL` | プロセス束縛。blt-server が読む唯一の接続先。手元の既定は disposable を代入。未設定＝ステートレス | 手元 `.env` の既定を本番 WRITE に差し替えたままにしない（WRITE はコマンド単位上書き） |
| `BLT_NEON_DISPOSABLE_DATABASE_URL` | 使い捨て（schema only 可）。探索・検証・スキーマやり直し | 本番を指させない |
| `BLT_NEON_RO_DATABASE_URL` | 本番 SELECT / 件数（WRITE の **子＝RO**。作成／reset 時点のコピー） | 書き込み・`DROP`・これを `DATABASE_URL` にして起動（`autoMigrate`） |
| `BLT_NEON_WRITE_DATABASE_URL` | サイクル上の本番 ingest／ユーザー明示の書き込み（**親＝WRITE**） | 既定差し替え・`DROP`・未検証の探索 ingest。未設定なら追加案内して停止（RO へ書かない） |
| `NEON_API_KEY` | RO を親へ reset する Neon API 認証 | リポジトリへ書かない |
| `NEON_PROJECT_ID` | Neon project id | — |
| `NEON_WRITE_BRANCH_ID` | WRITE 親の `br-…`（`source_branch_id`）。`BLT_NEON_WRITE_DATABASE_URL` と同ブランチ | 接続 URL の `ep-…` や `postgresql://` を流用しない |
| `NEON_RO_BRANCH_ID` | RO 子の `br-…`（reset 対象）。`BLT_NEON_RO_DATABASE_URL` と同ブランチ | 同上 |

**RO 同期**: WRITE への書き込みは RO に流れない。`scripts/neon-reset-ro-from-parent.sh`（Neon Restore API＝GUI の Reset from parent 相当）で RO を親 HEAD に上書きする。ingest 後に上記 4 変数が揃っていれば実行（欠ける／失敗しても ingest 成否には影響させない）。

**42P07**（使い捨てのみ）: テーブルあり・`_fluent_migrations` 空で起動失敗 → 空確認のうえ disposable 接続で `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`。本番では不可。
