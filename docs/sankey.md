# Sankey

## 責務

サーバーは軸ごとの分解済み数値を JSON で返す。ノード・リンク・左右配置・色・描画は
クライアント責務とする。Blue Ticker は Sankey のレイアウトを規定しない。
サーバーは開示にない軸間配賦を推計しない。

方針の正本は本ファイル。着手順と現在地は Linear Team `blue-ticker`。公開 REST 契約ではない。

## 材料契約

smoke の言語非依存プロトタイプは `smoke/sankey_prototype_expected.json`（`schema_version: 2`）。
公開 REST 契約ではなく、次の境界を固定する。

| 区分 | 役割 |
|---|---|
| `metric` | 分母となる指標（例: `sales` / `total_assets`） |
| `dimensions` | 同じ合計への独立 marginal（例: geography / business） |
| `bridges` | 会計基準別のカスケード（例: `profit_and_loss`）。**dimension ではない** |
| `drilldowns` | 分母が異なる分解。親ノードへ付ける（例: 販管費の下の R&D） |

- 欠測軸は `available=false` または省略。空配列でゼロ構成を装わない。
- `row_kind` の `segment` + `reconciling` を合計対象とし、subtotal は合計しない。
- 開示済み消去・全社は `reconciling`。丸め・未分類は明示 residual。
- `tag` は実際の XBRL タグを解決できる値にだけ載せる。プレースホルダーは作らない。
- `cross_axis_links_available` は開示交差表がない限り `false`。geography×business リンクは生成しない。
- JSON に `left_axis` / `right_axis` / `default_layout` や色役割は載せない。

Sales の PL は bridge。J-GAAP 事業会社と IFRS/US-GAAP でトポロジが異なる。
キヤノン（7751、S100XTLJ）は US-GAAP のため経常利益・特別損益を発明しない。
各 bridge stage は `conserved_total` へ一致し、説明不能な残差が 5% 超なら `needs_review`。

研究開発費は売上 dimension ではない。親は statement の置き場で分岐する（販管費の内数、または別掲なら Waterfall 事業利益の次）。欠測は販管費を葉のまま。費目内訳と接続の進捗は Linear Team `blue-ticker`。詳細は「階層カタログ」。

## 階層カタログ

Sankey に出す項目の親子と深さ上限。クライアントは同じ材料を左右どちらに置いてもよい。
サーバーはここに無い交差（地域×事業、売上→同セグメント投資など）を作らない。

深さは **ハブからのホップ数**。L0 が metric。同じ L の dimension 同士は独立で、入れ子にしない。

| 深さ | 意味 | 例 |
|---|---|---|
| L0 | metric ハブ | 売上高 / 総資産 / 営業CF |
| L1 | 同じ合計の独立 dimension、または bridge の最初の分岐 | 事業別・地域別 / 流動・非流動 / 売上原価・売上総利益 |
| L2 | bridge の次段、または L1 科目の内訳 | 販管費・営業利益 / 現金・売上債権 |
| L3 | 科目にぶら下がる drilldown（分母が親と異なることがある） | 販管費の下の研究開発費 / PPE の種類別 |
| L4 | drilldown の行 | R&D の報告セグメント / 借入金の科目 |

上限は **L4**。L5（セグメントの中の地域、種類の中のセグメント）は開示交差表があるときだけ。初期は作らない。

### 研究開発費の置き場は statement で分岐する

breakdown `research_and_development` の正本は発生支出（financials の rd と同じ。開発資産への振替前であることがある）。
売上ハブの dimension にも、投資ハブの配賦先にもしない。

**判定は statement の損益計算書だけ。** 研究開発費のタグが販管費合計の `components` に入っている → 販管費から分解。販管費（または販売費・一般管理費）と**兄弟**の独立行 → Waterfall の事業利益の次に分解。PL に行が無い（欠測）→ 販管費は葉のまま。開示の「事業利益」行（味の素 `BusinessProfitLossIFRS` 等）は探さない。

```text
売上総利益
├─ 販売費及び一般管理費          ← Waterfall の sga（別掲 R&D を含めない）
│  └─ [内数のとき] 研究開発費 → セグメント
└─ 事業利益                      ← Blue Ticker: GP − 販管費。開示行ではない
   ├─ [別掲のとき] 研究開発費 → セグメント
   ├─ その他（持分法、その他営業など）
   └─ 営業利益
```

