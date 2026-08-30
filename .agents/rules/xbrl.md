# XBRL 解析

- 数値・ファイル探索は `XBRLUtils` を使う。コンテキスト判定と会計基準判定は `XBRLUtils` に置かない。
- US-GAAP の Statement 本表と financials 組立は `USGAAPStatementHtml` / `USGAAPStatementHtmlVocabulary` を使う。`USGAAPHtml` は仮想タグヘルパと Extractor 単体テスト用。
- 抽出ロジックは EDINET / ESEF の実データで検証する。注記等は元の開示 HTML と抽出結果を照合する。
- statement・notes・breakdown の配信契約には可能な限り値の由来となる実 XBRL タグ名を載せる。固定プレースホルダーはタグを解決できない場合だけ使う。
- 会計基準・コンテキスト・smoke / golden の床は `docs/xbrl-parsing.md`。抽出 how-to は `.agents/skills/xbrl-development/SKILL.md`。
