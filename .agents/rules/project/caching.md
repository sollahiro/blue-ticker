# キャッシュ

生成キャッシュは `CacheManager`、EDINET 取得物は `EdinetCacheStore`。直接ファイル I/O は禁止。パスは `CachePaths.swift`。

derived は `_cache_version`＝`blueTickerVersion`。external はグローバル版に連動させない。Neon の `cache_version` は独立（`versioning.md`）。

キーは `{機能}_{識別子}_{パラメーター}`。XBRL キャッシュを symlink すると 0 facts になることがある。テスト用は `cp -a`。

探索用（Swift 非経由）: `tmp_cache/edinet/`（JP/EDINET）と `tmp_cache/eu/esef/`（EU/ESEF）。規約は `regions.md`。

生 XBRL の中央コピーは R2（バケット `BLT_R2_XBRL_BUCKET`、キー `jp/edinet/xbrl/{docID}.zip`）。ingest の取得順はローカル展開 → R2 → EDINET。バケット未設定なら R2 を飛ばす。配信は R2 を読まない。アイコンは別バケット（`BLT_R2_ICONS_BUCKET`）。
