# iOS クライアント

ネイティブ iOS の IA・画面対応。実装は `Apps/BlueTicker`（`open Apps/BlueTicker/BlueTicker.xcodeproj`）。REST `/v1` の HTTP クライアント。サーバー契約の正本は REST（`architecture.md`）。見た目は iOS SDK 標準コンポーネント。Figma の長方形はプレースホルダ。

ポンチ絵: [BLUE_TICKER / iOS](https://www.figma.com/design/sSGBrNMRkBLEgJOA43yIYc/BLUE_TICKER?node-id=67-30)。進捗は Linear Team `blue-ticker`（[BLT-53](https://linear.app/sollahiro/issue/BLT-53/ios-クライアントポンチ絵)）。条件面（Screen）は [BLT-49](https://linear.app/sollahiro/issue/BLT-49/jp-screen-v1-summary-横断検索)。

`BlueTickerCore` をリンクしない。iOS 専用の非公開エンドポイントを足さない。DTO は公開 JSON の手書き。Core の内部型をコピーしない。

## 置き場

`Apps/BlueTicker`。`Package.swift` の platforms は macOS のまま。Xcode プロジェクトは `Apps/` に閉じる。CI は `.github/workflows/ci.yml` の `ios` ジョブ（`macos-26`、シミュレータ SDK 向け `xcodebuild build`、署名なし）。`ios-paths` が `Apps/BlueTicker/` または `.github/workflows/ci.yml` の差分を見たときだけ走る。サーバーの `swift test` とはジョブを分けて並列に回す。シミュレータ不要の計算は `HAPISConsumer` / `ZeroAxisFill` / `FundMath` を `swift test` する。別リポジトリは App Store 署名がサーバー CI を汚し始めたら分ける。Cloud Agent の Linux VM では `xcodebuild` が無い。

## 決めたこと

| 項目 | 方針 |
|---|---|
| 探索 3 面 | `名称検索` / `条件検索` / `リスト`。OS 標準 `TabView`（タブバー）。各タブは `NavigationStack` + 標準ツールバー。右端は `ファンド`（設定タブは置かない） |
| 探索ツールバー | 不透明なトップバーは置かない。画面タイトルは標準のインライン `navigationTitle`。Liquid Glass のカプセルは「編集」「履歴」などツールバー操作だけ。B マークは探索に出さない。設定歯車タブは出さない |
| キーワード検索 | 名称検索の入力は `safeAreaBar`（タブバーの上。キーボード表示時はその上へ追従）。タブ選択だけではキーボードを出さない。`GET /v1/companies?q=`。銘柄・履歴へ push すると外れる |
| 銘柄面 | 探索から `NavigationStack` で push。タブの入れ子にしない。下部タブバー（`名称検索`〜`ファンド`）は探索と同じまま出す。カードとタブバーのあいだに 2 枚分のページ点を置く |
| 銘柄ヘッダ | ツールバーに B マークは出さない。戻るは標準の Liquid Glass。`探す` は出さない。上段は社名、下段はコードと業種。右側は `リストに追加` の下に `保有情報`（同じチップ高さ 2 段、合計 56pt）。未追加は `リストに追加`（青地・黒文字）、追加後は `追加済み`（青枠・抜き・青文字）。3 チップの横幅は `リストに追加` に揃える（追加済みで縮めない）。`保有情報` は白地・黒文字。社名は Headline +2pt。業種タグは緑枠・薄緑地・緑文字 |
| 銘柄ページ | `概要` / `分解` の 2 枚。タイルは出さない。左右スライドのみ。銘柄の短い会社説明（Overview）はヘッダ（社名・コード・業種）とカードのあいだ、カード外に置く。切替は各カード上端のピル型ボタン（概要は `業績` / `資産` / `効率性`、分解は `事業利益` / `ROIC` / `ROE`）。各カード内は縦スクロール可。カードは角丸。概要の表はカード幅に収める。`レポート` は廃止 |
| 会社アイコン | 角丸四角・白背景。リスト行と銘柄ヘッダで同じ |
| App Icon | `assets/blt-icon/icons_ios_light.png` / `icons_ios_dark.png` を 1024・不透明 PNG にして `AppIcon` に載せる。角まで絵の色。`bb_mark.png` はファンドのバージョンフッター用 |
| 社名表示 | 検索結果・銘柄ヘッダから「株式会社」を除く |
| 最低対応 OS | iOS 27.0。`IPHONEOS_DEPLOYMENT_TARGET` はプロジェクト側だけに置き、ターゲットは継承させる。iOS 27 の UI 作法（透過タブバー、ツールバー操作の Liquid Glass、`safeAreaBar` 等）をそのまま使い、`if #available` で古い OS に分岐させない |
| 背景 | 株価アプリ風のダーク。シェルはほぼ黒、カードは背景から浮かぶ濃いグレー、リスト行・コントロールはカードより黒寄り（`Theme.shell` / `Theme.card` / `Theme.control`）。紺の `#16446F` は使わない |
| 履歴 | 名称検索の右上ツールバー。開いた銘柄をクライアントローカル（`UserDefaults`、最大 30 件）に残す |
| 条件 | Screen。業種チップ + 3 プリセット。DualRangeSlider は出さない |
| フロー | Sankey。未実装。銘柄の次カード（3 枚目）にする。smoke・`/sankey` は作らない。描画はクライアント責務（`sankey.md`） |
| インタビュー | 構想。銘柄カードからは外し、ロードマップに残す |
| ニュース | 開発廃止。銘柄カードから外す。Brave 等の外部ニュースは載せない |
| 概要の中タブ | 概要カード上端のピルで `業績` / `資産` / `効率性` を切り替える。`業績` は売上高・売上総利益・営業利益・純利益・営業CF・投資CF・フリーCF。`資産` は正味現金・ネットD/E・自己資本比率・流動比率・固定比率。`効率性` は粗利率・営業利益率・純利益率・ROIC・ROE |
| 概要 | Summary の水準値（損益など）。年度は古い順に左から右。列は交互色ではなく FY ごとの縦線で区切る。単位は PL 系・キャッシュ系それぞれで表全体に共通のものを自動選択し、行ラベルに出す。`ROIC` / `ROE` の水準は効率性に置き、推移と要因分解は分解カードへ回す。銘柄の短い会社説明（Overview）は銘柄ヘッダとカードのあいだ、カード外（最大90字。footnote・ヘッダ幅で均等配置、最終行は左揃え。404 なら消す）。入力は有報「企業の概況」の「事業の内容」。系統図だけで読めないときは「セグメント情報」の「報告セグメントの概要」へフォールバックする。長さは 50〜80 字が目安（合格上限 90 字）で、情報量が少なければ無理に足さない。「Nつの報告セグメントで〜」の枠まとめは書かない。生成・検証は `BlueTickerCore`。格納契約は `company_overviews`（会社1社=1行。由来の有報は `doc_id`。Filing texts キーは増やさない）。ingest stage は `overviews`。公開 REST は `GET /v1/companies/{code}/overview`（MCP には出さない） |
| 分解 | Waterfall の `事業利益` / `ROIC` / `ROE` のみ。切替はカード上端のピル。ネットキャッシュ・CCC は出さない。`ROIC` / `ROE` は年度別の折れ線。未算出の年は点も線も描かない。前年差が無い年度は選べない。事業利益の一文は下部のみ（ROIC/ROE では出さない）。要因行の下に線を引き、その下に前年差（合計）の棒を置く。要因を選ぶと、棒の符号に応じた一文と計算式を出す |
| 事業利益 | 売上総利益 − 販管費。分解の下部に「開示されている営業利益と一致しない場合がございます。」 |
| 新着 | ウォッチリストだけ。名称検索の Feed 行には付けない。バッジの定義は未決のため v1 では出さない。Feed 行には提出日（`submitted_at`。矢印の左に「提出日」と日付）を出す |
| 近くの本社 | v1 から外す（位置情報も HQ API も無い） |
| ウォッチリスト | クライアントローカル（`SwiftData`。CloudKit コンテナは足していないので iCloud 同期はしない）。1 本のリスト。見出しは「あなたの追加した企業」。行は株数と取得単価（円/株）が両方入れば保有、欠けていればウォッチ（第三 enum は無い）。同じ銘柄は口座違いで複数行可。並べ替えはリストの `EditButton` + `onMove`（システムの editMode。独自のドラッグハンドルは足さない。編集中は会社アイコン・業種タグ・行の `>` を隠して、削除と並べ替えハンドルの余地を取る）。保有行のキャプションは口座ではなく保有数量。保有・口座の入力は銘柄ヘッダの `保有情報`。起動時に概要・分解・Overview を先読みし、解析キャッシュを 7 日持つ |
| 解析キャッシュ | 概要・分解・Overview の REST 応答を端末 Caches に保存（標準 6 時間。ウォッチリスト銘柄は 7 日）。期限切れでも通信失敗時は最後の成功応答を出す。サーバーが 404 を返したら捨てる。検索・Feed はキャッシュしない。iOS は Core をリンクしないので `CacheManager` は使わない |
| ファンド | タブ右端。公開 UI は「保有株数に応じた業績」（純利益 / 純資産 / 投資元本 / ファンドROE。ルックスルーは出さない）と「あなたの保有している企業」（ウォッチは出さない。リスト行と同じ会社アイコン。行は社名+コード、純利益・純資産・投資元本の 3 行。行タップで銘柄面）。保有・口座の入力は銘柄の `保有情報`。公開合計は銘柄単位で合算。バージョンはスクロール末尾に B マークと「バージョン x.y.z (ビルド n)」。サーバー切替・Access・発行者 URL は出さない。Debug だけ開発ラボ（ローカル / Access プレビュー / HAPIS）をファンド内の「開発ラボ」から開く。設定タブは復活させない |
| 会社行 | 社名・業種に加え銘柄コードを載せる。社名は最大3行 |
| 業種タグ | `search_companies` の `sector`（例: 富士フイルムは `化学`）。Feed からの遷移は `CompanyRef.sector` が空なので、銘柄面は `GET /v1/companies/{code}/financials` の `sector` で補う |

## 要因の ±（分解）

投資に詳しくない人向け。棒の色と符号は「その要因が前年差をどちらへ動かしたか」だけを示す。行を選ぶと、緑ならプラス、赤ならマイナスの一文を出す。計算式は現行どおりその下に置く。売上・回転・レバレッジは、開示粗利率が無くてもサーバーが事業利益+販管費からマージンを出すことがある。逆転は報告マージンではなく、ドライバー増減と寄与の符号が食い違うときだけ判定し、「変化が押し上げ／押し下げ」と逆転の一文を出す。

| 要因 | 説明 | + | − |
|---|---|---|---|
| 売上要因 | 売上が増えたか減ったかが、利益にどれだけ効いたかです。 | 前年に比べて、売上が増えて利益を押し上げました。 | 前年に比べて、売上が減って利益を押し下げました。 |
| 利益率要因（事業利益） | 同じ売上でも、原価のあとに残る利益の割合が変わった分です。 | 前年に比べて、仕入れや製造の効率が良くなり、同じ売上から残る利益が増えました。 | 前年に比べて、原価がかさみ、同じ売上から残る利益が減りました。 |
| 販管費要因 | 人件費・家賃・広告費などの経費の増減が、利益に効いた分です。経費は増えると利益が減ります。 | 前年に比べて、経費が減り、利益が増えました。 | 前年に比べて、経費が増え、利益が減りました。 |
| 利益率要因（ROIC） | 事業に使っているお金に対して、どれだけ利益を出せるかが変わった分です。 | 前年に比べて、同じお金でもより多く稼げるようになりました。 | 前年に比べて、同じお金でも稼げる額が減りました。 |
| 回転率要因（ROIC） | 事業に使っているお金を、どれだけ効率よく売上に変えられたかが変わった分です。 | 前年に比べて、同じ資金でより多くの売り上げを出せました。 | 前年に比べて、資金を効率よく活用できませんでした。 |
| 純利益率要因 | 売上のうち、最終的に株主の手元に残る利益の割合が変わった分です。 | 前年に比べて、売上に対して残る利益の割合が上がりました。 | 前年に比べて、売上に対して残る利益の割合が下がりました。 |
| 回転率要因（ROE） | 会社の資産全体を使って、どれだけ売上を出せるかが変わった分です。 | 前年に比べて、資産の使い方が良くなり、同じ資産でも売上が増えました。 | 前年に比べて、資産の使い方が悪くなり、同じ資産でも売上が減りました。 |
| レバレッジ要因 | 借入などを使って、自分たちのお金（自己資本）に対する収益をどれだけ膨らませたかの変化です。プラスが必ずしも良いとは限りません。 | 前年に比べて、借入などの比率が上がり、自己資本あたりの収益を押し上げました。 | 前年に比べて、借入などの比率が下がり、自己資本あたりの収益を押し下げました。 |

## 画面と既存 Feature

| 画面 | Feature | 備考 |
|---|---|---|
| 名称検索 | Feed Update / Search | 「最近新しい有報がアップロードされました」＋キーワード検索＋履歴。Feed 読み込み中は見出し右端に `ProgressView`。タブ往復では取り直さない。Feed は REST 省略時どおり直近90日を最大10件。同日過多のサンプルはサーバー。Feed Trend（「最近よく調べられています」）は呼び出しを保留中。再開時の 503 は空リスト |
| 条件検索 | Screen（BLT-49） | 業種チップ + 3 プリセット。タップで `GET /v1/screen` の結果へ。全社 `financials` をクライアントで絞らない |
| リスト | （クライアント） | ウォッチリスト 1 本。見出しは「あなたの追加した企業」。行はウォッチ／保有。`EditButton` + `onMove` で並べ替え。保有入力は銘柄の `保有情報` |
| ファンド | （クライアント） | 「保有株数に応じた業績」と「あなたの保有している企業」（ウォッチは出さない）。保有入力は銘柄の `保有情報`。並べ替えはリストの `EditButton`。指標は最新 FY Summary の `eps` / `bps`（円/株）。portfolio REST は足さない |
| 概要 | Summary | 年次の水準値。未集計は 404 |
| 分解 | Waterfall | 行タップで要因分解。事業利益は売上差 / 粗利率差 / 販管費差。ROIC は利益率 / 回転率。ROE は純利益率 / 回転率 / レバレッジ。要因を選ぶと、緑／赤に応じた一文と計算式（と可能な範囲で計算に使った数値）を出す |
| レポート | Filing | 銘柄カードから廃止。有報一覧は当面出さない |
| フロー | Sankey | 銘柄の次カード。ロードマップ。smoke・`/sankey` は作らない。描画はクライアント責務（`sankey.md`） |
| インタビュー | Report（構想） | ロードマップ。本来クライアント責務 |

## マイファンド（BLT-72）

手元の保有から利益・純資産・投資元本とファンドROEを見る。税務プロダクトではない。サーバーの portfolio API は足さない。指標は `GET /v1/companies/{code}/financials` の最新 FY（`years[].fy_end` が最大）の `eps` / `bps` だけ。キー名は Summary 公開 JSON の `eps` / `bps`（円/株）。Notes `per_share_information` はクライアントから呼ばない。欠測は「—」で、その行・銘柄を合計から外す（捏造しない）。公開 UI は「ルックスルー」「投下資本」を出さない（計算は同じ。表示は純利益 / 純資産 / 投資元本）。

計算（円。本表の百万円スケールは使わない）:

- 純利益（ルックスルー利益）= EPS（円/株）× 株数
- 純資産（ルックスルー純資産）= BPS（円/株）× 株数
- 投資元本（投下資本）= 取得単価（円/株）× 株数
- ファンドROE = Σ(EPS×株数) / Σ(取得単価×株数)（保有かつ EPS がある行だけ。時価・純資産合計は分母にしない）

同じ銘柄の口座行は管理上は分割してよい。公開合計は銘柄単位で株数を足してから掛ける。証券会社（SBI証券・楽天証券など）と口座区分（一般・特定・NISA）は選択式。未選択のままでもその行に株数を入れられる。株数は口座行ごと。保有の入力は銘柄ヘッダの `保有情報`（白地黒文字。証券会社・口座・株数・取得単価を口座ごとの1グループにまとめ、追加は下に足す。`口座を追加` のあとだけ `完了` を出し、空の追加入力を止められる。登録口座は各グループの `この口座を削除`。最後の1件はリストから外さず空のウォッチに戻す。複数口座なら先頭に合計保有数量と平均取得単価。`口座未選択` / `ウォッチ` と、株数・単価・口座が空の行は出さない。同じ銘柄に保有がある空ウォッチはリストに残さない）。並べ替えはリストタブの `EditButton`。ファンドは「保有株数に応じた業績」と「あなたの保有している企業」のみ（口座明細は出さない。保有企業一覧は社名+コードと純利益・純資産・投資元本の 3 行。行から銘柄面へ遷移する）。バージョンはリスト末尾に B マークと「バージョン x.y.z (ビルド n)」。

計算の切り出しは `Apps/BlueTicker/FundMath`（Linux / macOS の `swift test`）。

## 条件（Screen）

ポンチ絵の業種チップは Screen の一部だけ。完成形のレイアウト再現は求めない。

アプリ側の制約（サーバー許可リストは `ScreenMetric`。BLT-49）:

- 業種は横スクロール 3 段のチップで複数選択。セクション見出しは「業種を選ぶ」。各段は自然幅で敷き詰める。楕円。選択時は緑枠・薄緑地・緑文字、非選択は一律グレー地の白抜き。見切れマスクの半径はセクション枠の半径から内側オフセットを引く（outer r = inner r + padding）。リスト行・銘柄ヘッダの業種タグも選択時と同じ緑枠スタイル。市場チップは出さない。未選択と全選択は `sector` を送らない。1 業種は `sector=` 完全一致。2 業種以上は AND にせず、業種ごとに `GET /v1/screen` して ROIC 降順 50 件へマージする（サーバーは `sector` 1 件）
- DualRangeSlider・指標の詳細トグル・`ScreenMetricFilter` 組み立て UI は出さない。フローは業種（任意）→ プリセットタップ → 結果 → 銘柄
- プリセットは 3 つ。セクション見出しは「こんな企業を探す」（件数の読み込み中は見出し右端に `ProgressView`）。行はラベル（優良=青 / 成長=橙 / 安定=緑。業種タグと同形の枠）+ 1 行の説明文（「高収益で財務が健全な企業」など 15 字前後、1 行に収める）。右端に該当件数（`GET /v1/screen` の `matched`。`limit=1`。業種変更から 400ms debounce。タブ往復では取り直さない。未選択・全選択は 3 リクエスト。9 業種以上の部分選択は件数を出さない）。クライアントが `GET /v1/screen` の min/max + `sort=roic` desc に写す（閾値は整数、ネット D/E は 1 桁）:
  - **優良**: `roic_min=10`、`operating_margin_min=8`、`net_de_max=0.5`。成長フィルタなし
  - **成長**: `sales_cagr_3y_min=10`、`operating_margin_min=5`、`roic_min=8`。CAGR 上限なし
  - **安定**（旧 健全成長）: `sales_cagr_3y_min=5`、`roic_min=12`、`net_de_max=0.3`
- 結果行は常に core4 を出す（欠測は `—`。CAGR が null でも YoY に落とさない）: `roic` / `operating_margin` / `sales_cagr_3y` / `net_de`
- 理由はプリセット条件の短い言い換え（ブラックボックスのスコアではない）。プリセット行の脚注と結果セクションの footer に出す。チップは出さない
- `APIClient.screen` とサーバー許可リストの配線は残す。UI がスライダーを出さないだけ
- サーバー許可リスト: `sales`（サイズ。UI プリセットでは使わない）/ `operating_margin` / `roic` / `roe`（API は残す。UI では絞らない）/ `net_de` / `sales_cagr_3y`
- 3 期売上 CAGR `sales_cagr_3y` は `screen_index` の派生列。最新 Summary 年から売上 > 0 の直近 3 期を取り、`((latest/oldest)^(1/2) - 1) * 100`。3 期に満たなければ null。Summary の `years[]` には CAGR / YoY キーを足さない
- 対象は最新 FY の Summary 水準値だけ。YoY / Waterfall / Breakdown / Notes は混ぜない
- 業種チップの候補はクライアント側の表示用カタログ。`GET /v1/companies?sector=` は足さない

Screen REST は `GET /v1/screen`（`screen_index` 読み取り。`sector` 完全一致 + `<metric>_min` / `<metric>_max` の AND + `sort` / `order` / `limit`（既定 `roic` / `desc` / 50、上限 200））。許可リストは上の 6 指標。応答は `items[]`（メタ + core4 + フィルタ / ソートに使った指標）と `returned` / `matched` / `sort`。索引未生成（0 行）は 404、フィルタ 0 件は 200 で空配列。iOS 条件検索はこれを呼ぶ。`screen_index` は財務 ingest 直後に 1 社ずつ派生更新し、公開床（servable）の `company_financials` は現行 fin-vN 一致を問わず次回 ingest で投影する（列定義変更後の手動一発は `blt-server screen-rebuild`。`screenIndexVersion` = `screen-v2`。`fin-vN` は上げない）。skills カタログには載せない（BLT-49）。

## 認証

iOS は第三者と同じ公開 REST のクライアント。privileged にしない。トークン / Service Token は埋め込まない。`HAPIS_API_TOKEN` も consumer JWT として使わない。

| 段階 | 方針 |
|---|---|
| 開発 | loopback / http は無認証・Attest なし。既定 `http://127.0.0.1:3000`。同じ Wi-Fi の `http://<MacのIP>:3000` も無認証（現行どおり。段階 B でも変えない） |
| 自社プレビュー（段階 A） | `https://api.sollahiro.com` だけ Access SSO / OTP の短命 JWT（`CF_Authorization`）。**Debug ファンド → 開発ラボ**の WebView（App Launcher）または Cookie 貼り付け。任意の https には載せない。Store 配布の口ではない |
| 段階 B（HAPIS、現行実装） | アカウント不要の本線は HAPIS ゲートウェイ。iOS は制御面で短命匿名 JWT を mint / refresh し、ゲートウェイへ `Authorization: Bearer` を付ける。blt-server は見ない。**クライアントは App Attest を sessions に載せる（Release）。本番制御面は `ATTEST_MODE=enforce`**（stub mint は `missing_attest`）。Debug ビルドは stub mint のまま（Simulator / 手元ループバック用）。有料機能・ウォッチリスト同期が要るときだけ任意ログイン（Bearer）。機械直叩きの x402 は iOS の本線ではない |

**Release** は起動時から HAPIS ゲートウェイ固定。設定操作は不要（トークンはサイレント mint / refresh）。同じ Bundle ID の Debug UserDefaults は読まない。**Debug** のサーバー切替・Access SSO・発行者 URL はファンド面の開発ラボ。https 本番のログインは Access の App Launcher（`sollahiro.cloudflareaccess.com`）から入る。`api.*` 直叩きは 403 interstitial になる。段階 B 着地後の本番公開扉は HAPIS（Access は staging の内部退避に残す）。MCP は製品認証に使わない。

### HAPIS consumer mint（クライアント）

公開 URL（秘密ではない。ハードコードしてよい）:

| 役割 | URL |
|---|---|
| 発行者（制御面） | `https://hapis.sollahiro.workers.dev` |
| 本番ゲートウェイ（API base） | `https://hapis-blue-ticker-production.sollahiro.workers.dev` |

- `GET /v1/consumer/challenge` — App Attest の mint / attest / assertion のたびに取る（単回使い切り。stub mint では呼ばない）。応答 `challenge` は 32 バイトの unpadded base64url
- `POST /v1/consumer/sessions` — 201 で `token` / `refresh_at` / `expires_at`
  - **Debug（既定）:** ボディ `{}`（stub）。本番制御面は `ATTEST_MODE=enforce` なので拒否する（`missing_attest`）。Simulator / ローカル用
  - **Release（本番ゲートウェイ経路）:** App Attest 証拠。`attest.key_id` + `challenge` + `client_data` + 初回は `attestation`、以降の remint は `assertion`
- `POST /v1/consumer/token/refresh` — まだ有効な Bearer。期限の約 5 分前（`refresh_at` / `refresh_in`）にサイレント refresh。期限切れは remint（401 `token_expired`）。refresh は JWT のみで Attest しない。blt-server / Vapor には consumer JWT を付けない
- ゲートウェイへの REST だけに Bearer を付ける。発行者以外の上流へ consumer JWT を送らない
- **Release** の API base / 発行者はハードコード（ゲートウェイ + `hapis.sollahiro.workers.dev`）。ファンド面では切り替えない
- **Debug** の「HAPIS 本番」がゲートウェイを API base にする。「本番サーバー」は段階 A の `api.sollahiro.com`（Access）のまま
- Attest / トークン失敗: 制御面の mint / refresh は一時失敗を 2〜3 回。ゲートウェイの 401 `token_expired` は 1 回 remint。だめならキャッシュ表示 + 柔らかい「一時的に更新できない」。ハードブロックしない。Attest なしの緊急トークンは出さない（Simulator で App Attest 未対応なら失敗する。Debug は stub なので Simulator 検索は動く）

#### App Attest 証拠（Release / `blt.hapis.attestMode=appAttest`）

`DCAppAttestService`。鍵 ID は発行者 origin と App Attest 環境（Debug `development` / Release `production`）ごとに Keychain（JWT とは別）。Apple Team / Bundle はクライアントに秘密として置かず、enforce 時に制御面へ載せる。

`client_data` は常に challenge 埋め込み JSON（UTF-8、sorted keys）`{"challenge":"<GET /v1/consumer/challenge の値>"}`。challenge は attest / assertion のたびに取り直す。**hash は経路で分かれる**（HAPIS サーバーの verify 契約）:

| 経路 | Apple API | `clientDataHash` |
|---|---|---|
| 初回 mint（attestation） | `attestKey` | `SHA256(decoded challenge bytes)`（32 バイト raw。base64url 文字列や `client_data` JSON ではない） |
| 以降の remint（assertion） | `generateAssertion` | `SHA256(UTF-8 client_data JSON)` |

どちらも sessions には同じ `client_data` JSON を載せる。assertion はサーバーも JSON hash。attestation だけ raw challenge bytes。

1. 初回 mint: `GET /v1/consumer/challenge` → decoded challenge bytes の SHA256 で `attestKey` → sessions に `key_id` / `attestation`（base64url CBOR）/ `challenge` / `client_data`
2. 以降の remint: 新しい challenge を取り、`client_data` JSON の SHA256 で `generateAssertion` → sessions に `key_id` / `assertion` / `challenge` / `client_data`
3. 鍵は sessions 受理まで assertion に使わない。`attestKey` 失敗は同じ未登録鍵で再 attest。`attestKey` 成功後に sessions が落ちたら新しい鍵で attest（Apple は同じ鍵を再 attest できない）
4. 制御面の mint 一時失敗は challenge + 証拠を取り直して再送する（同じ attestation / assertion は使いまわさない）。challenge GET は mint の再試行に含め、内側で三重化しない。refresh は同じ JWT リクエストを再送してよい
5. 鍵が無効なら捨て、challenge を取り直して attest
6. 本番 `ATTEST_MODE=enforce` 時の subject は `app_attest:<keyId>`（サーバー）。今は stub なので `stub:<keyId>` になり得る
7. challenge の `expires_at` はサーバーが拒否する。クライアントは毎回取り直すだけで、TTL の事前判定はしない
8. Debug stub で発行したトークンを App Attest 経路（Release、または Debug 上書き再起動）に持ち込んだときは refresh せず取り直す。サーバー `attest_mode` は live stub でも `stub` なので、局所 `clientMintMode` で判定する
9. 鍵レコードは `client_data_hash_contract_version`（現行 `1` = attest が challenge bytes）。欠落や古い版は Keychain から捨て、次の mint で新しい `attestKey` をする。assertion の JSON hash は変えない。hash 契約をまた変えるときはこの版を上げる

Debug 実機で Attest を試す: UserDefaults `blt.hapis.attestMode` = `appAttest`。`APIClient.shared` は起動時に provider を固定するので、上書きの反映には再起動。Release は常に App Attest。Entitlements: Debug `development`、Release `production`。

段階 B のトークン: TTL 約 1 時間。期限の約 5 分前にサイレント refresh。残り 60 秒超なら手元のトークンで即リクエストを出し、refresh は裏で 1 本だけ走らせる（リクエスト経路で制御面の往復を待たない）。残り 60 秒以下は refresh を待つ。

### ゲートウェイの同時実行（`HAPISOriginGate`）

HAPIS の制限は 60/分のレートで同時数ではない。interactive（Feed / 検索 / 銘柄面）は 3 本まで並列に出し、銘柄面の financials / overview / waterfall を直列にしない。先読み（ウォッチリスト）は 1 本ずつ 4 秒間隔で、interactive が流れている・待っている間と、最後の interactive から 2 秒間は出さない。スロットが空いたら待ちを全員起こして条件を再確認させる（先頭だけ起こすと、その 1 本が間隔待ちで眠っている間に空きが使われない）。mint / refresh はスロットを取る前に済ませる。

### Mac / Simulator 手動スモーク（この PR では必須にしない）

Cloud Agent の Linux VM と、手元に Mac が無いラウンドではシミュレータ E2E を要求しない。単体は `Apps/BlueTicker/HAPISConsumer` の URLProtocol / HTTP mock（DeviceCheck は mock）。アプリの型検査は GitHub Actions `ios` ジョブ。Mac があるときの確認:

1. Debug → ファンド → 開発ラボ → ローカル（`http://127.0.0.1:3000` または LAN `http`）で検索できること（Bearer が付かない）
2. Debug → ファンド → 開発ラボ → HAPIS 本番。名称検索で `7203` など。200 で BLT JSON。制御面は stub mint（`POST /v1/consumer/sessions` が `{}`。challenge は叩かない）
3. プロキシで確認: ゲートウェイへ `Authorization: Bearer eyJ…`。発行者の mint/refresh（と Attest 時の challenge）以外に JWT が流れないこと
4. プロセスを殺して再起動しても、期限内なら mint せず検索できること。Keychain のトークンを捨てると sessions が再発行されること
5. Release はファンドの開発ラボを触らず検索できること（API base は HAPIS ゲートウェイ。バージョンはファンドのフッター）。Xcode の Run（Debug）は stub mint のため、本番 HAPIS（`ATTEST_MODE=enforce`）では `missing_attest` になる。実機の検索は Release を入れる

#### 実機 App Attest（後で。Simulator では不可）

本番 `ATTEST_MODE` は enforce。実機 Release（または Debug + `blt.hapis.attestMode=appAttest`。ただし Debug の Attest 環境は `development` で、本番 HAPIS の既定 `APP_ATTEST_ENVIRONMENT=production` とは合わない）:

1. Release はファンドの開発ラボを触らず検索できること。Debug で試すときはファンド → 開発ラボ → HAPIS 本番
2. プロキシ: `GET /v1/consumer/challenge` のあと `POST /v1/consumer/sessions` に `attest.key_id`・`challenge`・`client_data`（`{"challenge":…}`）と、初回は `attestation`、2 回目以降は `assertion`
3. Debug のトークン破棄後の再検索は assertion（同じ key_id）。App Attest 未対応なら「一時的に更新できない」で、空の stub mint には落ちない
4. Debug の Access「本番サーバー」と loopback は従来どおり（Attest も consumer JWT も付けない）


## 未決

- `インタビュー` の経営者 / アナリストは有報セクションか LLM か（カードはロードマップ）
- ファンド以外の製品設定（プライバシー、アカウント等）。バージョンはファンドフッター。開発ラボは Debug 限定
- ウォッチリストの「新着」を、その銘柄の新規有報としてよいか
- Screen REST を skills カタログに載せるか（BLT-49。listed drain 後でも別判断）

## Figma の途中

Starter の MCP 月次上限で、銘柄ヘッダのコードと分解の一文は未描き。探索の近くの本社削除、名称検索の新着削除、タブ／ヘッダの語、リストのコード、富士フイルム業種は反映済み。条件面は Figma 未完成のまま実装してよい。

## 関連

`architecture.md` · `sankey.md` · `financials-summary-separation.md` · `api-auth.md` · `public-api.md`
