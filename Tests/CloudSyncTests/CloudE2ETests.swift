import Foundation
import Testing
@testable import CloudSync

/// Two fake Macs (separate temp homes, token stores and in-memory preferences) against a real
/// local server (the Worker under wrangler, or the same Worker under celld). Opt-in: set CLOUD_SYNC_E2E=1, CLOUD_SYNC_E2E_INVITE (the local INVITE_SECRET) and optionally
/// CLOUD_SYNC_E2E_SERVER, with the server running locally (`make server-dev` or `make server-local` at the repo root). These tests never start a server.
/// Loopback only: the test refuses any other host, so it can never reach the deployed service.
@Suite("CloudE2E", .enabled(if: ProcessInfo.processInfo.environment["CLOUD_SYNC_E2E"] == "1"), .serialized)
struct CloudE2ETests {
    private let groceries = "groceries"
    private let todo = "todo"
    private let ideas = "ideas"

    /// The first test's namespace.
    private let namespace = "alpha"

    @Test func twoMacsSyncThroughTheLocalServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        let server = try CloudAPI.normalizedServer(environment["CLOUD_SYNC_E2E_SERVER"] ?? "http://127.0.0.1:8787")
        try #require(CloudAPI.isLoopback(server), "CloudE2ETests only talks to a loopback server")
        let invite = try #require(environment["CLOUD_SYNC_E2E_INVITE"], "CLOUD_SYNC_E2E_INVITE (the local INVITE_SECRET) is required")
        let transport = URLSessionCloudTransport()
        let meta = try await CloudAPI(server: server, transport: transport, clientVersion: "1.2.3", namespace: namespace).meta()
        #expect(meta.api == 1)

        // Mac A starts the account from its own file.
        let a = try NotesMac(transport: transport, text: notes([groceries: "milk"]), namespace: namespace)
        let linkedA = try await a.linkCreate(name: "E2E Mac A", invite: invite, serverURL: server)
        #expect(linkedA.rev == 1)
        #expect(try await a.cloud.status().state == .inSync)

        // The live socket opens, and `hello` is still there for the session to read.
        let socket = try await a.cloud.openSocket()
        #expect(try await socket.receive().contains("\"hello\""))
        await socket.close()

        // Mac B pairs; Mac A approves.
        let b = try NotesMac(transport: transport, namespace: namespace)
        let code = LockedBox<String>()
        var request = LinkRequest(server: server, deviceName: "E2E Mac B")
        request.pollInterval = 0.2
        request.timeout = 60
        b.cloud.sleep = { try await Task.sleep(for: .milliseconds(Int($0 * 1000))) }
        let cloudB = b.cloud
        async let linkedB = cloudB.link(request, onCode: { code.value = $0.code })
        while code.value == nil { try await Task.sleep(for: .milliseconds(20)) }
        let name = try await a.cloud.approve(code: code.value!)
        #expect(name == "E2E Mac B")
        let resultB = try await linkedB
        #expect(resultB.adopted == "remote")
        #expect(try b.canonical().contains(groceries))
        #expect(b.machine[groceries] == "milk")
        #expect(try await a.cloud.devices().map(\.name).sorted() == ["E2E Mac A", "E2E Mac B"])

        // A pushes, B pulls.
        try a.write([groceries: "milk", todo: "call Sam"])
        #expect(try await a.cloud.push().rev == 2)
        #expect(try await b.cloud.pull().rev == 2)
        #expect(try b.canonical().contains(todo))

        // Conflicting edits: B edits a different key (merges), then both edit the same one.
        try b.write([groceries: "milk", todo: "call Sam", ideas: "boat"])
        try a.write([groceries: "milk", todo: "call Sam B"])
        #expect(try await a.cloud.push().rev == 3)
        let pushedB = try await b.cloud.push()
        #expect(pushedB.rev == 4)
        #expect(pushedB.conflicts.isEmpty)
        let merged = try b.canonical()
        #expect(merged.contains(ideas) && merged.contains("call Sam B"))

        try b.write([groceries: "oat milk", todo: "call Sam B", ideas: "boat"])
        try a.write([groceries: "soy milk", todo: "call Sam B", ideas: "boat"])
        _ = try await b.cloud.push()
        let conflicted = try await a.cloud.push()
        #expect(conflicted.conflicts.count == 1)
        #expect(try a.canonical().contains("soy milk"))

