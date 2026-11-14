# 課題と進捗の置き場所

2026-11-12 時点の置き場所。旧課題管理のチケット番号やそのホスト名は Git に新たに書かない（`scripts/ci/cichecks.py` の tracker-ref。baseline は shrink-only）。

生きている進捗・バックログ・運用の正本は **オーナー管理のトラッカー Sheet** とする。URL はここだけに置く。

[オーナー管理のトラッカー Sheet](https://docs.google.com/spreadsheets/d/1r4ppxOmTLAdMcizHE9oLBXqvz6cNYSGvYZgGZ5q28vs/edit)

| 種類 | 正本 |
|---|---|
| 決定・契約・プロセス | このリポジトリの `docs/`（および `.agents/`） |
| 実装不具合・コード作業 | GitHub Issues（`sollahiro/blue-ticker`） |
| 実害（有報と公開面の不一致） | オーナー管理のトラッカー Sheet（タブ「実害トラッカー」） |
| 生きている進捗・運用・手動作業・非コードのバックログ | 同 Sheet の「現在地」「BLT バックログ」 |

新しい実害は Sheet に書く。コード修正が必要なら、Sheet から GitHub Issue を立て、Sheet 側に Issue URL を残す。他の文書からは「オーナー管理のトラッカー Sheet」と呼び、このファイルへ辿る。
