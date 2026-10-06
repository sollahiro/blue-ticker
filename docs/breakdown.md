# Breakdown（ドメイン契約）

企業間比較（同業の割合）と同一企業の期ごと推移が目的。**同じ形の割合（軸・分母・外部売上）で並べること**が本体。行ラベルの会社間統一はしない。抽出の再発防止は `.agents/skills/xbrl-development/SKILL.md`。正本分離は `docs/financials-summary-separation.md`。

## 方針（確定）

- 事業再編・名称変更の過去遡及補正はしない。各期はその期の開示どおり。
- 会社間の行ラベル対応は必須にしない。比較は構造（軸・分母・割合）まで。
- `segments` / `geography` は開示ブロックの取り分け。事業×地域の両方が常にあることは保証しない。
- 原則指標は外部顧客売上。分母は連結の外部売上（調整後）。金融機関は別経路（粗利益等）。
- Summary の `sales` は本表の収益相当（三菱商事の `Revenue2IFRS`「収益」を含む。JPX は `OperatingRevenueRevenue2IFRS` の営業収益）。product_service 分母は表の出どころに合わせる。収益認識表なら「顧客との契約から認識した収益」連結金額、報告セグメント表なら Summary sales。geography は Summary sales に揃える。

## 抽出の二段

1. TextBlock 内 HTML 表 → `html_table`
2. dimension 付き数値 fact → `xbrl_facts`

セグメント注記の product_service は、専用タグ `DescriptionOfFactThatCompanysBusinessComprisesSingleSegment` または `DescriptionOfFactThatCompanysBusinessComprisesSingleSegmentIFRS` の**当期**本文があり、当期の報告セグメント売上 member が 1 以下でも、**製品・サービス別（または事業別）の組立可能表があるときは省略しない**（475A S100YJX2）。収益認識の分解表があるときも表ステップへ進む。どちらも無く member が 1 以下のときだけ `single_segment_disclosed`。表 Choice の確率 0.9 は待たない。当期 member が 2 以上ならタグを信じず、当期 facts または表経路で内訳を組む。当期コンテキストのタグと当期 facts が食い違うときは内訳を残し `needs_review` と `warnings` の `single_segment_tag_disagrees_with_current_year_reportable_segments` を付ける。製品90％の文、本邦90％の文、主要顧客の表はこの省略を取り消さない。2321 型の顧客表がセグメント情報の下にあっても、公開する product_service 内訳には入れない。監査は `jev.decision_source` = `dedicated_single_segment_tag`。キーがあるときは省略提案のあと Jev 第二パス（`review_decision`）で「使える製品・事業表があるか」を聞く。確率 0.9 以上で表インデックスを返したときだけ回復し、`decision_source` は `jev_review_decision`。低信頼・keep・欠測は提案を維持する（published-wrong=0。空行は捏造しない）。列追加はしない。公開軸キー改名のため `cache_version` は新軸系列 `breakdown-product_service-v1`（旧 `breakdown-business-v15` の番号は引き継がない。金額の再計算はしない。マージ後にキー書き換え）。

専用タグの本文が無い product_service は、これまでどおり `OPENROUTER_DECISION_API_KEY` があるときだけ OpenRouter Decisions API（`typesafe/jev-1.13`）へ Choice を出す。コードが候補の文と表を切り出し、Jev は表が分析すべき内訳か（違えば `none_of_these`）、違えば省略が単一セグメント・製品サービス外部売上90％超・本邦外部売上90％超・どれでもない、のどれかを返す。省略文を分類するのは、表 Choice が `none_of_these` かつ選ばれた選択肢の `probabilities[choice]` が `SegmentNoteDecision.applyProbabilityThreshold`（0.9）以上のときだけ。表インデックスを選んだときは確率に関係なくその表を残し、`needs_review` は列選択 0.5 と合計・顧客/時点/地域軸・分母カバーに任せる。`single_segment_disclosed` になるのは Jev のクラスが `single_segment` で 0.9 以上のときだけ。製品90％の文だけでは `single_segment_disclosed` にしない。製品90％かつ報告セグメントが地域だけのときは `geography_only`。`detectSingleSegmentDisclosure` の集中度・散文フォールバックはこの写像に使わない。確率が閾値未満、欠測、または文ごとの種類が食い違うときは適用せず、決定論の結果に `needs_review` を残す。

geography は変えない。本邦90％の `not_found` は既存の Jev ゲートだけを通る。専用タグは geography の判定を飛ばさず、置き換えない。キーがあるときは、product_service を専用タグで確定しても geography の Jev は続ける。

