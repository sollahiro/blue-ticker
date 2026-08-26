# Sankey

## 責務

サーバーは軸ごとの分解済み数値を JSON で返す。ノード・リンク・左右配置・色・描画は
クライアント責務とする。Blue Ticker は Sankey のレイアウトを規定しない。
サーバーは開示にない軸間配賦を推計しない。

方針の正本は Linear
[BLT-18](https://linear.app/sollahiro/issue/BLT-18/sankey要求具体化後)。
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
| `drilldowns` | 分母が異なる分解（例: R&D） |

- 欠測軸は `available=false` または省略。空配列でゼロ構成を装わない。
- `row_kind` の `segment` + `reconciling` を合計対象とし、subtotal は合計しない。
- 開示済み消去・全社は `reconciling`。丸め・未分類は明示 residual。
- `tag` は実際の XBRL タグを解決できる値にだけ載せる。プレースホルダーは作らない。
- `cross_axis_links_available` は開示交差表がない限り `false`。geography×business リンクは生成しない。
- JSON に `left_axis` / `right_axis` / `default_layout` や色役割は載せない。

Sales の PL は bridge。J-GAAP 事業会社と IFRS/US-GAAP でトポロジが異なる。
キヤノン（7751、S100XTLJ）は US-GAAP のため経常利益・特別損益を発明しない。
各 bridge stage は `conserved_total` へ一致し、説明不能な残差が 5% 超なら `needs_review`。

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

- キヤノン: 粗利益 → 販管費・研究開発費・営業利益（PL bridge stage）
- キヤノン: 営業利益 + その他純益 → 税引前利益 → 法人税・帰属差等・当期純利益
- 味の素: 期首資本 + 当期純利益 → 資本変動 → 期末資本・配当・自己株式取得・OCI等を含む差額（純減）
- 味の素: PL 研究開発費 → セグメント別研究開発費（XBRLタグ行 + 丸め差）

配当・自己株式取得を当期純利益から直接配賦せず、期首資本を含む SS 資本ブリッジとして表示する。
`research_and_development` は投資額ではなく当期費用。分母が売上と異なるため `drilldowns` に分離する。

```bash
cd smoke
python3 -m http.server 8765
# http://127.0.0.1:8765/sankey_prototype.html
```

HTML デモの表示モードと各ステージ間の値保存は `node smoke/sankey_prototype_test.mjs` で検証する。
