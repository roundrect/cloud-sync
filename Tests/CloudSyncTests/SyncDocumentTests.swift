import Foundation
import Testing
@testable import CloudSync

@Suite struct SyncDocumentTests {
    private let body = NotesDocument(["groceries": "milk", "todo": "call “Sam” ⌃T"]).text

    @Test func roundTripsThroughTheEnvelope() throws {
        let document = SyncDocument(format: "app-text", schema: 1, body: body, summary: "+groceries")
        #expect(document.format == "app-text")
        #expect(document.schema == 1)
        #expect(document.body == body)
        #expect(document.summary == "+groceries")
        #expect(document.sha256 == SyncDocument.checksum(of: body))
        #expect(try document.verifiedBody(format: "app-text", maxSchema: 1) == body)
    }

    @Test func envelopeIsCamelCaseJSON() throws {
        let document = SyncDocument(format: "app-text", schema: 1, body: "", summary: "s")
        let data = try JSONEncoder().encode(document)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "schema", "body", "sha256", "summary"])
        #expect(try JSONDecoder().decode(SyncDocument.self, from: data) == document)
    }

    @Test func checksumIsLowercaseHexSHA256() {
        #expect(SyncDocument.checksum(of: "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func anUppercaseChecksumFromTheServerStillVerifies() throws {
        var document = SyncDocument(format: "app-text", schema: 1, body: body)
        document.sha256 = document.sha256.uppercased()
        #expect(try document.verifiedBody(format: "app-text", maxSchema: 1) == body)
    }

    @Test func newerSchemaIsRefused() {
        var document = SyncDocument(format: "app-text", schema: 1, body: body)
        document.schema = 2
        #expect(throws: SyncDocumentError.schemaTooNew(2)) { try document.verifiedBody(format: "app-text", maxSchema: 1) }
        // The newest schema this build knows is fine.
        #expect(throws: Never.self) { try document.verifiedBody(format: "app-text", maxSchema: 2) }
    }

    @Test func checksumMismatchIsRefused() {
        var document = SyncDocument(format: "app-text", schema: 1, body: body)
        document.body += "# tampered\n"
        #expect(throws: SyncDocumentError.checksumMismatch) { try document.verifiedBody(format: "app-text", maxSchema: 1) }
    }

    @Test func unknownFormatIsRefused() {
        var document = SyncDocument(format: "app-text", schema: 1, body: body)
        document.format = "app-text+enc1"
        #expect(throws: SyncDocumentError.unknownFormat("app-text+enc1")) { try document.verifiedBody(format: "app-text", maxSchema: 1) }
    }

    @Test func unparseableBodyIsRefused() async throws {
        // The envelope is fine; the host can't read the body. The client reports it as a document error.
        let server = FakeCloudServer()
        let mac = try NotesMac(server: server, text: notes(["groceries": "milk"]))
        _ = try await mac.linkCreate()
        let garbage = "this is not key and value\n"
        server.writeRaw(SyncDocument(format: "app-text", schema: 1, body: garbage))
        let before = try mac.fileText()
        do {
            _ = try await mac.cloud.pull()
            Issue.record("expected a document error")
        } catch CloudError.document(.unparseable) {
        } catch {
            Issue.record("expected unparseable, got \(error)")
        }
        #expect(try mac.fileText() == before)
    }
}

@Suite struct RevisionTests {
    @Test func decodesTheHistoryJSON() throws {
        let json = """
        {"rev":7,"createdAt":"2026-10-26T09:30:00.123Z","deviceId":"dev_1","deviceName":"MacBook","kind":"revert","revertedTo":3,"summary":"Reverted to 3"}
        """
        let revision = try CloudJSON.makeDecoder().decode(Revision.self, from: Data(json.utf8))
        #expect(revision.rev == 7)
        #expect(revision.kind == .revert)
        #expect(revision.revertedTo == 3)
        #expect(revision.deviceName == "MacBook")
        let again = try CloudJSON.makeDecoder().decode(Revision.self, from: CloudJSON.makeEncoder().encode(revision))
        #expect(again == revision)
    }

    @Test func dateWithoutFractionalSecondsDecodes() throws {
        let json = #"{"rev":1,"createdAt":"2026-10-26T09:30:00Z","deviceId":"d","deviceName":"n","kind":"bootstrap","summary":""}"#
        let revision = try CloudJSON.makeDecoder().decode(Revision.self, from: Data(json.utf8))
        #expect(revision.kind == .bootstrap)
        #expect(revision.revertedTo == nil)
    }

    @Test func aDateThatIsNotISO8601IsRejected() {
        let json = #"{"rev":1,"createdAt":"yesterday","deviceId":"d","deviceName":"n","kind":"put","summary":""}"#
        #expect(throws: DecodingError.self) { _ = try CloudJSON.makeDecoder().decode(Revision.self, from: Data(json.utf8)) }
    }

    @Test func remoteDocCarriesTheEnvelope() throws {
        let document = SyncDocument(format: "app-text", schema: 1, body: "version: 1\n", summary: "s")
        let remote = RemoteDoc(rev: 4, format: document.format, schema: document.schema, body: document.body, sha256: document.sha256, summary: "s")
        let back = try CloudJSON.makeDecoder().decode(RemoteDoc.self, from: CloudJSON.makeEncoder().encode(remote))
        #expect(back.document == document)
        #expect(!back.isEmpty)
        let empty = try CloudJSON.makeDecoder().decode(RemoteDoc.self, from: Data(#"{"rev":0}"#.utf8))
        #expect(empty.isEmpty)
        #expect(empty.document == nil)
    }
}
