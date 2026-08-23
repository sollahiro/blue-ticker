# 開発ワークフロー

原理原則・実装サイクル・監査の正本は `AGENTS.md`。

- 曖昧な仕様のまま実装しない。不明点はユーザーに確認する。
- 前提はコードと実行結果で検証する。食い違えばコードを優先し、先に指摘する。
- **API・CLI・DBスキーマ・設定ファイル・ファイルフォーマット**の追加・変更・削除はユーザーに確認する。内部実装は裁量。
- コード変更はブランチを切る。main へ直接コミットしない。main への変更はマージ経由のみ。
- 不要と判断したものは削除せず候補として提示する。新規追加時は同等以上の削除も検討する。
- レビューは事実のみ。問題がなければ「問題なし」。無理に指摘を作らない。
- 品質ゲートはブランチと統合／配布で別。「ブランチ緑 ≠ 統合緑 ≠ 配布緑」。

## トラッカー

| 置くもの | 場所 |
|---|---|
| 抽出バグ・契約欠陥・テスト欠陥など、コード上の不具合 | GitHub Issue |
| コード変更 | GitHub PR（単一経路） |
| 実装サイクル段階・本番 ingest・公開ゲート・needs_review・訂正有報キュー | Linear Team `blue-ticker` |

GitHub Issue を ingest 進捗や機能ボードにしない。件数・公開判断・サイクル「現在地」は Git の docs に書かず Linear を更新する（[JP 現在地](https://linear.app/sollahiro/document/jp-現在地-af2abd076034) / [EU 現在地](https://linear.app/sollahiro/document/eu-現在地-844f7112eb70) / [公開と基盤 現在地](https://linear.app/sollahiro/document/公開と基盤-現在地-3bd56370454b)）。仕様の正本（Feature 一覧・ジョブ編成・Contract・サイクル定義）は Git のまま。本番 ingest 後の件数は `scripts/post-ingest-linear.sh` が Project の status update へ載せる（Issue コメントはしない）。日付付きスナップショットは作らない。

### 残作業の着手（Blocked by の先頭）

**着手は Blocked by の先頭。今は BLT-4（BLT-41 解除後）。**

残作業・Cloud Agent 起動は、Linear の親 Feature や Statement / Notes / Filing / Breakdown の子を先に拾わない。依存鎖の **Blocked by 先頭**（いまは [BLT-4](https://linear.app/sollahiro/issue/BLT-4) 自体が先頭。BLT-41 は語彙データ化で閉じた）を次の実装単位とする。先頭が動いたら `AGENTS.md` のトラッカー一行と本節の「今は …」を同じ ID に更新する。

理由: [BLT-41](https://linear.app/sollahiro/issue/BLT-41)（US-GAAP 表分類・語彙のデータ化）は完了。BLT-4 は BLT-5（Statement-Notes）・BLT-3（Filing）・BLT-40（Breakdown 親）を block する。BLT-4 の残（statement-v2 の job-01／サイクル）を閉じる前に Notes / Breakdown 側へ逸れない。

Cloud Agent に残作業を渡す既定プロンプトがリポジトリに無い間は、起動文に上記一行（「着手は Blocked by の先頭。今は BLT-4。」）を必ず含める。プロンプト雛形を後から置く場合も同じ一行を載せる。
