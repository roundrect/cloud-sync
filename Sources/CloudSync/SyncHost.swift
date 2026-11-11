import Foundation

/// How a write should treat the file it replaces.
public enum SyncBackupPolicy: Sendable {
    /// Always keep a copy: the write may throw away edits nobody merged.
    case always
    /// Keep a copy unless a recent one exists: an ordinary merged write.
    case ifStale
}

public enum SyncHostError: Error, Equatable, Sendable {
    /// The document can't be read or parsed right now. Nothing is pushed and remote changes are held
    /// until it is fixed.
    case unreadable(String)
}

/// The outcome of a three-way merge.
public struct SyncMerge<Host: SyncHost>: Sendable {
    public var merged: Host.Document
    public var conflicts: [Host.Conflict]
    /// The merge couldn't produce a valid document, so `merged` is the remote document whole. The
    /// client backs the local file up before writing it.
    public var fellBackToRemote: Bool

    public init(merged: Host.Document, conflicts: [Host.Conflict] = [], fellBackToRemote: Bool = false) {
        self.merged = merged
        self.conflicts = conflicts
        self.fellBackToRemote = fellBackToRemote
    }
}

/// Everything the library needs to know about one app's synced document. The library owns the
/// protocol (linking, revisions, retries, the live connection); the app owns what the document means.
///
/// `@unchecked Sendable` conformers are fine when their stores guard themselves: one client may be
/// used from several tasks, and a pull or a push holds the link's lock end to end.
public protocol SyncHost: Sendable {
    /// The parsed document. It can simply be the file's text.
    associatedtype Document: Sendable
    /// One difference between two documents, as shown to the person.
    associatedtype Change: Sendable
    /// One place where both Macs changed the same thing.
    associatedtype Conflict: Sendable
    /// What applying the document to this Mac did.
    associatedtype Report: Sendable

    /// The app's slug on a shared server (`^[a-z][a-z0-9-]{0,31}$`): every request goes to
    /// `/v1/ns/<namespace>/…`. It isn't stored in `sync.json`.
    var namespace: String { get }
    /// The envelope's format name. The server only checks its shape; this client's own check is what
    /// refuses a document in a format it can't read.
    var format: String { get }
    /// The newest schema this build can read; a newer document stops sync with an upgrade message.
    var maxSchema: Int { get }
    var wording: SyncWording { get }
    /// The file being synced.
    var documentURL: URL { get }
    /// What an account or a Mac holds before anything is written.
    var emptyDocument: Document { get }

    func schema(of document: Document) -> Int
    /// The exact text sent to the server, stored as the merge base, and compared to detect changes.
    /// It must be deterministic. A host that keeps comments returns the file's text as it stands.
    func text(of document: Document) -> String
    func parse(_ text: String) throws -> Document

    /// Reads the file. A missing file is `emptyDocument`. Throws `SyncHostError.unreadable` for a file
    /// that exists but can't be used yet; anything else is passed on to the caller.
    func loadLocal() throws -> Document
    /// Writes the file and returns the backup it made, if any.
    func save(_ document: Document, backup: SyncBackupPolicy) throws -> URL?

    /// Every reason this document must not be uploaded; empty when it is fine.
    func validationErrors(in document: Document) -> [String]
    /// `base` is the last synced document. Must always return something writable: fall back to
    /// `remote` whole rather than failing. `KeyedMerge` does the three-way part for keyed documents.
    func merge(base: Document, local: Document, remote: Document) -> SyncMerge<Self>
    func changes(from old: Document, to new: Document) -> [Change]
    /// A one-line description of `changes`, kept with the revision.
    func summary(of changes: [Change], maxLength: Int) -> String

    /// Makes this Mac match the saved file.
    func apply(mayPrompt: Bool) throws -> Report
    /// What applying `document` would do, writing nothing; `nil` when it can't be worked out.
    func previewApply(of document: Document) -> Report?
    /// Whether a preview would change anything on this Mac.
    func hasEffect(_ report: Report) -> Bool
}

/// The words the library's messages use, so they read as the app's own. Everything else in a message
/// is neutral.
public struct SyncWording: Equatable, Sendable {
    /// As in `Update Example to keep syncing`.
    public var appName: String
    /// Plural, as in `the synced settings changed`.
    public var documentName: String
    /// As in `the settings file has errors`.
    public var fileName: String
    /// The CLI's name. `nil` leaves command hints out of messages.
    public var commandName: String?

    public init(appName: String, documentName: String, fileName: String, commandName: String? = nil) {
        self.appName = appName
        self.documentName = documentName
        self.fileName = fileName
        self.commandName = commandName
    }

    public static let neutral = SyncWording(appName: "this app", documentName: "settings", fileName: "settings file")

    /// `'example pull'`, or `nil` without a CLI.
    func command(_ arguments: String) -> String? {
        commandName.map { "'\($0) \(arguments)'" }
    }
}
