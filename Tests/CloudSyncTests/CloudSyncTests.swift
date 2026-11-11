import Foundation
import Testing
@testable import CloudSync

private let groceries = "groceries"
private let todo = "todo"
private let ideas = "ideas"

@Suite("CloudSync")
struct CloudSyncTests {
    @Test func linkingAnEmptyAccountPushesRev1() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        let result = try await mac.linkCreate()
        #expect(result.outcome == .linked)
        #expect(result.adopted == "local")
        #expect(result.rev == 1)
        #expect(server.headRev == 1)
        #expect(try mac.link.load()?.lastRev == 1)
        #expect(try await mac.cloud.status().state == .inSync)
        // The token went to the token store, never into sync.json.
        let record = try #require(try mac.link.load())
        #expect(try mac.tokens.token(for: record.deviceId) != nil)
        #expect(!(try String(contentsOf: mac.link.recordURL, encoding: .utf8)).contains("secret"))
    }

    @Test func linkingAnEmptyAccountWithNoNotesPushesNothing() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server)
        let result = try await mac.linkCreate()
        #expect(result.adopted == "none")
        #expect(server.headRev == 0)
    }

    @Test func adoptRemoteBacksUpWritesThenAppliesOnce() async throws {
        let server = FakeCloudServer()
        server.writeAsOtherDevice([todo: "call Sam"])
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        let asked = Box<LinkPreview<NotesHost>>()
        var request = LinkRequest(server: NotesMac.url, deviceName: "Mac B", invite: server.invite, adopt: .remote)
        request.pollInterval = 0
        let result = try await mac.cloud.link(request, confirm: { preview in asked.value = preview; return true })

        #expect(asked.value?.changes.isEmpty == false)
        #expect(asked.value?.report?.preview == true)
        let backup = try #require(result.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8).contains(groceries))
        #expect(!(try mac.canonical()).contains(groceries))
        #expect(try mac.canonical().contains(todo))
        #expect(result.report?.values == [todo: "call Sam"])
        #expect(mac.machine == [todo: "call Sam"])
        #expect(mac.applied.applyCount == 1)
        #expect(result.rev == 1)
        #expect(try await mac.cloud.status(offline: true).localChanges == false)
    }

    @Test func adoptRemoteCanBeDeclined() async throws {
        let server = FakeCloudServer()
        server.writeAsOtherDevice([todo: "call Sam"])
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        let before = try mac.fileText()
        var request = LinkRequest(server: NotesMac.url, deviceName: "Mac B", invite: server.invite)
        request.pollInterval = 0
        await #expect(throws: CloudError.self) {
            _ = try await mac.cloud.link(request, confirm: { _ in throw CloudError.refused("no terminal") })
        }
        #expect(try mac.fileText() == before)
        #expect(mac.applied.applyCount == 0)
        // Linked all the same.
        #expect(try mac.link.load() != nil)
    }

    @Test func adoptLocalUploadsThisMacsFile() async throws {
        let server = FakeCloudServer()
        server.writeAsOtherDevice([todo: "call Sam"])
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        let result = try await mac.linkCreate(adopt: .local)
        #expect(result.rev == 2)
        #expect(server.body(of: 2)?.contains(groceries) == true)
        #expect(server.body(of: 2)?.contains(todo) == false)
    }

    @Test func adoptMergeUnionsAndTheSyncedValueWins() async throws {
        let server = FakeCloudServer()
        server.writeAsOtherDevice([groceries: "oat milk"])
        let mac = try NotesMac(server: server, text: notes([groceries: "milk", ideas: "boat"] .merging([todo: "call Sam"]) { $1 }))
        let result = try await mac.linkCreate(adopt: .merge)
        let merged = try mac.canonical()
        #expect(merged.contains("oat milk"))
        #expect(merged.contains(ideas))
        #expect(merged.contains(todo))
        #expect(result.rev == 2)
        #expect(server.body(of: 2) == merged)
    }

    @Test func linkingTwiceIsANoOp() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        let requests = server.requests.count
        let again = try await mac.linkCreate()
        #expect(again.outcome == .alreadyLinked)
        #expect(server.requests.count == requests)
        await #expect(throws: CloudError.self) {
            var other = LinkRequest(server: URL(string: "https://elsewhere.example")!, deviceName: "x", invite: "y")
            other.pollInterval = 0
            _ = try await mac.cloud.link(other)
        }
    }

    @Test func aBadInviteIsRefused() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server)
        await #expect(throws: CloudError.invalidInvite) {
            _ = try await mac.cloud.link(LinkRequest(server: NotesMac.url, deviceName: "x", invite: "wrong"))
        }
        #expect(try mac.link.load() == nil)
    }

    @Test func plainHttpToARemoteHostIsRefused() async throws {
        let mac = try NotesMac(server: FakeCloudServer())
        await #expect(throws: CloudError.self) {
            _ = try await mac.cloud.link(LinkRequest(server: URL(string: "http://example.com")!, deviceName: "x", invite: "y"))
        }
        #expect(throws: CloudError.self) { _ = try CloudAPI.normalizedServer("http://example.com") }
        #expect(try CloudAPI.normalizedServer("https://sync.example.com/").absoluteString == "https://sync.example.com")
        #expect(try CloudAPI.normalizedServer("http://localhost:8787").host == "localhost")
    }

    @Test func linkDryRunContactsNothing() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server)
        var request = LinkRequest(server: NotesMac.url, deviceName: "x", invite: server.invite)
        request.dryRun = true
        let result = try await mac.cloud.link(request)
        #expect(result.outcome == .dryRun)
        #expect(server.requests.isEmpty)
        #expect(try mac.link.load() == nil)
    }

    // MARK: - Pairing

    @Test func pairingANewMacEndToEnd() async throws {
        let server = FakeCloudServer()
        let a = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await a.linkCreate()
        let b = try NotesMac(server: server)
        let code = Box<String>()
        var request = LinkRequest(server: NotesMac.url, deviceName: "Mac mini")
        request.pollInterval = 0.001
        request.timeout = 60
        b.cloud.sleep = { try await Task.sleep(for: .milliseconds(2)); _ = $0 }
        let cloud = b.cloud
        async let linked = cloud.link(request, onCode: { code.value = $0.code }, confirm: { _ in true })
        while code.value == nil { await Task.yield() }
        let shown = Box<String>()
        let name = try await a.cloud.approve(code: code.value!, confirm: { shown.value = $0; return true })
        #expect(name == "Mac mini")
        #expect(shown.value == "Mac mini")
        let result = try await linked
        #expect(result.adopted == "remote")
        #expect(try b.canonical().contains(groceries))
        #expect(b.machine[groceries] == "milk")
        #expect(server.deviceNames == ["Mac A", "Mac mini"])
    }

    @Test func pairingTimesOutWhenNobodyApproves() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server)
        var request = LinkRequest(server: NotesMac.url, deviceName: "Mac mini")
        request.pollInterval = 10
        request.timeout = 30
        await #expect(throws: CloudError.approvalTimedOut) { _ = try await mac.cloud.link(request) }
        #expect(try mac.link.load() == nil)
        #expect(server.count("POST", "/v1/pair/poll") == 3)
    }

    @Test func approvingAWrongCodeIsRejected() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server)
        _ = try await mac.linkCreate()
        await #expect(throws: CloudError.invalidCode) { _ = try await mac.cloud.approve(code: "AAAA-AAAA") }
    }

    @Test func approvalCanBeDeclined() async throws {
        let server = FakeCloudServer()
        let a = try NotesMac(server: server)
        _ = try await a.linkCreate()
        let start = try await CloudAPI(server: NotesMac.url, transport: server, clientVersion: "x", namespace: "app").pairStart(deviceName: "Intruder")
        await #expect(throws: CloudError.self) { _ = try await a.cloud.approve(code: start.code, confirm: { _ in false }) }
        #expect(server.count("POST", "/v1/pair/approve") == 1)
    }

    // MARK: - Push

    @Test func aPushWithAnUnchangedFileSendsNothing() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        let puts = server.count("PUT", "/v1/doc")
        let result = try await mac.cloud.push()
        #expect(result.outcome == .nothingToPush)
        #expect(server.count("PUT", "/v1/doc") == puts)
    }

    @Test func aLocalEditIsPushedWithAReadableSummary() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        try mac.write([groceries: "milk", todo: "call Sam"])
        #expect(try await mac.cloud.status(offline: true).state == .localChanges)
        let result = try await mac.cloud.push()
        #expect(result.outcome == .pushed)
        #expect(result.rev == 2)
        let last = server.requests.last { $0.method == "PUT" }
        #expect(last?.header("If-Match") == "1")
        #expect(last?.header("Sync-Client") == "1.2.3")
        let page = try await mac.cloud.history()
        #expect(page.revisions.first?.summary == "+todo")
        #expect(try await mac.cloud.status().state == .inSync)
    }

    @Test func aVersionShowsWhatItChanged() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        try mac.write([groceries: "milk", todo: "call Sam"])
        _ = try await mac.cloud.push()

        let first = try #require(try await mac.cloud.changesMade(in: 1))
        #expect(first == [NotesHost.Change(kind: .added, key: groceries)])
        let second = try #require(try await mac.cloud.changesMade(in: 2))
        #expect(second == [NotesHost.Change(kind: .added, key: todo)])
    }

    @Test func aStalePushMergesAndRetriesWithTheNewIfMatch() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([groceries: "milk", ideas: "boat"], name: "Mac mini")
        try mac.write([groceries: "milk", todo: "call Sam"])

        let result = try await mac.cloud.push()
        #expect(result.outcome == .pushed)
        #expect(result.rev == 3)
        #expect(result.conflicts.isEmpty)
        #expect(result.remoteDevice == "Mac mini")
        let puts = server.requests.filter { $0.method == "PUT" }
        #expect(puts.map { $0.header("If-Match") } == ["0", "1", "2"])
        let merged = try mac.canonical()
        #expect(merged.contains(ideas) && merged.contains(todo))
        #expect(server.body(of: 3) == merged)
        // The remote change reached this Mac through the host's apply.
        #expect(result.report?.values == [groceries: "milk", ideas: "boat", todo: "call Sam"])
        #expect(mac.machine[ideas] == "boat")
        #expect(mac.applied.applyCount == 1)
    }

    @Test func aConflictingPushKeepsLocalAndReportsIt() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([groceries: "oat milk"], name: "Mac mini")
        try mac.write([groceries: "soy milk"])
        let result = try await mac.cloud.push()
        #expect(result.conflicts == [NotesHost.Conflict(key: groceries, local: "soy milk", remote: "oat milk", tookRemote: false)])
        #expect(result.remoteDevice == "Mac mini")
        #expect(try mac.canonical().contains("soy milk"))
        #expect(server.headRev == 3)
        // The overwritten value is still in history.
        #expect(server.body(of: 2)?.contains("oat milk") == true)
    }

    @Test func aPushAgainstAnInvalidRemoteFallsBackToItAndBacksUp() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        // Another Mac's document holds a key this build rejects, so merging it with ours is invalid.
        server.writeAsOtherDevice([groceries: "milk", "bad": "x"])
        try mac.write([groceries: "milk", todo: "call Sam"])
        let local = try mac.fileText()
        let result = try await mac.cloud.push()
        #expect(result.fellBackToRemote)
        #expect(result.outcome == .mergedWithRemote)
        #expect(server.headRev == 2, "nothing was uploaded over the remote")
        let backup = try #require(result.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == local)
        #expect(try mac.canonical() == notes([groceries: "milk", "bad": "x"]))
    }

    @Test func anOfflineEditIsJustAFileThatDiffersFromBase() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.offline = true
        try mac.write([groceries: "oat milk"])
        await #expect(throws: CloudError.self) { _ = try await mac.cloud.push() }
        #expect(try await mac.cloud.status().state == .offline)
        #expect(try await mac.cloud.status(offline: true).localChanges)
        server.offline = false
        let result = try await mac.cloud.push()
        #expect(result.outcome == .pushed)
        #expect(server.headRev == 2)
    }

    @Test func anInvalidLocalFileIsNeverPushed() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()

        try mac.write("this line has no equals sign")
        await #expect(throws: CloudError.self) { _ = try await mac.cloud.push() }
        #expect(try await mac.cloud.status().state == .waitingForValidFile)

        try mac.write(["bad": "1"])
        await #expect(throws: CloudError.invalidLocalConfig(["the key 'bad' is not allowed"])) { _ = try await mac.cloud.push() }
        #expect(server.count("PUT", "/v1/doc") == 1)
    }

    @Test func aRemoteChangeIsHeldWhileTheFileIsInvalid() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([groceries: "milk", ideas: "boat"])
        let broken = "oops: not valid"
        try mac.write(broken)
        await #expect(throws: CloudError.waitingForValidFile("line 1 is not 'key = value'")) { _ = try await mac.cloud.pull() }
        #expect(try mac.fileText() == broken)
    }

    // MARK: - Pull

    @Test func pullingAppliesThroughTheHostAndLeavesNoEcho() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([groceries: "milk", ideas: "boat"], name: "Mac mini")
        #expect(try await mac.cloud.status().state == .remoteChanges)

        let result = try await mac.cloud.pull()
        #expect(result.outcome == .pulled)
        #expect(result.rev == 2)
        #expect(result.remoteDevice == "Mac mini")
        #expect(mac.machine[ideas] == "boat")
        #expect(mac.applied.mayPromptCalls == [true])
        // Writing the remote change and re-reading says "no local changes": no echo push.
        let status = try await mac.cloud.status()
        #expect(status.state == .inSync)
        #expect(!status.localChanges)
        let puts = server.count("PUT", "/v1/doc")
        #expect(try await mac.cloud.push().outcome == .nothingToPush)
        #expect(server.count("PUT", "/v1/doc") == puts)
        #expect(try await mac.cloud.pull().outcome == .upToDate)
    }

    @Test func pullNoApplyWritesTheFileButNotTheMac() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([ideas: "boat"])
        let result = try await mac.cloud.pull(apply: false)
        #expect(result.report == nil)
        #expect(try mac.canonical().contains(ideas))
        #expect(mac.machine.isEmpty)
        #expect(mac.applied.applyCount == 0)
    }

    @Test func pullPassesMayPromptToTheHost() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([ideas: "boat"])
        _ = try await mac.cloud.pull(mayPrompt: false)
        #expect(mac.applied.mayPromptCalls == [false])
    }

    @Test func pullDryRunChangesNothing() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([ideas: "boat"])
        let before = try mac.fileText()
        let result = try await mac.cloud.pull(dryRun: true)
        #expect(result.outcome == .dryRun)
        #expect(!result.changes.isEmpty)
        #expect(try mac.fileText() == before)
        #expect(try mac.link.load()?.lastRev == 1)
        #expect(mac.applied.applyCount == 0)
    }

    @Test func pullMergesWithLocalEdits() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([groceries: "milk", ideas: "boat"])
        try mac.write([groceries: "milk", todo: "call Sam"])
        let result = try await mac.cloud.pull(apply: false)
        #expect(result.localChanges)
        let merged = try mac.canonical()
        #expect(merged.contains(ideas) && merged.contains(todo))
        // The local edit is still pending, and pushes next.
        #expect(try await mac.cloud.status(offline: true).state == .localChanges)
        #expect(try await mac.cloud.push(apply: false).outcome == .pushed)
        #expect(server.body(of: 3) == merged)
    }

    @Test func aPullWhoseMergeIsInvalidTakesTheRemoteAndBacksUpTheLocalFile() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([groceries: "milk", ideas: "boat"])
        // A local edit that is readable but invalid; merged with the remote it stays invalid.
        let local = notes([groceries: "milk", "bad": "1"])
        try mac.write(local)
        let result = try await mac.cloud.pull(apply: false)
        #expect(result.fellBackToRemote)
        #expect(!result.localChanges)
        let backup = try #require(result.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == local)
        #expect(try mac.canonical() == notes([groceries: "milk", ideas: "boat"]))
        #expect(try await mac.cloud.status(offline: true).localChanges == false)
    }

    @Test func aNewerSchemaIsRefusedAndTheFileUntouched() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        let future = SyncDocument(format: "app-text", schema: 2, body: "version: 2\n")
        server.writeRaw(future)
        let before = try mac.fileText()
        await #expect(throws: CloudError.document(.schemaTooNew(2))) { _ = try await mac.cloud.pull() }
        #expect(try mac.fileText() == before)
        #expect(mac.applied.applyCount == 0)
    }

    @Test func aDocumentInAnotherFormatIsRefused() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeRaw(SyncDocument(format: "other-app", schema: 1, body: "version: 1\n"))
        await #expect(throws: CloudError.document(.unknownFormat("other-app"))) { _ = try await mac.cloud.pull() }
    }

    // MARK: - Failure states

    @Test func aRevokedTokenIsRevokedAndNotRetried() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.forcedStatus = 401
        let before = server.requests.count
        #expect(try await mac.cloud.status().state == .revoked)
        #expect(server.requests.count == before + 1)
        await #expect(throws: (any Error).self) { _ = try await mac.cloud.pull() }
        #expect(server.requests.count == before + 2)
        do { _ = try await mac.cloud.pull() } catch let error as CloudError {
            guard case .unauthorized = error else { Issue.record("expected unauthorized, got \(error)"); return }
        }
    }

    @Test func paymentRequiredAndUpgradeRequiredAreStatesNotRetries() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.forcedStatus = 402
        #expect(try await mac.cloud.status().state == .paymentRequired)
        await #expect(throws: CloudError.paymentRequired) { _ = try await mac.cloud.pull() }
        server.forcedStatus = 426
        #expect(try await mac.cloud.status().state == .upgradeRequired)
        do { _ = try await mac.cloud.pull() } catch let error as CloudError {
            guard case .upgradeRequired = error else { Issue.record("expected upgradeRequired, got \(error)"); return }
        }
    }

    @Test func aDisabledLinkDoesNothing() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        _ = try mac.cloud.setEnabled(false)
        let before = server.requests.count
        #expect(try await mac.cloud.status().state == .disabled)
        await #expect(throws: CloudError.disabled) { _ = try await mac.cloud.pull() }
        await #expect(throws: CloudError.disabled) { _ = try await mac.cloud.push() }
        #expect(server.requests.count == before)
        _ = try mac.cloud.setEnabled(true)
        #expect(try await mac.cloud.status().state == .inSync)
    }

    @Test func notLinkedIsAStateAndOperationsRefuse() async throws {
        let mac = try NotesMac(server: FakeCloudServer())
        #expect(try await mac.cloud.status().state == .notLinked)
        await #expect(throws: CloudError.notLinked) { _ = try await mac.cloud.pull() }
        let result = try await mac.cloud.unlink()
        #expect(result.outcome == "notLinked")
    }

    // MARK: - Moved file

    @Test func aMovedFileBlocksPushAndPullDoesNotMergeIntoIt() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        let other = mac.directory.appending(path: "elsewhere.txt")
        try notes([todo: "call Sam"]).write(to: other, atomically: true, encoding: .utf8)
        mac.cloud.host.documentURL = other

        #expect(try await mac.cloud.status().state == .configMoved)
        let puts = server.count("PUT", "/v1/doc")
        await #expect(throws: CloudError.configMoved(linked: mac.fileURL.path, current: other.path)) { _ = try await mac.cloud.push() }
        #expect(server.count("PUT", "/v1/doc") == puts)
        // "Use the synced notes": the remote replaces the other file (backed up) and the link follows it.
        server.writeAsOtherDevice([ideas: "boat"])
        let pulled = try await mac.cloud.pull(apply: false)
        #expect(pulled.backup != nil)
        #expect(try String(contentsOf: other, encoding: .utf8).contains(ideas))
        #expect(!(try String(contentsOf: other, encoding: .utf8)).contains(todo))
        #expect(try await mac.cloud.status().state == .inSync)
    }

    @Test func forcePushUploadsTheMovedFile() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        let other = mac.directory.appending(path: "elsewhere.txt")
        try notes([todo: "call Sam"]).write(to: other, atomically: true, encoding: .utf8)
        mac.cloud.host.documentURL = other
        let result = try await mac.cloud.push(force: true)
        #expect(result.outcome == .pushed)
        #expect(server.body(of: 2)?.contains(todo) == true)
        #expect(try await mac.cloud.status().state == .inSync)
    }

    // MARK: - History and revert

    private func twoRevisions() async throws -> (FakeCloudServer, NotesMac) {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        try mac.write([groceries: "milk", todo: "call Sam"])
        _ = try await mac.cloud.push()
        return (server, mac)
    }

    @Test func revertDryRunMakesNoWrite() async throws {
        let (server, mac) = try await twoRevisions()
        let before = try mac.fileText()
        let result = try await mac.cloud.revert(to: 1, dryRun: true)
        #expect(result.outcome == .dryRun)
        #expect(result.rev == 3)
        #expect(result.revertedTo == 1)
        #expect(result.changes.count == 1)
        #expect(server.count("POST", "/v1/revert") == 0)
        #expect(server.count("PUT", "/v1/doc") == 2)
        #expect(server.headRev == 2)
        #expect(try mac.fileText() == before)
    }

    @Test func revertCreatesANewRevisionAndWritesTheFile() async throws {
        let (server, mac) = try await twoRevisions()
        let result = try await mac.cloud.revert(to: 1, apply: false)
        #expect(result.outcome == .reverted)
        #expect(result.rev == 3)
        #expect(server.headRev == 3)
        #expect(server.body(of: 3) == server.body(of: 1))
        #expect(!(try mac.canonical()).contains(todo))
        let page = try await mac.cloud.history()
        #expect(page.revisions.first?.kind == .revert)
        #expect(page.revisions.first?.revertedTo == 1)
        #expect(page.revisions.first?.summary == "Reverted to rev 1: -todo")
        #expect(try await mac.cloud.status().state == .inSync)
    }

    @Test func revertingToRevisionZeroIsRefused() async throws {
        let (_, mac) = try await twoRevisions()
        await #expect(throws: CloudError.self) { _ = try await mac.cloud.revert(to: 0) }
    }

    @Test func historyShowDiffsFromTheCurrentDocument() async throws {
        let (_, mac) = try await twoRevisions()
        let shown = try await mac.cloud.revisionDiff(1)
        #expect(shown.changes == [NotesHost.Change(kind: .removed, key: todo)])
    }

    // MARK: - Unlink and devices

    @Test func unlinkingOfflineStillUnlinksLocally() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        let record = try #require(try mac.link.load())
        let before = try mac.fileText()
        server.offline = true
        let result = try await mac.cloud.unlink()
        #expect(result.outcome == "unlinked")
        #expect(!result.revoked)
        #expect(result.notes.first?.contains("revoke") == true)
        #expect(try mac.link.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: mac.linkDirectory.path))
        #expect(try mac.tokens.token(for: record.deviceId) == nil)
        #expect(try mac.fileText() == before)
    }

    @Test func unlinkingRevokesTheDevice() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server)
        _ = try await mac.linkCreate()
        let result = try await mac.cloud.unlink()
        #expect(result.revoked)
        #expect(server.deviceNames.isEmpty)
    }

    @Test func revokingOnlySeesThisAppsDevices() async throws {
        let server = FakeCloudServer()
        let a = try NotesMac(server: server)
        _ = try await a.linkCreate()
        // One Mac linked in two apps has the same name in both.
        server.addDevice("Mac mini", namespace: a.cloud.host.namespace)
        server.addDevice("Mac mini", namespace: "other-app")
        server.addDevice("Only elsewhere", namespace: "other-app")

        await #expect(throws: CloudError.self) { _ = try await a.cloud.revoke("Only elsewhere") }
        let revoked = try await a.cloud.revoke("Mac mini")
        #expect(revoked.namespace == a.cloud.host.namespace)
    }

    @Test func devicesDefaultToThisAppsAndCanIncludeOtherApps() async throws {
        let server = FakeCloudServer()
        let a = try NotesMac(server: server)
        _ = try await a.linkCreate()
        server.addDevice("Mac mini", namespace: "other-app")

        let own = try await a.cloud.devices()
        #expect(own.allSatisfy { $0.namespace == a.cloud.host.namespace })
        #expect(!own.contains { $0.name == "Mac mini" })
        let all = try await a.cloud.devices(includingOtherApps: true)
        #expect(all.first { $0.name == "Mac mini" }?.namespace == "other-app")
        #expect(all.count == own.count + 1)
    }

    @Test func listingAndRevokingDevices() async throws {
        let server = FakeCloudServer()
        let a = try NotesMac(server: server)
        _ = try await a.linkCreate()
        let code = Box<String>()
        let b = try NotesMac(server: server)
        var request = LinkRequest(server: NotesMac.url, deviceName: "Mac mini")
        request.pollInterval = 0.001
        request.timeout = 60
        b.cloud.sleep = { _ in try await Task.sleep(for: .milliseconds(2)) }
        let cloud = b.cloud
        async let linked = cloud.link(request, onCode: { code.value = $0.code })
        while code.value == nil { await Task.yield() }
        _ = try await a.cloud.approve(code: code.value!)
        _ = try await linked

        let devices = try await a.cloud.devices()
        #expect(devices.map(\.name) == ["Mac A", "Mac mini"])
        #expect(devices.first { $0.current }?.name == "Mac A")
        await #expect(throws: CloudError.self) { _ = try await a.cloud.revoke("Mac A") }
        await #expect(throws: CloudError.self) { _ = try await a.cloud.revoke("nobody") }
        let revoked = try await a.cloud.revoke("mac MINI")
        #expect(revoked.name == "Mac mini")
        #expect(try await b.cloud.status().state == .revoked)
    }
}

