import Foundation
import Testing
@testable import CloudSync

@Suite("Wording")
struct WordingTests {
    private let withCommand = SyncWording(appName: "Notes", documentName: "notes", fileName: "notes file", commandName: "notes")
    private let withoutCommand = SyncWording(appName: "Notes", documentName: "notes", fileName: "notes file")

    private let everyCloudError: [CloudError] = [
        .offline("no route"), .unauthorized("gone"), .invalidInvite, .paymentRequired, .upgradeRequired("min 2.0"),
        .conflict(RemoteDoc(rev: 3)), .rateLimited("slow down"), .notFound("no such"), .invalidCode,
        .server(status: 500, message: "boom"), .insecureServer("use https"), .document(.schemaTooNew(2)),
        .notLinked, .disabled, .configMoved(linked: "/a/one", current: "/b/two"), .waitingForValidFile("line 3"),
        .invalidLocalConfig(["first problem", "second problem"]), .approvalTimedOut, .approvalExpired,
        .refused("declined"), .local("disk"), .namespaceMismatch("wrong app"),
    ]

    private let everyDocumentError: [SyncDocumentError] = [
        .unknownFormat("other-format"), .schemaTooNew(2), .checksumMismatch, .unparseable("line 2"),
    ]

    private func mentionsAnApp(_ text: String) -> Bool {
        ["short" + "y", "sw" + "url", "short" + "cut"].contains { text.lowercased().contains($0) }
    }

    // MARK: - Neutral

