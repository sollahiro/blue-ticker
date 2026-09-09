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
| 銘柄ページ | `概要` / `分解` の 2 枚。タイルは出さない。左右スライドのみ。下部の円（現行を大きく）で枚数と位置を示す。各カード内は縦スクロール可。概要の表はカード幅に収める。`レポート` は廃止 |
| 会社アイコン | 角丸四角・白背景。リスト行と銘柄ヘッダで同じ |
| App Icon | `assets/blt-icon/icons_ios_light.png` / `icons_ios_dark.png` を 1024・不透明 PNG にして `AppIcon` に載せる。角まで絵の色。`bb_mark.png` はツールバー用 |
| 社名表示 | 検索結果・銘柄ヘッダから「株式会社」を除く |
| 最低対応 OS | iOS 26.0。`IPHONEOS_DEPLOYMENT_TARGET` はプロジェクト側だけに置き、ターゲットは継承させる。iOS 26 の UI 作法（透過タブバー、`scrollEdgeEffectHidden` 等）をそのまま使い、`if #available` で古い OS に分岐させない |
| 背景 | 株価アプリ風のダーク。シェルはほぼ黒、カードは背景から浮かぶ濃いグレー、リスト行・コントロールはカードより黒寄り（`Theme.shell` / `Theme.card` / `Theme.control`）。紺の `#16446F` は使わない |
| 履歴 | 名称検索の右上ツールバー。開いた銘柄をクライアントローカル（`UserDefaults`、最大 30 件）に残す |
| 条件 | Screen。キーワードは正本にしない。Figma の業種チップ列は未完成で、インタラクティブな条件設定ができればよい |
| フロー | Sankey。未実装。銘柄の次カード（3 枚目）にする。smoke・`/sankey` は作らない。描画はクライアント責務（`sankey.md`） |
| インタビュー | 構想。銘柄カードからは外し、ロードマップに残す |
| ニュース | 開発廃止。銘柄カードから外す。Brave 等の外部ニュースは載せない |
| 概要の中タブ | `売上` / `利益率` / `CF` / `BS` / `投資` はフロー側の metric 切替へ移す（フロー実装時） |
| 概要 | Summary の水準値（損益など）。年度は古い順に左から右。単位は PL 系・キャッシュ系それぞれで表全体に共通のものを自動選択し、行ラベルに出す。`ROIC` / `ROE` は水準より推移が要るので概要には置かず分解へ回す。銘柄の短い会社説明（Overview）は概要カードの表の上（最大90字。footnote・カード幅で均等配置、最終行は左揃え）。入力は有報「企業の概況」の「事業の内容」。系統図だけで読めないときは「セグメント情報」の「報告セグメントの概要」へフォールバックする。長さは 50〜80 字が目安（合格上限 90 字）で、情報量が少なければ無理に足さない。「Nつの報告セグメントで〜」の枠まとめは書かない。生成・検証は `BlueTickerCore`。格納契約は `company_overviews`（会社1社=1行。由来の有報は `doc_id`。Filing texts キーは増やさない）。ingest stage は `overviews`。公開 REST は `GET /v1/companies/{code}/overview`（MCP には出さない） |
| 分解 | Waterfall の `事業利益` / `ROIC` / `ROE` のみ。ネットキャッシュ・CCC は出さない。`ROIC` / `ROE` は年度別の折れ線。未算出の年は点も線も描かない。前年差が無い年度は選べない。事業利益の一文は下部のみ（ROIC/ROE では出さない）。要因行の下に線を引き、その下に前年差（合計）の棒を置く。要因グラフに ± の凡例を置く。要因を選ぶと、投資に詳しくなくても読める ± の意味と計算式を出す |
| 事業利益 | 売上総利益 − 販管費。開示の営業利益ではない。分解の下部に一文を置く |
| 新着 | ウォッチリストだけ。名称検索の Feed 行には付けない。バッジの定義は未決のため v1 では出さない。Feed 行には提出日（`submitted_at`。矢印の左に「提出日」と日付）を出す |
| 近くの本社 | v1 から外す（位置情報も HQ API も無い） |
| ウォッチリスト | クライアントローカル（`SwiftData`）。起動時に概要・分解・Overview を先読みし、解析キャッシュを 7 日持つ |
| 解析キャッシュ | 概要・分解・Overview の REST 応答を端末 Caches に保存（標準 6 時間。ウォッチリスト銘柄は 7 日）。期限切れでも通信失敗時は最後の成功応答を出す。サーバーが 404 を返したら捨てる。検索・Feed はキャッシュしない。iOS は Core をリンクしないので `CacheManager` は使わない |
| 会社行 | 社名・業種に加え銘柄コードを載せる |
| 業種タグ | `search_companies` の `sector`（例: 富士フイルムは `化学`） |

