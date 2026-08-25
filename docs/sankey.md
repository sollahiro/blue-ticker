# Sankey

## 責務

サーバーは軸ごとの分解済み数値を JSON で返す。軸の順序、ノード、リンク、描画はクライアント責務とする。
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

軸ごとの独立した構成比として実現可能。キヤノン（7751、S100XTLJ）では geography、business、PL の
各軸がすべて売上高 `4,624,727,000,000` 円に一致する。材料は既存の次の JSON。

- `GET /v1/companies/{code}/breakdown?axis=geography`
- `GET /v1/companies/{code}/breakdown?axis=business`
- `GET /v1/companies/{code}/statement` または `financials`

地域×事業の交差値は既存データにない。周辺合計だけから交差リンクは一意に決まらないため、
「地域→事業→PL」の真の逐次 Sankey は生成できない。クライアントは各軸を独立した分解として表示するか、
全社売上のハブを介して表示する必要がある。

### 営業利益

現状の3軸では実現不可。smoke の geography 行に利益がなく、business のセグメント利益合計
`454,479,000,000` 円と PL 営業利益 `455,390,000,000` 円の間にも `911,000,000` 円の調整差がある。
対応するには、地域別利益の新しい抽出元と、事業別の消去・全社調整行が必要。

## プロトタイプ境界

`smoke/sankey_prototype_expected.json` は値の受け渡し形と実現可能性を固定するテスト資産であり、
公開 REST/MCP 契約ではない。smoke 段階では `/sankey` エンドポイントや `nodes` / `links` を追加しない。
