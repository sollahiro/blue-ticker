import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// リダイレクトを追わずに 1 リクエストを取得する。3xx はそのまま応答として返す。
/// EDINET はメンテナンス中に全 API を案内 HTML へ 302 する。Linux の FoundationNetworking は
/// 302 を追うとき同じ easy handle に CURLOPT_BUFFERSIZE を設定し直し、libcurl 8.5 が 43 を返して
/// `try!` でプロセスごと落ちる。追っても JSON / ZIP は得られないので、追わずに失敗扱いにする。
enum NoRedirectFetch {
    static func data(from url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = Delegate(continuation: continuation)
            let session = URLSession(
                configuration: .default, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: url).resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var response: URLResponse?
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

        init(continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            lock.lock()
            self.response = response
            lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            buffer.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let data = buffer
            let resp = response ?? task.response
            let cont = continuation
            continuation = nil
            lock.unlock()
            session.finishTasksAndInvalidate()
            if let error {
                cont?.resume(throwing: error)
            } else if let resp {
                cont?.resume(returning: (data, resp))
            } else {
                cont?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}