    @Test func descriptionIsTheNeutralMessage() {
        for error in everyCloudError { #expect(error.description == error.message(.neutral)) }
        for error in everyDocumentError { #expect(error.description == error.message(.neutral)) }
    }

    @Test func neutralWordingUsesGenericWordsAndNoCommand() {
        #expect(SyncWording.neutral.commandName == nil)
        #expect(CloudError.upgradeRequired("min 2.0").message(.neutral) == "Update this app to keep syncing (min 2.0)")
        #expect(CloudError.conflict(RemoteDoc(rev: 3)).message(.neutral) == "the synced settings changed on another Mac; try again")
        #expect(CloudError.waitingForValidFile("line 3").message(.neutral) == "waiting: fix the settings file first (line 3)")
        #expect(CloudError.notLinked.message(.neutral) == "this Mac isn't linked to sync")
        #expect(CloudError.disabled.message(.neutral) == "sync is switched off on this Mac")
        #expect(SyncDocumentError.schemaTooNew(2).message(.neutral) == "This Mac's copy of this app is too old for the synced settings — update")
        #expect(SyncDocumentError.checksumMismatch.message(.neutral) == "the synced settings were damaged in transit (checksum mismatch)")
    }

    @Test func nothingNamesAnAppUnlessTheHostSaidSo() {
        for wording in [SyncWording.neutral, withCommand, withoutCommand] {
            for error in everyCloudError { #expect(!mentionsAnApp(error.message(wording)), "\(error)") }
            for error in everyDocumentError { #expect(!mentionsAnApp(error.message(wording)), "\(error)") }
        }
    }

    // MARK: - The host's words

    @Test func theHostsWordsReplaceTheNeutralOnes() {
        #expect(CloudError.upgradeRequired("min 2.0").message(withCommand) == "Update Notes to keep syncing (min 2.0)")
        #expect(CloudError.conflict(RemoteDoc(rev: 3)).message(withCommand) == "the synced notes changed on another Mac; try again")
        #expect(CloudError.waitingForValidFile("line 3").message(withCommand) == "waiting: fix the notes file first (line 3)")
        #expect(CloudError.invalidLocalConfig(["a", "b"]).message(withCommand) == "the notes file has errors, so it was not uploaded:\na\nb")
        #expect(CloudError.document(.schemaTooNew(2)).message(withCommand) == SyncDocumentError.schemaTooNew(2).message(withCommand))
        #expect(SyncDocumentError.schemaTooNew(2).message(withCommand) == "This Mac's copy of Notes is too old for the synced notes — update")
        #expect(SyncDocumentError.unparseable("line 2").message(withCommand) == "the synced notes can't be read: line 2")
        #expect(SyncDocumentError.unknownFormat("x").message(withCommand) == "unknown synced-document format 'x'")
        for error in everyCloudError {
            #expect(!error.message(withCommand).contains("this app") && !error.message(withCommand).contains("settings file"), "\(error)")
        }
    }

    @Test func aCommandNameAddsHintsToTheMessagesThatHaveOne() {
        #expect(CloudError.notLinked.message(withCommand) == "this Mac isn't linked to sync (run 'notes link')")
        #expect(CloudError.disabled.message(withCommand) == "sync is switched off on this Mac ('notes sync enable' turns it on)")
        let moved = CloudError.configMoved(linked: "/a/one", current: "/b/two").message(withCommand)
        #expect(moved == "this Mac's notes file changed from /a/one to /b/two; 'notes pull' uses the synced notes there, 'notes push --force' uploads that file")
    }

    @Test func withoutACommandNameNoHintAppears() {
        #expect(CloudError.notLinked.message(withoutCommand) == "this Mac isn't linked to sync")
        #expect(CloudError.disabled.message(withoutCommand) == "sync is switched off on this Mac")
        #expect(CloudError.configMoved(linked: "/a/one", current: "/b/two").message(withoutCommand) == "this Mac's notes file changed from /a/one to /b/two")
        for error in everyCloudError {
            let message = error.message(withoutCommand)
            #expect(!message.contains("(run"), "\(error)")
            #expect(!message.contains("'notes"), "\(error)")
            #expect(!message.contains("turns it on"), "\(error)")
        }
    }

    @Test func theNeutralWordingNeverHintsAtACommand() {
        for error in everyCloudError {
            let message = error.message(.neutral)
            #expect(!message.contains("(run"), "\(error)")
            #expect(!message.contains("--force"), "\(error)")
        }
    }

    // MARK: - From the client

    @Test func theClientsOwnMessagesFollowTheHostsWording() async throws {
        let server = FakeCloudServer()
        let withHint = try NotesMac(server: server, text: notes(["a": "1"]))
        _ = try await withHint.linkCreate()
        server.offline = true
        let unlinked = try await withHint.cloud.unlink()
        #expect(unlinked.notes.first?.contains("('notes devices revoke')") == true)

        // The same operations for a host without a CLI.
        let quiet = try NotesMac(server: FakeCloudServer(), text: notes(["a": "1"]))
        quiet.cloud.host.wording = withoutCommand
        let quietServer = try #require(quiet.server)
        _ = try await quiet.linkCreate()
        await #expect(throws: CloudError.self) { _ = try await quiet.cloud.revoke("nobody") }
        do { _ = try await quiet.cloud.revoke("nobody") } catch let error as CloudError {
            #expect(error == .notFound("no device named “nobody”"))
        }
        do {
            var other = LinkRequest(server: URL(string: "https://elsewhere.example")!, deviceName: "x", invite: "y")
            other.pollInterval = 0
            _ = try await quiet.cloud.link(other)
        } catch let error as CloudError {
            #expect(error == .refused("already linked to http://127.0.0.1:8787"))
        }
        quietServer.offline = true
        let result = try await quiet.cloud.unlink()
        #expect(result.notes.first == "couldn't reach the sync service: revoke “Mac A” from another Mac")
    }

    @Test func aCommandHintShowsUpInTheClientsRefusalsWhenTheHostHasACommand() async throws {
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes(["a": "1"]))
        _ = try await mac.linkCreate()
        do { _ = try await mac.cloud.revoke("nobody") } catch let error as CloudError {
            #expect(error == .notFound("no device named “nobody” (see 'notes devices')"))
        }
        do {
            var other = LinkRequest(server: URL(string: "https://elsewhere.example")!, deviceName: "x", invite: "y")
            other.pollInterval = 0
            _ = try await mac.cloud.link(other)
        } catch let error as CloudError {
            #expect(error == .refused("already linked to http://127.0.0.1:8787; run 'notes unlink' first"))
        }
    }
}
