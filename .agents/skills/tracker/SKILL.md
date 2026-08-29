---
name: tracker
description: 次の作業選定、コード欠陥、PR、ingest進捗、公開ゲート、needs_reviewを記録または更新するときに使う。
---

# トラッカー

| 対象 | 正本 |
|---|---|
| 抽出・契約・テスト等のコード欠陥 | GitHub Issue |
| コード変更 | GitHub PR |
| 実装サイクル、本番 ingest、件数、公開ゲート、`needs_review`、訂正有報 | Linear Team `blue-ticker` |

## 次の作業

Linear の依存関係を取得し、親 Feature や後続領域ではなく `Blocked by` の先頭を選ぶ。現在の先頭 Issue ID を作業規則として Git に固定しない。

## 更新

- 仕様・Contract・ジョブ編成は Git、変動する進捗・件数・ゲートは Linear に置く。
- 本番 ingest 後の件数は `scripts/post-ingest-linear.sh` で Project status update へ載せ、Issue コメントや日付付き snapshot を増やさない。
- コード欠陥と運用進捗を同じ tracker に重複登録しない。