キーが無い、または呼び出しに失敗したときは、専用タグ以外は今日の決定論のまま。失敗で `needs_review` は足さない。専用タグの product_service はキーが無くても適用する。研究開発費・設備投資はこの省略判定を使わない。公開 reason は `single_segment_disclosed` / `geography_only` / `not_found`。`cache_version` は変えない。専用タグは「セグメント注記の省略」であり、収益分解表が無いことの印ではない。分解表があるときは表ステップへ進む。選んだ表が合計行だけ（顧客契約 / その他 / 外部顧客など、カテゴリ行が無い）で専用タグがあるときは main と同じ `single_segment_disclosed`（8771 S100YKOI）。製品行がある表は残す（8771 S100R95J / S100OL2K の事業法人向け・金融法人向け保証サービスは意図した変更）。表が無い（Jev `none_of_these`）ときも省略する。並行次元やフィルタでカテゴリ行を落としたあとの空表は `not_applicable` にせず `needs_review`（5936 S100YKHR）。収益分解の列 Choice は confidence 0.5 未満を `needs_review` にする。表選択 Jev が表インデックスを返したときは 0.9 を待たずその表を残す（列 0.5・合計・顧客/時点/地域軸・分母カバーが残るゲート）。`none_of_these` は confidence ≥ 0.5 かつ `p_none` ≥ 0.75 のときだけ採用し、それ以外は最良の実列へ落として `needs_review` にする（単一報告セグメント列＝全社は有効な列）。明細合計が表の合計行（外部顧客への売上高 / 顧客との契約から生じる収益 等）と合わないとき、または明細合計が分母を超えるときも `needs_review`（`table_sum_mismatch`。4519 S100XTBJ）。明細合計が分母（表合計があればそれ、無ければ連結売上）の 95% を切るときも `needs_review`。免除はカテゴリ行のその他の源泉 / その他の収益 / その他収益だけであり、合計行やグリッドの「その他の収益（注）」では免除しない（6620 S100R5UA / S100TUOL / S100YJZT）。単一行の表、または明細合計 0 は公開しない。`llm_audit.column_jev` に列選択、`llm_audit.jev` にセグメント注記判断を残す。スナップショットが無いとき（受理した `none_of_these` 等）も両方の audit を落とさない。`SegmentInfoLLMNormalizer` は収益認識と同じ表構造 4 段と Jev の列・行選択でセグメント情報 html_table を組む（閾値 0.5。`none_of_these` は confidence ≥ 0.5 かつ p_none ≥ 0.75 のときだけ。Chat Completions は使わない）。選んだ表が空行なら他の製品・マトリクス表から組み、それでも空ならスナップショットを作らず `xbrl_facts` へフォールバックする（空 LLM で facts を隠さない。7273 S100YLTN）。Jev の keepTable は組立不能・前期（当期あり）・製品表があるのに選んだ表が製品でないときは1表に閉じない（3600 S100YHMW / 4324 S100QHOJ）。「収益(注)」は売上行として認める。銀行の内部小計距離は segment+reconciling で見る（8316 S100LU5N）。事業別の報告セグメントはそのまま採る。地域別の報告セグメントで製品別もあるときは製品を採り地域は捨て、両方を足さない（`製品・サービス別情報` の表を報告セグメントの地域表より先に出す）。列が製品・行が当連結会計年度のマトリクスも転置する。選んだ列が見出しの事業名でも合計列でなければ残す。地域別のみ（使える製品表が無い。製品90％省略の文は製品表ではない）なら product_service は `geography_only`。地域は geography 軸に置き、日本/アジアを product_service に載せない。`segment_info_geography_only_taken` で公開する経路は使わない。単一セグメントと開示なら `single_segment_disclosed`。`GeographyBreakdownLLMNormalizer` は収益認識と同じ表構造と Jev の列選択で地域別 html_table を組む（列 Choice と最終判定を 3 回並列。成功 ≥2 かつ selected が揃えば confident。生 confidence 0.5 は公開ゲートにしない。不一致・成功不足は `needs_review`。Chat Completions は使わない）。列見出しの 前連結会計年度 はキャプションの 当 より優先し、同じ表に当期列がある前期列は候補に出さない。前期だけの地域表は当期内訳に使わず、報告セグメントが地域軸なら facts へ落とす。Prior コンテキストの比較表に当期行があるときは html を残す（1887 / 4568）。前期列の金額は `geography_prior_period_column`、選んだ当期列と金額が食い違うときは `geography_selected_column_mismatch` で `needs_review`（最終判定の correct では覆さない。7272 は訂正 130 S100YTNF の当期 137,712 であり、原本 120 S100XRTH の 155,330 列へ載せると不一致。ingest は 130 overlay 後の表を使う）。最終判定の state に `period_columns`（当期/前期の金額）を載せる。行を組んだあと公開直前と低確信 NR について Jev 第二パス（`review_decision`: `correct` / `wrong`）で最終判定する。列と最終判定は 3 回並列し、成功 ≥2 かつ selected が揃ったときだけ confident。確率 0.9 以上の一致した `wrong` は公開を `needs_review` に落とす。低確信 NR は一致した 0.9 以上の `correct` かつ行が組めて、小計・分母・ラベル・単位・前期列・選択列不一致・サンプル不一致・カバレッジ（`geography_coverage_below_sales`。公開セグメント合計が分母の 95% 未満。内部小計分母でも売上と表合計に対して同じ床。`llm_denominator_from_internal_subtotal` では迂回しない）のハードガードが無いときだけ公開に戻す。親地域見出しに（うち〜）が重なった列は親を残し、うち行だけ落とす（3382 / 4005）。製品×地域マトリクスは同じ合計の単純地域表があるとき落とす（6762）。表内小計が損益計算書売上より明らかに近いときは同一報告ベースで表合計を分母にする（6758）。失敗・不一致・低信頼は提案維持。 最終判定の table_markdown が 8000 字で切れたときは state に table_truncated=true を付け、correct 回復はしない（confident wrong の降格はする）。監査は `llm_audit.jev`（適用時 `decision_source` = `jev_review_decision`）。`cache_version` は上げない。収益認識の事業別分解は `RevenueRecognitionColumnNormalizer` が Jev に当期の全社金額列だけを選ばせ、行・`category_group` / `category`・金額は決定論で組む。候補表に製品・事業・サービス軸と顧客軸（顧客別 / 〜向け / グループ向け / 主要な顧客 / 販売経路 / 官公庁 / 民間 / 公共 / 政府 / 中央省庁 / 地方自治体 / 業販 / 金融 / 情報通信 / 小売と卸売の対）または時点軸（一時点 / 一定の期間）が両方あるときは、Jev の前に製品・事業表だけを残す（デンソー S100Y9T1）。顧客軸または時点軸だけのとき、行ラベルが全て地域のとき（日本 / 国内 / 海外 / 仕向地。6273 / 7202）、同一表に製品と顧客が混在するとき、前期表のときは `needs_review`。当期の製品表があるときは前期表を列候補から外す（オークマ 6103 S100YFQC 当期 235,888）。時点ラベル（一時点で移転される財又はサービス）はサービス / 財より先に時点へ倒す（7050）。表構造は Jev 列選択の前に 4 段で決める。(1) ラベル域は 1 または 2 列（rowspan/colspan 展開後）。(2) 各行は `category_group` か `category`（金額なし見出しと 2 列ラベル域の外側は group。`業界の名称` のような軸タイトルと単位キャプションは落とす。6140）。(3) 各行は subtotal（〜計 / 計 / 外部顧客への売上高・収益 / 合計 / 小計 / その他収益）か segment。(4) 全てのブロックが表全体合計と同じ小計で閉じるときだけ並行次元：加算せず事業次元だけを残し、特定できなければ `needs_review`。全行が「－」/0/空のブロックと、顧客との契約 / その他の収益 / 外部顧客への売上高の調整末尾は並行次元にしない（2467 S100YMA4）。並行ブロックは見出しに加え行ラベルで分類し、時点（一時点 / 一定の期間）や地域だけのブロックは製品ではない。残りが1つならそれを残し `needs_review` にしない（6287 S100YE10）。地理と製品が同じ合計で並ぶ表（東京エレクトロン S100YEOO）は (4)。品種別 / 品目別 / 製品別 / 事業別 / サービス別は製品ブロック。デンソー S100Y9T1 の空 rowspan + `自動車分野計` は (1)(2)(3) の 2 列ラベル域。括弧付きの子行、および直後の行が親金額に一致する親子は、親と子を両方出さず、子の合計が親に一致すれば子、そうでなければ親。Jev は金額を読まない。REST/MCP の `label` は `category` があればその文言、無ければ `category_group`（括弧で連結しない）。`category_group` と `category` は別フィールドのまま返す。`(注)` だけの注記マーカーもラベルから落とす。

