# ドキュメント

<<<<<<< HEAD
- Git 履歴をドキュメントに複製しない。現在の判断に必要な情報だけ残す。
- `AGENTS.md`＝原理原則、`.agents/rules/`＝実装時の禁止、`docs/`＝構成・運用・契約。rules にモジュール一覧や検証ログを置かない。
- `docs/` は教訓（再発防止）と指標（現在地・未決）を混ぜない。構成は architecture、進捗は roadmap、手順は deploy、結合点は operations。
- 残作業の正本は GitHub issue（作成はユーザー確認後）。セッション再開だけ `.claude/handoff.local.md`（非追跡）。
=======
履歴は Git に、現在地はドキュメントに残す。

- ドキュメントは Git 履歴を複製してはならない。コミットで履歴化された情報は要約・統合・削除の対象とする。
- ドキュメントは現在および将来の意思決定に必要な情報のみ保持する。
- 情報は資産だが、未整理の情報は負債。開発ドキュメントは規約ドキュメントにまとめ、定期的に見直して陳腐化させない（完了済み作業記録・古い議論は削除・圧縮）。
- セッションをまたいで残すべき判断・文脈は Git もしくは memory に記録する。一時的な議論・作業メモは Git に残さない。

## 置き場の役割（docs / rules / AGENTS）

| 置き場 | 役割 | 置かないもの |
|---|---|---|
| `AGENTS.md` | 原理原則・ターゲット境界・実装サイクル・Cloud 起動の正本 | 機能別の詳細手順・履歴 |
| `.agents/rules/` | **実装時の規律**（落とし穴回避・命名・依存・バンプ規則）。短く保つ | モジュール一覧のスナップショット、完了済み作業記録、検証ログ |
| `docs/` | 構成・運用・契約・ドメイン仕様・未決指標 | Git で辿れる経緯の再叙述、機械生成の全件棚卸し |

`docs/` を書く／直すときは次の2軸を分けて考える（混ぜない）:

1. **教訓** — 再発防止・判定ルール・禁止事項（日付・PR 番号は原則不要）
2. **指標** — 現在地・未決・次・非ゴール（達成済みゲートの詳細は不要）

## `docs/` ファイル責務（正本の所在）

| ファイル | 正本とするもの |
|---|---|
| `architecture.md` | 現構成（箱・依存・エンドポイント・Region×Source 命名） |
| `blt-server-roadmap.md` | 進捗・未決・次 |
| `deploy.md` | デプロイ・同期の手順 |
| `operations.md` | 外部依存の結合点・代替・定常の落とし穴 |
| `api-auth.md` | 認証の住み分け |
| `api-compatibility.md` | REST 互換判定 |
| `feature-tiers.md` | 機能・課金境界（Allocation の未着手メモ含む） |
| `public-api.md` | 第三者公開（段階 B）のみ |
| `statement.md` / `breakdown.md` | 各ドメインの現行仕様・再発防止 |
| `financials-summary-separation.md` | Summary 正本分離の進行中設計 |
| `xbrl-parsing.md` | XBRL 技術リファレンス・smoke/golden |
| `test-spec-assets.md` | テスト層区分の方針 |

床・バンプ定数の索引は `.agents/rules/project/versioning.md`（値はコード定義箇所）。

重複させない: 構成は architecture、進捗は roadmap、床は versioning、手順は deploy、結合点は operations。

## 残タスク・引き継ぎの置き場所

追跡可能でクローズ可能な残作業（バグ・未実装・改善）は **GitHub issue を正本**とする。roadmap の TODO や引き継ぎ文にはその詳細を複製せず、必要なら issue 番号への短い参照に留める。

| 置き場所 | 役割 |
|---|---|
| GitHub issue | 追跡可能な残作業の正本 |
| roadmap TODO | 現在地の索引 |
| `.claude/handoff.local.md`（非追跡） | セッション再開手順のみ |

issue の作成はユーザーに確認してから行う（GitHub に公開されるため）。
>>>>>>> e1a8390 (Document Region×Source naming and finish eu/esef layout.)
