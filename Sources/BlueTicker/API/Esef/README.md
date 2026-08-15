# EU / ESEF — API（Meta）

Region `EU` · Source `ESEF`。命名は `.agents/rules/project/regions.md`。

| ファイル | 役割 |
|---|---|
| `EsefModels.swift` | entity / filing / search hit |
| `EsefFilingsAPIClient.swift` | filings.xbrl.org JSON:API |
| `EsefEntityIndexStore.swift` | 発行体ローカル索引（JP EDINET CSV の対） |
| `EsefSearchService.swift` | Meta Search（Icon 保留・REST/MCP 未配線） |

```swift
let search = EsefSearchService()
try await search.refreshIndex()           // 初回・更新
let hits = try await search.search("Atlas Copco")
let byLei = try await search.search("213800T8PC8Q4FYJZR07")
```

REST preview（skills / MCP 未掲載）:

```http
GET /v1/eu/companies?q=Atlas%20Copco
GET /v1/eu/companies?q=213800T8PC8Q4FYJZR07
```

Cache: `external/eu/esef/entity_index.json`（blt-server の cacheDir 配下）。探索スクリプトは `tmp_cache/eu/esef/`。
