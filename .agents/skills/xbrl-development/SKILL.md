---
name: xbrl-development
description: XBRL 抽出ロジック、Stage、statement・notes・breakdown 契約を追加または変更するときに使う。
---

# XBRL 開発

## 先に読む

- `.agents/rules/xbrl.md`
- `.agents/rules/versioning.md`
- `docs/xbrl-parsing.md` §6
- 配信面を変える場合は `docs/feature-tiers.md` と該当 Contract

## 手順

1. `docs/xbrl-parsing.md` の固定 smoke 企業で実データを取得し、ローカルの `swift test` で床を確認する。
2. 抽出値と元の開示 HTML、コンテキスト、実タグ名を照合する。推測やモックだけで採否を決めない。
3. smoke で拾えない失敗事例を該当 `RealXbrl*Tests.swift` の golden に追加する。新しい note type / breakdown 軸は smoke の床も広げる。
4. 抽出ロジックまたは契約の意味が変わる場合だけ Contract `cache_version` を上げる。細かな連続バンプはマージ前に 1 つへまとめる。
5. ロジックが安定したら disposable Neon へ日経225限定で ingest し、件数・欠測・`needs_review` と `/v1` の配信契約を確認する。
6. 本番 write、公開、対象母集団の拡張はユーザー確認後に `.agents/skills/production-ingest/SKILL.md` に従う。

## 母集団

- statements、financials、filing-sections、breakdowns の business / geography は上場全体が最終母集団。`assets/nikkei225.csv` は処理優先度であり対象限定ではない。
- notes と breakdowns の employees / rd / goodwill は日経225限定。限定実行では `--codes` 等で対象を明示する。
- 最新有報を取得できた会社を分母とし、欠測が正当か抽出不具合かを実データで判定する。
- coverage の分母は最新 120 がある対象社・書類とし、120 がない上場社は含めない。