## 要因の ±（分解）

投資に詳しくない人向け。棒の色と符号は「その要因が前年差をどちらへ動かしたか」だけを示す。行を選ぶと次の文言を出す。計算式は現行どおりその下に置く。売上・回転・レバレッジは、開示粗利率が無くてもサーバーが事業利益+販管費からマージンを出すことがある。逆転は報告マージンではなく、ドライバー増減と寄与の符号が食い違うときだけ判定し、「変化が押し上げ／押し下げ」と逆転の一文を出す。

共通（グラフ直下）:

> プラス（緑）はその要因が前年より押し上げた分、マイナス（赤）は押し下げた分です。行を選ぶと詳しく見られます。

| 要因 | 説明 | + | − |
|---|---|---|---|
| 売上要因 | 売上が増えたか減ったかが、利益にどれだけ効いたかです。 | 売上が増えて、利益を押し上げた | 売上が減って、利益を押し下げた |
| 利益率要因（事業利益） | 同じ売上でも、原価のあとに残る利益の割合が変わった分です。 | 仕入れや製造の効率が良くなり、同じ売上から残る利益が増えた | 原価がかさみ、同じ売上から残る利益が減った |
| 販管費要因 | 人件費・家賃・広告費などの経費の増減が、利益に効いた分です。経費は増えると利益が減ります。 | 経費が減り、利益が増えた | 経費が増え、利益が減った |
| 利益率要因（ROIC） | 事業に使っているお金に対して、どれだけ利益を出せるかが変わった分です。 | 同じお金でも、より多く稼げるようになった | 同じお金でも、稼げる額が減った |
| 回転率要因（ROIC） | 事業に使っているお金を、どれだけ効率よく売上に変えられたかが変わった分です。 | 同じ資金で、より多くの売上を回せるようになった | 資金が滞り、売上の回りが悪くなった |
| 純利益率要因 | 売上のうち、最終的に株主の手元に残る利益の割合が変わった分です。 | 売上に対して、残る利益の割合が上がった | 売上に対して、残る利益の割合が下がった |
| 回転率要因（ROE） | 会社の資産全体を使って、どれだけ売上を出せるかが変わった分です。 | 資産の使い方が良くなり、同じ資産でも売上が増えた | 資産の使い方が悪くなり、同じ資産でも売上が減った |
| レバレッジ要因 | 借入などを使って、自分たちのお金（自己資本）に対する収益をどれだけ膨らませたかの変化です。プラスが必ずしも良いとは限りません。 | 借入などの比率が上がり、自己資本あたりの収益を押し上げた | 借入などの比率が下がり、自己資本あたりの収益を押し下げた |

## 画面と既存 Feature

| 画面 | Feature | 備考 |
|---|---|---|
| 名称検索 | Feed Update / Search | 「最近新しい有報がアップロードされました」＋キーワード検索＋履歴。Feed は REST 省略時どおり直近90日を最大10件。同日過多のサンプルはサーバー。Feed Trend（「最近よく調べられています」）は呼び出しを保留中。再開時の 503 は空リスト |
| 条件検索 | Screen（BLT-49） | 横断フィルタ UI。`検索` で結果画面へ。Screen REST は未接続なので空状態。全社 `financials` をクライアントで絞らない |
| リスト | （クライアント） | ウォッチリスト |
| 概要 | Summary | 年次の水準値。表の上に Overview。未集計は 404 |
| 分解 | Waterfall | 行タップで要因分解。事業利益は売上差 / 粗利率差 / 販管費差。ROIC は利益率 / 回転率。ROE は純利益率 / 回転率 / レバレッジ。要因を選ぶと ± の意味（非専門家向け）と計算式（と可能な範囲で計算に使った数値）を出す |
| レポート | Filing | 銘柄カードから廃止。有報一覧は当面出さない |
| フロー | Sankey | 銘柄の次カード。ロードマップ。smoke・`/sankey` は作らない。描画はクライアント責務（`sankey.md`） |
| インタビュー | Report（構想） | ロードマップ。本来クライアント責務 |

