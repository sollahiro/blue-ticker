---
name: production-ingest
description: 本番 Neon への定期・手動取り込み、ジョブ編成、件数確認、訂正有報の手動処理を行うときに使う。任意のエージェント向けの取り込み運用正本。
---

# 本番取り込み運用

任意のコーディングエージェントがこのファイルを読んで実行する。特定の Bot・製品チャネル・クラウドエージェント機能には依存しない。スケジューラは launchd / cron など実行ホスト側に置く。

## 目的

- 上場企業の EDINET 有報を `blt-ingest` で Neon 本番へ取り込み、配信（Fly の `blt-server`）が読む正本を更新する。
- ジョブを stage 系統ごとに分け、失敗時の再実行範囲と `needs_review` 多発軸を隔離する。
- Git に置く取り込み運用の正本はこの skill のみ。固定の起動スクリプトは置かない。処理本体（抽出・計算・DB 書き込み）は `Sources/BltIngest*` / `Sources/BltIngestCore` / `Sources/BlueTicker` が正であり、再生成しない。

関連する禁止事項・設計は既存ファイルのまま読む。

| 対象 | 正本 |
|---|---|
| 接続変数 | `.env.example` |
| Neon ブランチ（子ブランチは使わない） | `docs/process/neon-branches.md` |
| 訂正有報 130 | `.agents/rules/amendments.md` |
| R2 生 XBRL | `.agents/rules/caching.md` |
| `cache_version` / `fin-vN` / `screen-vN` | `.agents/rules/versioning.md` |
| 抽出ロジックの変更 | `.agents/skills/xbrl-development/SKILL.md` |
| ローカル Postgres 検証 | `.agents/skills/local-rest-testing/SKILL.md` |
| Fly / Tunnel | `.agents/skills/deploy/SKILL.md` |
| 件数・公開ゲートの記録（オーナー管理のトラッカー Sheet） | `.agents/skills/tracker/SKILL.md` |
| 会社アイコン | ingest しない（`.agents/skills/company-icon-quality/SKILL.md`） |

## 実行環境

- 本番 write は手元 Mac の repo checkout から `blt-ingest` を動かす。Fly / Docker の `blt-server` は読み取り専用。
- 市場は `JP`、開示 Source は `EDINET`。
- 生 XBRL の取得順はローカル展開 → R2（`BLT_R2_XBRL_BUCKET`、オブジェクト `jp/edinet/xbrl/{docID}.zip`）→ EDINET。バケット未設定でも ingest は可。
- 標準タクソノミ日本語ラベルは git の `assets/taxonomy/labels/`。`BLUE_TICKER_ASSETS_PATH` 未設定なら `$REPO/assets`。CWD が repo 根でないとき（launchd 等）は明示する。
- `assets/nikkei225.csv` は gitignore。処理順の先頭寄せだけ。未配置でも母集団は上場全体のまま（0 件にはならない）。
- 生成したラッパー・チューニングファイル・ログは Git 外（`.build/`、gitignore 済みの手元パス、または repo 外）。コミットしない。

## 標準動作（1 サイクル）

ジョブは stage 系統ごとに分け、1 プロセスに `--stages` を詰め込まない（失敗時の再実行範囲・所要時間・`needs_review` 多発軸の隔離のため）。最新年度を先に回し、過去年度バックフィルは別サイクル。探索的試し書きはしない。件数（`--limit`）・周期・どの stage を回すかは実行側が決める（Git に表で固定しない）。

守る順序と依存:

- `sync` と `filing-sections`（R2/L1 温め）を最初に回す。
- `financials` は組立の最後。BPS / EPS を埋めるなら `statements` と `statement-notes`（`per_share_information,issued_shares_and_capital`）を先に回す。
- `breakdowns` は時間がかかり、LLM（Jev）にも依存するので、他の stage と分けて回す。依存が無ければ別スロットでもよい。
- `overviews` と `relations` は他 stage に依存しない。`--stages` 省略時の `ingest` には `relations` と `industry-kpis` は入らない（明示指定だけ）。`industry-kpis` は標準サイクルに載せない。
- 旧 PPE / のれん注記の stage は廃止済み。`breakdowns` の `fixed_assets` 軸が引き継いだ。
- 1 つでも失敗したらサイクルを止め、後ろの stage を続けない。