| 判定 | statement 上の根拠 | R&D の親 | smoke |
|---|---|---|---|
| 内数 | 販管費合計の `components` に `ResearchAndDevelopmentExpensesSGA` 等 | 販管費 | ニチレイ |
| 欠測 | PL に R&D 行が無い | 販管費は葉。費目内訳の公開と、それを販管費の子にする接続は Linear Team `blue-ticker`（費目内訳の後） | オークマ、クボタ、スズキ、AZ、東邦レマック |
| 別掲 | 販管費（または販売費・一般管理費）と兄弟 | 事業利益（Waterfall）の次 | 味の素、キヤノン、富士フイルム |

銀行（MUFG / SMFG）は商業 PL を当てない。R&D は欠測。

味の素の開示 `BusinessProfitLossIFRS` 159,302m は使わない。Waterfall 事業利益は 550,764 − 366,854 ＝ 183,910m。差は主に R&D と持分法で、開示とは一致しない。

保存:

- 内数: `PL の R&D + その他販管費 == 開示販管費`
- 別掲: 開示販管費から R&D を引かない。`1,367,277 − 339,288` をその他販管費にしない
- 欠測: breakdown / financials の rd（`ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities`）は**発生支出**。製造費用（オークマ 4,265 のうち販管費費目は 2,097）や開発資産への振替（スズキ FY2025 は 265,571 → 販管費内 241,018）を含む。これを販管費から引いて残差を作らない。子にする額は `sga_expense_breakdown` の販管費費目（今は葉）
- `sum(R&D の segment＋reconciling＋residual) == breakdown 分母`（発生支出側。販管費の子の分母とは別）
- R&D 欠測は空の内訳で埋めない
- 地域別 R&D は通常非開示。推計しない

材料: PL の販管費と独立 R&D 行は statement `income_statement`。セグメント内訳は breakdown `research_and_development`（発生支出。financials の rd と同じ）。欠測社の販管費費目は note_type `sga_expense_breakdown`（構造化 `*SGA` / IFRS 販管費注記タグ。発生支出軸は流用しない。**未公開**。進捗は Linear Team `blue-ticker`）。

### 連結損益計算書（metric `sales`）

PL は dimension ではなく `bridges.profit_and_loss`。L1 の稼得 dimension とハブで接続するだけ。

#### L1 稼得 dimension（分母＝連結外部売上）

| id | 内容 | 深さ | 材料 |
|---|---|---|---|
| `business` | 稼得の主軸。報告セグメントを優先 | L1 で打ち切り | breakdown `business` |
| `geography` | 地域別 | L1 で打ち切り | breakdown `geography` |

製品・サービス別は **別 dimension にしない**。報告セグメントと同じ L1 スロット（売上の切り口が事業か品目か）。現行 REST `axis=business` が報告セグメント表と製品表を混在して取りうるのは抽出の話で、Sankey では同じハブへ二重に並べない。

- 報告セグメントが取れる → それだけを `business` にする
- 報告セグメントが無く製品表だけ（オークマ等） → 同じ `business` として出す
- 両方あり中身が違う（クボタ） → 二本出す。ラベルで切り口を区別する。永続軸の分割は実装時

交差表が無い限り L2 のマトリクスは無い。欠測軸は出さない。銀行は分母が粗利益等なら Sales ハブへ繋げない。

#### L1–L4 費用・利益カスケード（J-GAAP 事業会社）

```text
L0 売上高
├─ L1 売上原価
└─ L1 売上総利益
   ├─ L2 販売費及び一般管理費
   │  └─ [内数のとき] L3 研究開発費 → L4 セグメント
   └─ L2 事業利益                    ← Waterfall: GP − 販管費。開示行は探さない
      ├─ [別掲のとき] L3 研究開発費 → L4 セグメント
      ├─ L3 その他（無ければこの段は営業利益と同一）
      └─ L2 営業利益                 ← statement の営業利益
         ├─ L3 営業外損益
         └─ L3 経常利益
            ├─ L4 特別損益
            └─ L4 税引前利益
               ├─ L4 法人税等
               ├─ L4 非支配持分・帰属差
               └─ L4 親会社帰属当期純利益
                  └─ L4 当期包括利益（SS にあれば。無ければこの段は省略）
                     ├─ 株主還元
                     │  ├─ 配当（SS）
                     │  └─ 自己株式取得（SS）
                     └─ 留保・その他（残差。還元が包括利益を超えるなら負）
```

