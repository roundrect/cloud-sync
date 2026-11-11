import Foundation
import Testing
@testable import CloudSync

@Suite("Namespaces")
struct NamespaceTests {
    private let base = URL(string: "http://127.0.0.1:8787")!

    private func api(_ namespace: String, token: String? = "tok") -> CloudAPI {
        CloudAPI(server: base, transport: FakeCloudServer(), clientVersion: "1", namespace: namespace, token: token)
    }

    /// Every endpoint's request, by name, so each is checked under its namespace.
    private func paths(_ api: CloudAPI) async -> [String: String] {
        let server = FakeCloudServer()
        let api = CloudAPI(server: base, transport: server, clientVersion: "1", namespace: api.namespace, token: "tok")
        let start = PairingStart(pairingId: "p", code: "c", pollSecret: "s", expiresIn: 1)
        _ = try? await api.meta()
        _ = try? await api.createAccount(invite: "i", deviceName: "d")
        _ = try? await api.pairStart(deviceName: "d")
        _ = try? await api.pairPoll(start)
        _ = try? await api.pairApprove(code: "c", confirm: false)
        _ = try? await api.doc()
        _ = try? await api.put(SyncDocument(format: "f", schema: 1, body: "b"), ifMatch: 0)
        _ = try? await api.history()
        _ = try? await api.revision(3)
        _ = try? await api.revert(to: 1, ifMatch: 2, summary: "s")
        _ = try? await api.devices()
        _ = try? await api.revoke(deviceID: "dev_1")
        var result: [String: String] = [:]
        for request in server.requests { result[request.method + " " + request.url.path] = request.url.path }
        return result
    }

    private let routes = ["GET meta", "POST accounts", "POST pair/start", "POST pair/poll", "POST pair/approve", "GET doc", "PUT doc",
                          "GET history", "GET history/3", "POST revert", "GET devices", "DELETE devices/dev_1"]

    @Test func namedRoutesGoUnderTheNamespace() async {
        let seen = Set(await paths(api("alpha-2")).keys)
        #expect(seen == Set(routes.map { route in
            let parts = route.split(separator: " ", maxSplits: 1)
            return "\(parts[0]) /v1/ns/alpha-2/\(parts[1])"
        }))
    }

    @Test func theSocketRequestFollowsTheNamespace() throws {
        #expect(try api("alpha").socketRequest().url.path == "/v1/ns/alpha/ws")
        #expect(try api("alpha").socketRequest().header("Authorization") == "Bearer tok")
    }

    @Test(arguments: ["a", "alpha", "a-b-9", String(repeating: "a", count: 32)])
    func goodSlugsAreAccepted(slug: String) {
        #expect(CloudAPI.isValidNamespace(slug))
    }

    @Test(arguments: ["", "Alpha", "1abc", "-a", "a_b", "a:b", "a/b", "../x", "a b", "ä", String(repeating: "a", count: 33)])
    func malformedSlugsAreRefusedBeforeAnythingIsSent(slug: String) async {
        #expect(!CloudAPI.isValidNamespace(slug))
        let server = FakeCloudServer()
        let api = CloudAPI(server: base, transport: server, clientVersion: "1", namespace: slug, token: "t")
        await #expect(throws: CloudError.self) { _ = try await api.doc() }
        await #expect(throws: CloudError.self) { _ = try await api.meta() }
        #expect(throws: CloudError.self) { _ = try api.socketRequest() }
        #expect(server.requests.isEmpty)
    }

    @Test func theClientPassesTheHostsNamespaceToTheServer() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes(["a": "1"]), namespace: "alpha")
        _ = try await mac.linkCreate()
        _ = try await mac.cloud.status()
        #expect(server.requests.allSatisfy { $0.url.path.hasPrefix("/v1/ns/alpha/") })
        #expect(server.count("GET", "/v1/doc") > 0)
    }

    // MARK: - Decoding

    @Test func deviceInfoCarriesItsNamespace() throws {
        let decoder = CloudJSON.makeDecoder()
        let json = Data(#"{"id":"d","name":"n","createdAt":"2026-01-01T00:00:00.000Z","current":false,"namespace":"alpha"}"#.utf8)
        let device = try decoder.decode(DeviceInfo.self, from: json)
        #expect(device.namespace == "alpha")
        #expect(device.current == false)
    }

    @Test func metaIsTheApiVersionAndTheMinimum() throws {
        let meta = try CloudJSON.makeDecoder().decode(CloudAPI.Meta.self, from: Data(#"{"api":1,"minClient":"1.0.0"}"#.utf8))
        #expect(meta == CloudAPI.Meta(api: 1, minClient: "1.0.0"))
    }

    // MARK: - No routes without a namespace

    @Test func theFakeServerAnswersNoRouteWithoutANamespace() async throws {
        let server = FakeCloudServer()
        let request = CloudRequest(method: "GET", url: base.appending(path: "v1/doc"))
        let response = try await server.send(request)
        #expect(response.status == 404)
    }

    // MARK: - The 403

    @Test func theMismatchMessageIsPlain() {
        let message = CloudError.namespaceMismatch("not yours").message(.neutral)
        #expect(message.contains("not yours"))
        #expect(CloudError.namespaceMismatch("x").description == CloudError.namespaceMismatch("x").message(.neutral))
    }

    @Test func aFakeServerRefusesAnotherNamespacesToken() async throws {
        let server = FakeCloudServer()
        let a = try NotesMac(server: server, text: notes(["a": "1"]), namespace: "alpha")
        _ = try await a.linkCreate()
        let record = try #require(try a.link.load())
        let token = try #require(try a.tokens.token(for: record.deviceId))
        let wrong = CloudAPI(server: base, transport: server, clientVersion: "1", namespace: "beta", token: token)
        await #expect(throws: CloudError.namespaceMismatch("this token is for another app")) { _ = try await wrong.doc() }
    }

    @Test func statusReportsAMismatchWithoutRetrying() async throws {
        let server = FakeCloudServer()
        let a = try NotesMac(server: server, text: notes(["a": "1"]), namespace: "alpha")
        _ = try await a.linkCreate()
        server.forcedStatus = 403
        let status = try await a.cloud.status()
        #expect(status.state == .revoked)
        #expect(status.detail?.contains("different app") == true)
    }

    // MARK: - sync.json

    @Test func aSavedRecordKeepsItsKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-ns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = """
        {"version":1,"server":"https://x.example","accountId":"acc_1","deviceId":"dev_1","deviceName":"Mac",
         "linkedConfigPath":"/tmp/c.txt","lastRev":7,"lastSyncedAt":"2026-01-01T00:00:00.000Z","enabled":true}
        """
        let link = SyncLink(directory: directory)
        try old.write(to: link.recordURL, atomically: true, encoding: .utf8)
        let loaded = try #require(try link.load())
        #expect(loaded.lastRev == 7)
        #expect(loaded.linkedConfigPath == "/tmp/c.txt")

        try link.save(loaded)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: link.recordURL)) as? [String: Any])
        #expect(Set(saved.keys) == ["version", "server", "accountId", "deviceId", "deviceName", "linkedConfigPath", "lastRev", "lastSyncedAt", "enabled"])
    }
}