@Suite("CloudSync locking")
struct CloudSyncLockingTests {
    @Test func aPushWaitsForTheLinksLockAndThenRuns() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        try mac.write([groceries: "oat milk"])
        let before = server.requests.count

        // Another process (the CLI, say) holds the lock.
        let descriptor = open(mac.link.lockURL.path, O_CREAT | O_RDWR, 0o644)
        #expect(flock(descriptor, LOCK_EX) == 0)
        let cloud = mac.cloud
        let push = Task { try await cloud.push(apply: false) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(server.requests.count == before, "nothing is sent while another process holds the lock")

        flock(descriptor, LOCK_UN)
        close(descriptor)
        let result = try await push.value
        #expect(result.outcome == .pushed)
        #expect(server.headRev == 2)
    }

    @Test func aPullAndAPushInOneProcessRunOneAtATime() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes([groceries: "milk"]))
        _ = try await mac.linkCreate()
        server.writeAsOtherDevice([groceries: "milk", ideas: "boat"])
        try mac.write([groceries: "milk", todo: "call Sam"])
        let cloud = mac.cloud
        async let pulled = cloud.pull(apply: false)
        async let pushed = cloud.push(apply: false)
        _ = try await (pulled, pushed)
        // However they interleave, both edits end up everywhere and the base matches the server.
        let head = try #require(server.body(of: server.headRev))
        #expect(head.contains(ideas) && head.contains(todo))
        #expect(try mac.canonical().contains(ideas) && mac.canonical().contains(todo))
        #expect(try mac.link.load()?.lastRev == server.headRev)
    }
}
