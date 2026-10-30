# iOS クライアント

ネイティブ iOS の IA・画面対応。実装は `Apps/BlueTicker`（`open Apps/BlueTicker/BlueTicker.xcodeproj`）。REST `/v1` の HTTP クライアント。サーバー契約の正本は REST（`architecture.md`）。見た目は iOS SDK 標準コンポーネント。Figma の長方形はプレースホルダ。

ポンチ絵: [BLUE_TICKER / iOS](https://www.figma.com/design/sSGBrNMRkBLEgJOA43yIYc/BLUE_TICKER?node-id=67-30)。変動する進捗は Linear Team `blue-ticker`（[JP 現在地](https://linear.app/sollahiro/document/jp-現在地-af2abd076034) / [公開と基盤 現在地](https://linear.app/sollahiro/document/公開と基盤-現在地-3bd56370454b)）。いまの床は Summary / Statement-Notes / Breakdown。条件面（Screen）は実装済み。

`BlueTickerCore` をリンクしない。iOS 専用の非公開エンドポイントを足さない。DTO は公開 JSON の手書き。Core の内部型をコピーしない。

## 名称（アプリと API）

アプリのユーザー向け名称は **有報LAB**、英語（ラテン文字）表記は **YUHO LAB**（大文字・スペースあり）。1.2.0 から。旧作業名「有報ラボ（YuhoLab）」は使わない。アプリが使うサーバー（REST・MCP）の外向き名称も **有報LAB API**（YuhoLAB API）に揃える（2026-10-27）。旧名「ブルーティッカーAPI（Blue Ticker API）」は使わない。内部の抽出・解析ロジックは **BLT**（Business Line Terminal）と呼び、`blt-server`・`blt-ingest`・`BLT_*` などの `blt` 接頭辞はこの略として残す。

| 対象 | 名称 |
|---|---|
| ホーム画面の表示名・App Store のアプリ名・法務ページ上のアプリ名 | 有報LAB / YUHO LAB |
| REST `/v1`・HAPIS・MCP の製品名・ドキュメント上の API 名 | 有報LAB API / YuhoLAB API |
| 抽出・解析ロジック、`blt-server`・`blt-ingest`・`BLT_*` 環境変数などの内部名 | BLT（Business Line Terminal） |

表示名の定義は `INFOPLIST_KEY_CFBundleDisplayName`（pbxproj。ja の `有報LAB`）と `InfoPlist.xcstrings`（ja `有報LAB` / en `YUHO LAB`）だけに置く。1.1.x の表示名は `Blue Ticker`。

改名しても変えない内部識別子（ストアの同一アプリ・iCloud データ・Keychain の引き継ぎに効くので触らない）:

- Bundle ID `com.sollahiro.BlueTicker`、アプリ ID `6807425773`、Team `BM744XMK6M`
- CloudKit コンテナ `iCloud.com.sollahiro.BlueTicker`
- Keychain service `com.sollahiro.BlueTicker.hapisConsumer` / `com.sollahiro.BlueTicker.hapisAttestKey`
- ターゲット／スキーム `BlueTicker`、`PRODUCT_NAME`、型名 `BlueTickerApp`、置き場 `Apps/BlueTicker`
- Xcode Cloud ワークフロー（下の「配布」）

文書やコードの文言でアプリを指すときは有報LAB、外向きの API を指すときは有報LAB API、内部の抽出・解析ロジックを指すときは BLT と書き分ける。リポジトリ名 `sollahiro/blue-ticker`・Swift モジュール `BlueTicker` / `BlueTickerCore`・R2 バケットなど「blue-ticker」と綴った識別子は、移行を決めるまで旧名のまま残る（Linear の有報LAB リブランディング計画で判断）。

## 置き場

`Apps/BlueTicker`。`Package.swift` の platforms は macOS のまま。Xcode プロジェクトは `Apps/` に閉じる。シミュレータ不要の計算は `HAPISConsumer` / `ZeroAxisFill` / `FeedRSS` / `ScreenSnapshot` を `swift test` する。Cloud Agent の Linux VM では `xcodebuild` が無い。

マージ品質と配布は分け、同じ検証を二箇所で走らせない。

| 経路 | 役割 |
|---|---|
| GitHub Actions `.github/workflows/ci.yml` | マージ品質。`ios` ジョブは `macos-26`、シミュレータ SDK 向け `xcodebuild build`、署名なし。`ios-paths` が `Apps/BlueTicker/` または `ci.yml` の差分を見たときだけ走る。サーバーの `swift test` とはジョブを分けて並列 |
| Xcode Cloud | 配布のみ。Release Archive → TestFlight Internal。ワークフローは App Store Connect が正本 |

Xcode Cloud を GitHub の required check にしない。PR Changes も、Archive ワークフローへの Test / Analyze も足さない。GHA に Archive や TestFlight アップロードを足さない。証明書と ASC API キーは GitHub secrets に置かない。

品質ゲートを Xcode Cloud に寄せるのは、アプリに XCTest が載ってシミュレータ実行がマージ条件になるとき、または署名なし compile では entitlements 差を捉えられなくなったときに限る。そのときは GHA `ios` を消して **PR + Test 専用の別ワークフロー**に置き換える（並走させない。Archive ワークフローに Test を足さない）。

別リポジトリ化は、Xcode Cloud が署名を隔離しているあいだはしない。

## 配布（TestFlight）

導入範囲は Internal TestFlight まで。External と App Store Submit は公開範囲の拡張なので別判断。`v*` サーバー tag とは連動しない。チーム向け要約は Linear [Xcode Cloud（TestFlight 配布専用）](https://linear.app/sollahiro/document/xcode-cloudtestflight-配布専用-1f8cd760dc6f)（正本はこの節）。

### ワークフロー（ASC に 1 本）

- Project: `Apps/BlueTicker/BlueTicker.xcodeproj`、Scheme `BlueTicker`、configuration `Release`
- Action: Archive のみ。Deployment Preparation は TestFlight (Internal Testing Only)
- Post-action: TestFlight Internal（グループ 1 つ）
- スタート条件: Branch Changes（ブランチ `main`。Files and Folders は Custom Conditions、`Apps/BlueTicker` 配下の Any File。Auto-cancel Builds）。手動再実行用に Manual Start - Branch を残す。タグ `ios-tf-*` は日常切らない
- Environment: Xcode を GHA `macos-26` にピン（現行コメントは 26.6）。Clean
- `ci_scripts` は `Apps/BlueTicker/ci_scripts/ci_pre_xcodebuild.sh` のみ。Archive 時に `CURRENT_PROJECT_VERSION` を `CI_BUILD_NUMBER` へ。`MARKETING_VERSION`（今 `1.2.0`）は Git のユーザー向け版で、`blueTickerVersion` とは独立。初回アップロードが ASC 上の既存 build と衝突したら番号を上げて再実行する。App Store で承認された版はトレインが閉じ、同じ版の build は TestFlight にも上がらない（ASC 90062 / 90186。Xcode Cloud の Archive は「Preparing build for App Store Connect failed」で落ちる）。承認後に `main` へ iOS 差分を入れる前に `MARKETING_VERSION` を上げる（機能追加はマイナー、修正のみはパッチ）

### ASC 手順（人が一度だけ）

1. Xcode Cloud を有効化し、この GitHub リポジトリを接続する（Account Holder）
2. 証明書作成を Xcode Cloud に許可する。手元の Development 証明書は触らない・失効しない。`.p12` を書き出さない。Fastlane match は使わない。`CODE_SIGN_STYLE = Automatic` のまま
3. ワークフローを 1 本作る。ウィザードが付けがちな Test / Analyze は削除する
4. Internal テスターグループを 1 つ作り、自分を入れる
5. App Privacy と暗号申告は既存のまま（`ITSAppUsesNonExemptEncryption = NO`、文面は `ios-privacy.md`）。未入力なら埋めるだけ
6. Team `BM744XMK6M`、Bundle `com.sollahiro.BlueTicker`、アプリ ID `6807425773` は新規発行しない。Release entitlements（App Attest production、CloudKit `iCloud.com.sollahiro.BlueTicker`、Push）もこの導入で足したり外したりしない

Release Archive は HAPIS 本番 + App Attest production。Internal TestFlight でも TestFlight 配信なら Attest は production。初回で HAPIS `enforce` が拒否したら、そのときだけ Deployment Preparation を TestFlight and App Store に上げ、Submit は足さない。

### 運用

1. iOS 変更は PR → GHA `ios` 緑 → `main`（マージ品質は GHA。Xcode Cloud はマージゲートにしない）
2. `main` に `Apps/BlueTicker` の差分が入ると Xcode Cloud が Archive → Internal TestFlight。同じ `main` に続く iOS push は Auto-cancel
3. Internal で実機確認（Release は開発ラボ無し、HAPIS ゲートウェイ固定）。同じコミットの再実行や `main` 以外を載せるときだけ Manual Start - Branch

## 決めたこと

| 項目 | 方針 |
|---|---|
| 探索 2 面 | `ホーム` / `リスト`。OS 標準 `TabView`（タブバー）。各タブは `NavigationStack` + 標準ツールバー。名称検索と条件検索はホームの検索に統合した（独立タブは置かない）。設定タブは置かない。ファンド・保有資産管理は廃止し、企業分析に絞る |
| 探索ツールバー | 不透明なトップバーは置かない。画面タイトルは標準のインライン `navigationTitle`。Liquid Glass のカプセルはツールバー操作だけ。設定歯車タブは出さない。ホームは左上に白抜きロゴ「有報LAB」（アセット `YuhoLabLogo`、SVG。アセットカタログは SVG フィルタを描かないので元ファイルの影は外す。ガラスは付けない）、右上に検索 `magnifyingglass` と履歴 `clock` |
| キーワード検索 | ホーム右上の検索を押すと、ナビゲーションバーが上部の検索バーに変わり、すぐ入力できる。欄内 `xmark.circle.fill`（クリア）と欄外の円形 `xmark`（検索を閉じてキュレーションへ戻る。VoiceOver は「検索を閉じる」）。未入力なら条件一覧（6 プリセットと件数）、入力中は会社名の検索候補（`GET /v1/companies?q=`）。リストのスクロールでキーボードを閉じる |
| 銘柄面 | 探索から `NavigationStack` で push。タブの入れ子にしない。下部タブバー（`ホーム`・`リスト`）は探索と同じまま出す |
| 銘柄ヘッダ | 戻るは標準の Liquid Glass。`探す` は出さない。右上はお気に入り（リストの星）とチャットの 2 つを 1 つのカプセルに並べる（左が星、右がチャット `text.bubble`）。星は未追加 `star` / 追加済み `star.fill`（プラスは使わない。塗り分けやチップ色は付けない。VoiceOver は「リストに追加」「リストから削除」）。チャットは HIG のシート（`.medium` / `.large`、つまみ表示）で開く。チャット本体は未実装で、シートには「準備中」だけ出す。会社アイコン＋社名は `.title` 領域の位置に Liquid Glass カプセルを置く（戻ると右上グループの配置をシステムが先に決めて残りを割り当てるので、右上が「…」へ折りたたまれることはない）。見た目のピルはナビのタイトル遷移から外し、銘柄面への push に合わせて同じ位置へフェードインする（切り替わり完了時にはほぼ出ている。横にも下にもスライドしない。標準の戻る・星ボタンと同じく、その場で不透明になる）。銘柄面を離れるときは遷移の序盤で、同じ位置のままフェードアウトする（下へは動かさない）。戻ると右上は標準のナビのまま。カプセルの幅も高さも社名の文字数によらない。幅は戻るボタンと右の星のあいだで一定（被せない。間を空ける。短い社名は左寄せで右に余白が残る）。高さは、戻る・星と同じ円に揃える（画面ごとに別の枠を拾わない。ナビゲーションバー自体の高さにはしない。2行の社名もこの高さのまま、枠の中で折り返す）。戻る円とピルの隙間と、ピルと星の隙間は同じ。縦の中心もその円に合わせる。フェードは push の残り時間に合わせ、標準の戻る・星ボタンと一緒に不透明になる。高さは星の円（内側の小さい枠ではなく、ガラスの実寸。滑っている枠の高さでは確定しない）。右端はその円の幅を画面端の余白から置く（円の幅が取れるまでフェードを始めない）。戻る円がまだ滑っているあいだは、同じ余白から着地位置を予測する（点の固定値にはしない。スクロールを待たない）。遷移が終わるまでは、着地した円の寸法へ合わせ直す。アイコン＋社名はピル内で左寄せ、2行の社名も左揃え。アイコンは内側余白を広めに確保する。社名は1行なら Headline +2pt、収まらないときは時計程度の小さめ（15pt semibold）で最大2行・行間を詰め、入りきらない部分は…で切り詰める。伸縮中は字間を組み直さず、はみ出した字は枠で隠す。閉じる枠がピル幅に達した時点で、その幅の…を出す（見切れてから…にしない）。収まった枠に入る社名は省略しない。2行のときはカードへ広げてもその2行のままにし、ピルで…になった続きを広がった幅で足す（1行には戻さず、字も縮めない）。ピルの横幅は戻ると右上のカプセルと重ならない上限に抑える。社名ピルをタップすると、そのガラスが上端を保ったまま広がり、社名・銘柄コード・業種・Overview のカードになる。広がったカードではアイコンと社名の上端を、外側の角丸からアイコンの角丸を引いた余白まで下げる（左右の本文余白はピルと同じ）。閉じる `xmark` はその右余白の内側に置く。外タップと `xmark` では、同じガラスがピルの矩形へ戻る。銘柄面を離れたら窓上のガラスは外す（戻る、タブ、別画面への push のあとには残さない）。ピルとカードは別オブジェクトを重ねない。広がっているあいだツールバー側のカプセルは置かない（残すとガラス越しにピルが映る）。ピル自体にはコードと業種は出さない |
| 銘柄ページ（分析結果） | 1 枚の縦スクロール。左右スワイプのカード送り（旧 `概要` / `分解` の 2 枚とページ点）は廃止。上から `業績`・`収益構造`・`資本効率`・`資金配分`・`労働生産性` のカードを並べる。入力は `GET /v1/companies/{code}/waterfall` 1 本。グラフは Swift Charts、年度は古い順に左から右、目盛り線は破線。銘柄の短い会社説明（Overview）は社名ピルの詳細カードに置く。`レポート` は廃止 |
| 会社アイコン | 角丸四角・白背景。リスト行と銘柄ヘッダで同じ |
| App Icon | Icon Composer の `Apps/BlueTicker/BlueTicker/AppIcon.icon` をターゲットのリソースに直接載せる（`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。`Assets.xcassets` に `AppIcon.appiconset` は置かない）。ライト・ダーク・ティントは `.icon` 側で指定する。差し替えは Icon Composer で開いて保存し直す。`assets/blt-icon/` は旧アイコンの原本。アプリ内の B マーク（`BrandMark` / `BBMark`、`bb_mark.png`）は廃止 |
| 社名表示 | 検索結果・銘柄ヘッダから「株式会社」を除く。「ホールディングス」で言い切るときだけ HD（直前の「・」も付けない）。途中の「ホールディングス・アンド…」は触らない |
| 最低対応 OS | iOS 26.0。`IPHONEOS_DEPLOYMENT_TARGET` はプロジェクト側だけに置き、ターゲットは継承させる。iOS 26 の UI 作法（透過タブバー、ツールバー操作の Liquid Glass、`safeAreaBar` 等）をそのまま使い、`if #available` で古い OS に分岐させない。CI の `macos-26` 既定 Xcode 26.6 に iOS 27 SDK は無いので、27 へ上げるのは 27 専用 API が要るときだけ |
| 背景 | 株価アプリ風のダーク。シェルはほぼ黒、カードは背景から浮かぶ濃いグレー、リスト行・コントロールはカードより黒寄り（`Theme.shell` / `Theme.card` / `Theme.control`）。紺の `#16446F` は使わない |
| 履歴 | ホーム右上の時計から開く「履歴」画面に「最近あなたが調べた企業」を並べる。開いた銘柄をクライアントローカル（`UserDefaults`、最大 30 件）に残す（`CompanyHistory`） |
| 条件 | Screen。ホームの検索（未入力）に 6 プリセットの条件一覧。押すと条件検索結果一覧。結果一覧の上部に 17 業種のタブ（アイコン＋業種名）を横スライドで置き、複数選択・全解除できる。選んだ業種はアイコンだけに縮む。業種を変えるとその場で引き直す。業種の選択は条件一覧の件数にも効く（見出しに選択中の業種アイコン）。DualRangeSlider は出さない |
| インタビュー | 構想。銘柄カードからは外し、ロードマップに残す |
| ニュース | 開発廃止。銘柄カードから外す。Brave 等の外部ニュースは載せない |
| 分析の各区分 | `業績` は売上高と純利益の棒（純利益の赤字は赤）と営業利益率の折れ線（右軸、%）。`収益構造` は事業利益の分解（年次バーで年を選び、売上・利益率・販管費の要因と前年差。前年差が無い年度は選べない。要因を選ぶと符号に応じた一文と計算式を出す）。`資本効率` は ROE と ROIC の推移の折れ線（マイナスも描く。未算出の年は点も線も描かない。値は凡例に直近値を添える）と、その下に ROE のデュポン分解（純利益率・総資産回転率・財務レバレッジ・ROE、いずれも期末）を直近 5 年分の表で並べる。ROE・ROIC の前年差の要因分解は出さない。`資金配分` は準備中（見出しと「準備中です。」だけ。構想はフリーCF → 有利子負債の増減（CFベース）→ 配当支払（支配持分のみ）→ その他財務CF → 換算差額 → 現金増減のウォーターフォールと、有利子負債＋正味現金＝期末残高の積み上げ棒。CFベースの借入増減と換算差額は公開 API に無い）。`労働生産性` は従業員数の棒と従業員あたり売上高（売上高 ÷ `employees`）の折れ線 |
| 事業利益 | 売上総利益 − 販管費。分解の下部に「開示されている営業利益と一致しない場合がございます。」 |
| 新着 | ウォッチリストだけ。ホームのキュレーション行には付けない。バッジの定義は未決のため v1 では出さない。Feed 行には提出日（`submitted_at`。矢印の左に「提出日」と日付）を出す |
| 近くの本社 | v1 から外す（位置情報も HQ API も無い） |
| ウォッチリスト | クライアントの SwiftData。同じ Apple ID の端末へ iCloud（CloudKit、コンテナ `iCloud.com.sollahiro.BlueTicker`）で同期する。有報LAB API（HAPIS / blt-server）へは送らない。1 本のリスト。見出しは「あなたの追加した企業」。アイコン・社名・銘柄コードのタイルを 3 列で並べ、縦にスクロールする。押すと銘柄面。同じ銘柄は 1 件（旧版の口座別の行はリスト表示時に並びが上の 1 行へ畳む）。保有（株数・取得単価・証券会社・口座）は持たない。並べ替え UI と編集モードは置かない（削除はタイル長押しのメニュー「リストから外す」のみ）。起動時に概要・分解・Overview を先読みし、解析キャッシュを 7 日持つ |
| 解析キャッシュ | 概要・分解・Overview の REST 応答を端末 Caches に保存（標準 6 時間。ウォッチリスト銘柄は 7 日）。期限切れでも通信失敗時は最後の成功応答を出す。サーバーが 404 を返したら捨てる。応答の単位・形が変わったら置き場所の版（`ResponseCache.formatVersion`、現行 v2＝金額が円）を上げ、旧版は起動時に捨てる。検索はキャッシュしない。Feed は下の「Top feed」の端末保存を使う。会社アイコンは取れた画像を端末 Caches に 7 日持つ（配信に `Cache-Control` が無いため）。iOS は Core をリンクしないので `CacheManager` は使わない |
| バージョン・開発ラボ | リストのスクロール末尾に「バージョン x.y.z (ビルド n)」（B マークは廃止）。免責・プライバシー・利用規約はアプリ内に出さず、App Store 用の公開ページ（Cloudflare Worker `workers/legal/`、URL は `ios-privacy.md`）。サーバー切替・発行者 URL は出さない。Debug だけリスト末尾に開発ラボ（ローカル / HAPIS 本番）。開発ラボの銘柄面（キヤノン、トヨタ自動車、守谷輸送機工業、ファーストリテイリング、ジャパンエレベーターサービスHD）は通信なしで開ける（リストには入れない）。設定タブは復活させない |
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
| ホーム | Feed Update / Search | キュレーション「最近有報が更新された企業」（6 社ずつのページを横にめくるスライドショー。6 秒で次へ送り、手でめくるとそこから数え直す）＋右上の検索・履歴。Feed は公開 RSS（下の「Top feed」）から取り、直近の有報（120）10 件だけを出す（RSS は有報だけで、直近7日の窓＋期間に関係ない直近10件）。保存の無い初回の取得中だけ見出し右端に `ProgressView`。保存も取得結果も無い・0件なら一文だけ出す。Feed Trend（「最近よく調べられています」）は呼び出しを保留中。再開時の 503 は空リスト |
| 条件検索 | Screen | ホームの検索から。6 プリセットの条件一覧 → 17 業種タブ付きの結果一覧。件数・結果は `GET /v1/screen/snapshot`（`screen_index` 全行）を端末内で絞る。取れないときだけ `GET /v1/screen`。全社 `financials` はクライアントで絞らない |
| リスト | （クライアント） | ウォッチリスト 1 本。見出しは「あなたの追加した企業」。3 列タイル。削除はタイル長押しのみ（並べ替え UI は無い）。末尾にバージョン、Debug は開発ラボ |
| 概要 | Summary | 年次の水準値。未集計は 404 |
| 分解 | Waterfall | 行タップで要因分解。事業利益は売上差 / 粗利率差 / 販管費差。資本効率は ROIC・ROE の重ね折れ線と、ROE のデュポン3要素の直近 5 年表。事業利益の要因を選ぶと、緑／赤に応じた一文と計算式（と可能な範囲で計算に使った数値）を出す |
| レポート | Filing | 銘柄カードから廃止。有報一覧は当面出さない |
| インタビュー | Report（構想） | ロードマップ。本来クライアント責務 |

## マイファンド（廃止）

ファンド（保有株数に応じた業績）と保有資産管理（株数・取得単価・証券会社・口座）は廃止した。アプリは企業分析に絞る。portfolio REST は足さない。

## 条件（Screen）

ポンチ絵の業種チップは Screen の一部だけ。完成形のレイアウト再現は求めない。

アプリ側の制約（サーバー許可リストは `ScreenMetric`。BLT-49）:

- 業種は横スクロール 3 段のチップで複数選択。セクション見出しは「業種を選ぶ」。各段は自然幅で敷き詰める。楕円。選択時は緑枠・薄緑地・緑文字、非選択は一律グレー地の白抜き。見切れマスクの半径はセクション枠の半径から内側オフセットを引く（outer r = inner r + padding）。リスト行の業種タグも選択時と同じ緑枠スタイル。市場チップは出さない。未選択と全選択は `sector` を送らない。1 業種は `sector=` 完全一致。2 業種以上は AND にせず、カンマ区切りの `sector=` 1 リクエストでサーバーの IN 検索（OR）に任せる（ソート・件数もサーバー側）
- DualRangeSlider・指標の詳細トグル・`ScreenMetricFilter` 組み立て UI は出さない。フローは業種（任意）→ プリセットタップ → 結果 → 銘柄
- プリセットは 6 つ。セクション見出しは「こんな企業を探す」（件数の読み込み中は見出し右端に `ProgressView`）。行はラベル（優良=青 / 成長=橙 / 安定=緑 / 高CF=ティール / 改善=ゴールド / 高還元=パープル。業種タグと同形の枠）+ 1 行の説明文（「高収益で財務が健全な企業」など 15 字前後、1 行に収める）。右端に該当件数（スナップショットを端末内で数える。下の「スナップショット」。取れないときだけ `GET /v1/screen` の `matched`（`limit=1`。業種変更から 400ms debounce。6 件揃ったらタブ往復では取り直さない（欠けたら次の表示で再試行）。未選択・全選択は 6 リクエスト。9 業種以上の部分選択は件数を出さない））。クライアントが `GET /v1/screen` の min/max + `sort` desc に写す（閾値は整数、ネット D/E は 1 桁。ソートはプリセットごとにフィルタで必ず非 null になる指標を選ぶ — 高還元は `payout_ratio`、それ以外（改善を含む）は `roic`。ソート指標が null の行はサーバーが落とすため。改善を `roic_cagr_3y` で並べると上位 10 件中 9 件が 3 期前 ROIC < 0 の赤字回復銘柄になる（2026-09 本番相当データ。`roic` 順では上位 50 件中 9 件）ため、変化幅は条件だけに使う）:
  - **優良**: `roic_min=10`、`operating_margin_min=8`、`net_de_max=0.5`。成長フィルタなし
  - **成長**: `sales_cagr_3y_min=10`、`operating_margin_min=5`、`roic_min=8`。CAGR 上限なし
  - **安定**（旧 健全成長）: `sales_cagr_3y_min=5`、`roic_min=12`、`net_de_max=0.3`
  - **高CF**: `cfo_margin_min=10`、`fcf_min=0`（`min` は包含比較なので「FCF > 0」の近似）、`roic_min=8`
  - **改善**: `operating_margin_cagr_3y_min=3`、`roic_cagr_3y_min=2`、`roic_min=8`。3 期年平均変化幅（pp/年。前年差は 1 年のブレを拾いすぎるため不採用）。変化幅だけだと該当の約 6 割が 3 期前 ROIC < 0 の赤字回復銘柄になるため、到達水準を `roic_min=8` で縛る（2026-09 本番 financials で 277 → 136 社、赤字回復は 162 → 30 社）
  - **高還元**: `payout_ratio_min=40`、`payout_ratio_max=60`。`payout_ratio` は直近 3 期の年次性向の算術平均（screen-v4。最新 FY 単年は残さない）。高効率案は優良と重複するため採用しない
- 結果行の指標は会社アイコンの左端から業種タグの右端まで使う（社名左端には揃えない）。短い 4 指標（優良・成長）は 1 行。項目名・数値が大きい安定・高CF・改善は 2×2 のまま。高還元は上段に配当性向3年平均と 3年推移（項目名と数値は同一行）、下段に営業利益率 / ROIC / ネットD/E。欠測は `—`（CAGR が null でも YoY に落とさない）:
  - **優良**: ROIC / 営業利益率 / ネットD/E / 売上CAGR（1 行）
  - **成長**: 売上CAGR / 営業利益率 / ROIC / ネットD/E（1 行）
  - **安定**: 売上CAGR / ROIC / ネットD/E / 営業利益率（2 行）
  - **高CF**: 営業CFマージン / FCF（`autoYen`、符号で色分け）/ ROIC / ネットD/E（2 行）
  - **改善**: 営業利益率 年変化 / ROIC 年変化（`+1.2pp/年`）/ ROIC / 営業利益率（2 行）
  - **高還元**: 上段は項目名グレー・数値色付きの 2 行（同一行に `配当性向3年平均` `XX%` / `3年推移` `XX%→XX%→XX%`。高低の優劣は付けないため色帯なし、数値は accent。項目名・数値とも縮小しない。1 行に入らなければ数値だけ次行）/ 下段 営業利益率 / ROIC / ネットD/E
- 理由はプリセット条件の短い言い換え（ブラックボックスのスコアではない）。プリセット行の脚注と結果セクションの footer に出す。チップは出さない
- `APIClient.screen` とサーバー許可リストの配線は残す。UI がスライダーを出さないだけ
- サーバー許可リスト（12 指標。screen-v3 で 6 → 12。screen-v4 は `payout_ratio` の意味を最新 FY 単年から直近 3 期算術平均へ差し替えるだけでキーは増やさない。旧 `operating_margin_yoy` / `roic_yoy` は物理列だけ nullable で残し、許可リスト・書き込み・応答から外す）: `sales`（サイズ。UI プリセットでは使わない）/ `operating_margin` / `roic` / `roe`（API は残す。UI では絞らない）/ `net_de` / `sales_cagr_3y` / `cfo` / `cfo_margin` / `fcf` / `operating_margin_cagr_3y` / `roic_cagr_3y` / `payout_ratio`
- 銀行業（Summary の銀行判定。`DepositsLiabilitiesBNK` または EDINET 提出者業種＝銀行業）は `roic` / `net_de` / `roic_cagr_3y` が null（2026-10-12）。null 行はソート・フィルタで落ちるため、ROIC 順の既定ソートと `net_de_max` 条件の結果に銀行は載らない
- 3 期売上 CAGR `sales_cagr_3y` は `screen_index` の派生列。最新 Summary 年から売上 > 0 の直近 3 期を取り、`((latest/oldest)^(1/2) - 1) * 100`。3 期に満たなければ null。Summary の `years[]` には CAGR / YoY キーを足さない
- screen-v3 の派生列（いずれも ingest 時に Summary から派生。Summary の同義語と単位・符号は揃える）: `cfo` = 営業 CF（格納は百万円、応答は円）。`cfo_margin` = cfo ÷ sales × 100（%）で sales ≤ 0 は null。`fcf` = cfo − capex（格納は百万円、応答は円。Summary の `cfc` = cfo + cfi とは別物）。`operating_margin_cagr_3y` / `roic_cagr_3y` = 3 期年平均変化幅（pp/年、直近の非欠測 3 期で（最新 − 最古）÷ 2。利益率・ROIC は負やゼロ跨ぎがあり得るため幾何 CAGR ではなく pp の年率変化。期の選定は `sales_cagr_3y` と同じで 3 期に満たなければ null）
- screen-v4: `payout_ratio` は最新 FY 単年を残さず、直近 3 期の年次性向（各期 `dividend_ss` ÷ `net_profit` × 100）の算術平均に置き換える。3 期とも定義できるときだけ。欠ける・赤字（net_profit ≤ 0）・配当行無しはその期を null とし平均も null（無配と未抽出を区別しない。特別配当も区別しない。SS 当期帰属を採り CF 実払いは使わない）。表示用の年次系列 `payout_ratio_3y`（古→新、不足は先頭 null、許可リスト外）は `payout_ratio` を投影するときだけ `items[]` に載せる
- 対象は最新 FY の Summary 水準値だけ。YoY / Waterfall / Breakdown / Notes は混ぜない
- 業種チップの候補はクライアント側の表示用カタログ。`GET /v1/companies?sector=` は足さない

Screen REST は `GET /v1/screen`（`screen_index` 読み取り。`sector` 完全一致 + `<metric>_min` / `<metric>_max` の AND + `sort` / `order` / `limit`（既定 `roic` / `desc` / 50、上限 200））。許可リストは上の 12 指標。応答は `items[]`（メタ + core4 + フィルタ / ソートに使った指標。`payout_ratio` 投影時は `payout_ratio_3y` も）と `returned` / `matched` / `sort`。索引未生成（0 行）は 404、フィルタ 0 件は 200 で空配列。iOS 条件検索はスナップショットが取れないときだけこれを呼ぶ。`screen_index` は財務 ingest 直後に 1 社ずつ派生更新し、公開床（servable）の `company_financials` は現行 fin-vN 一致を問わず次回 ingest で投影する（列定義変更後の手動一発は `blt-ingest screen-rebuild`。`screenIndexVersion` = `screen-v4`。`fin-vN` は上げない）。skills カタログには載せない。

### スナップショット（`GET /v1/screen/snapshot`）

- 中身：`screen_index` 全行（約 3,700 社）を列形式で返す。`schema_version`（形の版、`screenSnapshotSchemaVersion` = 1）/ `screen_version`（`screenIndexVersion`）/ `count` / `code` / `name` / `market` / `sector` / `period_end` / `metrics`（許可リスト 12 指標すべて。指標名 → 行と同じ長さの配列、null は null）/ `payout_ratio_3y`（行ごとに長さ 3、古→新）。code 昇順。数値は小数 4 桁に丸める（閾値との比較で境界がずれるのは 0.00005 未満の行だけ）。索引未生成は 404、DB 非接続は 503。skills カタログ・MCP には載せない
- 検証子：本文の SHA-256 を強い `ETag`。`If-None-Match` 一致は 304（本文なし）。`Cache-Control: private, no-cache`
- 端末内検索（`Apps/BlueTicker/ScreenSnapshot`）は `GET /v1/screen` と同じ規則：業種は完全一致の OR（空は全業種）、範囲は両端含む AND、フィルタ・ソート対象が null の行は落とす、同値はコード昇順、結果は 50 件
- サーバー：本文と ETag は起動時と 3 日ごと（`Api.screenSnapshotRebuildIntervalSeconds`）に裏で作り置きし、リクエストはそれを返すだけ（作り置きが無いときだけそのリクエストで作る）。手元から ingest した直後に反映したいときはサーバーを再起動する
- 表示：アプリ起動時に先読みする。保存済みがあれば通信せずに件数を出す（業種変更も debounce なし）。表示のたびに条件付き GET（前回の取得から 3 日以内は送らない）。304 は取得時刻だけ進め、200 は保存を差し替えて数え直す。結果画面も同じ保存から引く。件数と結果画面の同時取得は 1 本にまとめる
- 失敗時：保存済みの分を使い続ける。版違い・列の長さ不一致・途中で切れた本文は失敗扱いで保存を差し替えない。保存も取得もできなければ `GET /v1/screen` に戻す
- 保存：本文と `ETag` / 取得時刻を Caches の `blt-screen/v1/screen-snapshot.json` に 1 ファイル（`ScreenSnapshotStore`）
- 解析・検索・再検証の判定は `Apps/BlueTicker/ScreenSnapshot`（Linux / macOS の `swift test`）。アプリはそのソースを直接コンパイルする

## 認証

iOS は第三者と同じ公開 REST のクライアント。privileged にしない。トークン / Service Token は埋め込まない。`HAPIS_API_TOKEN` も consumer JWT として使わない。アプリに Cloudflare Access の JWT / OTP / Service Token は載せない。

| 経路 | 方針 |
|---|---|
| Release | HAPIS ゲートウェイ + App Attest。起動時からゲートウェイ固定。設定操作は不要（トークンはサイレント mint / refresh） |
| Simulator | ローカル stub。既定 `http://127.0.0.1:3000`。同じ Wi-Fi の `http://<MacのIP>:3000` も無認証・Attest なし |
| 開発 / agents | REST を Service Token で叩く（アプリには埋め込まない）。手元 Debug の開発ラボはローカル、または実機の HAPIS 本番（App Attest） |

**Release** は起動時から HAPIS ゲートウェイ固定。同じ Bundle ID の Debug UserDefaults は読まない。**Debug** のサーバー切替・発行者 URL はリスト末尾の開発ラボ。本番公開扉は HAPIS。MCP は製品認証に使わない。

### HAPIS consumer mint（クライアント）

公開 URL（秘密ではない。ハードコードしてよい）:

| 役割 | URL |
|---|---|
| 発行者（制御面） | `https://hapis.sollahiro.workers.dev` |
| 本番ゲートウェイ（API base） | `https://hapis-blue-ticker-production.sollahiro.workers.dev` |

- `GET /v1/consumer/challenge` — App Attest の mint / attest / assertion のたびに取る（単回使い切り。stub mint では呼ばない）。応答 `challenge` は 32 バイトの unpadded base64url
- `POST /v1/consumer/sessions` — 201 で `token` / `refresh_at` / `expires_at`
  - **Simulator / Debug ローカル:** ボディ `{}`（stub）。challenge は叩かない。本番制御面は `ATTEST_MODE=enforce` なので stub mint は拒否する（`missing_attest`）
  - **Release および Debug の「HAPIS 本番」:** App Attest 証拠。`attest.key_id` + `challenge` + `client_data` + 初回は `attestation`、以降の remint は `assertion`
- `POST /v1/consumer/token/refresh` — まだ有効な Bearer。期限の約 5 分前（`refresh_at` / `refresh_in`）にサイレント refresh。期限切れは remint（401 `token_expired`）。refresh は JWT のみで Attest しない。blt-server / Vapor には consumer JWT を付けない
- ゲートウェイへの REST だけに Bearer を付ける。発行者以外の上流へ consumer JWT を送らない
- **Release** の API base / 発行者はハードコード（ゲートウェイ + `hapis.sollahiro.workers.dev`）。アプリ内では切り替えない
- **Debug** の「HAPIS 本番」がゲートウェイを API base にし、App Attest を使う（`blt.hapis.attestMode=appAttest`。起動時に読むので切替後は再起動）
- Attest / トークン失敗: 制御面の mint / refresh は一時失敗を 2〜3 回。ゲートウェイの 401 `token_expired` は 1 回 remint。だめならキャッシュ表示 + 柔らかい「一時的に更新できない」。ハードブロックしない。Attest なしの緊急トークンは出さない（Simulator で App Attest 未対応なら失敗する。Simulator 検索はローカル stub で動く）

#### App Attest 証拠（Release / Debug の HAPIS 本番 / `blt.hapis.attestMode=appAttest`）

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

Debug 実機で Attest を試す: 開発ラボの「HAPIS 本番」（既定で App Attest）。`APIClient.shared` は起動時に provider を固定するので、切替の反映には再起動。Release は常に App Attest。Entitlements: Debug `development`、Release `production`。

段階 B のトークン: TTL 約 1 時間。期限の約 5 分前にサイレント refresh。残り 60 秒超なら手元のトークンで即リクエストを出し、refresh は裏で 1 本だけ走らせる（リクエスト経路で制御面の往復を待たない）。残り 60 秒以下は refresh を待つ。

### Top feed（公開 RSS）

- 取得元は `https://feed.sollahiro.com/blue-ticker/edinet-filings.xml`（`workers/feed-rss`。毎日 19:15 JST 生成）。HAPIS・トークン・オリジン・Neon を通らない。`/v1/feed/updates` へはフォールバックしない。鮮度は 1 日 1 回
- 表示：ホームを開いたら端末に保存済みの RSS を解析してすぐ出す。裏で `If-None-Match` / `If-Modified-Since` 付きの条件付き GET を送り、304 は取得時刻だけ進め、200 は保存を差し替えて画面を更新する
- 間隔：前回の取得から 1 時間（RSS の `max-age`）以内は再検証しない。フォアグラウンド復帰時も同じ条件で再検証する
- 失敗時：保存済みの分を出し続ける。途中で切れた本文（`</rss>` が無い）は失敗扱いで、保存を差し替えない
- 保存：生の XML と `ETag` / `Last-Modified` / 取得時刻を Caches の `blt-feed/v1/edinet-filings.json` に 1 ファイル（`FeedRSSStore`）
- 行：銘柄コードは `<category domain="jp:sec_code">`、社名はタイトルのコード括弧より前、提出日は `pubDate`（JST）。アイコンは `<media:thumbnail url>` を `CompanyRef.iconURL` に渡し、無い会社は `CompanyIconLoader` の拡張子プローブ。業種は銘柄面が `financials` の `sector` で補う
- 対象は直近の有報（120）10 件だけ（REST 既定と同じ件数）。RSS 自体が有報だけになった（訂正・四半期・半期は載らない）が、アプリ側も 120 以外が混ざれば出さない。RSS 側が有報を期間に関係なく直近 10 件載せるので、閑散期も 10 件出る
- アイコンは画面に入った行の `.task` から取る
- 解析と再検証の判定は `Apps/BlueTicker/FeedRSS`（Linux / macOS の `swift test`）。アプリはそのソースを直接コンパイルする

### ゲートウェイの同時実行（`HAPISOriginGate`）

HAPIS の制限は 60/分のレートで同時数ではない。interactive（検索 / 銘柄面）は 3 本まで並列に出し、銘柄面の financials / overview / waterfall を直列にしない。先読み（ウォッチリスト）は 1 本ずつ 4 秒間隔で、interactive が流れている・待っている間と、最後の interactive から 2 秒間は出さない。スロットが空いたら待ちを全員起こして条件を再確認させる（先頭だけ起こすと、その 1 本が間隔待ちで眠っている間に空きが使われない）。mint / refresh はスロットを取る前に済ませる。

### Mac / Simulator 手動スモーク（この PR では必須にしない）

Cloud Agent の Linux VM と、手元に Mac が無いラウンドではシミュレータ E2E を要求しない。単体は `Apps/BlueTicker/HAPISConsumer` の URLProtocol / HTTP mock（DeviceCheck は mock）。アプリの型検査は GitHub Actions `ios` ジョブ。Mac があるときの確認:

1. Debug → リスト → 開発ラボ → ローカル（`http://127.0.0.1:3000` または LAN `http`）で検索できること（Bearer が付かない）
2. Debug → リスト → 開発ラボ → トヨタ自動車。通信不要。右上が星 1 つで、社名ピルが戻ると星のあいだに出ること。隣の社名はピル幅の確認用（リストには入らない）
3. Simulator では HAPIS 本番を使わない（App Attest 不可）。実機 Debug の HAPIS 本番、または Release で名称検索（`7203` など。200 で BLT JSON）
4. プロキシで確認: ゲートウェイへ `Authorization: Bearer eyJ…`。発行者の mint/refresh（と Attest 時の challenge）以外に JWT が流れないこと
5. プロセスを殺して再起動しても、期限内なら mint せず検索できること。Keychain のトークンを捨てると sessions が再発行されること
6. Release は開発ラボを触らず検索できること（API base は HAPIS ゲートウェイ。バージョンはリストのフッター）。Xcode の Run（Debug）の既定はローカル stub。実機で本番 HAPIS を叩くときは Release、または Debug の「HAPIS 本番」+ 再起動

#### 実機 App Attest（後で。Simulator では不可）

本番 `ATTEST_MODE` は enforce。実機 Release（または Debug の「HAPIS 本番」。ただし Debug の Attest 環境は `development` で、本番 HAPIS の既定 `APP_ATTEST_ENVIRONMENT=production` とは合わない）:

1. Release は開発ラボを触らず検索できること。Debug で試すときはリスト → 開発ラボ → HAPIS 本番（切替後は再起動）
2. プロキシ: `GET /v1/consumer/challenge` のあと `POST /v1/consumer/sessions` に `attest.key_id`・`challenge`・`client_data`（`{"challenge":…}`）と、初回は `attestation`、2 回目以降は `assertion`
3. Debug のトークン破棄後の再検索は assertion（同じ key_id）。App Attest 未対応なら「一時的に更新できない」で、空の stub mint には落ちない
4. Simulator / ローカルは Attest も consumer JWT も付けない


## 未決

- `インタビュー` の経営者 / アナリストは有報セクションか LLM か（カードはロードマップ）
- アカウント設定（有料・ウォッチ同期が要るときだけ）。免責・プライバシー・利用規約は App Store 用の公開ページ。バージョンはリストのフッター。開発ラボは Debug 限定
- ウォッチリストの「新着」を、その銘柄の新規有報としてよいか
- Screen REST を skills カタログに載せるか（BLT-49。listed drain 後でも別判断）

## Figma の途中

Starter の MCP 月次上限で、銘柄ヘッダのコードと分解の一文は未描き。探索の近くの本社削除、名称検索の新着削除、タブ／ヘッダの語、リストのコード、富士フイルム業種は反映済み。条件面は Figma 未完成のまま実装してよい。

## 関連

`architecture.md` · `financials-summary-separation.md` · `api-auth.md` · `public-api.md` · `ios-privacy.md`
