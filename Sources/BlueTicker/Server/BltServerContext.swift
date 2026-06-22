// blt-server（REST HTTP API）が共有するコンテキスト。

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - BltServerContext

/// blt-server 全体で共有するコンテキスト（EDINET クライアント・キャッシュ）。
actor BltServerContext {
    let edinetClient: EdinetAPIClient
    let cacheManager: CacheManager
    let cacheDir: URL

    init(apiKey: String, cacheDir: URL) {
        self.cacheDir = cacheDir
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        self.edinetClient = EdinetAPIClient(apiKey: apiKey, cacheStore: store)
        self.cacheManager = CacheManager(cacheDir: derivedCacheDir(cacheDir))
    }
}