## 条件（Screen）

ポンチ絵の業種チップは Screen の一部だけ。完成形のレイアウト再現は求めない。

アプリ側の制約（サーバー許可リストは削らない。BLT-49）:

- 業種は横スクロール 3 段のチップで複数選択。各段は自然幅で敷き詰める。楕円。選択時は業種色の塗り＋白文字、非選択は一律グレー地の白抜き。見切れマスクの曲率はセクション枠と同じで、枠から内側へオフセットする。リスト行・銘柄ヘッダの業種タグも同じ非選択スタイル。市場チップは出さない。REST 未接続のため送出契約は未決（AND にはしない）
- 数値指標の既定は `営業利益率` / `ROIC` / `ROE` の 3 つ。その下の `＋` でオプション行を足す（`売上高` / `売上増加率` / `粗利率` / `ネットD/E`）。追加行のタイトル右の上下シェブロンで項目を選び、右からのスライドでバツ削除。`＋` は常に最下行。各指標は DualRangeSlider（下限・上限、`[minValue, maxValue]`、値はハンドル上）。ソートは `roic` 降順、LIMIT 50 で固定
  - 売上高 `sales`（100 億円以上が緑、未満は黄）
  - 売上増加率 `sales_growth`（画面上のオプション。Summary `years[]` に YoY キーは無く、`screen_index` の派生列）
  - 粗利率 `gross_profit_margin`（売上高総利益率）
  - 営業利益率 `operating_margin`（開示営業利益 ÷ 売上。分解の事業利益率ではない）
  - ROIC `roic`
  - ROE `roe`
  - ネット D/E `net_de`
- スライダーはハンドルのドラッグだけが値を変える。トラックや余白のタップ、縦スクロール開始では動かない。ハンドル色は水準帯を赤→黄→緑で表す（文言ラベルは出さない）。数値はハンドルに追従し、近いときは重ならない。背景から横にはみ出さない。指標セクションの背景は設定のサーバー入力欄に近い黒寄り。Screen REST の許可リストは変えない
- 条件の実行はツールバーの `検索`。結果画面へ遷移する。Screen REST 未接続時は空状態。`絞り込む` は置かない
- 売上増加率 `sales_growth` は `screen_index` の派生列（最新 FY と直前 FY の `sales` から `%`。直前 FY が無い / 売上 0 以下なら null）。Summary の `years[]` には YoY キーを足さない
- 対象は最新 FY の Summary 水準値だけ。YoY / Waterfall / Breakdown / Notes は混ぜない
- 業種チップの候補はクライアント側の表示用カタログ。`GET /v1/companies?sector=` は足さない

Screen REST は `GET /v1/screen`（`screen_index` 読み取り。`sector` 完全一致 + `<metric>_min` / `<metric>_max` の AND + `sort` / `order` / `limit`（既定 `roic` / `desc` / 50、上限 200））。許可リストは上の 7 指標。応答は `items[]`（メタ + フィルタ / ソートに使った指標だけ）と `returned` / `matched` / `sort`。索引未生成（0 行）は 404、フィルタ 0 件は 200 で空配列。`screen_index` は財務 ingest 直後に 1 社ずつ派生更新し、欠落は次回 ingest の skip 時に補完、`blt-server screen-rebuild` で全件再生成する。skills カタログには載せない（BLT-49）。

## 認証

iOS は第三者と同じ公開 REST のクライアント。privileged にしない。トークン / Service Token は埋め込まない。`HAPIS_API_TOKEN` も consumer JWT として使わない。

