# バージョン

`blueTickerVersion`（`Constants/Version.swift`）は `YY.M.Micro`。月が変われば `YY.M.0`、月内は Micro +1。機能コミットとバンプは分ける。

## リリース（依頼されたとき）

1. 対象を main へ push し CI（macOS+Linux）緑を確認。ローカル test だけではタグを切らない
2. `blueTickerVersion` を更新し `chore: bump version to YY.M.Micro`
3. 軽量タグ `vYY.M.Micro` を push（`v*` ではデプロイしない。既存タグの付け直し禁止）

## Neon `cache_version`

`blueTickerVersion` と独立。値は各 Contract 定数が正本。上げるのは抽出ロジックまたは契約の意味が変わったときだけ。read 床（`*MinServableVersion`）は serving ポリシー変更時。LLM 行はバンプだけでは再計算しない（`needs_review` または削除）。

**タイミング**: smoke〜ロジック確認中の PR でも、上記の変更理由があれば定数を上げてよい（次の ingest から新世代。マージ前の連続バンプは1つにまとめてよい）。`AGENTS.md` 実装サイクル表の段階10「バンプする」は、全銘柄展開後の本番 write 定着バンプを指す（段階1–9の「しない」は本番再計算の義務付けをしない意味であり、PR 内の定数上げを禁じない）。
