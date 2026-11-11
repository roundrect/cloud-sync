import Foundation
import Testing
@testable import CloudSync

/// A host whose document is the file's text: `# comments` and ORDER-SENSITIVE rules (first match wins).
/// The library must carry every byte through a push, a pull, the merge base and the change check.
@Suite("OrderedTextHost")
struct OrderedTextHostTests {
    private let rules = """
    # Rules are read top to bottom; the first match wins.
    allow /Applications/Safari.app

    # Keep this above the broad deny.
    allow /Applications/*
    deny /Applications/Games/*
    \tdeny *   
    # last comment, no newline at the end
    """

    private let reordered = """
    # Rules are read top to bottom; the first match wins.
    allow /Applications/Safari.app

    # Keep this above the broad deny.
    deny /Applications/Games/*
    allow /Applications/*
    \tdeny *   
    # last comment, no newline at the end
    """

    // MARK: - Push

    @Test func aPushSendsTheExactBytesIncludingComments() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        let linked = try await mac.linkCreate()
        #expect(linked.adopted == "local")
        #expect(server.body(of: 1) == rules)
        #expect(server.bodyBytes(of: 1) == Data(rules.utf8))

        let edited = rules + "\n# added later, with a trailing newline\ndeny /tmp/*\n"
        try mac.write(edited)
        let pushed = try await mac.cloud.push()
        #expect(pushed.outcome == .pushed)
        #expect(server.body(of: 2) == edited)
        #expect(server.bodyBytes(of: 2) == Data(edited.utf8))
        // The envelope's checksum is over those same bytes.
        #expect(server.sha256(of: 2) == SyncDocument.checksum(of: edited))
    }

    @Test func windowsLineEndingsAndOddWhitespaceSurviveAPush() async throws {
        let server = FakeCloudServer()
        let text = "# crlf\r\nallow a\r\n\r\n  deny b \t\r\n"
        let mac = try RulesMac(server: server, text: text)
        _ = try await mac.linkCreate()
        #expect(server.bodyBytes(of: 1) == Data(text.utf8))
    }

    // MARK: - Pull

    @Test func aPullWritesTheExactBytes() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: "allow a\n")
        _ = try await mac.linkCreate()
        server.writeTextAsOtherDevice(rules)
        let pulled = try await mac.cloud.pull()
        #expect(pulled.outcome == .pulled)
        #expect(try mac.fileData() == Data(rules.utf8))
        #expect(mac.machine["text"] == rules, "apply saw the exact text")
        #expect(try await mac.cloud.status(offline: true).localChanges == false)
    }

    @Test func linkingWithAdoptRemoteWritesTheExactBytes() async throws {
        let server = FakeCloudServer()
        server.writeTextAsOtherDevice(rules)
        let mac = try RulesMac(server: server, text: "deny *\n")
        let result = try await mac.linkCreate(adopt: .remote)
        #expect(result.adopted == "remote")
        #expect(try mac.fileData() == Data(rules.utf8))
        let backup = try #require(result.backup)
        #expect(try Data(contentsOf: backup) == Data("deny *\n".utf8))
        #expect(mac.link.loadBase() == rules)
    }

    // MARK: - The merge base

    @Test func theMergeBaseStoresTheExactBytes() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        #expect(mac.link.loadBase() == rules)
        #expect(try Data(contentsOf: mac.link.baseURL) == Data(rules.utf8))

        server.writeTextAsOtherDevice(reordered)
        _ = try await mac.cloud.pull(apply: false)
        #expect(try Data(contentsOf: mac.link.baseURL) == Data(reordered.utf8))

        try mac.write(rules)
        _ = try await mac.cloud.push(apply: false)
        #expect(try Data(contentsOf: mac.link.baseURL) == Data(rules.utf8))
    }

    // MARK: - Changes

    @Test func reorderedLinesCountAsAChange() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        try mac.write(reordered)

        let status = try await mac.cloud.status(offline: true)
        #expect(status.localChanges)
        #expect(status.state == .localChanges)
        let pushed = try await mac.cloud.push()
        #expect(pushed.outcome == .pushed)
        #expect(pushed.changes == [OrderedTextHost.Change(kind: .reordered, line: "")])
        #expect(server.body(of: 2) == reordered)
        #expect(try await mac.cloud.status().state == .inSync)
    }

    @Test func aCommentOnlyEditIsALocalChange() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        let edited = rules.replacingOccurrences(of: "# last comment, no newline at the end", with: "# a different comment")
        #expect(edited != rules)
        try mac.write(edited)

        let status = try await mac.cloud.status(offline: true)
        #expect(status.state == .localChanges)
        #expect(status.localChanges)
        let online = try await mac.cloud.status()
        #expect(online.state == .localChanges)
        let pushed = try await mac.cloud.push()
        #expect(pushed.outcome == .pushed)
        #expect(server.body(of: 2) == edited)
        #expect(try await mac.cloud.status().state == .inSync)
    }

    @Test func aTrailingNewlineAloneIsALocalChange() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: "allow a")
        _ = try await mac.linkCreate()
        try mac.write("allow a\n")
        #expect(try await mac.cloud.status(offline: true).localChanges)
        _ = try await mac.cloud.push()
        #expect(server.bodyBytes(of: 2) == Data("allow a\n".utf8))
    }

    @Test func anEditThatOnlyChangesUnicodeNormalisationIsStillAChange() async throws {
        // "é" as one scalar versus "e" plus a combining accent: different bytes, equal as Swift Strings.
        let precomposed = "# caf\u{E9}\nallow a\n"
        let decomposed = "# cafe\u{301}\nallow a\n"
        #expect(Data(precomposed.utf8) != Data(decomposed.utf8))
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: precomposed)
        _ = try await mac.linkCreate()
        try mac.write(decomposed)
        #expect(try await mac.cloud.status(offline: true).localChanges)
        _ = try await mac.cloud.push()
        #expect(server.bodyBytes(of: 2) == Data(decomposed.utf8))
    }

    // MARK: - Merging

    @Test func aRemoteOnlyChangeIsTakenByteForByte() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        server.writeTextAsOtherDevice(reordered)
        let pulled = try await mac.cloud.pull(apply: false)
        #expect(pulled.conflicts.isEmpty)
        #expect(try mac.fileData() == Data(reordered.utf8))
    }

    @Test func aLocalOnlyChangeSurvivesAPullOfAnUnchangedRemote() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        try mac.write(reordered)
        let pulled = try await mac.cloud.pull(apply: false)
        #expect(pulled.outcome == .upToDate)
        #expect(try mac.fileData() == Data(reordered.utf8))
    }

    @Test func bothSidesChangingKeepsLocalAndReportsOneConflict() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        let theirs = "# theirs\n" + rules
        let ours = rules + "deny /tmp/*\n"
        server.writeTextAsOtherDevice(theirs, name: "Other")
        try mac.write(ours)

        let pulled = try await mac.cloud.pull(apply: false)
        #expect(pulled.conflicts == [OrderedTextHost.Conflict(local: ours, remote: theirs)])
        #expect(pulled.localChanges)
        #expect(try mac.fileData() == Data(ours.utf8))
        // The local version then goes up as it stands.
        let pushed = try await mac.cloud.push(apply: false)
        #expect(pushed.outcome == .pushed)
        #expect(server.body(of: 3) == ours)
    }

    @Test func aStalePushKeepsLocalBytesAndNeverInterleavesLines() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        server.writeTextAsOtherDevice("deny *\n" + rules)
        try mac.write(reordered)
        let pushed = try await mac.cloud.push(apply: false)
        #expect(pushed.conflicts.count == 1)
        #expect(pushed.outcome == .pushed)
        #expect(server.body(of: 3) == reordered)
        #expect(try mac.fileData() == Data(reordered.utf8))
    }

    // MARK: - Validation and unreadable files

    @Test func aFileWithAnUnknownRuleIsNeverPushed() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        try mac.write(rules + "\npermit everything\n")
        await #expect(throws: CloudError.invalidLocalConfig(["line 9: expected allow, deny or a comment"])) {
            _ = try await mac.cloud.push()
        }
        #expect(server.headRev == 1)
    }

    @Test func anEmptyAccountAndAnEmptyFileLinkWithoutUploading() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: "")
        let result = try await mac.linkCreate()
        #expect(result.adopted == "none")
        #expect(server.headRev == 0)
    }

    @Test func theAppliedTextIsWhatIsOnDisk() async throws {
        let server = FakeCloudServer()
        let mac = try RulesMac(server: server, text: rules)
        _ = try await mac.linkCreate()
        server.writeTextAsOtherDevice(reordered)
        let pulled = try await mac.cloud.pull()
        #expect(pulled.report == OrderedTextHost.Report(text: reordered, preview: false))
        #expect(mac.applied.applyCount == 1)
    }
}
