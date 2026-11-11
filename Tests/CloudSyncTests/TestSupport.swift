import CryptoKit
import Foundation
@testable import CloudSync

/// An in-memory stand-in for the sync service: the same wire shapes as `server/src`, no network.
final class FakeCloudServer: CloudTransport, @unchecked Sendable {
    struct StoredRevision {
        var rev: Int
        var document: SyncDocument
        var deviceId: String
        var deviceName: String
        var kind: String
        var revertedTo: Int?
        var createdAt: Date
    }

    struct StoredDevice {
        var id: String
        var name: String
        var token: String
        var namespace: String
        var revoked = false
    }

    private let lock = NSLock()
    private var revisions: [StoredRevision] = []
    private var devices: [String: StoredDevice] = [:]
    private var pairings: [String: (name: String, approved: Bool, code: String, namespace: String)] = [:]
    private var counter = 0
    private var log: [CloudRequest] = []

    let invite = "invite-secret"
    /// Every request fails as unreachable.
    var offline: Bool { get { lock.withLock { _offline } } set { lock.withLock { _offline = newValue } } }
    private var _offline = false
    /// Authenticated requests answer with this status (and an error body) instead.
    var forcedStatus: Int? { get { lock.withLock { _forced } } set { lock.withLock { _forced = newValue } } }
    private var _forced: Int?
    /// Polls answered `pending` before an approved pairing is released.
    var pendingPolls = 0

    var requests: [CloudRequest] { lock.withLock { log } }
    /// Requests of a method whose route ends in `suffix`, written as `/v1/<route>` whichever namespace they went to.
    func count(_ method: String, _ suffix: String) -> Int { requests.filter { $0.method == method && Self.split($0.url.path)?.path.hasSuffix(suffix) == true }.count }
    var headRev: Int { lock.withLock { revisions.last?.rev ?? 0 } }
    func bodyBytes(of rev: Int) -> Data? { body(of: rev).map { Data($0.utf8) } }
    func sha256(of rev: Int) -> String? { lock.withLock { revisions.first { $0.rev == rev }?.document.sha256 } }
    func body(of rev: Int) -> String? { lock.withLock { revisions.first { $0.rev == rev }?.document.body } }
    var deviceNames: [String] { lock.withLock { devices.values.filter { !$0.revoked }.map(\.name).sorted() } }

    /// Another Mac's write of a notes document, straight into the store.
    @discardableResult
    func writeAsOtherDevice(_ values: [String: String], name: String = "Other Mac", summary: String = "") -> Int {
        writeTextAsOtherDevice(notes(values), format: "app-text", name: name, summary: summary)
    }

    /// Another Mac's write of arbitrary text, straight into the store.
    @discardableResult
    func writeTextAsOtherDevice(_ text: String, format: String = "ordered-text", schema: Int = 1, name: String = "Other Mac", summary: String = "") -> Int {
        lock.withLock {
            append(SyncDocument(format: format, schema: schema, body: text, summary: summary), deviceId: "dev_other", deviceName: name, kind: revisions.isEmpty ? "bootstrap" : "put", revertedTo: nil)
        }
    }

    func writeRawDocument(_ document: SyncDocument) -> Int {
        lock.withLock { append(document, deviceId: "dev_other", deviceName: "Other Mac", kind: "put", revertedTo: nil) }
    }

    func openSocket(_ request: CloudRequest) async throws -> any CloudSocket { throw CloudError.offline("no sockets in the fake") }

    func send(_ request: CloudRequest) async throws -> CloudResponse {
        lock.withLock { log.append(request) }
        if offline { throw CloudError.offline("the Internet connection appears to be offline") }
        return lock.withLock { handle(request) }
    }

    // MARK: - Handling (lock held)

    private func isoNow() -> String { CloudJSON.isoString(Date()) }

    private func reply(_ status: Int, _ object: [String: Any]) -> CloudResponse {
        CloudResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func error(_ status: Int, _ code: String, _ message: String = "error") -> CloudResponse {
        reply(status, ["error": code, "message": message])
    }

    private func docObject(_ revision: StoredRevision?) -> [String: Any] {
        guard let revision else { return ["rev": 0] }
        return ["rev": revision.rev, "format": revision.document.format, "schema": revision.document.schema, "body": revision.document.body,
                "sha256": revision.document.sha256, "summary": revision.document.summary, "updatedAt": CloudJSON.isoString(revision.createdAt),
                "deviceId": revision.deviceId, "deviceName": revision.deviceName]
    }

    private func append(_ document: SyncDocument, deviceId: String, deviceName: String, kind: String, revertedTo: Int?) -> Int {
        let rev = (revisions.last?.rev ?? 0) + 1
        revisions.append(StoredRevision(rev: rev, document: document, deviceId: deviceId, deviceName: deviceName, kind: kind, revertedTo: revertedTo, createdAt: Date()))
        return rev
    }

    private func nextID() -> Int { counter += 1; return counter }

    private func mint(_ name: String, namespace: String) -> StoredDevice {
        let id = "dev_\(String(format: "%016x", nextID()))"
        let device = StoredDevice(id: id, name: name, token: "shk1_\(id)_secret", namespace: namespace, revoked: false)
        devices[id] = device
        return device
    }

    /// Another device of the account, straight into the store.
    func addDevice(_ name: String, namespace: String) { lock.withLock { _ = mint(name, namespace: namespace) } }

    private func authed(_ request: CloudRequest) -> StoredDevice? {
        guard let header = request.header("Authorization"), header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst(7))
        return devices.values.first { $0.token == token && !$0.revoked }
    }

