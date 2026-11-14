# カバレッジ / バックログの書き方

2026-09-22 の規則。

取り込み面を一つに畳まない。次は **必ず別行（または別列）** で書く。

| 面 | テーブル / 意味 |
|---|---|
| **financials** | `company_financials`（Summary / スクリーン用） |
| **statements** | `company_statements`（statement HTML / 構造化財務諸表） |

あるコードは financials では埋まっていて、statements は空、ということが起きる。面を言わずに「バックログ」と書くと、埋まっている側を根拠に訂正してしまう。

## 最低限の書式

コードまたは集団ごとに 2 行（または 2 列）:

- `financials:` done | empty | N/total | 注記
- `statements:` done | empty | N/total | 注記

filings / overview / screen_index を足すときも、それぞれ独自の行にする。financials に含めない。

## やってはいけないこと

- テーブル名を言わずに「埋まった」と言う。
- statements の残りリストを financials の状況として使い回す。
- Neon にしかないキーを、公開面のカバレッジとして使う。
