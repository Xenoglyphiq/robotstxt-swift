// HTTP transport over Foundation's URLSession (FoundationNetworking on Linux).

#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
#else
import Foundation
#endif

/// A `Transport` over `URLSession` that does **not** follow redirects (its delegate
/// declines them), so `fetch` can count them itself (spec §3.6). It sends
/// `Accept-Encoding: identity` and stops reading the body after `maxBodyBytes`.
public final class URLSessionTransport: Transport, @unchecked Sendable {
    /// A shared transport with an ephemeral configuration (no cache, no cookies).
    public static let shared = URLSessionTransport()

    private let session: URLSession
    private let delegate: Delegate
    private let userAgent: String?

    /// - Parameters:
    ///   - configuration: copied by `URLSession`; the default is `.ephemeral`.
    ///   - userAgent: sent as the `User-Agent` header when set.
    public init(configuration: URLSessionConfiguration = .ephemeral, userAgent: String? = nil) {
        delegate = Delegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.userAgent = userAgent
    }

    deinit { session.invalidateAndCancel() }

    public func get(_ url: URL, maxBodyBytes: Int) async -> TransportResponse? {
        var request = URLRequest(url: url)
        // The bytes as stored: robots.txt is small, and a decoded gzip body would
        // make the byte limit count something else.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let task = Box(session.dataTask(with: request))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TransportResponse?, Never>) in
                delegate.start(task.value, limit: max(0, maxBodyBytes), continuation)
            }
        } onCancel: {
            task.value.cancel()
        }
    }
}

/// Carries a task into the cancellation handler. `URLSessionTask` is thread-safe.
private struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Per-task state, kept under a lock: delegate callbacks arrive on URLSession's queue.
private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        let limit: Int
        let continuation: CheckedContinuation<TransportResponse?, Never>
        var response: HTTPURLResponse?
        var body: [UInt8] = []
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]

    func start(_ task: URLSessionDataTask, limit: Int, _ continuation: CheckedContinuation<TransportResponse?, Never>) {
        lock.lock()
        states[task.taskIdentifier] = State(limit: limit, continuation: continuation)
        lock.unlock()
        task.resume()
    }

    /// Removes the task's state and resumes its continuation exactly once.
    private func finish(_ task: URLSessionTask, failed: Bool) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }
        guard !failed, let http = state.response else {
            state.continuation.resume(returning: nil)
            return
        }
        let status = UInt32(clamping: http.statusCode)
        let location = http.value(forHTTPHeaderField: "Location")
        state.continuation.resume(returning: TransportResponse(status: status, location: location, body: state.body))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @Sendable @escaping (URLRequest?) -> Void
    ) {
        // Don't follow: the 3xx response itself completes the task.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        states[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var full = false
        let id = dataTask.taskIdentifier
        if let limit = states[id]?.limit, let count = states[id]?.body.count {
            states[id]!.body.append(contentsOf: data.prefix(limit - count))  // in place, no copy
            full = count + data.count >= limit
        }
        lock.unlock()
        if full {
            // Enough bytes: answer now and stop the download.
            finish(dataTask, failed: false)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task, failed: error != nil)
    }
}
