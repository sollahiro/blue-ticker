// NIO ベースの REST HTTP サーバー。

import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - RESTResult

/// REST API レスポンス。
struct RESTResult: Sendable {
    let statusCode: Int
    let data: Data
    let contentType: String

    static func json(_ value: Any, statusCode: Int = 200) -> RESTResult {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        else {
            return error(message: "JSON serialization failed")
        }
        return RESTResult(statusCode: statusCode, data: data, contentType: "application/json")
    }

    static func error(statusCode: Int = 500, message: String) -> RESTResult {
        let body: [String: Any] = ["error": message, "status": statusCode]
        let data =
            (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return RESTResult(statusCode: statusCode, data: data, contentType: "application/json")
    }
}

// MARK: - HTTPApp

actor HTTPApp {
    struct Configuration: Sendable {
        var host: String
        var port: Int

        init(host: String = "127.0.0.1", port: Int = 3000) {
            self.host = host
            self.port = port
        }
    }

    typealias RESTHandler = @Sendable (String, String, [String: String], Data?) async -> RESTResult

    private let configuration: Configuration
    private let restHandler: RESTHandler
    private var channel: Channel?

    init(
        configuration: Configuration = Configuration(),
        restHandler: @escaping RESTHandler
    ) {
        self.configuration = configuration
        self.restHandler = restHandler
    }

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        printError("blt-server listening on \(configuration.host):\(configuration.port)\n")

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel

        try await channel.closeFuture.get()
    }

    func stop() async {
        try? await channel?.close()
        channel = nil
        printError("blt-server stopped\n")
    }

    func handleRESTRequest(method: String, path: String, queryString: String, body: Data?) async -> RESTResult {
        let params = parseQueryString(queryString)
        return await restHandler(method, path, params, body)
    }

    private func parseQueryString(_ query: String) -> [String: String] {
        guard !query.isEmpty else { return [:] }
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            params[key] = val
        }
        return params
    }
}

// MARK: - NIO HTTP Handler

private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: HTTPApp

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var requestState: RequestState?

    init(app: HTTPApp) {
        self.app = app
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            Task { @MainActor in
                await self.handleRequest(state: state, context: ctx)
            }
        }
    }

    @MainActor
    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let uriParts = head.uri.split(separator: "?", maxSplits: 1)
        let path = String(uriParts[0])
        let queryString = uriParts.count > 1 ? String(uriParts[1]) : ""

        let body: Data? = state.bodyBuffer.readableBytes > 0
            ? state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes).map { Data($0) }
            : nil
        let result = await app.handleRESTRequest(
            method: head.method.rawValue,
            path: path,
            queryString: queryString,
            body: body
        )
        await writeRESTResult(result, version: head.version, context: context)
    }

    @MainActor
    private func writeRESTResult(
        _ result: RESTResult,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop
        let data = result.data
        let statusCode = result.statusCode
        let contentType = result.contentType

        eventLoop.execute {
            var head = HTTPResponseHead(
                version: version,
                status: HTTPResponseStatus(statusCode: statusCode)
            )
            head.headers.add(name: "Content-Type", value: contentType)
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
            var buffer = ctx.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
