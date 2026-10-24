# ingest 運用方針

本番 write・定期ジョブ・R2 温めの正本（ジョブ編成）。実装サイクルは `.agents/skills/xbrl-development/SKILL.md`。接続と Neon write 手順は `.agents/skills/production-ingest/SKILL.md`。会社アイコン週次ピンは `.agents/skills/company-icons/SKILL.md`。Fly / Tunnel は `.agents/skills/deploy/SKILL.md`。

## 原則

- **ジョブは stage 系統ごとに分離**する。1 プロセスに `--stages` を詰め込まない（失敗時の再実行範囲・所要時間・needs_review 多発軸の隔離）。
- **最新年度を先**、過去年度バックフィルは別サイクル。
- **探索的試し書き禁止**。本番 write は使い捨て225で確認済みの note_type / 軸だけ。
- **`financials` は組立の最後**に 1 回（正本を貯めてから `fin-vN` 再計算）。`#10b` により ingest 順序依存はないが、**BPS 等を埋めるなら notes を先**に回すと無駄が少ない。
- **R2（生 XBRL L2）**は doc 取得の副産物。`filing-sections` / 書類単位 stage を先に回して温める。

## ジョブ編成（推奨）

| # | スクリプト | 内容 | 母集団 | 既定 limit | 周期の目安 |
|---|---|---|---|---|---|
| 0 | `scripts/jp/edinet/ingest-job-00-sync-foundation.sh` | `sync` → `filing-sections` | 上場 | 80 | 日次（軽） |
| 1 | `scripts/jp/edinet/ingest-job-01-statements.sh` | `statements` | 上場（225は処理順） | 80 | 6h |
| 2 | `scripts/jp/edinet/ingest-job-02-notes-core.sh` | `statement-notes`（per_share, issued_shares） | 上場（225は処理順） | 80 | 6h |
| 3 | （廃止） | 旧 `statement-notes` の PPE / goodwill は Breakdown の `property_plant_equipment` / `goodwill_and_intangibles` 軸へ移した（job-4） | — | — | — |
| 4 | `scripts/jp/edinet/ingest-job-04-breakdowns.sh` | `breakdowns`（全11軸） | 上場（225は処理順） | 50 | 6h |
| 5 | `scripts/jp/edinet/ingest-job-05-financials.sh` | `financials` | 上場 | 80 | 6h（2の後） |
| 6 | `scripts/jp/edinet/ingest-job-06-overviews.sh` | `overviews` | 上場（225は処理順） | 80 | 日次 |
| 7 | `scripts/jp/edinet/ingest-job-07-relations.sh` | `relations`（主要な顧客・関係会社・親会社等・政策保有株式・大株主） | 上場（225は処理順） | 100 | 日次 |

1 周まとめて回す: `scripts/jp/edinet/ingest-run-cycle.sh`（各ジョブ間に短い sleep。個別 skip 可）。

**Git と手元の分離**

| 種別 | パス | Git |
|---|---|---|
| 正本ジョブ | `ingest-common.sh` · `ingest-job-*.sh` · `ingest-run-cycle.sh` | 管理 |
| 手元チューニング | `ingest.local.env`（limit / skip / write / pause） | **ignore** |
| 手元ラッパー | `*.local.sh` · `local/` | **ignore** |

**件数・skip の変更は PR 不要**。`ingest.local.env` を手元で編集する（`ingest-common.sh` が存在時に自動 load）。雛形は `ingest.local.env.example`。launchd / cron は `.local.sh` → 正本ジョブ。

## 本番 write

手元 `.env` の既定 `DATABASE_URL` は disposable のまま。write 可否も `ingest.local.env` の `BLT_INGEST_WRITE=1` で切替。

