# 事業別・地域別売上の正規化構想（Stage 6）

企業間比較（同業の事業割合・地域割合）と、同一企業の期ごとの推移把握を目的とする。抽出の綺麗さ自体ではなく、**同じ形の割合（軸・分母・外部売上）で並べられること**が本体。

関連: 現行抽出は `SegmentExtractor`（`docs/xbrl-parsing.md`）。ロードマップ上は Stage 6（`docs/blt-server-roadmap.md`）。

## 目的

| 用途 | 必要なもの |
|---|---|
| 同業比較 | 同じ期・同じ軸で各社の内訳割合を並べる（行ラベルの会社間統一は必須でない） |
| 推移 | 同一企業の期ごとのスナップショット列 |

割合の定義（比較の正本）:

\[
\text{事業割合}_i = \frac{\text{外部売上}_i}{\text{連結外部売上}},\quad
\text{地域割合}_j = \frac{\text{仕向地売上}_j}{\text{連結外部売上}}
\]

原則指標は **外部顧客売上**（内部取引込みは使わない）。分母は連結の外部売上（調整後）。

### 方針（確定）

- **事業再編・セグメント名称変更の過去遡及補正はしない。** 変わるのは所与。各期はその期の開示どおり保存・表示する。
- **会社間の行ラベル対応（共通バケットへの強制写像）は必須にしない。** 「プリンティング」と「デジタルシステム&サービス」が一致しないのは許容。比較は割合の形と軸の揃えまでとし、ラベル解釈は利用者側に委ねてよい。
- `segments` / `geography` は意味ラベルではなく **開示ブロックの取り分け**（報告セグメント注記 / 地域注記）。事業×地域の両方が常にあることは保証しない。

## 現行抽出の実態

`SegmentExtractor` は2段:

1. **本命** — 専用 TextBlock 内 HTML 表 → `method: "html_table"`（Markdown）
2. **フォールバック** — dimension 付き数値 fact（事業軸 / 地域軸キーワード）→ `method: "xbrl_facts"`

キー:

| API キー | XBRL 上の意味 |
|---|---|
| `segments` | 報告セグメント（`OperatingSegments` 等）。マネジメント・アプローチのため **事業とも地域とも限らない** |
| `geography` | 地域別注記（GeographicArea 系 TextBlock / dimension） |

## 試行で見えた会社差（2026-07）

対象は有報 XBRL（味の素・日立・オークマは 26-03、ヒューリック・キヤノンは 25-12）。

| 会社 | `segments` | `geography` | 「事業別」の実置き場 |
|---|---|---|---|
| 味の素 | `xbrl_facts`（事業） | `html_table` | 報告セグメント |
| 日立 | `xbrl_facts`（事業） | `html_table`（比較表） | 報告セグメント |
| オークマ | `xbrl_facts`（**地域**） | `html_table`（細かい地域。period 誤ラベルあり） | **収益認識関係 １**（製品別） |
| ヒューリック | `xbrl_facts`（事業） | `not_found` | 報告セグメント。収益認識１は事業×収益種別クロス |
| キヤノン | fact は設備・人員等のみ（主数値なし） | 表が混線（収益タイミング表が混入） | **US-GAAP 連結注記** 注23。収益は注15 |

追加ソースの例:

- `NotesRevenueRecognitionConsolidatedFinancialStatementsTextBlock`（J-GAAP 収益認識関係）
- `NotesToConsolidatedFinancialStatementsUSGAAPTextBlock` 内の注番号切出し（キヤノン型）

## 学び

