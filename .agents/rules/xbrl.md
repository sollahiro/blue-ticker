# XBRL 解析

- 数値・ファイル探索は `XBRLUtils` を使う。コンテキスト判定と会計基準判定は `XBRLUtils` に置かない。
- US-GAAP の Statement 本表と financials 組立は `USGAAPStatementHtml` / `USGAAPStatementHtmlVocabulary` を使う。`USGAAPHtml` は仮想タグヘルパと Extractor 単体テスト用。
- 抽出ロジックは可能な限り抽象化する。表の切り出し・結合セルの展開・数値セルの解析・TextBlock の読み取り・文字の詰め方（空白・改行の正規化）など、複数の機能で同じ形の処理は共有の部品に寄せ、機能ごとに書き直さない。
- 文脈を読まないと決められない構造化（どの行が誰を指すか、見出しと値の対応、自由記述の分類など）は Jev に委託する。決定論で拾える部分はコードで拾い、Jev には残りの判断だけを渡す。
- 機能ごとに固有の傾向（その注記に特有の見出し語、列の並び、注記記号の書式など）はコードにハードコードしてよい。ただし社名を直書きした辞書・例外リストは作らない。
- 抽出ロジックは EDINET の実データで検証する。注記等は元の開示 HTML と抽出結果を照合する。
- statement・notes・breakdown の配信契約には可能な限り値の由来となる実 XBRL タグ名を載せる。固定プレースホルダーはタグを解決できない場合だけ使う。
- 会計基準・コンテキスト・smoke / golden の床は `docs/xbrl-parsing.md`。抽出 how-to は `.agents/skills/xbrl-development/SKILL.md`。
