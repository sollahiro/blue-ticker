# キャッシュ設計規約

blue_ticker 生成キャッシュの読み書きは `CacheManager`（`Sources/BlueTicker/Utils/CacheManager.swift`、actor）を使う。直接ファイルI/Oは行わない。

EDINET API 由来キャッシュ（日別書類一覧、年次書類インデックス、XBRL 展開ディレクトリ）は `EdinetCacheStore`（`Sources/BlueTicker/API/EdinetCacheStore.swift`）を使う。

## 責務別ディレクトリ

キャッシュは取得物と生成物で分ける。

```text
analysis_cache/
  external/
    edinet/
      documents_by_date/
      document_indexes/
      xbrl/
  derived/
    document_discovery/
    xbrl_numeric_index/
    xbrl_sections/
    analysis/
    misc/
```

- `external/`: 外部API・外部資料から取得した生データまたは取得物
- `derived/`: blue_ticker が探索・パース・計算して作った中間結果または分析結果
  - `xbrl_sections/`: `xbrl_sections_*` キー（有報セクション抽出の中間結果）
  - `misc/`: 上記 prefix に当てはまらない derived キーの受け皿

パス解決は `Utils/CachePaths.swift`（`edinetCacheDir(_:)` / `derivedCacheDir(_:)`）を使う。

## バージョン

- derived: `_cache_version` に `blueTickerVersion` を埋め込み、不一致は再取得（詳細は `versioning.md`）
- external: グローバルバージョンに連動させない（TTL・取得日・個別バージョン）
- Neon テーブルの `cache_version` は `blueTickerVersion` と独立（同じく `versioning.md`）

## キャッシュキーの命名規則

`{機能}_{識別子}_{パラメーター}` の形式で命名する。

```swift
"individual_analysis_\(code)"
```

短すぎるキー（`"\(code)"` や `"data"` など）は衝突リスクがあるため使わない。

## 落とし穴

`~/.config/blue-ticker/analysis_cache/.../xbrl` を別ディレクトリへ **symlink** すると statement 抽出が 0 facts になることがある。テスト用に実 XBRL を置くときは **`cp -a` で実コピー**する。
