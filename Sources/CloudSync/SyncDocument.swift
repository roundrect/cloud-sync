import CryptoKit
import Foundation

public enum SyncDocumentError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownFormat(String)
    /// The document was written by a newer build of the app than this one.
    case schemaTooNew(Int)
    case checksumMismatch
    case unparseable(String)

    public var description: String { message(.neutral) }

    public func message(_ wording: SyncWording) -> String {
        switch self {
        case .unknownFormat(let format): "unknown synced-document format '\(format)'"
        case .schemaTooNew: "This Mac's copy of \(wording.appName) is too old for the synced \(wording.documentName) — update"
        case .checksumMismatch: "the synced \(wording.documentName) were damaged in transit (checksum mismatch)"
        case .unparseable(let reason): "the synced \(wording.documentName) can't be read: \(reason)"
        }
    }
}

/// What travels to and from the server: the document's text in a small JSON envelope. The server
/// treats `body` as opaque; `summary` is computed on the client.
public struct SyncDocument: Codable, Equatable, Sendable {
    public var format: String
    public var schema: Int
    public var body: String
    public var sha256: String
    public var summary: String

    public init(format: String, schema: Int, body: String, sha256: String, summary: String) {
        self.format = format
        self.schema = schema
        self.body = body
        self.sha256 = sha256
        self.summary = summary
    }

    public init(format: String, schema: Int, body: String, summary: String = "") {
        self.init(format: format, schema: schema, body: body, sha256: Self.checksum(of: body), summary: summary)
    }

    public static func checksum(of body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the envelope and returns the body.
    public func verifiedBody(format expected: String, maxSchema: Int) throws(SyncDocumentError) -> String {
        guard format == expected else { throw .unknownFormat(format) }
        guard schema <= maxSchema else { throw .schemaTooNew(schema) }
        guard Self.checksum(of: body) == sha256.lowercased() else { throw .checksumMismatch }
        return body
    }
}