税引前以降はホップを増やさず L4 に畳む。当期純利益は親会社帰属（`ProfitLossAttributableToOwnersOfParent*`）。連結合計の純利益と非支配持分を親会社帰属へ足して二重計上しない。

#### 事業利益は Waterfall の派生値

開示行は探さない。`business_profit = 売上総利益 − 販管費`（販管費が無ければ `GP − OP` で販管費を埋めてから引く）。味の素の `BusinessProfitLossIFRS`（159,302m）はこれではない。

| 例 | 営業利益 | Waterfall 事業利益 | R&D の置き場 |
|---|---|---|---|
| オークマ S100YFQC | 15,505m | ＝営業利益（1m 丸め） | 販管費は葉。注記合計 4,265m は製造費用込み。費目 2,097m は接続待ち（Linear Team `blue-ticker`） |
| ニチレイ | GP − 販管費合計 | ＝営業利益 | 販管費（`ResearchAndDevelopmentExpensesSGA` が販管費の内訳） |
| 味の素 S100VXJA | 113,968m | 550,764 − 366,854 ＝ 183,910m | 事業利益の次。開示事業利益 159,302m とは一致しない |
| キヤノン | 455,390m | 2,161,955 − 1,367,277 ＝ 794,678m | 事業利益の次（別掲 339,288m） |
| 富士フイルム | 350,210m | GP − 販管費。R&D 157,790m は販管費に入っていない | 事業利益の次 |

金融機関は Waterfall が経常収益−販管費（ラベルが経常利益/事業利益のとき）。IFRS 金融の PL 行「事業利益」（`BusinessProfitIFRS*`）は statement OP のフォールバックであり、ここでも使わない。

#### IFRS / US-GAAP

経常利益・特別損益を作らない。別掲 R&D は事業利益の次。内数は販管費の子。欠測は販管費を葉。費目内訳と接続の進捗は Linear Team `blue-ticker`。営業利益から金融損益・持分法（税引前の後に来る会社もある）・その他を経由して税引前へ。

味の素（S100VXJA）の Waterfall カスケード:

```text
売上総利益 550,764
├─ 販売費 211,976
├─ 一般管理費 154,878
└─ 事業利益 183,910          ← GP − (販売費＋一般管理費)。開示行ではない
   ├─ 研究開発費 30,921
   ├─ 持分法 +6,314
   ├─ その他営業収益 4,936
   ├─ その他営業費用 50,269
   └─ 営業利益 113,968
```

クボタ・スズキは PL に R&D 行が無く販管費合計だけ。`GP − 販管費 → その他営業 → 営業利益` は保存する。R&D を販管費の子にする接続は Linear Team `blue-ticker`（スズキ S100YFG2 の販管費内は振替後 271,082m）。breakdown の発生支出（同 270,400m、クボタ 110,300m）で残差を作らない。

#### 銀行

商業会社の売上原価・粗利益・販管費ツリーを当てない。経常収益 / 業務粗利益 / 経常利益 / 特別 / 税引前。
R&D 内訳は通常欠測。

#### 営業利益の事業別・地域別

事業別利益は breakdown `business` の `profit`（消去は `reconciling`）。地域別利益は
キヤノン smoke では非開示のため 3 軸化しない。開示がある会社だけ L1 の別 dimension
（分母＝営業利益）。販管費の子にはしない。

### 貸借対照表（metric `total_assets`）

2 つの L1 dimension。同じ総資産へ一致させる。交差配賦はしない。

```text
資産構成 ── 総資産ハブ ── 調達構成
```

#### 資産構成

