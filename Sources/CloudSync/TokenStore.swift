import Foundation

/// Where this Mac's device token lives. Keyed by device id.
public protocol TokenStore: Sendable {
    func token(for deviceID: String) throws -> String?
    func save(_ token: String, for deviceID: String) throws
    func delete(for deviceID: String) throws
}

/// Tests: nothing leaves the process.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String]

    public init(_ tokens: [String: String] = [:]) { self.tokens = tokens }

    public func token(for deviceID: String) throws -> String? { lock.withLock { tokens[deviceID] } }
    public func save(_ token: String, for deviceID: String) throws { lock.withLock { tokens[deviceID] = token } }
    public func delete(for deviceID: String) throws { lock.withLock { tokens[deviceID] = nil } }
}

/// A 0600 file per device, for tests, sandboxed dev runs that must not touch the Keychain, and as a
/// fallback if the Keychain can't be shared. Not a product default.
public struct FileTokenStore: TokenStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func url(_ deviceID: String) -> URL { directory.appending(path: "token-\(deviceID)") }

    public func token(for deviceID: String) throws -> String? {
        guard let data = try? Data(contentsOf: url(deviceID)) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func save(_ token: String, for deviceID: String) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = url(deviceID)
            try? FileManager.default.removeItem(at: target)
            guard FileManager.default.createFile(atPath: target.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CloudError.local("cannot write \(target.path)")
            }
        } catch let error as CloudError {
            throw error
        } catch {
            throw CloudError.local("cannot save the sync token: \(error.localizedDescription)")
        }
    }

    public func delete(for deviceID: String) throws {
        try? FileManager.default.removeItem(at: url(deviceID))
    }
}
