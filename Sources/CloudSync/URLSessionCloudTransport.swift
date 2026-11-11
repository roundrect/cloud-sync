import Foundation

/// `CloudTransport` over `URLSession`: ephemeral (no cookies, no cache, no credentials store).
public struct URLSessionCloudTransport: CloudTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    private func urlRequest(_ request: CloudRequest) throws -> URLRequest {
        try CloudAPI.requireAllowed(request.url)
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    public func send(_ request: CloudRequest) async throws -> CloudResponse {
        let urlRequest = try urlRequest(request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw CloudError.server(status: 0, message: "not an HTTP response") }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers["\(key)".lowercased()] = "\(value)" }
            return CloudResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            throw CloudError.offline(error.localizedDescription)
        }
    }

    public func openSocket(_ request: CloudRequest) async throws -> any CloudSocket {
        var urlRequest = try urlRequest(request)
        if var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            urlRequest.url = components.url
        }
        let task = session.webSocketTask(with: urlRequest)
        task.resume()
        let socket = URLSessionSocket(task: task)
        do {
            // The server's `hello` proves the upgrade went through; a refused upgrade surfaces here.
            // A pong can't: URLSession stops reading at an unread frame, so a ping sent with `hello`
            // unread never completes.
            try await socket.readFirstMessage(timeout: timeout)
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            task.cancel(with: .goingAway, reason: nil)
            if let status, status != 101 {
                throw CloudAPI.error(status: status, body: Data())
            }
            throw CloudError.offline(error.localizedDescription)
        }
        return socket
    }
}

final class URLSessionSocket: CloudSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    /// The frame `readFirstMessage` took, handed to the first `receive()`. One reader at a time.
    private var first: String?

    init(task: URLSessionWebSocketTask) { self.task = task }

    /// Waits for the first frame and keeps it for `receive()`. Cancels the task after `timeout`.
    func readFirstMessage(timeout: TimeInterval) async throws {
        let task = task
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        first = try await receive()
    }

    func receive() async throws -> String {
        if let first {
            self.first = nil
            return first
        }
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() async { task.cancel(with: .goingAway, reason: nil) }
}
