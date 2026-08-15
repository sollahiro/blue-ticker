# XBRL解析

`Analysis/` の数値・ファイル探索は `XBRLUtils` を使う。同じパーサを各モジュールに書き直さない。コンテキスト判定と会計基準判定は `XBRLUtils` に置かない。

US-GAAP HTML は二経路を混同しない。Summary / financials は `USGAAPHtml`、Statement 本表は `USGAAPStatementHtml`。

タグ透明性は `AGENTS.md`。タグ体系・smoke 床は `docs/xbrl-parsing.md`。