    /// `/v1/ns/<slug>/<route>` is `/v1/<route>` for the slug. Any other path is not a route of the service: nil.
    private static func split(_ path: String) -> (path: String, namespace: String)? {
        let prefix = "/v1/ns/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return ("/v1" + rest[slash...], String(rest[..<slash]))
    }

    private func handle(_ request: CloudRequest) -> CloudResponse {
        guard let (path, namespace) = Self.split(request.url.path) else { return error(404, "not_found", "no such route (every route is under /v1/ns/<namespace>)") }
        let json = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
        switch (request.method, path) {
        case ("GET", "/v1/meta"): return reply(200, ["api": 1, "minClient": "0.0.0"])
        case ("POST", "/v1/accounts"):
            guard json["invite"] as? String == invite else { return error(401, "invalid_invite") }
            let device = mint(json["deviceName"] as? String ?? "Mac", namespace: namespace)
            return reply(201, ["accountId": "acc_1", "device": ["id": device.id, "name": device.name], "token": device.token])
        case ("POST", "/v1/pair/start"):
            let id = "pair_\(nextID())"
            let code = "K7QF-M2X\(counter % 10)"
            pairings[id] = (json["deviceName"] as? String ?? "Mac", false, code, namespace)
            return reply(201, ["pairingId": id, "code": code, "pollSecret": "s", "expiresIn": 600])
        case ("POST", "/v1/pair/poll"):
            guard let id = json["pairingId"] as? String, let pairing = pairings[id] else { return reply(200, ["status": "expired"]) }
            guard pairing.approved else { return reply(200, ["status": "pending"]) }
            if pendingPolls > 0 { pendingPolls -= 1; return reply(200, ["status": "pending"]) }
            pairings[id] = nil
            let device = mint(pairing.name, namespace: pairing.namespace)
            return reply(200, ["status": "approved", "accountId": "acc_1", "device": ["id": device.id, "name": device.name], "token": device.token])
        default: break
        }

        if let forced = _forced { return error(forced, forced == 401 ? "unauthorized" : forced == 403 ? "namespace_mismatch" : forced == 402 ? "payment_required" : "upgrade_required") }
        guard let device = authed(request) else { return error(401, "unauthorized") }
        if device.namespace != namespace { return error(403, "namespace_mismatch", "this token is for another app") }

        switch (request.method, path) {
        case ("POST", "/v1/pair/approve"):
            guard let code = json["code"] as? String, let entry = pairings.first(where: { $0.value.code == code }) else { return error(404, "invalid_code") }
            // Own namespace, or one with no devices at all (revoked ones count).
            if entry.value.namespace != device.namespace, devices.values.contains(where: { $0.namespace == entry.value.namespace }) {
                return error(403, "namespace_mismatch", "that pairing is for another app")
            }
            if json["confirm"] as? Bool == true {
                pairings[entry.key]?.approved = true
                return reply(200, ["approved": true, "deviceName": entry.value.name])
            }
            return reply(200, ["deviceName": entry.value.name])
        case ("GET", "/v1/doc"):
            return reply(200, docObject(revisions.last))
        case ("PUT", "/v1/doc"):
            guard let match = request.header("If-Match"), let ifMatch = Int(match) else { return error(428, "precondition_required") }
            guard ifMatch == (revisions.last?.rev ?? 0) else {
                var object = docObject(revisions.last)
                object["error"] = "conflict"
                return reply(409, object)
            }
            guard let document = try? CloudJSON.makeDecoder().decode(SyncDocument.self, from: request.body ?? Data()) else { return error(400, "bad_request") }
            let rev = append(document, deviceId: device.id, deviceName: device.name, kind: revisions.isEmpty ? "bootstrap" : "put", revertedTo: nil)
            return reply(200, ["rev": rev])
        case ("GET", "/v1/history"):
            let items = revisions.reversed().map { r -> [String: Any] in
                var item: [String: Any] = ["rev": r.rev, "createdAt": CloudJSON.isoString(r.createdAt), "deviceId": r.deviceId, "deviceName": r.deviceName, "kind": r.kind, "summary": r.document.summary]
                if let to = r.revertedTo { item["revertedTo"] = to }
                return item
            }
            return reply(200, ["revisions": items])
        case ("POST", "/v1/revert"):
            guard let rev = json["rev"] as? Int, let ifMatch = json["ifMatch"] as? Int else { return error(400, "bad_request") }
            guard let target = revisions.first(where: { $0.rev == rev }) else { return error(404, "not_found") }
            guard ifMatch == (revisions.last?.rev ?? 0) else {
                var object = docObject(revisions.last)
                object["error"] = "conflict"
                return reply(409, object)
            }
            var document = target.document
            document.summary = json["summary"] as? String ?? ""
            return reply(200, ["rev": append(document, deviceId: device.id, deviceName: device.name, kind: "revert", revertedTo: rev)])
        case ("GET", "/v1/devices"):
            let list = devices.values.filter { !$0.revoked }.sorted { $0.id < $1.id }.map {
                var item = ["id": $0.id, "name": $0.name, "createdAt": isoNow(), "current": $0.id == device.id] as [String: Any]
                item["namespace"] = $0.namespace
                return item
            }
            return reply(200, ["devices": list])
        default: break
        }
        if request.method == "GET", path.hasPrefix("/v1/history/"), let rev = Int(path.dropFirst("/v1/history/".count)) {
            guard let target = revisions.first(where: { $0.rev == rev }) else { return error(404, "not_found") }
            return reply(200, docObject(target))
        }
        if request.method == "DELETE", path.hasPrefix("/v1/devices/") {
            let id = String(path.dropFirst("/v1/devices/".count))
            guard devices[id] != nil else { return error(404, "not_found") }
            devices[id]?.revoked = true
            return reply(200, ["revoked": true, "id": id])
        }
        return error(404, "not_found")
    }
}

