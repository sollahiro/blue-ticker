# ingest 運用方針

本番 write・定期ジョブ・R2 温めの正本。実装サイクル（`AGENTS.md` 段階1–10）との対応、CLI 詳細は `deploy.md` / `operations.md`。

## 原則

- **ジョブは stage 系統ごとに分離**する。1 プロセスに `--stages` を詰め込まない（失敗時の再実行範囲・所要時間・needs_review 多発軸の隔離）。
- **最新年度を先**、過去年度バックフィルは別サイクル。
- **探索的試し書き禁止**（段階3）。本番 write は使い捨て225で確認済みの note_type / 軸だけ。
- **`financials` は組立の最後**に 1 回（正本を貯めてから `fin-vN` 再計算）。`#10b` により ingest 順序依存はないが、**BPS 等を埋めるなら notes を先**に回すと無駄が少ない。
- **R2（生 XBRL L2）**は doc 取得の副産物。`filing-sections` / 書類単位 stage を先に回して温める。

## ジョブ編成（推奨）

| # | スクリプト | 内容 | 母集団 | 既定 limit | 周期の目安 |
|---|---|---|---|---|---|
| 0 | `scripts/jp/edinet/ingest-job-00-sync-foundation.sh` | `sync` → `filing-sections` | 上場 | 80 | 日次（軽） |
| 1 | `scripts/jp/edinet/ingest-job-01-statements.sh` | `statements` | 日経225 | 80 | 6h |
| 2 | `scripts/jp/edinet/ingest-job-02-notes-core.sh` | `statement-notes`（per_share, issued_shares） | 225 | 80 | 6h |
| 3 | `scripts/jp/edinet/ingest-job-03-notes-heavy.sh` | `statement-notes`（残り7種） | 225 | 80 | 日次 |
| 4 | `scripts/jp/edinet/ingest-job-04-breakdowns.sh` | `breakdowns`（全5軸） | business/geo=上場、他=225 | 50 | 6h |
| 5 | `scripts/jp/edinet/ingest-job-05-financials.sh` | `financials` | 上場 | 80 | 6h（2・3の後） |

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

## 環境変数（ジョブ共通）

`ingest.local.env` に書く運用向け変数（CLI 上書きも可）:

| 変数 | 意味 |
|---|---|
| `BLT_INGEST_WRITE` | `1` で本番 WRITE に接続 |
| `BLT_INGEST_SKIP_POST` | `1` で status ページ・Linear 投稿・RO reset をスキップ |
| `BLT_INGEST_SKIP_00` … `05` | `ingest-run-cycle` で該当 job を飛ばす |
| `BLT_INGEST_CYCLE_PAUSE_SEC` | cycle 内 job 間 sleep（既定 5） |
| `BLT_INGEST_FILING_LIMIT` | job-00 の `--limit`（既定 80） |
| `BLT_INGEST_STATEMENTS_LIMIT` | job-01（既定 80） |
| `BLT_INGEST_NOTES_LIMIT` | job-02/03（既定 80） |
| `BLT_INGEST_BREAKDOWN_LIMIT` | job-04 business/geography 用（既定 50。employees/rd/goodwill はコード側 30/回） |
| `BLT_INGEST_FINANCIALS_LIMIT` | job-05（既定 80） |
| `BLT_R2_XBRL_BUCKET` | 設定時 ingest が R2 L2 に PUT（未設定でも ingest は可） |

## 実行順（1サイクル内）

```text
sync + filing-sections   … R2/L1 温め、sections-v6 stale 消化
        ↓
statements               … 225 正本（statement-v1）
        ↓
notes-core               … fin-v9 の BPS/EPS 供給源を優先
        ↓
notes-heavy              … 重い note_type（borrowings / lease / PPE 等）
        ↓
breakdowns               … LLM 軸は時間がかかるため financials と分離
        ↓
financials               … fin-v9 + assembly_fingerprint 再組立
        ↓
（任意）status ページ / RO reset
```

`notes-heavy` と `breakdowns` は依存が無ければ cron 上は別スロットでもよい。`financials` だけは **notes-core 以降**に置く。

## 開発サイクルとの対応（現在地の目安）

| 対象 | サイクル | 本番 ingest の進め方 |
|---|---|---|
| financials | 9 の stale 消化 | job-05 を回して fin-v9 へ。床以上の旧行はそのまま servable だが現行版ではない |
| filing-sections | 9 途中 | job-00 で sections-v6 を優先消化 |
| statements | 6 済・8 残 | job-01 で 225 最新年度（2026 残） |
| notes core | 3–6 | job-02（per_share v3、issued_shares） |
| notes heavy | 3 試行→225 へ | job-03。3社試しは拡げず 225 最新年度一括 |
| breakdowns business/geo | 6 済・9 未 | job-04（上場拡張） |
| breakdowns employees | 6 直前 | job-04（225・needs_review 少） |
| breakdowns rd | 4–8 | job-04 継続。222 needs_review は手動／ロジック改善と分離 |
| breakdowns goodwill | Stage1 データあり | 公開判断前。ingest は job-04 で 225 のみ |

コード変更後は `swift build -c release --product blt-server` を先に実行（旧バイナリは新 stage を黙って飛ばす）。

## 事後処理

ジョブ末尾（`ingest-common.sh`、skip 可）:

1. `scripts/generate-status-page.sh` — 失敗しても ingest 成否に影響させない
2. `scripts/post-ingest-linear.sh` — `LINEAR_API_KEY` かつ `BLT_INGEST_WRITE=1` のとき、`status-report` を Linear Project「JP 機能サイクル」の status update へ投稿（Issue コメントはしない。未設定なら skip）
3. `scripts/neon-reset-ro-from-parent.sh` — `NEON_*` 4 変数が揃うときのみ（WRITE 後）

鮮度監視: `scripts/check-ingest-freshness.sh`。

## 手動・単発

バグ修正確認・訂正有報・needs_review 解消:

```bash
DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-server ingest \
  --codes 7203 --stages financials,statement-notes --note-types per_share_information
```

`--codes` は `--limit` を無視して全件。定期ジョブでは使わない。

## 関連

`AGENTS.md` · `deploy.md` · `operations.md` · `blt-server-roadmap.md` · `financials-summary-separation.md` · `breakdown.md` · `statement.md` · `scripts/jp/edinet/README.md`
