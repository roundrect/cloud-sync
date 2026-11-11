import Foundation

public enum RevisionKind: String, Codable, Equatable, Sendable {
    case put, revert, bootstrap
}

/// One entry of the synced history (`GET /v1/history`), no body.
public struct Revision: Codable, Equatable, Sendable {
    public var rev: Int
    public var createdAt: Date
    public var deviceId: String
    public var deviceName: String
    public var kind: RevisionKind
    /// For a `revert`: the revision whose body was restored.
    public var revertedTo: Int?
    public var summary: String

    public init(rev: Int, createdAt: Date, deviceId: String, deviceName: String, kind: RevisionKind, revertedTo: Int? = nil, summary: String = "") {
        self.rev = rev
        self.createdAt = createdAt
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.kind = kind
        self.revertedTo = revertedTo
        self.summary = summary
    }
}

/// The current document (`GET /v1/doc`, a 409 body, a revision with its body). Revision 0 is an empty
/// account, which has no document.
public struct RemoteDoc: Codable, Equatable, Sendable {
    public var rev: Int
    public var format: String?
    public var schema: Int?
    public var body: String?
    public var sha256: String?
    public var summary: String?
    public var updatedAt: Date?
    public var deviceId: String?
    public var deviceName: String?

    public init(rev: Int, format: String? = nil, schema: Int? = nil, body: String? = nil, sha256: String? = nil, summary: String? = nil, updatedAt: Date? = nil, deviceId: String? = nil, deviceName: String? = nil) {
        self.rev = rev
        self.format = format
        self.schema = schema
        self.body = body
        self.sha256 = sha256
        self.summary = summary
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    public var isEmpty: Bool { rev == 0 }

    /// The envelope, when the server sent a body.
    public var document: SyncDocument? {
        guard let format, let schema, let body, let sha256 else { return nil }
        return SyncDocument(format: format, schema: schema, body: body, sha256: sha256, summary: summary ?? "")
    }
}

/// JSON as the sync API speaks it: camelCase keys, ISO-8601 dates (with or without fractional seconds).
public enum CloudJSON {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO-8601 date: \(text)"))
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter(fractional: true).string(from: date))
        }
        return encoder
    }
}
