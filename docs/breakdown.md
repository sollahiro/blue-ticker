# Breakdown（ドメイン契約）

企業間比較（同業の割合）と同一企業の期ごと推移が目的。**同じ形の割合（軸・分母・外部売上）で並べること**が本体。行ラベルの会社間統一はしない。抽出の再発防止は `.agents/skills/xbrl-development/SKILL.md`。正本分離は `docs/financials-summary-separation.md`。

## 方針（確定）

- 事業再編・名称変更の過去遡及補正はしない。各期はその期の開示どおり。
- 会社間の行ラベル対応は必須にしない。比較は構造（軸・分母・割合）まで。
- `segments` / `geography` は開示ブロックの取り分け。事業×地域の両方が常にあることは保証しない。
- 原則指標は外部顧客売上。分母は連結の外部売上（調整後）。金融機関は別経路（粗利益等）。
- `xbrl_facts` の行 `profit` は会社が「セグメント利益」と定義した測度。①セグメント表で行名が「セグメント利益／損益／損失」で始まる行のタグ（括弧付き「セグメント利益（事業利益）」を含む。inline XBRL の当期セグメント member fact の行名。接頭辞のハイフン付き会社拡張 QName もローカル名として読む。経常利益基準の金融・電力 8601 / 8750 / 8795 / 5831 / 9505–9509、東京海上 8766 の親会社所有者帰属利益、三井不動産 8801 の BusinessIncome）。その行名が数値の無い見出しで、下に営業利益・持分法投資損益等の内訳と「計」があるときは見出しの「計」行（東京建物 8804 の会社拡張 `SegmentProfit`。計の報告セグメント計が差異調整表の起点と食い違うときは採用しない。野村不動産 3231 のように合計行自体が「セグメント損益」ならその行）、②無ければ差異調整表の利益の部「報告セグメント計」と報告セグメント計 fact が一致するタグ（行名が測度名だけのりそな 8308 の与信費用控除後業務純益）、③どちらも無ければ従来のタグ優先リスト（`Xbrl.segmentProfitTags` / 銀行 / 保険）。タグ名・業種では分岐しない。
- Summary の `sales` は本表の収益相当（三菱商事の `Revenue2IFRS`「収益」を含む。JPX は `OperatingRevenueRevenue2IFRS` の営業収益）。product_service 分母は表の出どころに合わせる。収益認識表なら「顧客との契約から認識した収益」連結金額、報告セグメント表なら Summary sales。geography は連結 PL のトップライン（営業利益行より上の収益行のうち、他の収益行の構成要素でない行の和。売上高の上に合計行があればその合計。ソニーの 売上高及び金融ビジネス収入合計、9950 の 売上高＋営業収入。構成要素まで収益タグだけの行に限り、金融収益・その他の収益・受取利息などの営業外収益、うち内数（Of*／うち〜）は入れない。IFRS で別建ての収益行が2つ以上並ぶときは売上高／営業収益どうしのときだけ足す。根のどれかが残りの根の和に一致するときは合計と内訳なので足さない）が Summary sales より大きいときはそれ、無ければ Summary sales に揃える（銀行・保険・US-GAAP は Summary sales）。
- 報告セグメントが地域名のため収益認識へ寄せるとき、収益認識の**行**が報告セグメントと同じ日本語ラベルかつ同じ開示金額で、セグメント表に利益があるなら、product_service は収益認識ではなく `xbrl_facts`（利益と計 / 調整 / 連結を含む）を使う。列に製品名があっても、公開される行が報告セグメントなら同じ。行が酒類・飲料のような別次元なら従来どおり収益認識。どの値も開示セルからだけ読む（差額埋めはしない）。

## 抽出の二段

1. TextBlock 内 HTML 表 → `html_table`
2. dimension 付き数値 fact → `xbrl_facts`

セグメント注記の product_service は、専用タグ `DescriptionOfFactThatCompanysBusinessComprisesSingleSegment` または `DescriptionOfFactThatCompanysBusinessComprisesSingleSegmentIFRS` の**当期**本文があり、当期の報告セグメント売上 member が 1 以下でも、**製品・サービス別（または事業別）の組立可能表があるときは省略しない**（475A S100YJX2）。収益認識の分解表があるときも表ステップへ進む。どちらも無く member が 1 以下のときだけ `single_segment_disclosed`。表 Choice の確率 0.9 は待たない。当期 member が 2 以上ならタグを信じず、当期 facts または表経路で内訳を組む。当期コンテキストのタグと当期 facts が食い違うときは内訳を残し `needs_review` と `warnings` の `single_segment_tag_disagrees_with_current_year_reportable_segments` を付ける。製品90％の文、本邦90％の文、主要顧客の表はこの省略を取り消さない。2321 型の顧客表がセグメント情報の下にあっても、公開する product_service 内訳には入れない。監査は `jev.decision_source` = `dedicated_single_segment_tag`。キーがあるときは省略提案のあと Jev 第二パス（`review_decision`）で「使える製品・事業表があるか」を聞く。確率 0.9 以上で表インデックスを返したときだけ回復し、`decision_source` は `jev_review_decision`。低信頼・keep・欠測は提案を維持する（published-wrong=0。空行は捏造しない）。列追加はしない。公開軸キー改名のため `cache_version` は新軸系列 `breakdown-product_service-v1`（旧 `breakdown-business-v15` の番号は引き継がない。金額の再計算はしない。マージ後にキー書き換え）。

