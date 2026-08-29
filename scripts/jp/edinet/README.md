# JP / EDINET

Region `JP` · Source `EDINET`。命名規約は `.agents/rules/regions.md`。

本番ロジックの正本は Swift モノレポ側:

| 役割 | 置き場 |
|---|---|
| 取得 | `Sources/BlueTicker/API/EdinetAPIClient.swift` 等 |
| 解析 | `Sources/BlueTicker/Analysis/` |
| 定数・コンテキスト | `Sources/BlueTicker/Constants/Xbrl.swift` |
| 配信・取り込み | `blt-server`（REST / ingest） |
| ローカル cache | `tmp_cache/edinet/` |

## 定期 ingest ジョブ

方針の正本: [`docs/ingest-policy.md`](../../../docs/ingest-policy.md)

### Git 管理（正本）

| スクリプト | 内容 |
|---|---|
| `ingest-common.sh` | 共通（source 専用・`ingest.local.env` 自動 load） |
| `ingest-job-00` … `05` | stage 別ジョブ |
| `ingest-run-cycle.sh` | 0–5 を順実行 |

サイクル末尾の `ingest_post_hooks`（status ページ・Linear 件数・RO reset）は各 job でも呼ぶ。手元ラッパーは job 中 `BLT_INGEST_SKIP_POST=1`、末尾で 1 回だけ実行する。Linear 投稿は `.env` の `LINEAR_API_KEY` と `BLT_INGEST_WRITE=1` が揃ったときだけ。

### 手元専用（`.gitignore`・**PR 不要**）

| 雛形 | コピー先 | 用途 |
|---|---|---|
| `ingest.local.env.example` | `ingest.local.env` | **limit / skip / write / pause** |
| `ingest-run-cycle.local.example.sh` | `ingest-run-cycle.local.sh` | launchd 用ラッパー |
| `ingest-job.local.example.sh` | `local/*.local.sh` | job 単体ラッパー |

```bash
swift build -c release --product blt-server
cp scripts/jp/edinet/ingest.local.env.example scripts/jp/edinet/ingest.local.env
cp scripts/jp/edinet/ingest-run-cycle.local.example.sh \
   scripts/jp/edinet/ingest-run-cycle.local.sh
chmod +x scripts/jp/edinet/ingest-run-cycle.local.sh
# limit 等は ingest.local.env を編集するだけ
./scripts/jp/edinet/ingest-run-cycle.local.sh
```

対となる EU / ESEF 探索: `scripts/eu/esef/`。