設備投資マトリクス（`capex`）で数値タグも該当表も無いときは、`OPENROUTER_DECISION_API_KEY` がある場合だけ別の Choice を出す。対象は `OverviewOfCapitalExpendituresEtcOwnUsedAssetsLEATextBlock` / `OverviewOfCapitalExpendituresEtcTextBlock`。コードが文を切り、円へ換算する。Jev は Role だけ返す。`probabilities[choice]` が 0.9 以上の当期総額がちょうど1文のときだけ Overview セルの会社総額にする。source は `capex_prose`。タグ付きセグメント行があり差額に一致する1文があるときは reconciling を足す。セグメント別セルは埋めない。応答が無いときは行を作らず再試行する。キーが無いときは決定論のまま。

研究開発費で数値タグもセグメント fact も無いときは、`OPENROUTER_DECISION_API_KEY` がある場合だけ別の Choice を出す。対象は `ResearchAndDevelopmentActivitiesTextBlock`。コードが文を切り、百万円・千円・億円を円へ換算する。1文に金額が2つある文、0円、割合だけの文は候補にしない。候補が12を超えるときは「研究開発費」を含む文を先に残す。Jev は各文を当期の会社全体の総額 / 前期 / 一部金額 / 無関係に分類し、金額は返さない。`probabilities[choice]` が 0.9 以上の当期総額がちょうど1文のときだけ `rows=[]` の resolved にする。source は `research_and_development_prose`、`denominator_tag` も同じ sentinel。本文がセグメントへ配分できない、またはセグメント別の記載をしないと言うときは `warnings` に `not_allocatable_to_segments` を付ける。`single_segment_disclosed` にはしない。確率不足や当期総額が複数のときは `not_found` のままで、`needs_review` は足さない。応答が無いときは行を作らず、次回の欠測 ingest で再試行する。キーが無いときは数値タグの決定論のまま。`cache_version` は上げない。既存の `not_found` は行削除または `--codes` まで残る。Summary の `rd` は数値タグのままで、この本文総額は breakdown の分母にだけ入る。複数金額が1文に入るセグメント散文は対象外。