専用タグの本文が無い product_service は、これまでどおり `OPENROUTER_DECISION_API_KEY` があるときだけ OpenRouter Decisions API（`typesafe/jev-1.13`）へ Choice を出す。コードが候補の文と表を切り出し、Jev は表が分析すべき内訳か（違えば `none_of_these`）、違えば省略が単一セグメント・製品サービス外部売上90％超・本邦外部売上90％超・どれでもない、のどれかを返す。省略文を分類するのは、表 Choice が `none_of_these` かつ選ばれた選択肢の `probabilities[choice]` が `SegmentNoteDecision.applyProbabilityThreshold`（0.9）以上のときだけ。表インデックスを選んだときは確率に関係なくその表を残し、`needs_review` は列選択 0.5 と合計・顧客/時点/地域軸・分母カバーに任せる。`single_segment_disclosed` になるのは Jev のクラスが `single_segment` で 0.9 以上のときだけ。製品90％の文だけでは `single_segment_disclosed` にしない。製品90％かつ報告セグメントが地域だけのときは `geography_only`。`detectSingleSegmentDisclosure` の集中度・散文フォールバックはこの写像に使わない。確率が閾値未満、欠測、または文ごとの種類が食い違うときは適用せず、決定論の結果に `needs_review` を残す。

geography は変えない。本邦90％の `not_found` は既存の Jev ゲートだけを通る。専用タグは geography の判定を飛ばさず、置き換えない。キーがあるときは、product_service を専用タグで確定しても geography の Jev は続ける。

