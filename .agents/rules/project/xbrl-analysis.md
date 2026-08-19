# XBRL解析

`Analysis/` の数値・ファイル探索は `XBRLUtils` を使う。同じパーサを各モジュールに書き直さない。コンテキスト判定と会計基準判定は `XBRLUtils` に置かない。

US-GAAP HTML は二経路を混同しない。Statement 本表と financials 組立の本表行は `USGAAPStatementHtml`。`USGAAPHtml` は仮想タグヘルパと Extractor 単体テスト用。

タグ透明性は `AGENTS.md`。タグ体系・smoke 床は `docs/xbrl-parsing.md`。