```text
L0 総資産
├─ L1 流動資産
│  ├─ L2 現金・預金
│  ├─ L2 売上債権
│  ├─ L2 棚卸資産
│  └─ L2 その他流動資産
└─ L1 非流動資産
   ├─ L2 有形固定資産
   │  └─ L3 種類別（notes `property_plant_equipment_schedule`）。US-GAAP / 区分が statement にある J-GAAP は L2 で打ち切り
   ├─ L2 使用権資産
   ├─ L2 のれん・無形資産
   │  ├─ L3 種類別（notes `goodwill_and_intangibles`、IFRS 連結）
   │  └─ L3 セグメント別残高（breakdown `goodwill`）。種類別と混ぜない
   ├─ L2 投資・持分法投資
   │  ├─ L3 政策保有株式の銘柄（notes `policy_holding_securities`）
   │  └─ L3 持分法投資のセグメント（breakdown `equity_method_investments`）
   └─ L2 その他非流動資産
```

#### 調達構成

```text
L0 総資産
├─ L1 流動負債
│  ├─ L2 仕入債務
│  ├─ L2 有利子負債（流動）          ← IBD 葉の合算。下表
│  │  ├─ L3 短期借入 / CP / 1年内返済
│  │  └─ L3 リース負債（流動）
│  └─ L2 その他流動負債
├─ L1 非流動負債
│  ├─ L2 有利子負債（非流動）
│  │  ├─ L3 社債 / 長期借入
│  │  └─ L3 リース負債（非流動）
│  └─ L2 その他非流動負債
└─ L1 純資産
   ├─ L2 資本金・資本剰余金 → L3 notes `issued_shares_and_capital`
   ├─ L2 利益剰余金
   ├─ L2 OCI 等
   ├─ L2 自己株式（符号を保つ）
   └─ L2 非支配持分
```

L2 科目は statement `balance_sheet` の `section` / `is_total` / `components`。
計算リンクの components が無い行は L1 で打ち切り。

#### 有利子負債の LX 合算

可能。BS 上は流動/非流動に分かれた葉（短期借入・社債・リース等）のまま置き、一番深い層の IBD 葉を **derived 親「有利子負債」** にまとめる。値は `IBDExtractor.extractCanonical` と同じ（項目タグの合算。notes 合計行で置き換えない）。

```text
有利子負債（derived）
├─ 流動分（短期借入・CP・1年内返済・流動リース…）
└─ 非流動分（社債・長期借入・非流動リース…）
```

葉は調達構成の L2/L3 に残す。合算親はグループであり、BS に無い科目を発明しない。

| 規則 | 内容 |
|---|---|
| 足すもの | statement にある IBD 項目（内訳でも「社債及び借入金」のような集約でも、BS の粒度） |
| 足してよい notes | statement に無い項目だけ（典型はリース帳簿。`borrowings_schedule` 区分 / `lease_liabilities`） |
| 足さない | notes の内訳を statement 項目の上に重ねる、notes 合計行で IBD 全体を置換、金融負債そのもの（味の素: その他の金融負債 ≠ リース） |
| 保存 | `sum(IBD 葉) == extractCanonical.total`。5% 超は `needs_review` |
| 銀行 | `bankIBDComponents`（預金・借用金等）。商業会社の借入/社債ツリーを当てない |

`borrowings_schedule` の科目別は、statement 葉が粗いときの L3 drilldown。合計の第二の源にはしない。

#### BS に付けない drilldown

| 材料 | 付け先 | 理由 |
|---|---|---|
| breakdown `segment_assets` | 総資産ハブの独立 drilldown（分母は segment＋reconciling） | 資産構成の子にすると流動/非流動と交差する |
| breakdown `noncurrent_asset_additions` | 投資ハブ側。期末残高ツリーに混ぜない | フローでありストックではない |
| 地域別非流動資産 | metric を `noncurrent_assets` に切り替える | 総資産 dimension へ混ぜない |

### キャッシュ・フローと投資ハブ

R&D はここに置かない（置き場は連結 PL。投資ハブの配賦先にしない）。Capex と株主還元を売上 PL に足さない。

```text
L0 営業CF（初期 metric）
├─ L1 設備投資
│  └─ L2 セグメント（breakdown `capital_expenditures` または `capital_expenditures_overview`。値は軸で異なり得る）
├─ L1 配当（notes `dividends` / SS）
├─ L1 自己株式取得
├─ L1 借金の増減
└─ L1 現金増減（残差を明示）
```

設備投資のセグメントは L2 まで。地域別 capex は通常非開示。
R&D 費用と capex 内の研究設備は足さない・相殺しない。