キーが無い、または呼び出しに失敗したときは、専用タグ以外は今日の決定論のまま。失敗で `needs_review` は足さない。専用タグの product_service はキーが無くても適用する。研究開発費・設備投資はこの省略判定を使わない。公開 reason は `single_segment_disclosed` / `geography_only` / `not_found`。`cache_version` は変えない。専用タグは「セグメント注記の省略」であり、収益分解表が無いことの印ではない。分解表があるときは表ステップへ進む。選んだ表が合計行だけ（顧客契約 / その他 / 外部顧客など、カテゴリ行が無い）で専用タグがあるときは main と同じ `single_segment_disclosed`（8771 S100YKOI）。製品行がある表は残す（8771 S100R95J / S100OL2K の事業法人向け・金融法人向け保証サービスは意図した変更）。表が無い（Jev `none_of_these`）ときも省略する。並行次元やフィルタでカテゴリ行を落としたあとの空表は `not_applicable` にせず `needs_review`（5936 S100YKHR）。収益分解の列 Choice は confidence 0.5 未満を `needs_review` にする。表選択 Jev が表インデックスを返したときは 0.9 を待たずその表を残す（列 0.5・合計・顧客/時点/地域軸・分母カバーが残るゲート）。`none_of_these` は confidence ≥ 0.5 かつ `p_none` ≥ 0.75 のときだけ採用し、それ以外は最良の実列へ落として `needs_review` にする（単一報告セグメント列＝全社は有効な列）。明細合計が表の合計行（外部顧客への売上高 / 顧客との契約から生じる収益 等）と合わないとき、または明細合計が分母を超えるときも `needs_review`（`table_sum_mismatch`。4519 S100XTBJ）。明細合計が分母（表合計があればそれ、無ければ連結売上）の 95% を切るときも `needs_review`。免除はカテゴリ行のその他の源泉 / その他の収益 / その他収益だけであり、グリッドの「その他の収益（注）」では免除しない（6620 S100R5UA）。顧客との契約の外の収益（合計行の「その他の源泉から生じる収益」「その他の収益（注）」等）は、明細合計にその行を足すと分母の表合計（外部顧客への売上高、または顧客との契約の小計の下の「合計」）に一致するときだけ `row_kind=reconciling` 行として載せる（ラベルは開示どおり、注記マーカーは落とす）。カバー率はそのとき segment + reconciling で見る。分母が顧客との契約の合計の表（三菱商事 S100YB25）や、足すと合計に一致しない表では足さない。カテゴリ行に同じ語があるときは明細に入っているので足さない（7464 S100YJG0 / 7532 S100Z42G）。6620 S100TUOL / S100YJZT は reconciling で分母を覆うが、単一行・明細 0 で公開しない。単一行の表、または明細合計 0 は公開しない。`llm_audit.column_jev` に列選択、`llm_audit.jev` にセグメント注記判断を残す。スナップショットが無いとき（受理した `none_of_these` 等）も両方の audit を落とさない。`SegmentInfoLLMNormalizer` は収益認識と同じ表構造 4 段と Jev の列・行選択でセグメント情報 html_table を組む（閾値 0.5。`none_of_these` は confidence ≥ 0.5 かつ p_none ≥ 0.75 のときだけ。Chat Completions は使わない）。選んだ表が空行なら他の製品・マトリクス表から組み、それでも空ならスナップショットを作らず `xbrl_facts` へフォールバックする（空 LLM で facts を隠さない。7273 S100YLTN）。Jev の keepTable は組立不能・前期（当期あり）・製品表があるのに選んだ表が製品でないときは1表に閉じない（3600 S100YHMW / 4324 S100QHOJ）。「収益(注)」は売上行として認める。子の直後に親の小計が来る表（7752 S100LKDZ のオフィス分野）は、セグメント合計が売上の許容幅を超え、直前の連続した 2 行以上の合計に一致する行を小計にすると許容幅に収まるときだけ、その行を `subtotal` にする（ラベルは見ない）。売上の行が無く、営業利益・セグメント損益・のれん償却額・未償却残高・税金等調整前当期純利益の行だけの表は売上内訳の候補にしない（4901 S100LV2D / 7062 S100YLVZ）。銀行の内部小計距離は segment+reconciling で見る（8316 S100LU5N）。事業別の報告セグメントはそのまま採る。地域別の報告セグメントで製品別もあるときは製品を採り地域は捨て、両方を足さない（`製品・サービス別情報` の表を報告セグメントの地域表より先に出す）。列が製品・行が当連結会計年度のマトリクスも転置する。選んだ列が見出しの事業名でも合計列でなければ残す。地域別のみ（使える製品表が無い。製品90％省略の文は製品表ではない）なら product_service は `geography_only`。地域は geography 軸に置き、日本/アジアを product_service に載せない。`segment_info_geography_only_taken` で公開する経路は使わない。単一セグメントと開示なら `single_segment_disclosed`。`GeographyBreakdownLLMNormalizer` は収益認識と同じ表構造と Jev の列選択で地域別 html_table を組む（列 Choice と最終判定を 3 回並列。成功 ≥2 かつ selected が揃えば confident。生 confidence 0.5 は公開ゲートにしない。不一致・成功不足は `needs_review`。Chat Completions は使わない）。列見出しの 前連結会計年度 はキャプションの 当 より優先し、同じ表に当期列がある前期列は候補に出さない。前期だけの地域表は当期内訳に使わず、報告セグメントが地域軸なら facts へ落とす。Prior コンテキストの比較表に当期行があるときは html を残す（1887 / 4568）。前期列の金額は `geography_prior_period_column`、選んだ当期列と金額が食い違うときは `geography_selected_column_mismatch` で `needs_review`（最終判定の correct では覆さない。7272 は訂正 130 S100YTNF の当期 137,712 であり、原本 120 S100XRTH の 155,330 列へ載せると不一致。ingest は 130 overlay 後の表を使う）。最終判定の state に `period_columns`（当期/前期の金額）を載せる。行を組んだあと公開直前と低確信 NR について Jev 第二パス（`review_decision`: `correct` / `wrong`）で最終判定する。列と最終判定は 3 回並列し、成功 ≥2 かつ selected が揃ったときだけ confident。確率 0.9 以上の一致した `wrong` は公開を `needs_review` に落とす。低確信 NR は一致した 0.9 以上の `correct` かつ行が組めて、小計・分母・ラベル・単位・前期列・選択列不一致・サンプル不一致のハードガードが無いときだけ公開に戻す。分母整合は既存の `llm_row_sum_mismatch`（公開セグメント合計が損益計算書売上の 95–105% の外。売上が無ければ表の総合計。同じ表の内部小計では満たさない。最終判定の correct では覆さない）。銀行・保険の経常収益／営業収益／保険収益表は表の総合計をアンカーにする。PL に営業収益（OperatingRevenue*）と売上高（NetSales*）が並ぶときはトップラインの営業収益を使い、同じアンカー選択に倒す（3382 / 8233 / 8267。Summary sales_label は変えない）。親地域見出しに（うち〜）が重なった列は親を `segment` として残し、うち内数は `row_kind=subtotal`（`category_group`=親ラベル、`category`=子ラベル）として残す。加算・coverage は `segment` だけ。うち内数は `extractedSubtotalsMismatch` の加算検査から外し、子 ≤ 親だけ見る。employees の真の「うち」子（9104 型）も同じキーを付ける。花王の親落とし・`ReportableSegmentsMember`・タグ付き合計には付けない。製品×地域マトリクスは同じ合計の単純地域表があるとき落とす（6762）。表の総合計が損益計算書売上より明らかに近く公開行が総合計を覆うときは同一報告ベースで表合計を分母にするが、IS 95–105% の外は `llm_row_sum_mismatch` のまま（6758）。失敗・不一致・低信頼は提案維持。 最終判定の table_markdown が 8000 字で切れたときは state に table_truncated=true を付け、correct 回復はしない（confident wrong の降格はする）。最終判定 state に `consolidated_sales_million_yen` を載せる。監査は `llm_audit.jev`（適用時 `decision_source` = `jev_review_decision`）。`cache_version` は上げない。収益認識の事業別分解は `RevenueRecognitionColumnNormalizer` が Jev に当期の全社金額列だけを選ばせ、行・`category_group` / `category`・金額は決定論で組む。候補表に製品・事業・サービス軸と顧客軸（顧客別 / 〜向け / グループ向け / 主要な顧客 / 販売経路 / 官公庁 / 民間 / 公共 / 政府 / 中央省庁 / 地方自治体 / 業販 / 金融 / 情報通信 / 小売と卸売の対）または時点軸（一時点 / 一定の期間）が両方あるときは、Jev の前に製品・事業表だけを残す（デンソー S100Y9T1）。顧客軸または時点軸だけのとき、行ラベルが全て地域のとき（日本 / 国内 / 海外 / 仕向地。6273 / 7202）、同一表に製品と顧客が混在するとき、前期表のときは `needs_review`。当期の製品表があるときは前期表を列候補から外す（オークマ 6103 S100YFQC 当期 235,888）。時点ラベル（一時点で移転される財又はサービス）はサービス / 財より先に時点へ倒す（7050）。表構造は Jev 列選択の前に 4 段で決める。(1) ラベル域は 1 または 2 列（rowspan/colspan 展開後）。(2) 各行は `category_group` か `category`（金額なし見出しと 2 列ラベル域の外側は group。`業界の名称` のような軸タイトルと単位キャプションは落とす。6140）。(3) 各行は subtotal（〜計 / 計 / 外部顧客への売上高・収益 / 合計 / 小計 / その他収益）か segment。(4) 全てのブロックが表全体合計と同じ小計で閉じるときだけ並行次元：加算せず事業次元だけを残し、特定できなければ `needs_review`。全行が「－」/0/空のブロックと、顧客との契約 / その他の収益 / 外部顧客への売上高の調整末尾は並行次元にしない（2467 S100YMA4）。並行ブロックは見出しに加え行ラベルで分類し、時点（一時点 / 一定の期間）や地域だけのブロックは製品ではない。残りが1つならそれを残し `needs_review` にしない（6287 S100YE10）。地理と製品が同じ合計で並ぶ表（東京エレクトロン S100YEOO）は (4)。品種別 / 品目別 / 製品別 / 事業別 / サービス別は製品ブロック。デンソー S100Y9T1 の空 rowspan + `自動車分野計` は (1)(2)(3) の 2 列ラベル域。括弧付きの子行、および直後の行が親金額に一致する親子は、親と子を両方出さず、子の合計が親に一致すれば子、そうでなければ親。Jev は金額を読まない。REST/MCP の `label` は `category` があればその文言、無ければ `category_group`（括弧で連結しない）。`category_group` と `category` は別フィールドのまま返す。`(注)` だけの注記マーカーもラベルから落とす。

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
| `interest_bearing_debt` | 有利子負債（社債・借入金＋リース負債）。行=負債の行、セル= `opening` / `closing`、行ごとに `source`・`maturity_class`・`in_total`・`excluded_reason`・`paired_row_index`。合計は `in_total=true` の行だけ |

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
| `interest_bearing_debt` | 有利子負債内訳 |