全社合計の数値タグがあり、タグ付きの segment と reconciling を足しても全社合計より 5% 以上足りないときは、同じ本文から差額に一致する文を探す。一致は差額との差が 5百万円以内。5百万円で一致する文が無く、配分できない文が1つだけのときは、その文の金額を見る。事業区分が億円単位だと、本文の配分不能額と円の差額が 5百万円を超えることがある。一致がちょうど1文のときだけ、別の Choice でその文が報告セグメントに配分されていない当期の残りかを聞く。確率 0.9 以上ならその金額を `reconciling` 行として足し、足した合計が 5% 以内に収まり `research_and_development_segment_sum_far_from_total` が解消すれば `needs_review` を外す。`warnings` に `research_and_development_prose_remainder` を残す。source は `xbrl_facts` のまま。セグメント行が無い合計のみの開示は埋めない。一致が無い、2文以上、確率不足、応答が無い、足しても 5% を超えるときは、タグ付きの決定論のまま残す。`cache_version` は上げない。既存の不足行は行削除または `--codes` まで残る。複数文の金額を組み合わせて差額を作る処理は対象外。

活動タグの全社合計が無く、抽出が販管費タグに落ちているとき、研究開発活動の本文にある研究開発費の総額が1文だけで製造費用込みの注記 `ResearchAndDevelopmentExpensesIncludedInGeneralAndAdministrativeExpensesAndManufacturingCostForCurrentPeriod` と一致するなら、分母はその注記である。億円表記は 0.5億円までを一致とする。Summary の `rd` も同じ分母を使う。活動タグの全社合計がある書類は注記へ替えない。

タグ付き合計が全社合計を 5% 以上超えるとき、総額とその外の金額が同じ文にあり「このほか」等で総額の外と分かる1文だけを、別の Choice で総額の外かを聞く。確率 0.9 以上ならその金額を負の `reconciling` 行として足し、既存の行は削らない。合計が 5% 以内になれば `needs_review` を外し、`warnings` に `research_and_development_prose_exclusion` を残す。この warning は 404 にしない。

| API キー | 意味 |
|---|---|
| `segments` | 報告セグメント（事業とも地域とも限らない） |
| `geography` | 地域別注記 |
| `employees` | 従業員数のセグメント別内訳 |
| `research_and_development` | 研究開発費のセグメント別内訳 |
| `goodwill` | のれん |
| `goodwill_amortization` | 報告セグメントごとののれんの償却額 |
| `equity_method_investments` | 報告セグメントごとの持分法会計処理される投資 |
| `capex` | 設備投資マトリクス（行=セグメント / 調整額 / EntityTotal。セル= `segment_assets` / `flow` / `capital_expenditures_overview`）。`flow` は書類単位で資本的支出があればそれ、無ければ非流動性資産への追加額。旧 4 軸名は廃止 |

