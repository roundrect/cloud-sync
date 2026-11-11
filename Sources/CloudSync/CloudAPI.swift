import Foundation

public struct CreatedAccount: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
    }

    public var accountId: String
    public var device: Device
    public var token: String
}

public struct PairingStart: Codable, Equatable, Sendable {
    public var pairingId: String
    public var code: String
    public var pollSecret: String
    public var expiresIn: Int
}

public enum PairingPoll: Equatable, Sendable {
    case pending
    case expired
    case approved(CreatedAccount)
}

/// A device of the account (`GET /v1/devices`).
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var current: Bool
    /// The app the device belongs to on the shared server.
    public var namespace: String
}

public struct HistoryPage: Codable, Equatable, Sendable {
    public var revisions: [Revision]
    /// Pass as `before` for the next (older) page; nil at the end.
    public var nextBefore: Int?
}

/// The typed endpoints of the sync API (`/v1`) over a `CloudTransport`, mapping status codes onto
/// `CloudError`. Holds no state besides the token it was made with.
public struct CloudAPI: Sendable {
    public var server: URL
    public var transport: any CloudTransport
    public var clientVersion: String
    public var token: String?
    /// The app's slug on the shared server: every route is `/v1/ns/<namespace>/…`.
    public var namespace: String

    public init(server: URL, transport: any CloudTransport, clientVersion: String, namespace: String, token: String? = nil) {
        self.namespace = namespace
        self.server = server
        self.transport = transport
        self.clientVersion = clientVersion
        self.token = token
    }

    // MARK: - Server URLs

    /// https anywhere; plain http only for loopback (local development).
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    public static func requireAllowed(_ url: URL) throws {
        guard isAllowed(url) else {
            throw CloudError.insecureServer("the sync server must be an https:// address (http:// only works for localhost): \(url.absoluteString)")
        }
    }

    /// Parses a user-supplied server, dropping a trailing slash.
    public static func normalizedServer(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { throw CloudError.insecureServer("not a server address: \(text)") }
        try requireAllowed(url)
        return url
    }