## 変えてよい項目 / 変えてはいけない安全条件

恒久的な変更（順序・必須ガード・既定の意味）は本 skill を PR で直す。一回限りの limit / skip / 対象銘柄は実行記録（Git 外の env・ログ）に置く。件数・skip の変更だけで PR しない。

変えてよい:

- 各 job の `--limit`、ジョブ間 sleep、どの job を飛ばすか
- その回だけの `--codes` / `--doc-ids` / `--note-types` / `--axes`
- ラッパーの置き場、ログパス、launchd の時刻（環境側。この skill は切替しない）
- 一度生成したラッパーの再利用・定期実行。毎回の再生成は必須ではない

変えてはいけない:

- ユーザー明示なしの本番 write。`.env` の既定 `DATABASE_URL` を WRITE に固定しない
- 読み取り URL（`BLT_NEON_READ_DATABASE_URL`）への書き込み、本番 schema の `DROP` / 作り直し
- Fly 上での ingest / migrate
- 未検証ロジック・探索 ingest の本番書き込み
- `needs_review`・あいまい失敗・異常欠測・訂正有報 130 の自動処理
- 会社アイコンの ingest
- `--codes` / `--doc-ids` / `--axes` を定期サイクルの既定にすること（手動・単発専用）
- 秘密情報を argv・Git・ログへ出すこと

## 入力 / コマンド契約

バイナリ: `$REPO/.build/release/blt-ingest`（無ければ先に release ビルド）。サブコマンドの詳細は `Sources/BltIngest/main.swift`。

秘密・接続は `.env`（gitignore）。運用チューニングは Git 外の env（従来名 `ingest.local.env` でも、別パスでも可）。

| 変数 | 意味 |
|---|---|
| `BLT_INGEST_WRITE` | `1` のときだけ `DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL"` を束縛。WRITE URL 未設定なら停止 |
| `BLT_EDINET_API_KEY` | 必須。未設定なら停止 |
| `OPENROUTER_OVERVIEW_API_KEY` | overviews を回すなら必須（未設定ならその job を失敗させる。CLI 単体は skip するが、定例の overviews job は閉じる） |
| `OPENROUTER_DECISION_API_KEY` | Jev（内訳の分類、relations の区分不定表）。未設定なら `needs_review` で残す（job は止めない）。`OpenRouter decisions HTTP 403` がログに続くときは、鍵の失効・残高・上限を確認する |
| `BLT_R2_XBRL_BUCKET` / `BLT_R2_ACCOUNT_ID` / `BLT_R2_ACCESS_KEY_ID` / `BLT_R2_SECRET_ACCESS_KEY` | 生 XBRL の R2（正本）。4 つそろわないと R2 は無効（ローカル → EDINET の経路になる） |
| `BLT_INGEST_LOCK_FILE` / `BLT_INGEST_LOCK_WAIT_SEC` | 排他ロックのファイル（既定 `/tmp/blt-ingest-<uid>.lock`）と待ち秒数（既定 0 = すぐ失敗） |
| `BLUE_TICKER_ASSETS_PATH` | 未設定なら `$REPO/assets` |

生 XBRL の取得（R2 が正本）:

- 取得順は「ローカル展開 → R2（`jp/edinet/xbrl/{docID}.zip`）→ EDINET」。R2 から取れた書類は展開して使う。R2 に無く EDINET から取った書類は、展開に成功した直後に R2 へ PUT する。書類（docID）ごとの ZIP は変わらない（訂正有報は別の docID）。
- ローカル展開（`tmp_cache/edinet/`）は使い捨てのキャッシュ。消えても動く。別の Mac でも `.env` の R2 と EDINET の設定だけで動かせるよう、R2 の設定は必須とする。
- R2 の GET / PUT が失敗しても ingest は止まらない（stderr に `R2 XBRL GET/PUT 失敗` が出るだけ）。ログで失敗が続いていないかを見る。PUT が失敗した書類は、ローカルに展開が残っていると R2 へ再 PUT されない。補うときは、その docID のローカル展開を消して再取得する。