旧 `segment_assets` / `capital_expenditures` / `noncurrent_asset_additions` / `capital_expenditures_overview` は REST / MCP / skills から削除した（breaking。`apiSkillsSchemaVersion` 2、`breakdown-capex-v1`）。

## 契約・永続化

- 比較用スナップショット: `BreakdownSnapshot`（`BreakdownContract.swift` / `BreakdownNormalizer`）。
- 保存: `company_breakdowns`（filing-sections とは別。LLM 行を filing バンプに巻き込まない）。主キー `doc_id#axis`。
- `not_found` は行を作らない。business の E/F/unknown は `not_applicable` プレースホルダ。REST と開発用 MCP は 404＋ボディ `reason`（200 化しない）。
- 公開 serving（REST `GET /v1/companies/{code}/breakdown`、開発用 MCP `get_breakdown`。iOS Breakdown の backing）は `needs_review=true` または `warnings` に `llm_unit_unresolved` がある **LLM 行を出さない**（千円表の 1000 倍誤り stopgap。fail closed）。残行が 0 なら未算出と同じ 404。payload 形は変えない。XBRL（`xbrl_facts` / `stacked_segment_pnl`）と `not_applicable`（'none'）、研究開発費の本文総額（`research_and_development_prose`）、設備投資の本文総額（`capex_prose`）はそのまま出す。`not_allocatable_to_segments` が付いていても 404 にしない。抽出・Neon 行・`cache_version` は触らない。`interest_bearing_debt` だけは、行が version-servable で公開除外の理由が `needs_review` だけのとき、未算出ではなく 404 reason `unknown`（「有利子負債の内訳は公開していません」。内部の保留理由 `needs_review` は公開しない）。他軸の公開除外は reason 無しの 404 のまま。
- 対象母集団: 全軸とも上場全体（日経225は処理順の先頭寄せのみ。2026-09 に employees / rd / goodwill および報告セグメント別指標軸も日経225限定を廃止して拡大）。read は Fly 専用（ingest 時に LLM 計算）。処理順は各社の最新有報 → 前年以降。同一年次内は日経225 → ローカル XBRL 展開済み → 欠測/要再試行/版ずれのラウンドロビン（軸ごとにキャッシュ集合を取り直す）。
- 売上分母・employees / rd の Summary 正本は breakdown 分母（ingest も同一 XBRL パスで直接解決）。
- 報告セグメント別指標の分母は通常 segment + reconciling（表の小計・EntityTotal は行として保持）。`capex` の各セル（`segment_assets` / `flow` / `capital_expenditures_overview`）の分母は、その指標の連結の無 dimension 総額タグ（EntityTotal）である。加算した segment+reconciling は 100% 分母にしない（項目タグ漏れがシェアに出るようにする）。5% 超ずれは `needs_review`。総額が無いときは Jev 本文総額（Role のみ、円はコード）、それも無ければそのセルの分母は null。`segment_assets` だけ、銀行の固定資産など連結 EntityTotal が無いとき segment + reconciling を残す。差額表 HTML の非分類行が既存 segment 行と同額のときは、その行だけ落とす（ラベル非依存）。
  XBRL タグ付き reconciling member（`ReconcilingItemsMember` 等）には適用しない。
- `capex` は名前付きセル。単一 `amount` は使わない。欠測セルは null。`flow` は書類単位で `capital_expenditures` があればそれ、無ければ `noncurrent_asset_additions`（混ぜず足さない）。Overview HTML 表は正本。HTML ラベルと XBRL member の結合は初期はしない。財務諸表計上額の `row_kind` は `EntityTotal`。Overview の表で一部の行だけタグが無いとき（6752「その他・全社」）は、未タグ行の和が総額 − タグ付き行に一致し、Jev が行の種別を reconciling / segment と分類したときだけその行を足す（`CapexOverviewUntaggedRowFill`。キーが無いときは足さない）。
- 設備投資の本文総額は `OPENROUTER_DECISION_API_KEY` があるときだけ別 Choice（`capex_prose`）。Jev は Role だけ、円はコード。埋めるのは Overview の会社総額と、タグ付きセグメント行があるときの reconciling だけ。セグメント別は埋めない。`SegmentNoteDecision` の表/省略 Choice には載せない。source `capex_prose` は公開面で研究開発費本文総額と同じ扱い。`cache_version` は `breakdown-capex-v1`。