1. **比較に必須な揃えは構造側**（軸・外部売上・分母・割合）。会社間の行ラベル一致は必須ではない（許容する）。
2. **`xbrl_facts` の整形自体は決定的処理で足りるが、売上系タグの選択が最初の関門**。1メンバーに資産・持分法損益・研究開発費・従業員数など無関係タグが大量に紐づくため、候補タグリストで絞らないと事故る。会社間でタグ表記も割れる（IFRS の外部顧客売上は `SalesToExternalCustomersIFRS` と `RevenueFromExternalCustomersIFRS` が混在）。単一タグ決め打ちは不可（下記 smoke 検証参照）。
3. **LLM が効くのは意味の写像**（軸判定、変則表ヘッダ）。入力帰属が壊れていると救えない（オークマ geography の全表 `前期`、キヤノンの表取り違え。いずれも 2026-07 の `SegmentExtractor` 前処理修正で解消済み）。
4. **全社で事業×地域の両軸がある前提は置けない。** 軸ごとに欠測を許す。
5. **ミソはプロンプト単体ではなく正規化契約**（スキーマ・分母・指標・軸判定）。LLM を使うなら契約を `json_schema` / プロンプトに落とす。使わないなら同じ契約をコードと別名表に落とす。
6. 時系列はスナップショット列でよい（再編の連続補正なし）。
7. **小計・調整行の除外は名称リストより数値判定が頑健**。`ReportableSegmentsMember` / `ReconcilingItemsMember` 等の命名は会社で揺れるが、「金額が分母候補と一致する」「他行の合計と一致する」といった数値的判定なら会社をまたいで機械的に効く。
8. **金融機関（銀行等）は Stage 6 v1 の対象外とする（確定）。** セグメント指標が外部顧客売上ではなく `NetRevenue`（純収益）や `ConsolidatedGrossProfit`（連結粗利益）という別概念で、連結損益計算書の売上を分母にする設計とは整合しない。smoke 検証（三菱UFJ・三井住友）でシェア合計がそれぞれ 1.08 / 0.41 に破綻することを確認済み。銀行固有ロジックは既存の `Extractors.swift` 銀行系抽出と同様、後続の別トラックとして切り出す。
9. **実装コストの重心は `segments` の `xbrl_facts` ではなく `geography` の `html_table` 側にある。** smoke 11社では `segments` は会計基準（J-GAAP/IFRS/US-GAAP）を問わず **11社中11社が `xbrl_facts`**。一方 `geography` は9社が `html_table`（fact なし）・2社が `not_found`（AZplanning・東邦レマックは小規模で海外拠点なし＝正当な欠測、抽出漏れではない）。現状 `SegmentResult.tables` は見出し＋markdown文字列のみで行パースをしておらず、ここが Stage 6 の実カバレッジを左右する。
10. **`segments` キーの軸（business/geography）は member 名のキーワード判定で機械的に決まる。** smoke 11社中10社は事業名（例: `SeasoningsAndFoodsReportableSegmentMember`）、オークマ1社のみ地域名（`JapanReportableSegmentsMember` 等）。小計・調整行を除いた member 全部が地域キーワードに一致する（オークマ: 4/4）か、1つも一致しない（他10社: 0/N）かで完全に分かれ、混在ケースは smoke 内では0件だった。→ 詳細は下記「軸判定ルール（案）」。

### smoke 検証（2026-07-18）

smoke fixture の非金融7社（味の素・ニチレイ・AZplanning・オークマ・クボタ・スズキ・東邦レマック、IFRS/J-GAAP 混在）に対し、正しい外部顧客売上タグ＋数値判定による小計除外を適用したところ、事業別シェア合計は **0.98〜1.00 に収束**（クボタ・スズキ・オークマ・東邦レマックは 1.000）。コモンモデルの骨格が非金融企業には実データで機能することを確認した（銀行2社の破綻は学び8参照）。

### 軸判定ルール（案・2026-07-18 検証）

`segments` キーは報告セグメント（マネジメント・アプローチ）のため、中身が事業別とは限らない（学び10）。判定ルール案:

1. `row_kind=segment`（小計・調整行を除く）の member ラベルを地域名キーワード（`Japan`・`Americas`・`Europe`・`Asia`・`AsiaAndPacific`・`China`・`NorthAmerica`・`Emea`・`Domestic`・`Overseas` 等）と照合する
2. **全 member が一致** → `axis=geography` として扱う
3. **1つも一致しない** → `axis=business`
4. **一部だけ一致**（混在） → `axis=business` をデフォルトにしつつ `needs_review=true`・`warnings=["axis_ambiguous"]` を立てて後続確認に回す（LLM が効く場面はここに限定できる）

smoke 11社で検証: オークマ（4/4 一致・地域名）以外の10社は0/N一致（事業名）。**ルールのみで11/11正しく分類**（混在ケースは今回のサンプルには存在しなかったため、ルール4の実効性は未検証）。既存の `Xbrl.geographyDimensionKeywords`（XBRL dimension 軸名の判定用）とは別レイヤーの、member ラベル文字列に対する新規キーワード表として実装する。

### 実装で分かったこと（2026-07-18・`SegmentNormalizer.swift`）

- **対象外（銀行・US-GAAP企業）は特別分岐ではなく、売上系タグ候補リストとの不一致から自然に nil になる。** 銀行はタグ自体が別概念（`NetRevenue`/`ConsolidatedGrossProfit`）、US-GAAP2社（富士フイルム・キヤノン）は `segments` の `xbrl_facts` に売上が一切タグ付けされていない（設備・人員等の補助指標のみ）。どちらも `if bank { skip }` のようなコードを書かずに済んだ
- **連結優先・非連結フォールバックが必須。** 東邦レマック（子会社を持たない小規模企業）は `segments` も連結売上自体も非連結コンテキストでしか開示されない。「連結のみ」決め打ちだと有効企業7社中1社が丸ごと消える。既存 `ContextHelpers` の当期/前期判定パターン文字列は流用しつつ、"Member" サフィックス除外だけは外して実装（セグメント軸コンテキストは意図的に Member 修飾があるため）
- **小計・調整行の数値判定は「他に segment 候補が2件以上あるとき」に限定する。** 単一セグメント企業では売上高がそのまま分母と一致するのが正しい姿であり、数値近似だけで判定すると単一行を誤って小計扱いしてしまう
- **member ラベルの選択は Dictionary 走査順に依存させない。** dimension が複数ある fact（smoke には無いが実データでは起こりうる）で行ラベルが実行ごとに揺れないよう、dimension キー名の辞書順で決定的に選ぶ
- **利益（事業利益・営業利益）は売上と同じ仕組みでほぼ無料で乗る。** 売上と同様タグ表記が会社で割れる（IFRS でも味の素は `BusinessProfitLossIFRS`、クボタ・スズキは `OperatingProfitLossIFRS`）ため候補リスト化し、`resolvePerMember` を売上・利益で共有した。任意フィールド（`BreakdownRow.profit`）とし、一致するタグが無くても snapshot 自体は成立する。smoke 6社（オークマ除く、非金融のIFRS/J-GAAP企業）の実額をユーザーが目視確認し、`smoke/segment_breakdown_expected.json` にゴールデン値として記録・回帰テスト化済み（利益率などの派生値は含めない）

## 正規化契約（草案）

比較用コモンモデルの骨格。実装時に型へ落とす。

```text
BreakdownSnapshot
  code, doc_id, fy_end
  axis: business | geography | product   # 欠ける軸は出さない
  unit: 百万円
  denominator: external_revenue          # 連結外部売上（金融機関は対象外＝スナップショット自体を作らない）
  denominator_tag: string                # 採用した売上系タグ名（候補リストのどれを使ったか。監査・再現用）
  rows: [{ id?, label_raw, amount, share, row_kind: segment | subtotal | reconciling }]
  source: { kind: html_table | xbrl_facts | revenue_recognition | usgaap_note, ref }
  as_reported: true                      # 組替補正しない
  needs_review: bool                     # 例: section 期待軸と判定軸のずれ
  warnings: [string]                     # 例: axis_mismatch_with_section_key
```

契約で固定する方針:

| 項目 | 方針 |
|---|---|
| 行の単位 | 軸ごと（事業 / 地域 / 製品）。報告セグメントが地域なら `geography` 側に載せるか、`axis=geography` の snapshot として出す |
| 行ラベル | 開示の表記をそのまま使う。会社間の共通名への強制マップはしない |
| 売上タグ解決 | 会計基準ごとの**候補タグリスト**から優先順で選ぶ（単一タグ決め打ちにしない）。例: IFRS→`SalesToExternalCustomersIFRS`/`RevenueFromExternalCustomersIFRS`、J-GAAP→`RevenuesFromExternalCustomers`。採用タグは `denominator_tag` に残す |
| 小計・調整行 | `row_kind` で区別して rows には残すが、比較の分母・シェア計算には使わない。判定は名称リストではなく数値判定（学び7参照） |
| 利益 | 比較の第一指標は売上割合。利益割合は任意・定義を明示 |
| 対象外 | 金融機関（銀行等）。セグメント指標が外部顧客売上と別概念のため v1 では非対応（学び8参照） |

`segments` / `geography` 生データは raw として残し、比較用は `BreakdownSnapshot` に写す二層が安全。

### 保存単位

**1企業 × 1年度（× 軸 or section）の1レコードに、正規化結果（内容）とフラグを同居させる。** フラグだけ別管理・内容だけ別管理にしない。

例（オークマ）:

- section キーは `segments` のまま／または派生の `axis=geography` snapshot
- `rows` / `denominator` / `share` は地域別の中身（使える）
- 同時に `needs_review=true`、`warnings=["axis_mismatch_with_section_key"]` を同じレコードに持つ

こうすると「中身は比較に使う／フラグで要確認・再計算対象にする」が同じ主キーで完結する。フラグ無しのきれいな行も、同じ形で `needs_review=false` として揃える。

## 処理分担（構想）

```text
1. ソース発見（決定的）
   TextBlock / dimension fact / 収益認識注記 / US-GAAP 注番号
2. 正規化
   fact ピボット・単位・割合 = コード
   軸判定・変則表解釈 = ルール優先、難所のみ LLM
3. 検証
   行合計≒分母、期・単位の整合、抜き打ち（任意で LLM）
```

LLM は「構造化の本体」ではなく **契約に沿った写像の補助・検証** に置く。

## 今後の検討事項

優先度は未確定。実装前に決めること:

1. ~~**比較用コモンモデルの確定**~~（2026-07-18 確定・実装済み。`Sources/BlueTicker/Analysis/SegmentNormalizer.swift` + 定数は `Xbrl.swift`、テストは smoke 実データ照合で5件パス）
2. ~~**軸判定ルール**~~（2026-07-18 確定・実装済み。同上 `SegmentNormalizer.classifyAxis`）。残課題: 混在ケース（ルール4）は smoke サンプルに存在せず未検証のまま
3. **追加ソースの採用範囲** — 収益認識１・US-GAAP 注15/23 を Stage 6 に含めるか、後続か。US-GAAP 企業（富士フイルム・キヤノン）は `segments` の `xbrl_facts` に売上自体が無い（設備・人員等のみ）ため `SegmentNormalizer` は自然に nil を返す。html_table 行パース未実装のため、着手前提として #9（学び）の行パースが要る
   - **オークマ型（`segments` キーの axis が geography と判定される）の配線方針（未着手・2026-07-19 決定）**: `segments` キー呼び出しの結果が `axis == "geography"` になった場合、その snapshot を「事業別（business）」として採用してはならない。`SegmentNormalizer.normalize()` 自体の挙動（axis をデータから判定して返す。学び10・`okumaSegmentsAxisIsGeography` テストで固定済みの仕様）は変更しない — 採用可否の判断は呼び出し側（ingest/配線コード）の責務とする。オークマの本当の事業別（製品別）データは「収益認識関係１」（学び冒頭の会社差表を参照）にあり、これは上記の追加ソース採用が決まってから初めて拾える。配線時のチェックリスト: (a) `segments` 結果の axis が geography なら business breakdown は "not found" 扱い（geography-labeled snapshot をそのまま business として出さない）、(b) 可能なら収益認識１から business breakdown を再抽出する、(c) 地域別（geography）は常に `geography` キー由来（html_table/xbrl_facts）を正とする