### 株主資本等変動（SS）

PL 末尾（親会社帰属純利益 → 包括利益 → 還元）とは別ハブ。期末資本の保存はこちら。還元は同じ SS 行を両方から参照してよいが、一つの図に混ぜない。

```text
L0 期首資本 + 当期包括利益（無ければ親会社帰属純利益）
├─ L1 期末資本
├─ L1 配当（SS）
├─ L1 自己株式取得（SS）
└─ L1 その他（資本取引・NCI・丸め。残差を明示）
```

当期包括利益は SS の `ComprehensiveIncome*`（トヨタ S100VWVY の `ComprehensiveIncomeIFRS` 等）。無ければこの段を省略し、親会社帰属純利益の次を株主還元にする。OCI 内訳（為替・年金等）は初期は切らない。

還元が包括利益を超えるのは正当（味の素: 配当 39,119m ＋自社株 90,695m ＞ 純利益 70,272m）。残差は負＝期首資本からの取り崩し。1株情報（notes `per_share_information`）は Sankey に出さない。

### 報告セグメント指標（PL/BS ツリーの外）

分母が売上でも総資産でもない。親ノードへ黙って接続しない。独立 drilldown。深さは L1（全社）→ L2（セグメント）のみ。

| axis | 内容 |
|---|---|
| `employees` | 従業員数 |
| `depreciation_and_amortization` | 減価償却費及び償却費 |
| `goodwill_amortization` | のれん償却 |
| `impairment_loss` | 減損損失 |
| `capital_expenditures` | 報告セグメント表の capex |
| `capital_expenditures_overview` | 設備投資等の概要の capex |
| `noncurrent_asset_additions` | 非流動資産への追加 |

`employees` / `rd` / `goodwill` と上表は日経225。business / geography と segment_assets は上場全体。

### 初期にやらない深さ

- geography × business、セグメント売上 → 同セグメント R&D / capex の逐次リンク
- 販管費の人件費・減価償却など、開示内訳が statement components に無い科目
- 原価の中の材料費・労務費（通常非開示）
- R&D の地域別、製品別
- のれんの種類別とセグメント別の掛け合わせ
- 銀行への商業会社ツリーの当てはめ
- IBD 葉の上に `borrowings_schedule` 合計を重ねる

## プロトタイプ境界

`smoke/sankey_prototype_expected.json` は値の受け渡し形と実現可能性を固定するテスト資産であり、
公開 REST 契約ではない。smoke 段階では `/sankey` エンドポイントや `nodes` / `links` を追加しない。
本番 Neon 書き込み・ingest ジョブも出さない。

簡易表示は `smoke/sankey_prototype.html`。外部ライブラリを使わず同 JSON を読み、描画可能であることを
示すデモクライアントである。配置や既定ビューは契約の一部ではない。

会社ごとの「深掘り」で、会計上値が保存する単位に分けた複数 Sankey も表示する。

- キヤノン: 粗利益 → 販管費 → 事業利益（Waterfall）→ 別掲 R&D → 営業利益
- キヤノン: 営業利益 + その他純益 → 税引前利益 → 法人税・帰属差等・親会社帰属純利益
- 味の素: 売上総利益 → 販売費・一般管理費 → 事業利益（Waterfall）→ 別掲 R&D・持分法・その他営業 → 営業利益
- 味の素: 親会社帰属純利益 →（SS の）当期包括利益 → 配当・自己株式取得・残差
- 味の素: 期首資本 + 当期包括利益 → 期末資本・配当・自己株式取得・その他
- 味の素: 事業利益（Waterfall）→ 別掲 R&D → セグメント別（XBRLタグ行 + 丸め差）

配当・自己株式取得を当期純利益から直接配賦せず、期首資本を含む SS 資本ブリッジとして表示する。
`research_and_development` は発生支出。売上 dimension ではない。販管費の drilldown にするのは内数に限る。欠測は費目内訳が揃ってから接続する（進捗は Linear Team `blue-ticker`）。

```bash
cd smoke
python3 -m http.server 8765
# http://127.0.0.1:8765/sankey_prototype.html
```

HTML デモの表示モードと各ステージ間の値保存は `node smoke/sankey_prototype_test.mjs` で検証する。
