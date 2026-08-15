import Foundation

func externalCacheDir(_ cacheDir: URL) -> URL {
    cacheDir.appendingPathComponent("external", isDirectory: true)
}

func edinetCacheDir(_ cacheDir: URL) -> URL {
    externalCacheDir(cacheDir).appendingPathComponent("edinet", isDirectory: true)
}

/// Region EU · Source ESEF の外部取得物（entity index 等）。
func esefCacheDir(_ cacheDir: URL) -> URL {
    externalCacheDir(cacheDir)
        .appendingPathComponent("eu", isDirectory: true)
        .appendingPathComponent("esef", isDirectory: true)
}

func derivedCacheDir(_ cacheDir: URL) -> URL {
    cacheDir.appendingPathComponent("derived", isDirectory: true)
}