        // History and revert.
        let history = try await a.cloud.history()
        #expect(history.revisions.first?.rev == conflicted.rev)
        #expect(history.revisions.contains { $0.deviceName == "E2E Mac B" })
        let reverted = try await a.cloud.revert(to: 2)
        #expect(reverted.rev == conflicted.rev + 1)
        #expect(!(try a.canonical()).contains(ideas))
        #expect(try await b.cloud.pull().rev == reverted.rev)
        #expect(!(try b.canonical()).contains(ideas))

        // Revoking B stops it.
        _ = try await a.cloud.revoke("E2E Mac B")
        #expect(try await b.cloud.status().state == .revoked)
        await #expect(throws: CloudError.self) { _ = try await b.cloud.pull() }
        let unlinked = try await a.cloud.unlink()
        #expect(unlinked.revoked)
    }

    @Test func twoNamespacesShareAnAccountButNotADocument() async throws {
        let environment = ProcessInfo.processInfo.environment
        let server = try CloudAPI.normalizedServer(environment["CLOUD_SYNC_E2E_SERVER"] ?? "http://127.0.0.1:8787")
        try #require(CloudAPI.isLoopback(server), "CloudE2ETests only talks to a loopback server")
        let invite = try #require(environment["CLOUD_SYNC_E2E_INVITE"], "CLOUD_SYNC_E2E_INVITE (the local INVITE_SECRET) is required")
        let transport = URLSessionCloudTransport()

        // Mac A links namespace alpha, which creates the account.
        let a = try NotesMac(transport: transport, text: notes([groceries: "milk"]), namespace: "alpha")
        _ = try await a.linkCreate(name: "E2E alpha", invite: invite, serverURL: server)
        let recordA = try #require(try a.link.load())

        // The same Mac links namespace beta into the same account: beta has no devices yet, so alpha's device may approve it.
        let b = try NotesMac(transport: transport, text: notes([todo: "call Sam"]), namespace: "beta")
        let code = LockedBox<String>()
        var request = LinkRequest(server: server, deviceName: "E2E beta", adopt: .local)
        request.pollInterval = 0.2
        request.timeout = 60
        b.cloud.sleep = { try await Task.sleep(for: .milliseconds(Int($0 * 1000))) }
        let cloudB = b.cloud
        async let linkedB = cloudB.link(request, onCode: { code.value = $0.code })
        while code.value == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await a.cloud.approve(code: code.value!) == "E2E beta")
        _ = try await linkedB
        let recordB = try #require(try b.link.load())
        #expect(recordB.accountId == recordA.accountId)

        // Each namespace keeps its own document.
        try a.write([groceries: "oat milk"])
        _ = try await a.cloud.push()
        try b.write([todo: "call Sam", ideas: "boat"])
        _ = try await b.cloud.push()
        #expect(try await a.cloud.status().state == .inSync)
        #expect(try await b.cloud.status().state == .inSync)
        let canonicalA = try a.canonical()
        let canonicalB = try b.canonical()
        #expect(canonicalA.contains("oat milk") && !canonicalA.contains(todo))
        #expect(canonicalB.contains(ideas) && !canonicalB.contains(groceries))

        // The devices list is the whole account, each device naming its app.
        let devices = try await a.cloud.devices(includingOtherApps: true)
        #expect(Set(devices.compactMap(\.namespace)) == ["alpha", "beta"])
        #expect(Set(try await a.cloud.devices().compactMap(\.namespace)) == ["alpha"])

        // beta now has a device, so alpha can no longer approve a third one joining beta.
        let beta = CloudAPI(server: server, transport: transport, clientVersion: "1.2.3", namespace: "beta")
        let third = try await beta.pairStart(deviceName: "E2E beta third")
        do {
            _ = try await a.cloud.approve(code: third.code)
            Issue.record("alpha approved a device joining beta")
        } catch {
            guard case CloudError.namespaceMismatch = error else {
                Issue.record("expected namespaceMismatch, got \(error)")
                return
            }
        }

        // alpha's token gets the new error on beta's routes.
        let token = try #require(try a.tokens.token(for: recordA.deviceId))
        let crossed = CloudAPI(server: server, transport: transport, clientVersion: "1.2.3", namespace: "beta", token: token)
        do {
            _ = try await crossed.doc()
            Issue.record("alpha's token read beta's document")
        } catch {
            guard case CloudError.namespaceMismatch = error else {
                Issue.record("expected namespaceMismatch, got \(error)")
                return
            }
        }

        _ = try await a.cloud.unlink()
        _ = try await b.cloud.unlink()
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
