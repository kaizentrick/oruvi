import Foundation

/// Chunked reception avoids millions of async byte appends for an album cover.
/// Size and redirect restrictions are enforced before allocating the full response.
final class BoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var continuation: CheckedContinuation<HTTPReply, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var buffer = Data()
    private var finished = false
    init(limit: Int) { self.limit = limit }

    func start(in session: URLSession, request: URLRequest, continuation: CheckedContinuation<HTTPReply, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let task = session.dataTask(with: request)
        self.task = task; task.delegate = self
        lock.unlock()
        task.resume()
    }
    func cancel() { finish(.failure(CancellationError()), cancelTask: true) }
    private func finish(_ result: Result<HTTPReply, Error>, cancelTask: Bool = false) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, task = self.task
        self.continuation = nil; self.task = nil; buffer = Data()
        lock.unlock()
        if cancelTask { task?.cancel() }
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(RemoteError.invalidResponse)); return
        }
        guard http.expectedContentLength <= limit else {
            completionHandler(.cancel); finish(.failure(RemoteError.oversized)); return
        }
        if http.statusCode != 200 {
            let reply = HTTPReply(status: http.statusCode, data: Data(), retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            finish(.success(reply)); completionHandler(.cancel); return
        }
        lock.lock()
        let active = !finished
        if active {
            self.response = http
            buffer.reserveCapacity(min(limit, max(0, Int(http.expectedContentLength))))
        }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let oversized = data.count > limit - buffer.count
        if !oversized { buffer.append(data) }
        lock.unlock()
        if oversized { finish(.failure(RemoteError.oversized), cancelTask: true) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let http = response, data = buffer
        lock.unlock()
        guard let http else { finish(.failure(RemoteError.invalidResponse)); return }
        finish(.success(HTTPReply(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              target.scheme == "https", target.user == nil, target.password == nil,
              target.port == nil || target.port == 443,
              let oldHost = original.host?.lowercased(), let newHost = target.host?.lowercased(),
              oldHost == newHost || (oldHost.hasSuffix(".mzstatic.com") && newHost.hasSuffix(".mzstatic.com")) else {
            completionHandler(nil); finish(.failure(RemoteError.invalidURL), cancelTask: true); return
        }
        completionHandler(request)
    }
}
