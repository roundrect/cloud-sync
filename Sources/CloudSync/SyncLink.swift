import Foundation

/// This Mac's link to the sync service (`sync.json`).
public struct SyncLinkRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var server: String
    public var accountId: String
    public var deviceId: String
    public var deviceName: String
    /// The synced file at link time; a different file later is `configMoved`.
    public var linkedConfigPath: String
    /// The revision the merge base holds.
    public var lastRev: Int
    public var lastSyncedAt: Date?
    public var enabled: Bool

    public init(server: String, accountId: String, deviceId: String, deviceName: String, linkedConfigPath: String, lastRev: Int = 0, lastSyncedAt: Date? = nil, enabled: Bool = true) {
        self.version = Self.currentVersion
        self.server = server
        self.accountId = accountId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.linkedConfigPath = linkedConfigPath
        self.lastRev = lastRev
        self.lastSyncedAt = lastSyncedAt
        self.enabled = enabled
    }
}

public enum SyncLinkError: Error, Equatable, Sendable, CustomStringConvertible {
    case corrupt(String, reason: String)
    case unsupportedVersion(Int)
    case lockFailed(String)

    public var description: String {
        switch self {
        case .corrupt(let path, let reason): "the sync record at \(path) can't be read: \(reason)"
        case .unsupportedVersion(let version): "the sync record is version \(version), newer than this build understands"
        case .lockFailed(let path): "couldn't lock \(path)"
        }
    }
}

/// Per-machine sync state on disk: `sync.json`, the merge base (the document's text at `lastRev`) and
/// `lock`, shared by every front-end of one app. Never synced.
public struct SyncLink: Sendable {
    public let directory: URL
    public let baseFileName: String

    public init(directory: URL, baseFileName: String = "base") {
        self.directory = directory
        self.baseFileName = baseFileName
    }

    public var recordURL: URL { directory.appending(path: "sync.json") }
    public var baseURL: URL { directory.appending(path: baseFileName) }
    public var lockURL: URL { directory.appending(path: "lock") }

    /// `nil` when this Mac isn't linked.
    public func load() throws -> SyncLinkRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let record: SyncLinkRecord
        do {
            record = try CloudJSON.makeDecoder().decode(SyncLinkRecord.self, from: Data(contentsOf: recordURL))
        } catch {
            throw SyncLinkError.corrupt(recordURL.path, reason: error.localizedDescription)
        }
        guard record.version <= SyncLinkRecord.currentVersion else { throw SyncLinkError.unsupportedVersion(record.version) }
        return record
    }

    public func save(_ record: SyncLinkRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = CloudJSON.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    /// The merge base, or `nil` before the first sync.
    public func loadBase() -> String? { try? String(contentsOf: baseURL, encoding: .utf8) }

    public func saveBase(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: baseURL, atomically: true, encoding: .utf8)
    }

    /// Forgets the link: this folder goes, the synced file is not touched.
    public func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Runs `body` holding an exclusive advisory lock, so two front-ends never write the link at once.
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw SyncLinkError.lockFailed(lockURL.path) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SyncLinkError.lockFailed(lockURL.path) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Like `withLock`, but for work that awaits (a whole pull or push, network included). Polls for the
    /// lock rather than blocking a thread, and gives up after `timeout`. The lock is per open file, so it
    /// also serialises two operations in one process; `body` must not take `withLock` itself.
    public func withExclusiveAccess<T>(timeout: TimeInterval = 60, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw SyncLinkError.lockFailed(lockURL.path) }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw SyncLinkError.lockFailed(lockURL.path) }
            try await Task.sleep(for: .milliseconds(25))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }
}
