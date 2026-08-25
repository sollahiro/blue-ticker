# Sankey

## 責務

サーバーは軸ごとの分解済み数値を JSON で返す。表示する分解軸の選択、ノード、リンク、描画は
クライアント責務とする。
サーバーは開示にない軸間配賦を推計しない。

smoke の言語非依存プロトタイプは `smoke/sankey_prototype_expected.json`。各軸を同じ
`{ id, label, total, items: [{ id, label, value, tag? }] }` 形に揃えているため、クライアントは
`axes` の並びを差し替えられる。`tag` は XBRL タグを解決できる Statement 値にだけ載せる。

## smoke 結果

### 総資産

実現可能。味の素（2802、S100VXJA）で次の両軸が `1,721,131,000,000` 円に一致する。

- 資産: 流動資産 + 非流動資産
- 負債・純資産: 流動負債 + 非流動負債 + 資本

材料は既存 Statement JSON の `balance_sheet`。ただし、資産項目から個別の負債・資本項目へのリンク値は
開示されないため、プロトタイプは `cross_axis_links_available: false` とする。

### 売上高

軸ごとの独立した構成比として実現可能。キヤノン（7751、S100XTLJ）の正規化後 spot fixture では
geography、business、PL の各軸がすべて売上高 `4,624,727,000,000` 円に一致する。材料は既存の
次の JSON。

- `GET /v1/companies/{code}/breakdown?axis=geography`
- `GET /v1/companies/{code}/breakdown?axis=business`
- `GET /v1/companies/{code}/statement` または `financials`

地域×事業の交差値は既存データにない。周辺合計だけから交差リンクは一意に決まらないため、
「地域→事業→PL」の真の逐次 Sankey は生成できない。クライアントは各軸を独立した分解として表示するか、
全社売上のハブを介して表示する必要がある。

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

簡易表示は `smoke/sankey_prototype.html`。外部ライブラリを使わず同 JSON を読み、軸ごとの積み上げ列と
曲線帯を描画する。売上高は中央ハブ、左は地域別、右は事業別。右側だけを PL の粗利益階層または
営業利益階層へ差し替えられる。営業利益階層は売上原価・販管費・研究開発費・営業利益で売上高合計を
分解する。各内訳は中央ハブにのみ接続し、開示にない地域×事業の配賦は描かない。

```bash
cd smoke
python3 -m http.server 8765
# http://127.0.0.1:8765/sankey_prototype.html
```
