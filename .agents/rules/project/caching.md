# キャッシュ

生成キャッシュは `CacheManager`、EDINET 取得物は `EdinetCacheStore`。直接ファイル I/O は禁止。パスは `CachePaths.swift`。

derived は `_cache_version`＝`blueTickerVersion`。external はグローバル版に連動させない。Neon の `cache_version` は独立（`versioning.md`）。

キーは `{機能}_{識別子}_{パラメーター}`。XBRL キャッシュを symlink すると 0 facts になることがある。テスト用は `cp -a`。
