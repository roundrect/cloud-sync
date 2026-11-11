import Foundation
import Testing
@testable import CloudSync

@Suite("SyncLink")
struct SyncLinkTests {
    private func temp() -> URL { FileManager.default.temporaryDirectory.appending(path: "cloud-sync-link-\(UUID().uuidString)") }

    private let record = SyncLinkRecord(server: "https://x.example", accountId: "acc_1", deviceId: "dev_1", deviceName: "Mac", linkedConfigPath: "/tmp/c.txt", lastRev: 7, lastSyncedAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func aRecordAndBaseRoundTrip() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = SyncLink(directory: directory)
        #expect(try link.load() == nil)
        #expect(link.loadBase() == nil)
        try link.save(record)
        try link.saveBase("version: 1\n")
        #expect(try link.load() == record)
        #expect(link.loadBase() == "version: 1\n")
        try link.remove()
        #expect(try link.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try link.remove()
    }

    @Test func theBaseFileNameIsTheHostsChoice() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = SyncLink(directory: directory, baseFileName: "base.txt")
        #expect(link.baseURL.lastPathComponent == "base.txt")
        #expect(SyncLink(directory: directory).baseURL.lastPathComponent == "base")
        try link.saveBase("x")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "base.txt").path))
        #expect(SyncLink(directory: directory).loadBase() == nil)
    }

    @Test func theBaseKeepsEveryByte() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = SyncLink(directory: directory)
        let text = "# keep me\r\nallow a\n\n\tdeny b  \nno trailing newline"
        try link.saveBase(text)
        #expect(try Data(contentsOf: link.baseURL) == Data(text.utf8))
        #expect(link.loadBase() == text)
    }

    @Test func aCorruptRecordIsReportedNotIgnored() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = SyncLink(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{nope".write(to: link.recordURL, atomically: true, encoding: .utf8)
        #expect(throws: SyncLinkError.self) { _ = try link.load() }
    }

    @Test func aNewerVersionIsRefused() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = SyncLink(directory: directory)
        var future = record
        future.version = 99
        try link.save(future)
        #expect(throws: SyncLinkError.unsupportedVersion(99)) { _ = try link.load() }
    }

    @Test func theLockExcludesAnotherHolder() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = SyncLink(directory: directory)
        try link.withLock {
            // A second descriptor in the same process conflicts with the first flock.
            let other = open(link.lockURL.path, O_RDWR)
            defer { close(other) }
            #expect(flock(other, LOCK_EX | LOCK_NB) == -1)
        }
        // Released afterwards, and the body's value and errors pass through.
        let other = open(link.lockURL.path, O_RDWR)
        defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) == 0)
        flock(other, LOCK_UN)
        #expect(try link.withLock { 42 } == 42)
        struct Boom: Error {}
        #expect(throws: Boom.self) { try link.withLock { throw Boom() } }
        #expect(try link.withLock { 1 } == 1)
    }

    @Test func exclusiveAccessGivesUpAfterTheTimeout() async throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = SyncLink(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let held = open(link.lockURL.path, O_CREAT | O_RDWR, 0o644)
        defer { close(held) }
        #expect(flock(held, LOCK_EX) == 0)
        await #expect(throws: SyncLinkError.lockFailed(link.lockURL.path)) {
            try await link.withExclusiveAccess(timeout: 0.1) { 1 }
        }
        flock(held, LOCK_UN)
        #expect(try await link.withExclusiveAccess(timeout: 1) { 7 } == 7)
    }

    @Test func fileTokensAreOwnerOnly() throws {
        let directory = temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTokenStore(directory: directory)
        #expect(try store.token(for: "dev_1") == nil)
        try store.save("tok1_secret", for: "dev_1")
        #expect(try store.token(for: "dev_1") == "tok1_secret")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "token-dev_1").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        try store.delete(for: "dev_1")
        #expect(try store.token(for: "dev_1") == nil)
    }

    @Test func keychainPathsComeFromTheBundleLayout() {
        let bundlePaths = ["Contents/MacOS/Example", "Contents/Resources/example"]
        let inApp = URL(fileURLWithPath: "/Applications/Example.app/Contents/Resources/example")
        #expect(KeychainTokenStore.trustedPaths(inBundle: bundlePaths, executable: inApp)
                == ["/Applications/Example.app/Contents/MacOS/Example", "/Applications/Example.app/Contents/Resources/example"])
        #expect(KeychainTokenStore.trustedPaths(inBundle: bundlePaths, executable: URL(fileURLWithPath: "/usr/local/bin/example")) == ["/usr/local/bin/example"])
        #expect(KeychainTokenStore.trustedPaths(inBundle: bundlePaths, executable: nil).isEmpty)
    }

    @Test func keychainStoresKeepTheirOwnServiceAndLabelWithoutTouchingTheKeychain() {
        // Constructing the store reads nothing; only token/save/delete reach the Keychain, and no test calls them.
        let store = KeychainTokenStore(service: "test.example.sync", label: "Example sync token", trustedApplicationPaths: ["/x"])
        #expect(store.service == "test.example.sync")
        #expect(store.label == "Example sync token")
        #expect(store.trustedApplicationPaths == ["/x"])
    }
}