    /// The same server, ignoring case and a trailing slash.
    public static func sameServer(_ a: URL, _ b: URL) -> Bool {
        a.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == b.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    // MARK: - Namespaces

    /// `^[a-z][a-z0-9-]{0,31}$`, which can't contain the `:` of a document name or collide with a route.
    public static func isValidNamespace(_ slug: String) -> Bool {
        let bytes = Array(slug.utf8)
        guard (1...32).contains(bytes.count), (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || $0 == UInt8(ascii: "-") }
    }

    /// `route` is relative to the namespace, e.g. `doc`: `v1/ns/<namespace>/doc`.
    func path(_ route: String) throws -> String {
        guard Self.isValidNamespace(namespace) else {
            throw CloudError.local("not a valid sync namespace (lowercase letters, digits and hyphens, starting with a letter, up to 32): \(namespace)")
        }
        return "v1/ns/\(namespace)/\(route)"
    }

    // MARK: - Requests

    private struct ErrorBody: Decodable {
        var error: String?
        var message: String?
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: (any Encodable)? = nil, ifMatch: Int? = nil) throws -> CloudRequest {
        var components = URLComponents(url: server.appending(path: try self.path(path)), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var headers = ["Sync-Client": clientVersion, "Accept": "application/json"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let ifMatch { headers["If-Match"] = "\(ifMatch)" }
        var body: Data?
        if let json {
            headers["Content-Type"] = "application/json"
            body = try CloudJSON.makeEncoder().encode(AnyEncodable(json))
        }
        return CloudRequest(method: method, url: components.url!, headers: headers, body: body)
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable
        init(_ value: any Encodable) { self.value = value }
        func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
    }

    /// Maps a non-2xx status onto the error the caller reacts to.
    static func error(status: Int, body: Data) -> CloudError {
        let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body)
        let message = parsed?.message ?? "HTTP \(status)"
        switch status {
        case 401: return parsed?.error == "invalid_invite" ? .invalidInvite : .unauthorized(message)
        case 402: return .paymentRequired
        case 403: return parsed?.error == "namespace_mismatch" ? .namespaceMismatch(message) : .server(status: status, message: message)
        case 404: return parsed?.error == "invalid_code" ? .invalidCode : .notFound(message)
        case 409:
            if let doc = try? CloudJSON.makeDecoder().decode(RemoteDoc.self, from: body) { return .conflict(doc) }
            return .server(status: status, message: message)
        case 426: return .upgradeRequired(message)
        case 429: return .rateLimited(message)
        default: return .server(status: status, message: message)
        }
    }

    private func perform<T: Decodable>(_ request: CloudRequest, as type: T.Type = T.self) async throws -> T {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else { throw Self.error(status: response.status, body: response.body) }
        do {
            return try CloudJSON.makeDecoder().decode(T.self, from: response.body)
        } catch {
            throw CloudError.server(status: response.status, message: "unexpected response: \(error.localizedDescription)")
        }
    }

    // MARK: - Endpoints

    public struct Meta: Codable, Equatable, Sendable {
        public var api: Int
        public var minClient: String
    }

    public func meta() async throws -> Meta {
        try await perform(request("GET", "meta"))
    }

    public func createAccount(invite: String, deviceName: String) async throws -> CreatedAccount {
        struct Body: Encodable { var invite: String; var deviceName: String }
        return try await perform(request("POST", "accounts", json: Body(invite: invite, deviceName: deviceName)))
    }

    public func pairStart(deviceName: String) async throws -> PairingStart {
        struct Body: Encodable { var deviceName: String }
        return try await perform(request("POST", "pair/start", json: Body(deviceName: deviceName)))
    }

    public func pairPoll(_ start: PairingStart) async throws -> PairingPoll {
        struct Body: Encodable { var pairingId: String; var pollSecret: String }
        struct Reply: Decodable {
            var status: String
            var accountId: String?
            var device: CreatedAccount.Device?
            var token: String?
        }
        let reply: Reply = try await perform(request("POST", "pair/poll", json: Body(pairingId: start.pairingId, pollSecret: start.pollSecret)))
        switch reply.status {
        case "pending": return .pending
        case "approved":
            guard let accountId = reply.accountId, let device = reply.device, let token = reply.token else {
                throw CloudError.server(status: 200, message: "unexpected response: approval without a token")
            }
            return .approved(CreatedAccount(accountId: accountId, device: device, token: token))
        default: return .expired
        }
    }

    /// Without `confirm`, only looks the code up and returns the requesting device's name.
    @discardableResult
    public func pairApprove(code: String, confirm: Bool) async throws -> String {
        struct Body: Encodable { var code: String; var confirm: Bool? }
        struct Reply: Decodable { var deviceName: String }
        let reply: Reply = try await perform(request("POST", "pair/approve", json: Body(code: code, confirm: confirm ? true : nil)))
        return reply.deviceName
    }

    public func doc() async throws -> RemoteDoc {
        try await perform(request("GET", "doc"))
    }

    /// Returns the new revision; throws `.conflict(current)` when `ifMatch` is stale.
    public func put(_ document: SyncDocument, ifMatch: Int) async throws -> Int {
        struct Reply: Decodable { var rev: Int }
        return try await (perform(request("PUT", "doc", json: document, ifMatch: ifMatch)) as Reply).rev
    }

    public func history(before: Int? = nil, limit: Int = 50) async throws -> HistoryPage {
        var query = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let before { query.append(URLQueryItem(name: "before", value: "\(before)")) }
        return try await perform(request("GET", "history", query: query))
    }

    public func revision(_ rev: Int) async throws -> RemoteDoc {
        try await perform(request("GET", "history/\(rev)"))
    }

    public func revert(to rev: Int, ifMatch: Int, summary: String) async throws -> Int {
        struct Body: Encodable { var rev: Int; var ifMatch: Int; var summary: String }
        struct Reply: Decodable { var rev: Int }
        return try await (perform(request("POST", "revert", json: Body(rev: rev, ifMatch: ifMatch, summary: summary))) as Reply).rev
    }

    public func devices() async throws -> [DeviceInfo] {
        struct Reply: Decodable { var devices: [DeviceInfo] }
        return try await (perform(request("GET", "devices")) as Reply).devices
    }

    public func revoke(deviceID: String) async throws {
        struct Reply: Decodable { var revoked: Bool }
        _ = try await perform(request("DELETE", "devices/\(deviceID)")) as Reply
    }

    /// The upgrade request for the namespace's `ws` route.
    public func socketRequest() throws -> CloudRequest {
        try request("GET", "ws")
    }

    public func openSocket() async throws -> any CloudSocket {
        try await transport.openSocket(socketRequest())
    }
}