| 段階 | 方針 |
|---|---|
| 開発 | loopback / http は無認証・Attest なし。既定 `http://127.0.0.1:3000`。同じ Wi-Fi の `http://<MacのIP>:3000` も無認証（現行どおり。段階 B でも変えない） |
| 自社プレビュー（段階 A） | `https://api.sollahiro.com` だけ Access SSO / OTP の短命 JWT（`CF_Authorization`）。設定の WebView（App Launcher）または Cookie 貼り付け。任意の https には載せない。Store 配布の口ではない |
| 段階 B（HAPIS、現行実装） | アカウント不要の本線は HAPIS ゲートウェイ。iOS は制御面で短命匿名 JWT を mint / refresh し、ゲートウェイへ `Authorization: Bearer` を付ける。blt-server は見ない。**クライアントは App Attest を sessions に載せる（Release）。本番サーバーの `ATTEST_MODE=enforce` はまだオフ**（stub のまま。この PR では切替しない）。Debug ビルドは stub mint のまま（Simulator / stub 制御面）。有料機能・ウォッチリスト同期が要るときだけ任意ログイン（Bearer）。機械直叩きの x402 は iOS の本線ではない |

設定の SSO は段階 A プレビュー用。https 本番のログインは Access の App Launcher（`sollahiro.cloudflareaccess.com`）から入る。`api.*` 直叩きは 403 interstitial になる。段階 B 着地後の本番公開扉は HAPIS（Access は staging の内部退避に残す）。MCP は製品認証に使わない。

### HAPIS consumer mint（クライアント）

公開 URL（秘密ではない。ハードコードしてよい）:

| 役割 | URL |
|---|---|
| 発行者（制御面） | `https://hapis.sollahiro.workers.dev` |
| 本番ゲートウェイ（API base） | `https://hapis-blue-ticker-production.sollahiro.workers.dev` |

- `GET /v1/consumer/challenge` — App Attest の mint / attest / assertion のたびに取る（単回使い切り。stub mint では呼ばない）。応答 `challenge` は 32 バイトの unpadded base64url
- `POST /v1/consumer/sessions` — 201 で `token` / `refresh_at` / `expires_at`
  - **Debug（既定）:** ボディ `{}`（stub）。本番制御面は `ATTEST_MODE=stub` のまま受ける。**本番 `ATTEST_MODE=enforce` はこの PR では切替しない**
  - **Release（本番ゲートウェイ経路）:** App Attest 証拠。`attest.key_id` + `challenge` + `client_data` + 初回は `attestation`、以降の remint は `assertion`
- `POST /v1/consumer/token/refresh` — まだ有効な Bearer。期限の約 5 分前（`refresh_at` / `refresh_in`）にサイレント refresh。期限切れは remint（401 `token_expired`）。refresh は JWT のみで Attest しない。blt-server / Vapor には consumer JWT を付けない
- ゲートウェイへの REST だけに Bearer を付ける。発行者以外の上流へ consumer JWT を送らない
- 設定の「HAPIS 本番」がゲートウェイを API base にする。「本番サーバー」は段階 A の `api.sollahiro.com`（Access）のまま
- Attest / トークン失敗: 制御面の mint / refresh は一時失敗を 2〜3 回。ゲートウェイの 401 `token_expired` は 1 回 remint。だめならキャッシュ表示 + 柔らかい「一時的に更新できない」。ハードブロックしない。Attest なしの緊急トークンは出さない（Simulator で App Attest 未対応なら失敗する。Debug は stub なので Simulator 検索は動く）

#### App Attest 証拠（Release / `blt.hapis.attestMode=appAttest`）

`DCAppAttestService`。鍵 ID は発行者 origin と App Attest 環境（Debug `development` / Release `production`）ごとに Keychain（JWT とは別）。Apple Team / Bundle はクライアントに秘密として置かず、enforce 時に制御面へ載せる。

`client_data` は常に challenge 埋め込み JSON（UTF-8、sorted keys）`{"challenge":"<GET /v1/consumer/challenge の値>"}`。`attestKey` も `generateAssertion` も `SHA256(client_data)`。challenge は attest / assertion のたびに取り直す。hash 対象は decoded challenge バイト列ではなく、この JSON の UTF-8。

