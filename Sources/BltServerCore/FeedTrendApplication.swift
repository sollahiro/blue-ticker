// Feed Trend の Application.storage 配線。テストは registerRoutes 前に注入する。
// production は env（BLT_FEED_TREND_URL / TOKEN）。testing は未注入なら no-op（ネットワーク禁止）。

import BlueTickerCore
import Vapor

private struct FeedTrendBoxKey: StorageKey {
    typealias Value = FeedTrendBox
}

final class FeedTrendBox: @unchecked Sendable {
    let sink: any FeedTrendSink
    let query: any FeedTrendQueryClient
    init(sink: any FeedTrendSink, query: any FeedTrendQueryClient) {
        self.sink = sink
        self.query = query
    }
}

func installFeedTrendDefaults(_ app: Application) {
    guard app.storage[FeedTrendBoxKey.self] == nil else { return }
    if app.environment.name == "testing" {
        app.storage[FeedTrendBoxKey.self] = FeedTrendBox(
            sink: NoopFeedTrendSink(), query: UnconfiguredFeedTrendQueryClient())
        return
    }
    app.storage[FeedTrendBoxKey.self] = FeedTrendBox(
        sink: HTTPFeedTrendSink.fromEnvironment(),
        query: HTTPFeedTrendQueryClient.fromEnvironment())
}

func setFeedTrendServices(
    _ app: Application, sink: any FeedTrendSink, query: any FeedTrendQueryClient
) {
    app.storage[FeedTrendBoxKey.self] = FeedTrendBox(sink: sink, query: query)
}

func feedTrendBox(for app: Application) -> FeedTrendBox {
    installFeedTrendDefaults(app)
    return app.storage[FeedTrendBoxKey.self]!
}

func recordFeedTrend(
    _ app: Application, surface: String, tool: String, code: String? = nil, q: String? = nil
) {
    guard let event = makeFeedTrendEvent(surface: surface, tool: tool, code: code, q: q) else {
        return
    }
    feedTrendBox(for: app).sink.record(event)
}
