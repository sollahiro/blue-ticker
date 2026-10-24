import BlueTickerCore

/// `blt-ingest` CLI 向けの再エクスポート。BltIngest は BlueTickerCore を直 import しない。
public func redactSecrets(_ message: String) -> String {
    BlueTickerCore.redactSecrets(message)
}
