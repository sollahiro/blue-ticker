# Breakdown（ドメイン契約）

企業間比較（同業の割合）と同一企業の期ごと推移が目的。**同じ形の割合（軸・分母・外部売上）で並べること**が本体。行ラベルの会社間統一はしない。抽出の再発防止は `.agents/skills/xbrl-development/SKILL.md`。正本分離は `docs/financials-summary-separation.md`。

## 方針（確定）

- 事業再編・名称変更の過去遡及補正はしない。各期はその期の開示どおり。
- 会社間の行ラベル対応は必須にしない。比較は構造（軸・分母・割合）まで。
- `segments` / `geography` は開示ブロックの取り分け。事業×地域の両方が常にあることは保証しない。
- 原則指標は外部顧客売上。分母は連結の外部売上（調整後）。金融機関は別経路（粗利益等）。
- Summary の `sales` は本表の収益相当（三菱商事の `Revenue2IFRS`「収益」を含む。JPX は `OperatingRevenueRevenue2IFRS` の営業収益）。business 分母は表の出どころに合わせる。収益認識表なら「顧客との契約から認識した収益」連結金額、報告セグメント表なら Summary sales。geography は Summary sales に揃える。

## 抽出の二段

1. TextBlock 内 HTML 表 → `html_table`
2. dimension 付き数値 fact → `xbrl_facts`

セグメント注記の business は、専用タグ `DescriptionOfFactThatCompanysBusinessComprisesSingleSegment` または `DescriptionOfFactThatCompanysBusinessComprisesSingleSegmentIFRS` に本文があるとき、Jev を呼ばずに `single_segment_disclosed` にする。表 Choice の確率 0.9 は待たない。製品90％の文、本邦90％の文、主要顧客の表、報告セグメントの member fact はこれを取り消さない。2321 型の顧客表がセグメント情報の下にあっても、公開する business 内訳には入れない。理由は省略であり、Jev が表を却下したからではない。監査は `company_breakdowns.llm_audit` の `jev.decision_source` = `dedicated_single_segment_tag` と空の `calls` で、Jev を呼んでいないことを残す。列追加はしない。

専用タグの本文が無い business は、これまでどおり `OPENROUTER_DECISION_API_KEY` があるときだけ OpenRouter Decisions API（`typesafe/jev-1.13`）へ Choice を出す。コードが候補の文と表を切り出し、Jev は表が分析すべき内訳か（違えば `none_of_these`）、違えば省略が単一セグメント・製品サービス外部売上90％超・本邦外部売上90％超・どれでもない、のどれかを返す。省略文を分類するのは、表 Choice が `none_of_these` かつ選ばれた選択肢の `probabilities[choice]` が `SegmentNoteDecision.applyProbabilityThreshold`（0.9）以上のときだけ。`single_segment_disclosed` になるのは Jev のクラスが `single_segment` で 0.9 以上のときだけ。製品90％の文だけでは `single_segment_disclosed` にしない。製品90％かつ報告セグメントが地域だけのときは `geography_only`。`detectSingleSegmentDisclosure` の集中度・散文フォールバックはこの写像に使わない。確率が閾値未満、欠測、または文ごとの種類が食い違うときは適用せず、決定論の結果に `needs_review` を残す。

geography は変えない。本邦90％の `not_found` は既存の Jev ゲートだけを通る。専用タグは geography の判定を飛ばさず、置き換えない。キーがあるときは、business を専用タグで確定しても geography の Jev は続ける。

キーが無い、または呼び出しに失敗したときは、専用タグ以外は今日の決定論のまま。失敗で `needs_review` は足さない。専用タグの business はキーが無くても適用する。研究開発費・設備投資はこの省略判定を使わない。公開 reason は `single_segment_disclosed` / `geography_only` / `not_found`。`cache_version` は変えない。専用タグは「セグメント注記の省略」であり、収益分解表が無いことの印ではない。分解表があるときは表ステップへ進み、表が無い（Jev `none_of_these`）ときだけ省略する。`SegmentInfoLLMNormalizer` と `GeographyBreakdownLLMNormalizer` は選ばれた html_table を行・金額・単位へ写す。収益認識の事業別分解は `RevenueRecognitionColumnNormalizer` が Jev に当期の全社金額列だけを選ばせ、行・`category_group` / `category`・金額は決定論で組む。Jev は金額を読まない。

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
| `business` | 事業別売上 |
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