書き込み先の決め方:

1. `BLT_INGEST_WRITE=1` → WRITE URL を `DATABASE_URL` にする。無ければ停止。
2. それ以外で `DATABASE_URL` が空 → 停止。
3. `DATABASE_URL` が `BLT_NEON_READ_DATABASE_URL` と同じ → 停止（読み取りロールでは migrate も書き込みも拒否される）。
4. 検証はローカル Postgres の `DATABASE_URL`。Neon 本番ブランチを使い捨て検証に使わない。Neon の子ブランチは作らない。

再ビルド判定（定例ラッパー用）: スタンプ `$REPO/.build/blt-ingest.built-commit`。見るパスは `Sources/BlueTicker`、`Sources/BltStoreCore`、`Sources/BltIngestCore`、`Sources/BltIngest`、`Package.swift`、`Package.resolved`。HEAD コミット単位（作業ツリーの未コミット変更は見ない）。`blt-ingest` は Vapor / MCP をリンクしない。

一時ラッパーを書くときの骨子（全文の固定スクリプト化はしない）:

- repo 根で `.env` と Git 外チューニングを load する
- 上記の write ガードを通す
- 必要なら release ビルドしてから、上の順序・依存に従って `blt-ingest` を呼ぶ
- 失敗したら残ジョブを続けない（途中再開は DB 側の skip）
- ログは Git 外

## 再実行・途中再開・排他

- `--limit` は未処理側から消化する。現行 `cache_version` で skip できる行は skip する（ステージごとの skip 条件は実装側）。これが途中再開。
- `--codes` は limit を無視して指定銘柄を全件。`--doc-ids` は原本 120 の会社-FY 単位で cache_version / needs_review でも skip しない。他 FY は purge しない。定期サイクルでは使わない。
- `--axes` は `breakdowns` を指定軸だけに絞る（未指定は全軸）。`--doc-ids` は書類の全軸を書き直すので、軸を絞りたいときは行を削除して `--codes` と併用する。定期サイクルでは使わない。
- ジョブ失敗はそのサイクルを止める。次のスケジュールで、skip されなかった残件から再開する。
- 書き込みを伴う `blt-ingest` のコマンド（migrate / sync / ingest / master-data-upload / screen-rebuild / overrides add|revoke）は、`flock` の排他ロックで同時に 1 つだけ。別のプロセスが保持中は、既定ですぐ失敗する（`BLT_INGEST_LOCK_WAIT_SEC` で待てる）。ロックはプロセス終了時に OS が解放するので、古いロックは残らない。定例のジョブ間（sleep 中）には手動実行が入り得る。

## 成功判定

- 各 `blt-ingest` が exit 0。失敗した job より後を「成功」と数えない。
- ログに WRITE 接続の明示がある（本番 write のとき）。READ URL のまま書いていない。
- 取り込み状況は `workers/status-rss` の RSS（`https://feed.sollahiro.com/blue-ticker/ingest-status.xml`）。最終更新が 36 時間より古いステージは題に「遅延」。件数の Git 固定はしない。
- マイグレーション後は `/healthz` の `cache_versions` がイメージとずれていないこと。

## 異常時対応

- `BLT_EDINET_API_KEY` / WRITE URL / バイナリ欠落 → 停止。ダミーキーで本番取得しない。
- overviews で Overview キー欠落 → その job を失敗させる（黙って skip してサイクル成功にしない）。
- DB 不安定で sync が中断 → 残りは次回。無理に全件リトライで書き込まない。
- `needs_review`・異常欠測・訂正 130 → 自動で消さない。`.agents/rules/amendments.md` に従い手動。
- DB 操作は 1 回 60 秒でタイムアウトし、`withDbRetry` が最大 5 回再試行する。全社・全件のループを 1 つの `withDbRetry` で包まない（会社数が多いと毎回タイムアウトし、再試行も先頭からやり直しになる）。会社 1 社・書類 1 件の単位で包む。`DB retry exhausted` が出たら、どの `label` かを見る。
- ローカル Postgres の 42P07（テーブルはあるが `_fluent_migrations` が空）だけ、接続先がローカルでデータが空であることを確認して schema を再作成してよい。本番には適用しない。

