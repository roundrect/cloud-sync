import Foundation
import Testing
@testable import CloudSync

@Suite("TokenStore")
struct TokenStoreTests {
    private func temp() -> URL { FileManager.default.temporaryDirectory.appending(path: "cloud-sync-tokens-\(UUID().uuidString)") }

    @Test func theInMemoryStoreKeepsTokensPerDevice() throws {
        let store = InMemoryTokenStore(["dev_1": "a"])
        #expect(try store.token(for: "dev_1") == "a")
        #expect(try store.token(for: "dev_2") == nil)
        try store.save("b", for: "dev_2")
        try store.save("c", for: "dev_1")
        #expect(try store.token(for: "dev_1") == "c")
        #expect(try store.token(for: "dev_2") == "b")
        try store.delete(for: "dev_1")
        #expect(try store.token(for: "dev_1") == nil)
        try store.delete(for: "dev_1")
    }

    @Test func theFileStoreOverwritesAndKeepsTheFolderPrivate() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTokenStore(directory: directory)
        try store.save("one", for: "dev_1")
        try store.save("two", for: "dev_1")
        #expect(try store.token(for: "dev_1") == "two")
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(folder == 0o700)
        let file = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "token-dev_1").path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        try store.delete(for: "dev_missing")
    }

    @Test func aBlankOrPaddedTokenFileReadsCleanly() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileTokenStore(directory: directory)
        try "  tok\n".write(to: directory.appending(path: "token-dev_1"), atomically: true, encoding: .utf8)
        try "\n".write(to: directory.appending(path: "token-dev_2"), atomically: true, encoding: .utf8)
        #expect(try store.token(for: "dev_1") == "tok")
        #expect(try store.token(for: "dev_2") == nil)
    }

    @Test func aStoreThatCannotWriteReportsALocalError() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The "folder" is a file, so nothing can be created in it.
        try "x".write(to: directory, atomically: true, encoding: .utf8)
        #expect(throws: CloudError.self) { try FileTokenStore(directory: directory).save("t", for: "dev_1") }
    }
}
