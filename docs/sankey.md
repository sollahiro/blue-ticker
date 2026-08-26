# Sankey

## 責務

サーバーは軸ごとの分解済み数値を JSON で返す。ノード・リンク・左右配置・色・描画は
クライアント責務とする。Blue Ticker は Sankey のレイアウトを規定しない。
サーバーは開示にない軸間配賦を推計しない。

方針の正本は本ファイル。Linear
[BLT-18](https://linear.app/sollahiro/issue/BLT-18/sankey要求具体化後) は売上・BS の初期方針、
[BLT-45](https://linear.app/sollahiro/issue/BLT-45/sankey-投資ハブ利益の活用) は投資ハブ。
残作業の先頭は [BLT-28](https://linear.app/sollahiro/issue/BLT-28/statement-母集団拡大上場)。
本 Feature・ingest・Notes・listed drain へ BLT-28 より先に着手しない。

## 材料契約（BLT-18）

smoke の言語非依存プロトタイプは `smoke/sankey_prototype_expected.json`（`schema_version: 2`）。
公開 REST/MCP 契約ではなく、次の境界を固定する。

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

研究開発費（breakdown `research_and_development`）は売上 dimension ではなく、
連結損益計算書の **販売費及び一般管理費の子** として付ける。詳細は「階層カタログ」。

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

### 研究開発費は販管費の子

breakdown `research_and_development` の正本は当期費用（投資額ではない）。
売上ハブの dimension にも、投資ハブの配賦先にもしない。

```text
売上総利益
├─ 販売費及び一般管理費          ← 親。値の決め方は下表
│  ├─ 研究開発費                 ← L3。分母は breakdown rd
│  │  ├─ 報告セグメント…        ← L4。axis の segment / reconciling
│  │  └─ 丸め差
│  └─ その他販管費               ← residual = 親 − R&D
└─ 営業利益
```

| 開示 | 判定 | 親（L2 販管費）の値 | 子 |
|---|---|---|---|
| R&D が販管費の内数 | J-GAAP の `ResearchAndDevelopmentExpensesSGA` 等。IFRS で PL に R&D 行が無い | 連結 PL の販管費 | R&D（breakdown 分母）＋その他販管費 |
| R&D が PL 別掲 | US-GAAP HTML の販管費と研究開発費が兄弟（キヤノン） | **derived**＝開示販管費＋研究開発費。ラベルは「販売費及び一般管理費」。実タグは子に残す | 開示販管費（その他）＋研究開発費 |

別掲でも親を販管費に寄せる。キヤノンでは親 `1,706,565,000,000` 円＝販管費 `1,367,277,000,000`＋R&D `339,288,000,000`。
粗利益 `2,161,955,000,000`＝親＋営業利益 `455,390,000,000`。R&D を売上総利益の直下へ並べない。

保存:

- `sum(R&D の segment＋reconciling＋residual) == R&D 分母`
- `R&D 分母 + その他販管費 == 親の販管費`（5% 超は `needs_review`）
- R&D 欠測は販管費を葉のまま残す。空の内訳で埋めない
- 地域別 R&D は通常非開示。推計しない

材料: PL の販管費は statement `income_statement`。R&D 合計とセグメントは breakdown `research_and_development`（financials の rd と同じ分母）。

### 連結損益計算書（metric `sales`）

PL は dimension ではなく `bridges.profit_and_loss`。L1 の稼得 dimension とハブで接続するだけ。

#### L1 稼得 dimension（分母＝連結外部売上）

| id | 内容 | 深さ | 材料 |
|---|---|---|---|
| `business` | 報告セグメント | L1 で打ち切り | breakdown `business` |
| `geography` | 地域別 | L1 で打ち切り | breakdown `geography` |
| `product_service` | 製品・サービス別 | L1 で打ち切り。`business` とマージしない | 未分離。実装時に判定 |

交差表が無い限り L2 のマトリクスは無い。欠測軸は出さない。銀行は分母が粗利益等なら Sales ハブへ繋げない。

#### L1–L4 費用・利益カスケード（J-GAAP 事業会社）

```text
L0 売上高
├─ L1 売上原価
└─ L1 売上総利益
   ├─ L2 販売費及び一般管理費
   │  ├─ L3 研究開発費
   │  │  └─ L4 セグメント（breakdown rd）
   │  └─ L3 その他販管費
   └─ L2 営業利益
      ├─ L3 営業外損益
      └─ L3 経常利益
         ├─ L4 特別損益
         └─ L4 税引前利益
            ├─ L4 法人税等
            ├─ L4 非支配持分・帰属差
            └─ L4 当期純利益
```

税引前以降はホップを増やさず L4 に畳む。

#### IFRS / US-GAAP

経常利益・特別損益を作らない。営業利益から金融損益・持分法・その他を経由して税引前へ。
販管費の下の R&D は上表どおり。US-GAAP 別掲でも親は販管費（derived）。

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
│  ├─ L2 短期借入金・1年内返済
│  │  └─ L3 科目別（notes `borrowings_schedule` の流動）
│  ├─ L2 リース負債（流動）
│  │  └─ L3 notes `lease_liabilities`（BS にあれば `available_via_statement`）
│  └─ L2 その他流動負債
├─ L1 非流動負債
│  ├─ L2 長期借入金・社債 → L3 `borrowings_schedule`
│  ├─ L2 リース負債（非流動） → L3 `lease_liabilities`
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

#### BS に付けない drilldown

| 材料 | 付け先 | 理由 |
|---|---|---|
| breakdown `segment_assets` | 総資産ハブの独立 drilldown（分母は segment＋reconciling） | 資産構成の子にすると流動/非流動と交差する |
| breakdown `noncurrent_asset_additions` | 投資ハブ側。期末残高ツリーに混ぜない | フローでありストックではない |
| 地域別非流動資産 | metric を `noncurrent_assets` に切り替える | 総資産 dimension へ混ぜない |

### キャッシュ・フローと投資ハブ（BLT-45）

R&D はここに置かない（販管費の子のまま）。Capex と株主還元を売上 PL に足さない。

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

純利益から配当・自社株へ直接配賦しない。

```text
L0 期首資本 + 当期純利益
├─ L1 期末資本
├─ L1 配当
├─ L1 自己株式取得
└─ L1 OCI 等を含む差額
```

L2 は初期に切らない。1株情報（notes `per_share_information`）は Sankey に出さない。

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

## smoke 結果

### 総資産

実現可能。味の素（2802、S100VXJA）で次の両 dimension が `1,721,131,000,000` 円に一致する。

- 資産: 流動資産 + 非流動資産
- 負債・純資産: 流動負債 + 非流動負債 + 資本

材料は既存 Statement JSON の `balance_sheet`。資産項目から個別の負債・資本項目へのリンク値は
開示されないため、`cross_axis_links_available: false`。

### 売上高

軸ごとの独立した構成比として実現可能。キヤノンの正規化後 spot fixture では
geography・business の各 dimension と PL bridge の売上高がすべて `4,624,727,000,000` 円に一致する。
材料は既存の次の JSON。

- `GET /v1/companies/{code}/breakdown?axis=geography`
- `GET /v1/companies/{code}/breakdown?axis=business`
- `GET /v1/companies/{code}/statement` または `financials`

地域×事業の交差値は既存データにない。周辺合計だけから交差リンクは一意に決まらない。
クライアントは各 dimension / bridge を独立した材料として組み合わせて描画する。

キヤノンの business / geography は公式 smoke 床では LLM に渡す前の表までを固定しており、
正規化後の金額は spot 監査資産である。公開契約の可用性確認は disposable Neon への ingest 後に行う。

現行 smoke JSON のキヤノン `to_operating_profit` は別掲 R&D を販管費の兄弟に置いている。
階層カタログでは親を derived 販管費（開示販管費＋R&D）とし、R&D はその子にする。
smoke fixture の付け替えは実装着手時。

### 営業利益

現状の3軸では実現不可。smoke の geography 行に利益がない。business のセグメント利益合計
`454,479,000,000` 円と PL 営業利益 `455,390,000,000` 円の差 `911,000,000` 円は、元の開示表に
「消去」として存在するため、これを抽出すれば business→PL は保存できる。3軸化に残る必須要件は
地域別利益の開示・抽出元であり、開示がない会社では生成できない。

## プロトタイプ境界

`smoke/sankey_prototype_expected.json` は値の受け渡し形と実現可能性を固定するテスト資産であり、
公開 REST/MCP 契約ではない。smoke 段階では `/sankey` エンドポイントや `nodes` / `links` を追加しない。
本番 Neon 書き込み・ingest ジョブも出さない。

簡易表示は `smoke/sankey_prototype.html`。外部ライブラリを使わず同 JSON を読み、描画可能であることを
示すデモクライアントである。配置や既定ビューは契約の一部ではない。

会社ごとの「深掘り」で、会計上値が保存する単位に分けた複数 Sankey も表示する。

- キヤノン: 粗利益 → 販管費（別掲 R&D を子に含む derived 親）・営業利益
- キヤノン: 営業利益 + その他純益 → 税引前利益 → 法人税・帰属差等・当期純利益
- 味の素: 期首資本 + 当期純利益 → 資本変動 → 期末資本・配当・自己株式取得・OCI等を含む差額（純減）
- 味の素: 販管費 → 研究開発費 → セグメント別（XBRLタグ行 + 丸め差）

配当・自己株式取得を当期純利益から直接配賦せず、期首資本を含む SS 資本ブリッジとして表示する。
`research_and_development` は当期費用。売上 dimension ではなく販管費の drilldown。

```bash
cd smoke
python3 -m http.server 8765
# http://127.0.0.1:8765/sankey_prototype.html
```

HTML デモの表示モードと各ステージ間の値保存は `node smoke/sankey_prototype_test.mjs` で検証する。