```bash
cp scripts/jp/edinet/ingest.local.env.example scripts/jp/edinet/ingest.local.env
cp scripts/jp/edinet/ingest-run-cycle.local.example.sh \
   scripts/jp/edinet/ingest-run-cycle.local.sh
chmod +x scripts/jp/edinet/ingest-run-cycle.local.sh
# limit を ingest.local.env で編集 → launchd / cron / 手動実行
./scripts/jp/edinet/ingest-run-cycle.local.sh
```

手動 1 回（`.env` + `ingest.local.env` を読んだうえで）:

```bash
set -a; . ./.env; set +a
./scripts/jp/edinet/ingest-run-cycle.sh
```

`BLT_INGEST_WRITE=1` のとき `ingest-common.sh` が `DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL"` を束縛する（未設定なら停止）。

## 出荷順（マイグレーション）

スキーマ（DDL）を変えるのは Mac の書き込み側だけ。Fly の `blt-server`（配信）は起動時に migrate せず、読み取りロール `blt_reader` で動く。

- `blt-server migrate` は未適用のマイグレーションだけを `DATABASE_URL` へ適用する。`sync` / `ingest` / `master-data-upload` / `screen-rebuild` / `overrides add|revoke` も冒頭で同じ適用を行う。`status-report` / `overrides list` / サーバー起動は適用しない。
- マイグレーションを含む PR を main に入れたら、次の順で出す。
  1. Mac で `DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-server migrate`
  2. GitHub Actions の Deploy を workflow_dispatch で実行する。差分に `Sources/*/Migrations/` を含む自動デプロイは、Deploy ワークフローが失敗で止める（成功扱いにすると次の push で判定から外れるため）。
- デプロイ後は `/healthz` の `cache_versions` で、DB の中身とサーバーが話す版がずれていないかを確認する。

## 環境変数（ジョブ共通）

`ingest.local.env` に書く運用向け変数（CLI 上書きも可）:

| 変数 | 意味 |
|---|---|
| `BLT_INGEST_WRITE` | `1` で本番 WRITE に接続 |
| `BLT_INGEST_SKIP_POST` | `1` で status ページ更新をスキップ |
| `BLT_INGEST_SKIP_00` … `07` | `ingest-run-cycle` で該当 job を飛ばす |
| `BLT_INGEST_CYCLE_PAUSE_SEC` | cycle 内 job 間 sleep（既定 5） |
| `BLT_INGEST_FILING_LIMIT` | job-00 の `--limit`（既定 80） |
| `BLT_INGEST_STATEMENTS_LIMIT` | job-01（既定 80） |
| `BLT_INGEST_NOTES_LIMIT` | job-02/03（既定 80） |
| `BLT_INGEST_BREAKDOWN_LIMIT` | job-04 business/geography 用（既定 50。employees/rd/goodwill はコード側 30/回） |
| `BLT_INGEST_FINANCIALS_LIMIT` | job-05（既定 80） |
| `BLT_INGEST_OVERVIEW_LIMIT` | job-06（既定 80） |
| `BLT_INGEST_RELATIONS_LIMIT` | job-07（既定 100） |
| `BLT_R2_XBRL_BUCKET` | 設定時 ingest が R2 L2 に PUT（未設定でも ingest は可） |

## 実行順（1サイクル内）

```text
sync + filing-sections   … R2/L1 温め + 本文抽出
        ↓
statements               … 上場正本（225は処理順）
        ↓
notes-core               … BPS/EPS 供給源を優先
        ↓
breakdowns               … LLM 軸は時間がかかるため financials と分離
        ↓
financials               … 組立スナップショット再計算
        ↓
overviews                … 銘柄の短い会社説明（LLM。最新有報1件。financials 非依存。LLM 成功行は cache_version バンプでは再生成せず、最新 doc_id 変更と needs_review。`not_applicable` は版ずれで再実行）
        ↓
relations                … 取引先・関係会社（最新有報1件。区分の決まらない関係会社表だけ Jev。名前解決は決定論）
        ↓
（任意）status ページ / Linear 投稿
```