## 手動・単発

本番対象・Stage・母集団・公開範囲はユーザー確認後。ロジック変更は先に xbrl-development skill とローカル Postgres で確認する。

```bash
DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-ingest ingest \
  --codes 7203 --doc-ids S100W0S7 \
  --stages financials,statements,statement-notes,breakdowns,filing-sections \
  --note-types per_share_information
```

内訳の 1 軸だけ再取り込みする例: `--stages breakdowns --axes capex`（行を消したあと `--codes` と併用）。

Screen 列定義のあとで急ぐときだけ:

```bash
DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-ingest screen-rebuild
```

`cache_version` バンプ可否は versioning ルール。LLM 出力だけの訂正は上げない。現行版の clean な LLM 行は `--codes` でも skip されるため、対象行を消すか `needs_review=true` にしてから個別 ingest する。

## 運用ホストの要件（実装はホスト側。Git に置かない）

取り込みを実行するホストのラッパーは、次を満たす。具体的なコマンド・通知先・追従先（main かタグか）は、ホストごとに決める。

- **更新確認**: サイクルの冒頭で、追従先との差を確認する。古い場合は通知する（自動で切り替えるかは運用で決める。既定は通知のみ）。再ビルドは、上の「再ビルド判定」で依存パスに差分があるときだけ。ビルドに失敗したらサイクルを止める（古いバイナリで続けない）。
- **失敗通知**: サイクルが異常終了したときに通知する（ログを見に行かないと気づけない状態にしない）。skip している stage があるときは、サイクルのログ冒頭に `SKIP: …` と出す（戻し忘れを防ぐ）。
- **ログ**: 日次または一定サイズでローテーションし、stdout と stderr を分ける。

## 出荷順（マイグレーション）

スキーマを変えるのは Mac の書き込み側だけ。`blt-server` は起動時に migrate しない。

- `blt-ingest migrate` は未適用分だけを `DATABASE_URL` へ適用する。`sync` / `ingest` / `master-data-upload` / `screen-rebuild` / `overrides add|revoke` も冒頭で同じ適用を行う。`overrides list` とサーバー起動は適用しない。
- マイグレーションを含む PR を main に入れたら、(1) Mac で `DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-ingest migrate`、(2) GitHub Actions の Deploy を `workflow_dispatch`。差分に `Sources/*/Migrations/` を含む自動デプロイは失敗で止まる。

## 手元 Mac の Git 管理外ファイル（この skill では削除しない）

現行の定例は、launchd が Git 管理外の `ingest-run-cycle.local.sh` を呼び、それが repo 内の取り込みプログラムを起動していた。gitignore 済みの次は **まだディスク上に残り得る**。この skill を読んだだけでは消えないし、消したと扱わない。

- `scripts/jp/edinet/ingest-run-cycle.local.sh`
- `scripts/jp/edinet/ingest.local.env`
- `scripts/jp/edinet/local/`
- `scripts/install-launchd.sh` / `scripts/launchd/` / `scripts/blt-scheduled-sync.sh`

切替・削除条件（実施は実行ホストの管理者。この変更だけでは launchd を動かさない）:

1. 新しいラッパーが本 skill の CLI 契約だけで `blt-ingest` を呼び、削除済みの `ingest-common.sh` / `ingest-job-*.sh` / `ingest-run-cycle.sh` を source / exec しないことを確認する。
2. launchd の Program がその新しいラッパーを指す（または旧ラッパーを同じ契約に書き換える）。
3. 旧パスを呼ぶ plist が残っていないことを確認してから、旧 `.local.sh` を消す。
4. 取り込み Mac へこの変更を pull する前に 1–2 を終える。先に pull すると、旧ラッパーが無い Git 管理スクリプトを呼んで定例が止まる。