## 有利子負債（`interest_bearing_debt`）

- 社債・借入金とリース負債を1軸にまとめる。`cache_version` は `breakdown-interest-bearing-debt-v2`（v1 は新軸。銀行行の追加は互換追加で据え置き。v2 はタクソノミ preset の追加・リース込み「有利子負債」集約・除外リスト・証券業の営業借入・千円注記・`source_tag` で行と合計が変わるため）。`source_kind` は `xbrl_facts`。公開 note_type としての `borrowings_schedule` / `lease_liabilities` は廃止した。軸の行 `source` 名（`borrowings_schedule` / `lease_note`）とパーサは残す。
- 行は名前付きセル `opening`（前期末）/ `closing`（当期末）。平均利率は持たない（`average_rate` は廃止。書類ごとに別表・注記にあり行と対応しないため）。行ごとに `source`（`balance_sheet` / `borrowings_schedule` / `lease_note` / `financials_bank_components`）と `maturity_class`（`current` / `non_current` / null）を持つ。末尾に `合計` 行（`row_kind` `subtotal`）。返済期限列は持たない。
- `source_tag`（nullable string）: その行の値を読んだ XBRL 要素の**ローカル名だけ**（名前空間・プレフィックス・URI は付けない）。
  - BS 行（`source=balance_sheet`）と銀行行は数値要素（例: `BorrowingsCLIFRS`、`ShortTermLoansPayable`）。US-GAAP の BS は HTML 表の行なので仮想名 `USGAAP_HTML_*`（提出要素ではない）。
  - 明細表・注記の行（`borrowings_schedule` / `lease_note`）は読んだ表の TextBlock 要素（例: `AnnexedConsolidatedDetailedScheduleOfBorrowingsTextBlock`、`NotesBondsAndBorrowingsConsolidatedFinancialStatementsIFRSTextBlock`、`NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock`）。Jev が行を分類した場合も、数字の出所なので TextBlock を出す。明細表を直接タグ（`ShortTermDebtCLIFRS` 等が3つ揃う三井物産型）から作った行はその数値要素。
  - 会社拡張要素は提出どおりのローカル名（例: ニデック `LongTermDebtDueWithinOneYearCLIFRS`、ソニー `LongTermDebt2NCLIFRS`）。**提出者固有で、会社間で比較・集計できない**。
  - `合計` 行とコードで足した値は null（作った名前は入れない）。
- 行ごとの合計フラグ（明細行のみ。`合計` 行は 3 つとも null）:
  - `in_total`（bool）: 合計に数える行か。BS と明細表・注記の両方の値を行として残し、数える方だけ true にする。
  - `excluded_reason`: `in_total=false` の行は必ず次の 4 値のどれか、`in_total=true` の行は必ず null。自由文・unknown は無い。コードが理由を決められない除外行が出たら軸全体を `needs_review` にする。
    - `duplicate_of_balance_sheet`: BS 行と同じ負債（同額、または明細表に当期末値が無い前期だけの行）。
    - `scope_differs`: BS 行と同じ科目だが金額の範囲が違う（例: 明細表の長期借入金が1年内返済分を含む、明細表のリースが BS のリース債務と範囲違い）。BS 側を数える。
    - `non_interest_bearing`: 明細表に載るが利息の付かない預り（「受入保証金」「預り保証金」はラベルでコードが確定。Jev は他の曖昧ラベルだけに 0.9 以上で使う）。
    - `other_table`: 別の表（IFRS リース注記等）の同じ負債で、採用した行と重なる。
  - `paired_row_index`: 除外行が対応する `in_total=true` 行の、この payload の `rows` 配列内の添字（0 始まり）。対応先が1行に決まらないときは null。新しい ID は作らない。
  - 不変条件: `合計.closing == Σ(in_total=true の closing)`（完全一致）。カバレッジと /financials はこの和だけを使う。**クライアントは全行を足してはいけない**（除外行を含めると二重計上になる）。
- BS 行の分類順（コードだけ。キーワード規則より前に明示リストを見る。リストは `Xbrl.swift` の有利子負債タグ群の隣）:
  1. 明示除外 `Xbrl.ibdNonInterestBearingBSTags`（預り敷金・保証金、受入敷金保証金、賃貸料等前受金、リース資産減損勘定、有価証券貸借取引受入金・借入有価証券、代理店債務）→ `in_total=false` / `non_interest_bearing` の行として残す。
  2. 証券業の営業上の借入 `Xbrl.ibdSecuritiesBusinessBorrowingTags`（信用取引借入金 `BorrowingsOnMarginTransactionsCLSEC`・有価証券担保借入金 `LoansPayableSecuredBySecuritiesCLSEC`・現先取引借入金 `BorrowingsOnGensakiTransactionCLSEC`）→ 合計に入れず `in_total=false` / `scope_differs`。**定義: 有利子負債は事業会社の資金調達（社債・借入金・CP・リース）で、証券会社が顧客取引・トレーディングのために負う信用取引・有価証券担保・現先の借入は範囲が違う**（利息は付くが、営業資産と対で増減する）。新しい enum 値は作らず `scope_differs` を使う。明細表の同名行（「信用取引借入金（１年内返済予定）」等）と会社拡張要素のラベルも同じ扱い（大和証券グループ 8601）。
  3. 既知の債務タグ（`ibdCurrentComponents` / `ibdNonCurrentComponents` / `ibdLiquidityOrderComponents` / IFRS 集約。転換社債・新株予約権付社債・関係会社や株主等からの借入・リース会社の債権流動化に伴う支払債務（名前に Lease があっても債務）・流動性配列の IFRS / 保険の借入金を含む）→ 債務。
  4. 既知のリース（`leaseLiabilitiesBSTags`。流動性配列の `LeaseLiabilitiesLiabilitiesIFRS` / `LeaseObligationsLiabilities` を含む）→ リース。
  5. キーワードだけ当たる行: 標準タクソノミの要素なら Jev。会社拡張要素なら明細表と同じラベル規則（借入金・借入債務・社債・CP・借用金・有利子負債・長期債務・短期債務 → 債務、リース → リース、敷金・受入/預り保証金 → 非有利子。債務の語とリースの両方を含む「社債、借入金及びリース負債」は債務）。決まらなければ Jev（0.9）。会社拡張要素を一覧に手で足すことはしない。
