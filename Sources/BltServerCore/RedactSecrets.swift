import BlueTickerCore

/// `blt-server` CLI 向けの再エクスポート。BltServer は BlueTickerCore を直 import しない。
public func redactSecrets(_ message: String) -> String {
    BlueTickerCore.redactSecrets(message)
}
