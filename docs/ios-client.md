# iOS クライアント

ネイティブ iOS の IA・画面対応。実装は `Apps/BlueTicker`（`open Apps/BlueTicker/BlueTicker.xcodeproj`）。REST `/v1` の HTTP クライアント。サーバー契約の正本は REST（`architecture.md`）。見た目は iOS SDK 標準コンポーネント。Figma の長方形はプレースホルダ。

ポンチ絵: [BLUE_TICKER / iOS](https://www.figma.com/design/sSGBrNMRkBLEgJOA43yIYc/BLUE_TICKER?node-id=67-30)。進捗は Linear Team `blue-ticker`（[BLT-53](https://linear.app/sollahiro/issue/BLT-53/ios-クライアントポンチ絵)）。条件面（Screen）は [BLT-49](https://linear.app/sollahiro/issue/BLT-49/jp-screen-v1-summary-横断検索)。

`BlueTickerCore` をリンクしない。iOS 専用の非公開エンドポイントを足さない。DTO は公開 JSON の手書き。Core の内部型をコピーしない。

## 置き場

`Apps/BlueTicker`。`Package.swift` の platforms は macOS のまま。Xcode プロジェクトは `Apps/` に閉じる。CI は `.github/workflows/ci.yml` の `ios` ジョブ（`macos-26`、シミュレータ SDK 向け `xcodebuild build`、署名なし）。`ios-paths` が `Apps/BlueTicker/` または `.github/workflows/ci.yml` の差分を見たときだけ走る。サーバーの `swift test` とはジョブを分けて並列に回す。別リポジトリは App Store 署名がサーバー CI を汚し始めたら分ける。Cloud Agent の Linux VM では `xcodebuild` が無い。

## 決めたこと

| 項目 | 方針 |
|---|---|
| 探索 3 面 | `名称検索` / `条件検索` / `リスト`。OS 標準 `TabView`（タブバー）。各タブは `NavigationStack` + 標準ツールバー。設定はタブバー右端（リストの右） |
| 探索ツールバー | 左にブランドマーク。設定は下部タブの歯車 |
| キーワード検索 | 名称検索の下部検索欄（タブバーの直上）。`GET /v1/companies?q=` |
| 銘柄面 | 探索から `NavigationStack` で push。タブの入れ子にしない |
| 銘柄ヘッダ | ブランドマークは中央（探索の左マークと同じツールバー段）。`探す` は出さない。業種とウォッチ操作は右端に上下。未追加は `リストに追加`（青地・黒文字）、追加後は `追加済み`（青枠・抜き・青文字） |
| 銘柄ページ | `概要` / `分解` / `ニュース` / `レポート`。タイルは出さない。左右スライドのみ。下部の円（現行を大きく）で枚数と位置を示す。各カード内は縦スクロール可。概要の表はカード幅に収める |
| 社名表示 | 検索結果・銘柄ヘッダから「株式会社」を除く |
| 最低対応 OS | iOS 26.0。`IPHONEOS_DEPLOYMENT_TARGET` はプロジェクト側だけに置き、ターゲットは継承させる。iOS 26 の UI 作法（透過タブバー、`scrollEdgeEffectHidden` 等）をそのまま使い、`if #available` で古い OS に分岐させない |
| 背景 | 株価アプリ風のダーク。シェルはほぼ黒、カードは背景から浮かぶ濃いグレー、リスト行・コントロールはカードより黒寄り（`Theme.shell` / `Theme.card` / `Theme.control`）。紺の `#16446F` は使わない |
| 履歴 | 名称検索の右上ツールバー。開いた銘柄をクライアントローカル（`UserDefaults`、最大 30 件）に残す |
| 条件 | Screen。キーワードは正本にしない。Figma の業種チップ列は未完成で、インタラクティブな条件設定ができればよい |
| フロー | Sankey。未実装。銘柄カードからは外し、ロードマップに残す |
| インタビュー | 構想。銘柄カードからは外し、ロードマップに残す |
| ニュース | 外部ニュース。Brave News Search をサーバー経由（キーはアプリに埋め込まない） |
| 概要の中タブ | `売上` / `利益率` / `CF` / `BS` / `投資` はフロー側の metric 切替へ移す（フロー実装時） |
| 概要 | Summary の水準値（損益など）。年度は古い順に左から右。単位は PL 系・キャッシュ系それぞれで表全体に共通のものを自動選択し、行ラベルに出す。`ROIC` / `ROE` は水準より推移が要るので概要には置かず分解へ回す。銘柄の短い会社説明（Overview）の入力は有報「企業の概況」の「事業の内容」。長さは 50〜80 字が目安で、情報量が少なければ無理に足さない。生成・検証は `BlueTickerCore`。格納契約は `company_overviews`（会社1社=1行。由来の有報は `doc_id`。Filing texts キーは増やさない）。ingest stage / 公開 REST / iOS 製品面は未配線。 |
| 分解 | Waterfall の `事業利益` / `ROIC` / `ROE` のみ。ネットキャッシュ・CCC は出さない。`ROIC` / `ROE` は年度別の折れ線。未算出の年は点も線も描かない |
| 事業利益 | 売上総利益 − 販管費。開示の営業利益ではない。分解に一文を置く |
| 新着 | ウォッチリストだけ。名称検索の Feed 行には付けない。バッジの定義は未決のため v1 では出さない |
| 近くの本社 | v1 から外す（位置情報も HQ API も無い） |
| ウォッチリスト | クライアントローカル（`SwiftData`） |
| 会社行 | 社名・業種に加え銘柄コードを載せる |
| 業種タグ | `search_companies` の `sector`（例: 富士フイルムは `化学`） |

## 画面と既存 Feature

| 画面 | Feature | 備考 |
|---|---|---|
| 名称検索 | Feed Update / Search | 「最近新しい有報がアップロードされました」＋キーワード検索＋履歴。Feed Trend（「最近よく調べられています」）は呼び出しを保留中。再開時の 503 は空リスト |
| 条件検索 | Screen（BLT-49） | 横断フィルタ UI。`検索` で結果画面へ。Screen REST は未接続なので空状態。全社 `financials` をクライアントで絞らない |
| リスト | （クライアント） | ウォッチリスト |
| 概要 | Summary | 年次の水準値。未集計は 404 |
| 分解 | Waterfall | 行タップで要因分解。事業利益は売上差 / 粗利率差 / 販管費差。ROIC は利益率 / 回転率。ROE は純利益率 / 回転率 / レバレッジ |
| ニュース | News（Brave） | サーバー経由 preview。`GET /v1/companies/{code}/news`。キー未設定は空 |
| レポート | Filing | 有報一覧。v1 はページ枠 |
| フロー | Sankey | ロードマップ。smoke・`/sankey` は作らない。描画はクライアント責務（`sankey.md`） |
| インタビュー | Report（構想） | ロードマップ。本来クライアント責務 |

## 条件（Screen）

ポンチ絵の業種チップは Screen の一部だけ。完成形のレイアウト再現は求めない。

アプリ側の制約（サーバー許可リストは削らない。BLT-49）:

- 業種は横スクロール 3 段のチップで複数選択。各段は自然幅で敷き詰める。未選択は彩度を落とす。市場チップは出さない。REST 未接続のため送出契約は未決（AND にはしない）
- 数値指標は次の 6 つ。各指標は DualRangeSlider（下限・上限、`[minValue, maxValue]`、値はハンドル上）。ソートは `roic` 降順、LIMIT 50 で固定
  - 売上高 `sales`（100 億円以上が緑、未満は黄）
  - 粗利率 `gross_profit_margin`（売上高総利益率）
  - 営業利益率 `operating_margin`（開示営業利益 ÷ 売上。分解の事業利益率ではない）
  - ROIC `roic`
  - ROE `roe`
  - ネット D/E `net_de`
- スライダーのハンドル色は水準帯を赤→黄→緑で表す（文言ラベルは出さない）。数値はハンドルに追従し、近いときは重ならない。背景から横にはみ出さない。指標セクションの背景は設定のサーバー入力欄に近い黒寄り。Screen REST の許可リストは変えない
- 条件の実行はツールバーの `検索`。結果画面へ遷移する。Screen REST 未接続時は空状態。`絞り込む` は置かない
- **売上増加率は入れない。** Summary の `years[]` に YoY キーは無く、Screen v1 の 1 社 1 行（最新 FY）にも前年が無い。単体の概要では隣接 FY からクライアント計算できる。横断に載せるなら `screen_index` の派生列（公開契約）
- 対象は最新 FY の Summary 水準値だけ。YoY / Waterfall / Breakdown / Notes は混ぜない
- 業種チップの候補はクライアント側の表示用カタログ。`GET /v1/companies?sector=` は足さない

Screen REST（`screen_index`、横断エンドポイント、skills 掲載）はまだ無い。今は実装・カタログ追加をしない（BLT-49）。結果面は未接続の空状態。

## 認証

iOS は第三者と同じ公開 REST のクライアント。privileged にしない。

| 段階 | 方針 |
|---|---|
| 開発 | `127.0.0.1` 無認証（既存のローカル規則。既定ポートは `BLT_PORT` 未設定時 3000） |
| 自社本番（段階 A） | Access ユーザー SSO / OTP の短命 JWT。curl 用 Service Token はアプリに埋め込まない |
| 段階 B | iOS も第三者も x402。機能マスクはしない |

`api-auth.md` のクライアント表はまだ変えない。MCP は製品認証に使わない。

## ニュース（Brave）

候補は [Brave News Search](https://api-dashboard.search.brave.com/documentation/services/news-search)。EDINET の代替ではない。JP / `ja`、キーはサーバー側 `BLT_NEWS_CURATION_KEY`。iOS は公開 REST `GET /v1/companies/{code}/news` のみ（直叩きしない）。skills / MCP には未掲載の preview。

許可ソース（ホスト）: ロイター / 日経 / ブルームバーグ / TDnet（`release.tdnet.info`） / 東洋経済 / [PlantDB](https://plantdb.jp) / [LOGI-TODAY](https://www.logi-today.com/) / [SEMI Journal news](https://semi-journal.jp/news/latest.html)。クエリに `site:` を付け、応答でも同リスト以外は落とす。Brave 索引に載らないソース（TDnet 等）は 0 件になりうる。

## 未決

- 許可ソースの追加・除外と、TDnet など Brave 非索引の扱い
- `インタビュー` の経営者 / アナリストは有報セクションか LLM か（カードはロードマップ）
- `設定` の中身（開発用の base URL 以外）
- ウォッチリストの「新着」を、その銘柄の新規有報としてよいか
- Screen REST をいつ公開するか（BLT-49。listed drain 後でもカタログ追加は別判断）

## Figma の途中

Starter の MCP 月次上限で、銘柄ヘッダのコードと分解の一文は未描き。探索の近くの本社削除、名称検索の新着削除、タブ／ヘッダの語、リストのコード、富士フイルム業種は反映済み。条件面は Figma 未完成のまま実装してよい。

## 関連

`architecture.md` · `sankey.md` · `financials-summary-separation.md` · `api-auth.md` · `public-api.md`