- リース込みの債務科目: 「社債、借入金及びリース負債」等の合算タグ・ラベル、または **BS に別建てのリース科目が無いときの「有利子負債」集約（`InterestBearingLiabilities*IFRS`）** はリースを含むとみなす（BS の形だけで決める。注記の文言は見ない）。注記・明細表のリースを分母にも合計にも足さない。明細表（債務＋リース行）が集約の流動／非流動の和と一致するときは集約を親にして数え、明細表の行は `duplicate_of_balance_sheet` の内訳にする（トヨタ 7203 43,205,469、RIZAP 2928 63,674、HOYA 7741 42,241）。親はリース込み集約と、ラベル規則で債務に確定した区分つきの会社拡張 BS 科目（AGC 5201 の `LongTermInterestBearingDebtDueWithinOneYearCLIFRS`「1年内返済予定の長期有利子負債」は流動の親の1つ）。流動の内訳は流動の親だけ、非流動の内訳は流動以外の親だけ、区分が null の内訳はどの親にも入り得る。各親の closing が内訳の和と一致する割り当てがただ1つのときだけ入れ子にする（区分の無い行に区分を作らない。ブロードリーフ 3673 の素の「リース負債」は maturity null のまま流動の親に入る）。期末値の無い内訳は入り得る親が1つならそこ、複数なら対応先なし。BS に未分類行があるときは明細表の行を数える。集約を親にできる形なのに一致する割り当てが無い・複数ある・探索の上限（20万節点）を超えたときも明細表の行を数えるが、黙って戻さず `needs_review` と `interest_bearing_debt_nesting_parent_unresolved`、監査 `nesting_lease_inclusive_aggregate_unresolved <理由>` を残す（LINEヤフー 4689 の単一集約 `InterestBearingLiabilitiesLiabilitiesIFRS` は、明細表の「その他」が分類されれば入れ子、デサイダ無しでは未分類で `needs_review`）。旧 `IBDExtractor` も同じ規則でリース注記を足さない。
- IFRS 有利子負債注記の金額単位は表内の単位、無ければ表の直前の見出し（「（単位：千円）」）を見る（夢展望 3185・東静 8923・ブロードリーフ 3673 は千円）。
- BS を基準にした行の選び方（金額はすべてコードが決める。Jev は分類と候補の同一性判断だけ）:
  - 入れ子（多対一）: BS の借入金・CP 科目が明細表の行の親になるときは BS 行を数え（`in_total=true`）、明細表の行はその内訳の参照行（`in_total=false`）にする。内訳の金額が親と一致すれば `duplicate_of_balance_sheet`、一致しなければ `scope_differs`。不一致だけでは `needs_review` にしない（差は監査 `llm_audit` の `nesting_gap parent=… balance_sheet=… components=… gap=…` だけに残し、公開フィールドにしない）。例: シスメックス 6869 の BS 長期借入金 31,646 が親で、明細表 32,359（1年内分込み）は `scope_differs`。
  - 入れ子の表示は product_service と同じ `category_group`（親 = BS 科目のラベル）/ `category`（内訳のラベル）。親行は `category_group` = 自分のラベル・`category` = null、内訳行は `category_group` = 親のラベル・`category` = 自分のラベル・`paired_row_index` = 親の添字。入れ子が無い行にはこの2キーを出さない。新しいフィールドは足さない。`category_group` は親のラベルなので、流動と非流動の親が同じラベル（IFRS の「借入金」等）だと `category_group` で集計すると両方の内訳が1つにまとまる。正確な親は `paired_row_index` で引くこと。
  - 親の決め方（コードだけ。BS 科目はタグで、明細表行はラベルで区分する）: 短期借入金 → BS 短期借入金、無ければ IFRS の流動「借入金」（`BorrowingsCLIFRS`）。1年内返済の長期借入金 → BS の1年内返済科目、無ければ流動「借入金」、無ければ BS 短期借入金（BS 短期借入金に1年内返済分を含める会社。ラベルで含むと明示する例: ニッスイ 1332「短期借入金(１年以内に返済予定の長期借入金)」）。ただし BS 短期借入金が明細表の短期借入金だけと一致し1年内分に当期末値があるときは含めていないので入れ子にしない。長期借入金 → BS 長期借入金。CP → BS の CP、BS に CP 科目が無ければ流動の借入金科目1行に含めるとその科目の内訳と一致するときだけ（不二製油 2607）。BS の CP 等と同額で、どの区分にも入らない明細表行（J-GAAP 明細表の「その他有利子負債」に CP を載せる会社。王子 3861）も同じ負債の内訳。
  - 逆向き: 明細表の1行が BS の複数科目に跨る（「借入金」、「長期借入金（１年内返済予定の長期借入金を含む）」）ときは BS の借入金各科目を数え、明細表行は BS 各科目の和と比べて理由を付け、親を1行に決められないので `paired_row_index` と `category_group` は付けない（エムスリー 2413、367A）。
  - `needs_review` になるのは、全体の coverage が帯（95〜105%）を外れたときと、親の候補が2行以上あって決められないとき（`interest_bearing_debt_nesting_parent_unresolved`）だけ。
  - BS の合算科目（社債及び借入金、社債、借入金及びリース負債 等）は親にしない（明細表の内訳をそのまま数える。三菱電機 6503、JFE 5411）。BS に科目の無い区分の明細表行はそのまま数える。
  - BS にあって明細表に当期末値が無い短期借入金・CP は BS 行を数える（B6。対象は CP・短期借入金・リースの3種だけ。例: 8570 の CP 5,932 百万円、4186 の短期借入金 383 百万円、2798 の短期借入金 49.816 百万円）。
  - リースは BS のリース科目があれば BS を数える（明細表・注記のリースは除外行。BS に該当の流動/非流動区分が無いときだけ明細表の行を数える）。除外するリース行は、まず BS リース科目1行と同額か見て、同額なら `duplicate_of_balance_sheet` でその行を `paired_row_index` にする。残りは BS リース科目の和（同額で対応した行を除く）と比べる。BS にリース科目が無ければ明細表、明細表にも無ければ IFRS リース注記。
  - 担保に供している資産の「対応する債務」表は借入金の表として読まない（すかいらーく 3197、豊田合成 7282）。IFRS 社債及び借入金注記の「合計」の後の「（その他の金融負債）」区分のリース負債は、明細表にリース行が無いときだけ拾う（すかいらーく）。
  - IFRS リース注記で、使用権資産の表（取得原価・減価償却累計額・帳簿価額）の「帳簿価額」はリース負債に使わない。帳簿価額・将来リース料の列レイアウトの表から当期・前期の帳簿価額を取る（日機装 6376）。