1. 初回 mint: `GET /v1/consumer/challenge` → 上記 JSON の SHA256 で `attestKey` → sessions に `key_id` / `attestation`（base64url CBOR）/ `challenge` / `client_data`
2. 以降の remint: 新しい challenge を取り、同じ JSON で `generateAssertion` → sessions に `key_id` / `assertion` / `challenge` / `client_data`
3. 鍵は sessions 受理まで assertion に使わない。`attestKey` 失敗は同じ未登録鍵で再 attest。`attestKey` 成功後に sessions が落ちたら新しい鍵で attest（Apple は同じ鍵を再 attest できない）
4. 制御面の mint 一時失敗は challenge + 証拠を取り直して再送する（同じ attestation / assertion は使いまわさない）。challenge GET は mint の再試行に含め、内側で三重化しない。refresh は同じ JWT リクエストを再送してよい
5. 鍵が無効なら捨て、challenge を取り直して attest
6. 本番 `ATTEST_MODE=enforce` 時の subject は `app_attest:<keyId>`（サーバー）。今は stub なので `stub:<keyId>` になり得る
7. challenge の `expires_at` はサーバーが拒否する。クライアントは毎回取り直すだけで、TTL の事前判定はしない
8. Debug stub で発行したトークンを App Attest 経路（Release、または Debug 上書き再起動）に持ち込んだときは refresh せず取り直す。サーバー `attest_mode` は live stub でも `stub` なので、局所 `clientMintMode` で判定する

Debug 実機で Attest を試す: UserDefaults `blt.hapis.attestMode` = `appAttest`。`APIClient.shared` は起動時に provider を固定するので、上書きの反映には再起動。Release は常に App Attest。Entitlements: Debug `development`、Release `production`。

段階 B のトークン: TTL 約 1 時間。期限の約 5 分前にサイレント refresh。

### Mac / Simulator 手動スモーク（この PR では必須にしない）

Cloud Agent の Linux VM と、手元に Mac が無いラウンドではシミュレータ E2E を要求しない。単体は `Apps/BlueTicker/HAPISConsumer` の URLProtocol / HTTP mock（DeviceCheck は mock）。アプリの型検査は GitHub Actions `ios` ジョブ。Mac があるときの確認:

1. 設定 → ローカル（`http://127.0.0.1:3000` または LAN `http`）で検索できること（Bearer が付かない）
2. Debug ビルド → 設定 → HAPIS 本番。名称検索で `7203` など。200 で BLT JSON。制御面は stub mint（`POST /v1/consumer/sessions` が `{}`。challenge は叩かない）
3. プロキシで確認: ゲートウェイへ `Authorization: Bearer eyJ…`。発行者の mint/refresh（と Attest 時の challenge）以外に JWT が流れないこと
4. プロセスを殺して再起動しても、期限内なら mint せず検索できること。Keychain のトークンを捨てると sessions が再発行されること

#### 実機 App Attest（後で。Simulator では不可）

本番 `ATTEST_MODE` は stub のまま。実機 Release（または Debug + `blt.hapis.attestMode=appAttest`）:

1. 設定 → HAPIS 本番。検索できること
2. プロキシ: `GET /v1/consumer/challenge` のあと `POST /v1/consumer/sessions` に `attest.key_id`・`challenge`・`client_data`（`{"challenge":…}`）と、初回は `attestation`、2 回目以降は `assertion`
3. トークン破棄後の再検索は assertion（同じ key_id）。App Attest 未対応なら「一時的に更新できない」で、空の stub mint には落ちない
4. Access の「本番サーバー」と loopback は従来どおり（Attest も consumer JWT も付けない）


## 未決

- `インタビュー` の経営者 / アナリストは有報セクションか LLM か（カードはロードマップ）
- 設定の、開発用サーバー / Access ログイン / HAPIS 発行者以外
- ウォッチリストの「新着」を、その銘柄の新規有報としてよいか
- Screen REST を skills カタログに載せるか（BLT-49。listed drain 後でも別判断）

## Figma の途中

Starter の MCP 月次上限で、銘柄ヘッダのコードと分解の一文は未描き。探索の近くの本社削除、名称検索の新着削除、タブ／ヘッダの語、リストのコード、富士フイルム業種は反映済み。条件面は Figma 未完成のまま実装してよい。

## 関連

`architecture.md` · `sankey.md` · `financials-summary-separation.md` · `api-auth.md` · `public-api.md`