公開軸（意味。公開判断の現在地は Linear [JP 現在地](https://linear.app/sollahiro/document/jp-現在地-af2abd076034)）:

| axis | 内容 |
|---|---|
| `product_service` | 製品・サービス別売上 |
| `geography` | 地域別売上 |
| `employees` | 従業員内訳 |
| `research_and_development` | 研究開発費内訳（発生支出） |
| `goodwill` | のれん |
| `goodwill_amortization` | のれんの償却額 |
| `equity_method_investments` | 持分法投資 |
| `capex` | 設備投資マトリクス |

旧 `segment_assets` / `capital_expenditures` / `noncurrent_asset_additions` / `capital_expenditures_overview` は REST / MCP / skills から削除した（breaking。`apiSkillsSchemaVersion` 2、`breakdown-capex-v1`）。

## 契約・永続化

- 比較用スナップショット: `BreakdownSnapshot`（`BreakdownContract.swift` / `BreakdownNormalizer`）。
- 保存: `company_breakdowns`（filing-sections とは別。LLM 行を filing バンプに巻き込まない）。主キー `doc_id#axis`。
- `not_found` は行を作らない。business の E/F/unknown は `not_applicable` プレースホルダ。REST と開発用 MCP は 404＋ボディ `reason`（200 化しない）。
- 公開 serving（REST `GET /v1/companies/{code}/breakdown`、開発用 MCP `get_breakdown`。iOS Breakdown の backing）は `needs_review=true` または `warnings` に `llm_unit_unresolved` がある **LLM 行を出さない**（千円表の 1000 倍誤り stopgap。fail closed）。残行が 0 なら未算出と同じ 404。payload 形は変えない。XBRL（`xbrl_facts` / `stacked_segment_pnl`）と `not_applicable`（'none'）、研究開発費の本文総額（`research_and_development_prose`）、設備投資の本文総額（`capex_prose`）はそのまま出す。`not_allocatable_to_segments` が付いていても 404 にしない。抽出・Neon 行・`cache_version` は触らない。
- 対象母集団: 全軸とも上場全体（日経225は処理順の先頭寄せのみ。2026-09 に employees / rd / goodwill および報告セグメント別指標軸も日経225限定を廃止して拡大）。read は Fly 専用（ingest 時に LLM 計算）。処理順は各社の最新有報 → 前年以降。同一年次内は日経225 → ローカル XBRL 展開済み → 欠測/要再試行/版ずれのラウンドロビン（軸ごとにキャッシュ集合を取り直す）。
- 売上分母・employees / rd の Summary 正本は breakdown 分母（ingest も同一 XBRL パスで直接解決）。
- 報告セグメント別指標の分母は通常 segment + reconciling（表の小計・EntityTotal は行として保持）。`capex` の各セル（`segment_assets` / `flow` / `capital_expenditures_overview`）の分母は、その指標の連結の無 dimension 総額タグ（EntityTotal）である。加算した segment+reconciling は 100% 分母にしない（項目タグ漏れがシェアに出るようにする）。5% 超ずれは `needs_review`。総額が無いときは Jev 本文総額（Role のみ、円はコード）、それも無ければそのセルの分母は null。`segment_assets` だけ、銀行の固定資産など連結 EntityTotal が無いとき segment + reconciling を残す。差額表 HTML の非分類行が既存 segment 行と同額のときは、その行だけ落とす（ラベル非依存）。
  XBRL タグ付き reconciling member（`ReconcilingItemsMember` 等）には適用しない。
- `capex` は名前付きセル。単一 `amount` は使わない。欠測セルは null。`flow` は書類単位で `capital_expenditures` があればそれ、無ければ `noncurrent_asset_additions`（混ぜず足さない）。Overview HTML 表は正本。HTML ラベルと XBRL member の結合は初期はしない。財務諸表計上額の `row_kind` は `EntityTotal`。
- 設備投資の本文総額は `OPENROUTER_DECISION_API_KEY` があるときだけ別 Choice（`capex_prose`）。Jev は Role だけ、円はコード。埋めるのは Overview の会社総額と、タグ付きセグメント行があるときの reconciling だけ。セグメント別は埋めない。`SegmentNoteDecision` の表/省略 Choice には載せない。source `capex_prose` は公開面で研究開発費本文総額と同じ扱い。`cache_version` は `breakdown-capex-v1`。

## 非目標

過去セグメント遡及組替、会社間ラベル統一、全期の事業×地域完全充足、生 XBRL 一発 LLM 抽出。