`breakdowns` は依存が無ければ cron 上は別スロットでもよい。`financials` だけは **notes-core 以降**に置く。`overviews` は他 stage に依存しない（XBRL ダウンロードは自前）。`relations` も他 stage に依存しない。名前解決（上場企業への名寄せ）は書き込み時に決定論で行い、各回の最後に、解いたときの名簿（EDINET コードリスト）が今と違う行と、この回で子会社索引の親が変わった名前の行だけを解き直す（最終状態は処理順に依らない）。`--stages` 省略時の `ingest` には入らない（`--stages relations` の明示指定だけ）。Jev 保留の書類の再試行はキーがあるときだけ、新しい書類の後に回す。

サイクル段階・最新年度 100%・stale・公開ゲートの現在地は Linear Team `blue-ticker` の document「JP 現在地」に置く。Git に件数や段階番号を書かない。

コード変更後は `swift build -c release --product blt-server` を先に実行（旧バイナリは新 stage を黙って飛ばす）。

標準タクソノミ日本語ラベルは git の `assets/taxonomy/labels/`（2026年版 EDINET、タクソノミ日付 2025-11-01。jpcrp / jppfs / jpigp の `_lab.xml`）。本番 ingest は手元 Mac の repo checkout から読む。`ingest-common.sh` は `BLUE_TICKER_ASSETS_PATH` 未設定なら `$REPO/assets` を使う。詳細は `docs/xbrl-parsing.md` §4。

## 事後処理

ジョブ末尾（`ingest-common.sh`、skip 可）:

1. `scripts/generate-status-page.sh` — `BLT_STATUS_HTML` が指すファイルがあればマーカー置換（無ければ skip。git は触らない）。失敗しても ingest 成否に影響させない

鮮度監視: `scripts/check-ingest-freshness.sh`。

## 手動・単発

バグ修正確認・訂正有報・needs_review 解消:

```bash
DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-server ingest \
  --codes 7203 --doc-ids S100W0S7 \
  --stages financials,statements,statement-notes,breakdowns,filing-sections \
  --note-types per_share_information
```

`--codes` / `--doc-ids` は `--limit` を無視して全件。`--doc-ids` は原本有報(120)の会社-FY 単位（他 FY は purge しない。financials は会社1行なので当該発行体を再計算し、overlay は訂正がある FY だけ）。指定 doc は cache_version / needs_review に関係なく書き直す（financials は格納行の cache_version・high_water・assembly_fingerprint が現行でも再計算して格納する。最新 FY を失う上書き・years 行へのプレースホルダ上書きは縮小ガードで保留されるのは同じ）。定期ジョブでは使わない。

Screen 索引の列定義が変わったあと（`sales_cagr_3y` / screen-v3 指標の追加、screen-v4 の配当性向 3 年平均など）は `fin-vN` を上げない。次回の financials ingest は公開床（servable）の `company_financials` から screen_index を投影する（現行 fin-vN 一致・skip は問わない）。手動で急ぐときだけ WRITE で一発再生成する:

```bash
DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-server screen-rebuild
# 部分実行（走査 N 件。孤児削除はしない）:
DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-server screen-rebuild --limit 100
```

`/healthz` の `cache_versions.screen_index` がイメージの `screenIndexVersion` と一致することを確認する。

`cache_version` / `fin-vN` / `screen-vN` のバンプ可否は `.agents/rules/versioning.md`（破壊的変更だけ上げる。細粒度・非破壊は行削除 / `--codes`）。LLM 出力だけの訂正は上げない。現行版の clean な LLM 行は `--codes` でも skip されるため、対象の `company_breakdowns` 行を消すか `needs_review=true` にしてから個別 ingest する。

## 関連

`AGENTS.md` · `.agents/skills/production-ingest/SKILL.md` · `.agents/skills/deploy/SKILL.md` · `blt-server-roadmap.md` · `financials-summary-separation.md` · `breakdown.md` · `statement.md` · `scripts/jp/edinet/README.md`
