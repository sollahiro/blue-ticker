import Foundation

func externalCacheDir(_ cacheDir: URL) -> URL {
    cacheDir.appendingPathComponent("external", isDirectory: true)
}

func edinetCacheDir(_ cacheDir: URL) -> URL {
    externalCacheDir(cacheDir).appendingPathComponent("edinet", isDirectory: true)
}

func derivedCacheDir(_ cacheDir: URL) -> URL {
    cacheDir.appendingPathComponent("derived", isDirectory: true)
}