extension CloudJSON {
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}


extension FakeCloudServer {
    /// A document straight into the store, bypassing the client's own checks.
    func writeRaw(_ document: SyncDocument) {
        _ = writeRawDocument(document)
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
}

/// A fake Mac: its own temp folder, synced file, link directory, token store and applied state. Nothing
/// outside the temp folder is touched.
final class FakeMac<Host: SyncHost> {
    let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-test-\(UUID().uuidString)")
    let applied = AppliedState()
    let tokens = InMemoryTokenStore()
    let server: FakeCloudServer?
    let fileURL: URL
    var linkDirectory: URL { directory.appending(path: "sync") }
    var link: SyncLink { SyncLink(directory: linkDirectory) }
    var cloud: SyncClient<Host>

    static var url: URL { URL(string: "http://127.0.0.1:8787")! }

    init(transport: any CloudTransport, server: FakeCloudServer? = nil, text: String? = nil, fileName: String,
         makeHost: (URL, AppliedState) -> Host) throws {
        self.server = server
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: fileName)
        if let text { try Data(text.utf8).write(to: fileURL) }
        cloud = SyncClient(
            host: makeHost(fileURL, applied), transport: transport, tokens: tokens,
            link: SyncLink(directory: directory.appending(path: "sync")), clientVersion: "1.2.3")
        cloud.sleep = { _ in }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func write(_ text: String) throws { try Data(text.utf8).write(to: fileURL) }
    func fileText() throws -> String { try String(contentsOf: fileURL, encoding: .utf8) }
    func fileData() throws -> Data { try Data(contentsOf: fileURL) }
    /// What `apply` last put on this Mac.
    var machine: [String: String] { applied.values }

    func linkCreate(adopt: AdoptMode? = nil, name: String = "Mac A", invite: String? = nil, serverURL: URL = FakeMac.url) async throws -> LinkResult<Host> {
        var request = LinkRequest(server: serverURL, deviceName: name, invite: invite ?? server?.invite, adopt: adopt)
        request.pollInterval = 0
        return try await cloud.link(request)
    }
}

typealias NotesMac = FakeMac<NotesHost>
typealias RulesMac = FakeMac<OrderedTextHost>

extension FakeMac where Host == NotesHost {
    convenience init(server: FakeCloudServer, text: String? = nil, namespace: String = "app") throws {
        try self.init(transport: server, server: server, text: text, namespace: namespace)
    }

    convenience init(transport: any CloudTransport, server: FakeCloudServer? = nil, text: String? = nil, namespace: String = "app") throws {
        try self.init(transport: transport, server: server, text: text, fileName: "notes.txt") {
            var host = NotesHost(documentURL: $0, applied: $1)
            host.namespace = namespace
            return host
        }
    }

    func write(_ values: [String: String]) throws { try write(notes(values)) }
    func read() throws -> NotesDocument { try NotesDocument.parse(fileText()) }
    func canonical() throws -> String { try read().text }
}

extension FakeMac where Host == OrderedTextHost {
    convenience init(server: FakeCloudServer, text: String? = nil) throws {
        try self.init(transport: server, server: server, text: text)
    }

    convenience init(transport: any CloudTransport, server: FakeCloudServer? = nil, text: String? = nil) throws {
        try self.init(transport: transport, server: server, text: text, fileName: "rules.txt") { OrderedTextHost(documentURL: $0, applied: $1) }
    }
}
