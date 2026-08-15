# EU / ESEF — API（Meta）

Region `EU` · Source `ESEF`。命名は `.agents/rules/project/regions.md`。

| ファイル | 役割 |
|---|---|
| `EsefModels.swift` | entity / filing / search hit |
| `EsefFilingsAPIClient.swift` | filings.xbrl.org JSON:API |
| `EsefEntityIndexStore.swift` | 発行体ローカル索引の**試作**（本番運用は ESAP 後） |
| `EsefSearchService.swift` | Meta Search（Icon 保留・skills/MCP 未掲載） |

## entity index は保留

**ESAP（European Single Access Point）一般公開（目安 2027-07）まで、全件 entity index の構築・運用はしない**（`docs/eu-esef-roadmap.md`）。

それまでの Search の正:

| クエリ | 経路 |
|---|---|
| LEI / identifier | live `filter[identifier]` |
| fxo_id | live filings + include=entity |
| 名称 | live **完全一致**のみ（部分一致は index 依存 → ESAP 後） |

`refreshIndex()` / `entity_index.json` はテスト・将来用。本番ジョブに載せない。

## 使い方（preview）

```swift
let search = EsefSearchService()
let byLei = try await search.search("213800T8PC8Q4FYJZR07")
let byFxo = try await search.search("213800T8PC8Q4FYJZR07-2024-12-31-ESEF-SE-1")
```

```http
GET /v1/eu/companies?q=213800T8PC8Q4FYJZR07
GET /v1/eu/companies?q=213800T8PC8Q4FYJZR07-2024-12-31-ESEF-SE-1
```

Cache（index を使う場合のみ）: `external/eu/esef/entity_index.json`。探索スクリプトは `tmp_cache/eu/esef/`。