4. **`SegmentExtractor` の前処理欠陥**（2026-07-19、`worktree-fix-segment-extractor-defects` のコミット`d26005d`を本ブランチへ cherry-pick 済み。641 テスト全パス、コンフリクトなし） — period 誤ラベル（`detectPeriodFromPreceding` が最も近い当期/前期見出しではなく最初の一致を採用していたバグ）・US-GAAP 巨大注記未対応（`segments` が `NotesToConsolidatedFinancialStatementsUSGAAPTextBlock` を未走査でキヤノン等の事業別データが取れなかった）・geography への無関係表混入（同一巨大注記内の収益タイミング表・株式報酬表等を誤って拾っていた）の3件を修正。残るのは巨大注記内の見出し・テーブル意味的関連性を保証できない構造的限界のみ
   - **キヤノン（S100XTLJ）の具体例（2026-07-19発覚→同日 cherry-pick で解消を確認）**: 修正前は `geography` 候補表が2枚（1枚目=事業別収益認識タイミング表の誤混入、2枚目=地域別表・period="当期"と誤ラベル）あり、LLMは2枚目を採用したが中身は実際には前年度（FY2024-12）データで、連結売上高（FY2025-12、円）との差約2.48%は分母整合性チェック（許容 0.90〜1.10）では原理上検知できなかった。**cherry-pick後**: 誤混入していた1枚目が正しく除外され、残る1枚（本物の地域別表）の period ラベルも正しく "前期" に修正された（値は変わらず4,509,821百万円のまま）。結果として `SegmentBreakdownLLMNormalizer` は「候補が前期のみで当期データが存在しない」ことを自ら判定し `applicable=false`（snapshot=nil）を返すようになった（`notes`: 「候補テーブルは前期のみで連結売上高と金額が一致せず、当期データなし」）。**キヤノンを候補から除外する運用回避は不要になった** — 抽出層の修正だけで LLM 側が自然に安全側（非該当）に倒れる。
     - **当期データは抽出漏れと確定（2026-07-19、ユーザー提供のゴールデン値で確認）**: 第125期（FY2025-12）の真の地域別売上高は 日本961,480／米州1,489,639／欧州1,225,475／アジア・オセアニア948,133／**合計4,624,727百万円**（連結売上高と完全一致）。ライブEDINET再取得でも `geography` は前期の1表しか抽出できず、同一注記内にあるはずの `segments`（事業別、US-GAAP注23想定）も同じ「前期」ラベル・同じ合計4,509,821百万円しか取れていない（事業別・地域別が同一の巨大注記に同居し、当期分の表がその注記内のどこかにあるはずだが `SegmentExtractor` が拾えていない）。データが開示に無いのではなく**抽出漏れ**と確定した。次に着手する際は `SegmentExtractor` の巨大注記内テーブル走査（見出し検出範囲・複数期間表の網羅性）を見直すこと。本増分（LLM正規化）のスコープ外
5. **永続化** — filing-sections 派生か別テーブルか、cache_version 方針
6. **LLM の位置づけ**（確定） — read API（本番配信経路）には載せない。Stage 4/5 と同じ ingest バッチ内で計算し、結果を Neon に書いて Fly は読み取り専用配信のまま変えない。実行場所は現時点では Mac launchd 想定（Stage 4/5 と同一経路）。LLM 呼び出し自体は XBRL 解析のワーキングセットと違いメモリを食わないため実行場所の制約はゆるいが、呼び出し実装は場所に依存しない形（インターフェース越し）にしておき、将来 Fly 等へ移設する余地を残す
7. **検証セット** — 最低でも事業型・地域型報告セグメント・US-GAAP・収益認識製品別を含む書類セット
8. **LLM 成果のバージョンと再計算方針** — 下記「キャッシュ・再計算」

