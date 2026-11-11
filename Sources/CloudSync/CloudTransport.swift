import Foundation

public struct CloudRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Header lookup, case-insensitive.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

public struct CloudResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// One live WebSocket to the sync service. Text frames only.
public protocol CloudSocket: Sendable {
    /// The next text frame; throws when the socket closes.
    func receive() async throws -> String
    /// A protocol-level ping; completes when the pong arrives (not billed, unlike a message).
    func sendPing() async throws
    func close() async
}

/// The only seam to the network: tests substitute a fake, the product uses `URLSessionCloudTransport`.
/// `send` throws `CloudError.offline` when the server can't be reached; any HTTP status is a response.
public protocol CloudTransport: Sendable {
    func send(_ request: CloudRequest) async throws -> CloudResponse
    func openSocket(_ request: CloudRequest) async throws -> any CloudSocket
}
