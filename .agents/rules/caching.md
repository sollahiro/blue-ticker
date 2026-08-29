# キャッシュ

- 生成キャッシュは `CacheManager`、EDINET 取得物は `EdinetCacheStore`、パスは `CachePaths.swift` を使う。直接ファイル I/O を追加しない。
- derived の `_cache_version` は `blueTickerVersion`。external と Neon `cache_version` は連動させない。
- XBRL キャッシュの symlink は 0 facts を生むことがあるため、テスト用コピーは `cp -a` を使う。
- 生 XBRL の中央コピーは R2 `BLT_R2_XBRL_BUCKET`（`jp/edinet/xbrl/{docID}.zip`）。取得順はローカル展開 → R2 → EDINET。配信時は R2 を読まない。
- 数値 fact 索引は永続化せず、同一展開ディレクトリ内だけプロセス内 FIFO で再利用する。アイコンは別バケット `BLT_R2_ICONS_BUCKET`。
