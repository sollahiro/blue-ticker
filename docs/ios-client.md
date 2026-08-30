# iOS クライアント（ポンチ絵）

ネイティブ iOS の IA・画面対応。サーバー契約の正本は REST `/v1`（`architecture.md` / `feature-tiers.md`）。見た目は iOS SDK 標準コンポーネント前提の簡易矩形で、Figma の長方形はプレースホルダ。

ポンチ絵: [BLUE_TICKER / iOS](https://www.figma.com/design/sSGBrNMRkBLEgJOA43yIYc/BLUE_TICKER?node-id=67-30)。進捗は Linear Team `blue-ticker`。

## 決めたこと

| 項目 | 方針 |
|---|---|
| 探索 3 面 | `トップ` / `条件` / `リスト`。`TabView` + `.tabViewStyle(.page)` で左右スワイプ。下の 3 ラベルはページインジケータ（タップでも移動） |
| 銘柄面 | 探索から `NavigationStack` で push。タブの入れ子にしない |
| 銘柄ヘッダ | `探す`（探索へ戻る）と `設定`。戻るは標準 Back |
| 検索欄の実行 | `検索`（クエリ送信）。`search_companies` の `q` |
| フロー | Sankey。未実装。タブだけ先に置いてよい |
| 概要の中タブ | `売上` / `利益率` / `CF` / `BS` / `投資` はフロー側の metric 切替へ移す |
| 概要 | Summary の水準値（損益など） |
| 分解 | Waterfall の `事業利益` / `ROIC` / `ROE` のみ。ネットキャッシュ・CCC は出さない |
| 事業利益 | 売上総利益 − 販管費。開示の営業利益ではない。分解に一文を置く |
| 新着 | ウォッチリストだけ。トップの Feed 行には付けない |
| 近くの本社 | v1 から外す（位置情報も HQ API も無い） |
| ウォッチリスト | クライアントローカル（`SwiftData` / `UserDefaults`） |
| 会社行 | 社名・業種に加え銘柄コードを載せる |
| 業種タグ | `search_companies` の `sector`（例: 富士フイルムは `化学`） |

## 画面と既存 Feature

| 画面 | Feature | 備考 |
|---|---|---|
| トップ | Feed Trend / Feed Update | 「最近よく調べられています」「最近新しい有報がアップロードされました」 |
| 条件 | Search | キーワードが正本。業種チップは下記「未決」 |
| リスト | （クライアント） | ウォッチリスト |
| 概要 | Summary | 年次の水準値。未集計は 404 |
| 分解 | Waterfall | 行タップで要因分解（売上差 / 粗利率差 / 販管費差） |
| フロー | Sankey | smoke・`/sankey` 未公開。描画はクライアント責務（`sankey.md`） |
| インタビュー | Report（構想） | 本来クライアント責務 |
| レポート | Filing または外部ニュース | ニュースは下記「未決」 |

## 条件画面

- 上にキーワード欄（コードまたは社名）
- 業種チップは単一選択。未選択ならキーワード結果のみ。複数業種の AND はしない
- 市場チップは出さない（`market` は「上場」だけで、プライム等ではない）
- 結果行は社名・コード・業種。空なら「社名かコードを入力するか、業種を 1 つ選ぶ」

`GET /v1/companies` は `q` のみ、返却上限 50。業種ブラウズをサーバーでやるなら `?sector=` が要る（公開契約の変更。確認してから）。契約を触らない v1 はキーワードを正本にし、チップは見た目かクライアント側のヒット絞りに留める。

## ニュース（Brave）

候補は [Brave News Search](https://api-dashboard.search.brave.com/documentation/services/news-search)（`q` 必須、`freshness` / `search_lang` / `country`、`site:`、Goggles）。EDINET の代替ではない。有報・Summary と並べるなら出典を分ける。JP / `ja` の対応、料金、利用規約、キー管理、iOS 直叩きかサーバー経由かは未決。サーバーに載せるなら外部 API 追加になる。

## 未決

- 業種チップを `?sector=` で本物にするか、v1 はキーワード正本にするか
- ニュースを iOS から Brave 直呼び出しか、サーバー経由か。有報と同一カードに載せるか
- `インタビュー` の経営者 / アナリストは有報セクションか LLM か
- `設定` の中身
- ウォッチリストの「新着」を、その銘柄の新規有報としてよいか
- フローは空プレースホルダを 1 枚置くか、タブだけ先に置くか
- iOS の REST 認証（段階 A の Service Token か、別方式か）。`api-auth.md` はまだ変えない

## Figma の途中

Starter の MCP 月次上限で、銘柄ヘッダのコードと分解の一文は未描き。探索の近くの本社削除、トップの新着削除、タブ／ヘッダの語、リストのコード、富士フイルム業種は反映済み。

## 関連

`feature-tiers.md` · `architecture.md` · `sankey.md` · `financials-summary-separation.md` · `api-auth.md` · `public-api.md`