### キャッシュ・再計算（メモ）

決定的正規化（fact ピボット等）や現行 ingest は `cache_version` バンプで **正しい行も含めて全件再計算**してよい。安い・再現可能・監査しやすいからである。

LLM 経路を同じ感覚で `llm-v1` / `llm-v2` バンプすると問題が二重になる:

1. **費用が跳ねる**（単価というより **再計算範囲** の問題）
2. **すでに正しい出力まで作り直す**（不要な再計算）。ingest では許容できるが、LLM では厳しい

試行メモ（2026-07）: 味の素・日立・オークマ等へのスポット構造化で、使用モデルの従量は合計おおよそ **$0.06** だった。単発検証としては十分安い。ただし Stage 6 をユニバース×複数年で版バンプ全件再計算すると桁が違うため、単価が安くても **正しい行は触らない／フラグ付きだけ再計算** の設計が効く。

版の上げ方と再計算範囲はセットで設計する。**正しさが変わらない行は触らない**のが原則。

検討候補:

| 方針 | 内容 |
|---|---|
| 入力ハッシュ鍵 | プロンプト／スキーマ／モデルに加え、**入力 SegmentResult（または注記断片）のハッシュ**をキャッシュキーにする。入力も契約も同じなら版ラベルが上がっても再利用 |
| 信頼フラグ付き保存 | `needs_review` / `warnings` は **LLM出力と期待値の突き合わせ**（軸判定 vs section 期待、行合計 vs 分母 等の決定的検証）から立てる。LLM の自己申告 confidence スコアは較正精度が低いため主基準にしない。再計算・要確認は **フラグ付き・検証失敗** だけに限定（正しい行は据え置き） |
| 版の層分け | 契約スキーマ変更（破壊的・やむを得ず広範囲）と、プロンプト微修正・モデル入替を分ける。後者は全件必須にしない |
| 生ログ保持 | `BreakdownSnapshot` とは別に、LLM 呼び出し単位で入力ハッシュ（上記キャッシュキーと共用）・使用モデル/バージョン・生の応答・呼び出し日時を保持する。検証セット（今後の検討事項 7）でのスポット監査・再現に使う |
| 決定的層を厚くする | LLM 依存を減らし、バンプ対象の大半を安価なコード経路にする |

フラグを立てたい典型例:

- **軸の期待ずれ** — 利用側が `segments`＝事業別を期待しているのに、報告セグメントが地域別だった（オークマ型）。`axis=geography` と判定しつつ `needs_review` や `axis_mismatch_with_section_key` を付けると、比較や再処理の対象にできる
- 表の period が全部同じ・合計が分母と大きく不一致・必須 metrics 欠落、など機械検証で分かる異常

「怪しいものだけ再計算」は、コスト抑制であると同時に **正しい結果を壊さない／作り直さない** ための手段。ただしフラグの再現性（同じ入力で同じ flag か）と、フラグ無しの誤り見逃し（false negative）の監視がセット。抜き打ちサンプリングや合計不一致の機械検証と併用する前提が安全。

非目標（現時点）:

- 過去セグメント定義への遡及組替
- 会社間行ラベルの統一・共通バケットへの強制写像
- 全企業・全期での事業×地域の完全充足保証
- 生 XBRL を渡して LLM に一発抽出させる経路（現行 HTML/fact 前段を捨てない）
- **金融機関（銀行等）のセグメント正規化**（v1）。セグメント指標が外部顧客売上と別概念のため対象外（学び8参照）

## 関連

- `Sources/BlueTicker/Analysis/SegmentExtractor.swift`
- `Sources/BlueTicker/Constants/Xbrl.swift`（TextBlock / dimension キーワード）
- `docs/xbrl-parsing.md`
- `docs/blt-server-roadmap.md`（Stage 6）
