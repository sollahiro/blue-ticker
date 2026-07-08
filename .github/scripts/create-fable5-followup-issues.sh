#!/usr/bin/env bash
# Fable 5 レビュー追跡用 issue 一括作成スクリプト。
# 前提: gh auth login 済み、リポジトリ root で実行。
set -euo pipefail

create_issue() {
  local title="$1"
  local body="$2"
  local labels="$3"
  gh issue create --title "$title" --label "$labels" --body "$body"
}

create_issue \
  "fix: parseHtmlNumber が ▲ 負値表記を扱えない" \
  "$(cat <<'EOF'
## 概要
`XBRLUtils.parseHtmlNumber` は `△` のみ負値変換するが、`parseTextblockCellValue` は `△`/`▲` 両対応。US-GAAP HTML / IFRS リース HTML 経路で ▲ 表記の負値が nil に落ちる。

## 該当箇所
- `Sources/BlueTicker/Analysis/XBRLUtils.swift:64-78`

## 修正方針
`parseTextblockCellValue` と同様に `▲` プレフィックスを `-` に変換。テストを `XBRLUtilsTests` に追加。

## 優先度
中（特定表記の HTML 表で値欠落）
EOF
)" \
  "bug"

create_issue \
  "fix: HTML エンティティデコードの順序バグと重複実装" \
  "$(cat <<'EOF'
## 概要
`&amp;` を最初に置換するため `&amp;lt;`（リテラル `<`）が `<` に過剰デコードされる。同一実装が2箇所に重複している。

## 該当箇所
- `Sources/BlueTicker/Analysis/XBRLUtils.swift:443-452`
- `Sources/BlueTicker/Analysis/XBRLSectionParser.swift:359-368`

## 修正方針
1. `&amp;` を最後に置換する順序へ修正
2. 共通ヘルパーへ集約（重複ロジック規約）

## 優先度
中
EOF
)" \
  "bug"

create_issue \
  "fix: withFileLock のステイルロック除去 TOCTOU レース" \
  "$(cat <<'EOF'
## 概要
2プロセスが同時にステイル判定すると、片方が取得した新しいロックをもう片方が削除し、二重取得が起こり得る。

## 該当箇所
- `Sources/BlueTicker/API/EdinetCacheStore.swift:180-184`

## 修正方針
ロックファイルの inode 確認、または rename ベースの除去で TOCTOU を塞ぐ。

## 優先度
中（発生確率は低い）
EOF
)" \
  "bug"

create_issue \
  "fix: extractTextblockHtml の正規表現タグ名前方一致" \
  "$(cat <<'EOF'
## 概要
`<[^>]*:TagName[^>]*>` は `TagNameSomething` のような長いタグ名にもマッチする。

## 該当箇所
- `Sources/BlueTicker/Analysis/XBRLUtils.swift:365`

## 修正方針
`[\s>/]` 等でタグ名境界を締める。

## 優先度
中
EOF
)" \
  "bug"

create_issue \
  "refactor: abs(\$0) >= 200 ヒューリスティックの定数化とフォールバック" \
  "$(cat <<'EOF'
## 概要
2億円閾値が4箇所にハードコード。`financialTotals` はフォールバックなしのため、赤字年で法人税等が200百万円未満の場合に nil になる。

## 該当箇所
- `Sources/BlueTicker/Analysis/XBRLUtils.swift:428`
- `Sources/BlueTicker/Analysis/USGAAPHtmlFields.swift:243,268,304`

## 修正方針
1. `Constants` へ閾値を移動
2. `financial.isEmpty` 時のフォールバック方針を検討

## 優先度
中
EOF
)" \
  "enhancement"

create_issue \
  "investigate: USGAAP_HTML_ShareBuyback 死にタグ" \
  "$(cat <<'EOF'
## 概要
`Extractors.swift:925` で消費されるが `USGAAPHtml` に生成箇所がない。US-GAAP 企業の自己株式取得は常に非連結 SS フォールバックに落ちる。

## 確認事項
未実装なのか取り残しなのか。必要なら HTML 抽出を実装、不要ならタグ参照を削除。

## 優先度
低（レガシー候補）
EOF
)" \
  "enhancement"

create_issue \
  "refactor: 日付→文字列変換の3実装を集約" \
  "$(cat <<'EOF'
## 概要
`FiscalYear.formatDateString` / `EdinetAPIClient.isoDate` / `EdinetDiscovery.formatDateISO` が同一モジュール内で重複。

## 修正方針
`FiscalYear.formatDateString`（UTC 固定）へ集約。

## 優先度
低
EOF
)" \
  "enhancement"

create_issue \
  "cleanup: Python 移植名残の常に空フィールド" \
  "$(cat <<'EOF'
## 概要
`MasterStock.s17nm/s17`、`CompanyBasicInfo.nameEn/sector17/sector17Name` は常に空文字。

## 修正方針
利用箇所を確認し、不要なら型から削除または deprecated 化。

## 優先度
低
EOF
)" \
  "enhancement"

create_issue \
  "cleanup: 旧キャッシュパス互換コードの削除検討" \
  "$(cat <<'EOF'
## 概要
`CacheManager.legacyCacheFilePath`、`EdinetCacheStore` の cacheDir 直下フォールバック、`CachePruner` の旧形式 glob が残存。

## 前提
移行完了が確認できてから削除。

## 優先度
低
EOF
)" \
  "enhancement"

create_issue \
  "fix: EdinetAPIClient の AsyncLock 辞書が無限成長" \
  "$(cat <<'EOF'
## 概要
`downloadLocks` / `documentIndexLocks` は docID ごとの `AsyncLock` を削除しないため、長時間 ingest でメモリが純増する（XBRLUtils キャッシュ FIFO 化と同型の問題）。

## 該当箇所
- `Sources/BlueTicker/API/EdinetAPIClient.swift:15-16,177,385`

## 修正方針
LRU / FIFO 上限、または ingest 完了後の prune。

## 優先度
低〜中（長時間運用で顕在化）
EOF
)" \
  "bug"

create_issue \
  "fix: Routes の包括 catch が内部エラー詳細をレスポンスに漏洩" \
  "$(cat <<'EOF'
## 概要
`String(describing: error)` をそのまま 500 レスポンスに返すため、DB 接続文字列等が漏れる可能性がある。

## 該当箇所
- `Sources/BltServerCore/Routes.swift:223`

## 修正方針
クライアントには汎用メッセージ、詳細はサーバーログのみ。

## 優先度
低〜中（セキュリティ）
EOF
)" \
  "bug,security"

create_issue \
  "docs: caching.md に xbrl_sections / misc が未記載" \
  "$(cat <<'EOF'
## 概要
`CacheManager.categoryDir` が実際に使う `xbrl_sections` / `misc` がドキュメント一覧にない。

## 修正方針
`.agents/rules/project/caching.md` を実装に合わせて更新。

## 優先度
低
EOF
)" \
  "documentation"

echo "Done. Created follow-up issues."