- 読む書類はコードが選ぶ: 連結貸借対照表、連結の借入金等明細表、IFRS のリース負債注記。連結財務諸表がある会社は連結だけ、個別だけの会社は個別だけを読む（`BorrowingsSchedule.filerHasConsolidatedStatements`。DEI `WhetherConsolidatedFinancialStatementsArePreparedDEI` で判定。DEI が無いときは連結 BS の TextBlock があるときだけ連結扱い。連結・個別コンテキストの共存だけでは連結扱いにしない）。
- Jev（`OPENROUTER_DECISION_API_KEY`、Choice、確率 0.9 以上）は、コードが決められない行（会社独自タグ、デリバティブ等の明細表行）が有利子負債か・リースか・どちらでもないかだけを答える。金額は触らない。0.9 未満・キー無しは決定論のまま `needs_review`。応答が無いときは行を作らず再試行する。
- 重複除去はコードが先。明細表のリース行とリース注記が 2% 以内で一致しないときだけ、Jev が同一負債かを答える。両方の金額と理由を `llm_audit` に残す。黙って片方を選ばない。2% を超えて食い違うときは明細表側を残し `interest_bearing_debt_lease_sources_differ` と `needs_review`。
- 明細表の区分: 値の無い区分見出し行（「流動負債」「非流動負債」等）の下の行は、ラベルに区分が無くても `maturity_class` をその区分にする。区分ごとに「合計」を置く表（東静 8923）は、後ろに別区分の見出しがある「合計」を区分小計として読む。表の合計は内訳行の和と照合して決める: 区分小計の和、区分の直後の真の合計行、最後の区分の「合計」（流動の小計の後に全体の累計合計を置く表）の順に、内訳の和と端数以内で一致するもの。どれも一致しなければ内訳の和（累計型で流動分を二重に数えない）。リース行の `label` は区分の印（1年以内・短期・流動／非流動・長期・1年超・除く）か区分見出しがあるときだけ「リース負債（流動）／（非流動）」に正規化し、分からなければ開示どおりのラベル（`label_raw` と同じ）にする。借入金等明細表の注記（`borrowings_schedule`）の `label` も同じ（三菱UFJ・三井住友FGの「リース債務」は以前「リース負債（非流動）」と出ていた）。
- 分母は同じ財務諸表の貸借対照表の有利子負債＋リース負債。分母に入れるのはコードが分類した BS 行だけ（`presetClass`）。Jev が債務と答えた BS 行は行には残すが分母には入れない（coverage の自己参照を避ける）。行の合計が 95〜105% を外れたら `needs_review`（Jev は覆せない）。明細表が帯を外れ貸借対照表の行がすべて分類済みなら、貸借対照表の行を使い `borrowings_schedule_outside_coverage_band` を残す（例: ソフトバンクグループの明細表はセール・アンド・リースバック負債の表で、全体の約 6%）。BS にリース科目が無く、リース込み合算でもないとき、分母のリース部分はリース注記または明細表から足す。そのときは `interest_bearing_debt_lease_denominator_from_notes` を残す（`needs_review` にはしない。分母の一部が行の出所と同じで、coverage が完全な外部検算にならないため）。
- 合計行の `opening` は、明細行の期首が1つでも null なら null（部分合計はしない）。`closing` は従来どおり合計する。
- `maturity_class` は書類の表示だけから取る: 貸借対照表の流動/非流動タグ、注記の流動/非流動の区分、明細表のラベル（「1年以内に返済予定の…」「（1年以内に返済予定のものを除く。）」）。「除く」は「1年以内/1年内 … 除く」のときだけ非流動（「長期借入金（ノンリコース債務を除く）」は null）。日付や金額からは推定しない。曖昧なら null（例: 「長期借入金」「社債」だけの行）。行を流動・非流動に分けても合計とカバレッジは変わらない（同じ負債を二重に数えない）。
- 銀行（statement Instant FieldSet に `DepositsLiabilitiesBNK` の当期または前期がある、または EDINET コードリストの提出者業種が銀行業。後者は DEI `EDINETCodeDEI` から master を引く）は通常の BS / 明細表パイプラインに入れず、`Xbrl.bankIBDComponents`（CP・借用金・短期社債・社債・債券に加え、銀行子会社を持つ持株会社が BS に載せる一般事業会社の借入金・社債タグ。各タグは1コンポーネントだけ。リース債務・合算タグは除く）を1行ずつ出す。預金・譲渡性預金は銀行でも有利子負債に含めない（2026-10-11 決定。預金は銀行判定マーカーとしてだけ使う）。`source` は `financials_bank_components`。`maturity_class` はコンポーネントのラベルだけから取る（短期社債は `current`。社債・借用金は null）。statement にリース科目が無ければ notes のリース行を足す（出所は `borrowings_schedule` または `lease_note` のまま。J-GAAP リース注記の貸手側の表（リース料債権・リース投資資産、または「貸手」見出しの区分の表）は読まない）。分母はコンポーネント合計そのもの（`bank_components`。銀行には独立した coverage 検算が無い。コンポーネントが1つも無ければ `not_found` で、/financials は旧 Extractor の `bank_components` を使う。値は 0 円に notes のリースだけを足したもの。例: スルガ銀行 S100YCW1 15 百万円、豊和銀行 S100YF85 118 百万円）。保険は通常パイプライン（除外しない）。
- 公開 serving では、この軸だけ `needs_review=true` を出さない（source が `xbrl_facts` でも fail closed）。行が version-servable で公開除外の理由が `needs_review` だけのときは、未算出ではなく 404 reason `unknown`（メッセージ「有利子負債の内訳は公開していません」。公開 reason は single_segment_disclosed / geography_only / not_found / unknown の 4 種に固定し、needs_review などの内部理由は監査にだけ残す）。REST と MCP の両方。他軸の公開除外は reason 無しの 404 のまま。
- 再計算: この軸は source `xbrl_facts`（version-gated）。現行版でも再試行するのは、Jev が分類（`interest_bearing_debt_row_unclassified`）または近似重複（`interest_bearing_debt_near_duplicate_unresolved`）で止まった `needs_review` だけ。coverage 帯外だけの行は再試行しない。再試行は初回の後 3 回まで（`ibdJevRetryMaxAttempts`。回数は `llm_audit.jev.sentences` の `jev_retry_attempt=N`。列もキーも増やさない）。上限に達した行は通常の ingest では再試行しない（版を上げる・行を消す・`--doc-ids` で指定する）。`--doc-ids` は上限・`needs_review` に関係なくその書類を書き直し、保存する監査には回数を付けないので、回数は 0 に戻る。
- J-GAAP の借入金等明細表は社債を含まない（社債明細表は別）。明細表主で明細表に社債行が無いときは、BS の社債単独行（「社債及び借入金」等の合算行は除く）を `source=balance_sheet` のまま足す。
- /financials の `interest_bearing_debt` はこの軸の合計行（decider 無し。銀行は `financials_bank_components` 行）。軸が `needs_review`・`unavailable`・`not_found` のときは旧 `IBDExtractor`（BS 項目タグ合算）へフォールバックし、既存の `IBDExtractor.extractCanonical` をそのまま使う（新しい推定は足さない）。印は内部の method `legacy_ibd_extractor_fallback` と warnings だけで、/financials の公開フィールドは増やさない（例: ソニーは v1 では会社拡張の 長期借入債務 824,393 百万円 が Jev 待ちで 845,276 百万円 のままだった。v2 ではラベル規則で確定し 1,669,669 百万円）。無借金（大きなインスタンス文書に IBD タグが皆無）の 0 は旧 Extractor 自身の `zero_debt` をそのまま使い、印は付けない（軸の `not_found` だけで 0 にはしない。軸は会社独自タグ等を拾わないため）。`fin-vN` は上げない（組立指紋にこの軸の `cache_version` を足して再組立する）。銀行は `interest_bearing_debt` を出すが、それを使う比率（`net_cash` / `net_de` / `roic` / `nopat_margin` / `invested_capital_turnover`、Waterfall の `net_cash_change` / `debt_change_impact`、Screen の `roic` / `net_de` / `roic_cagr_3y`）は null（2026-10-12）。
- 対象外: 返済期限列、注記タイプの削除。

互換追加: 銀行行（`financials_bank_components`）と /financials の正本切替。`schema_version` / `cache_version` は据え置き。

v2（`breakdown-interest-bearing-debt-v2`）: 行と合計が変わる変更（上記の preset・除外・リース込み集約・単位・`source_tag`）。`/financials` は組立指紋にこの `cache_version` が入るので再組立される。`fin-vN` は上げない（`blt-cache-version-policy`: 既存行の読み出しは壊れず、軸の版で再計算対象が決まるため）。

## 変更履歴

- 2026-10: 軸 `interest_bearing_debt` を追加（`average_rate` は公開前に廃止し、`in_total` / `excluded_reason` / `paired_row_index` を追加。未公開の軸なので `cache_version` は v1 のまま）（互換追加。`schema_version` / `apiSkillsSchemaVersion` は据え置き）。/financials `interest_bearing_debt` の正本をこの軸へ（`fin-vN` は上げず組立指紋で再組立）。

## 非目標

過去セグメント遡及組替、会社間ラベル統一、全期の事業×地域完全充足、生 XBRL 一発 LLM 抽出。
