import Foundation
@testable import CloudSync

/// What "this Mac" holds after `SyncHost.apply`, and how often that happened. Lock-guarded so a host
/// value can be copied freely.
final class AppliedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String: String] = [:]
    private var _applyCount = 0
    private var _prompts: [Bool] = []

    var values: [String: String] { lock.withLock { _values } }
    var applyCount: Int { lock.withLock { _applyCount } }
    var mayPromptCalls: [Bool] { lock.withLock { _prompts } }

    func record(_ values: [String: String], mayPrompt: Bool) {
        lock.withLock {
            _values = values
            _applyCount += 1
            _prompts.append(mayPrompt)
        }
    }
}

enum TestFiles {
    /// Writes exactly `text` and returns the backup it made, if any, as `<file>.bak`.
    static func write(_ text: String, to url: URL, backup: SyncBackupPolicy) throws -> URL? {
        var made: URL?
        if let existing = try? Data(contentsOf: url) {
            let copy = URL(fileURLWithPath: url.path + ".bak")
            let differs = existing != Data(text.utf8)
            if differs, backup == .always || !FileManager.default.fileExists(atPath: copy.path) {
                try existing.write(to: copy, options: .atomic)
                made = copy
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return made
    }
}

// MARK: - NotesHost: a keyed document

struct NotesDocument: Equatable, Sendable {
    var version = 1
    var values: [String: String] = [:]

    init(_ values: [String: String] = [:], version: Int = 1) {
        self.values = values
        self.version = version
    }

    /// `version: N`, then sorted `key = value` lines.
    var text: String {
        "version: \(version)\n" + values.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)\n" }.joined()
    }

    static func parse(_ text: String) throws -> NotesDocument {
        var document = NotesDocument()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if line.hasPrefix("version:") {
                guard let number = Int(line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)) else {
                    throw SyncHostError.unreadable("line \(index + 1): bad version")
                }
                document.version = number
            } else if let range = line.range(of: " = ") {
                document.values[String(line[..<range.lowerBound])] = String(line[range.upperBound...])
            } else {
                throw SyncHostError.unreadable("line \(index + 1) is not 'key = value'")
            }
        }
        return document
    }
}

/// Builds the text of a notes file.
func notes(_ values: [String: String], version: Int = 1) -> String { NotesDocument(values, version: version).text }

struct NotesHost: SyncHost {
    typealias Document = NotesDocument

    struct Change: Equatable, Sendable {
        enum Kind: String, Sendable { case added, removed, changed }
        var kind: Kind
        var key: String
    }

    struct Conflict: Equatable, Sendable {
        var key: String
        var local: String?
        var remote: String?
        var tookRemote: Bool
    }

    struct Report: Equatable, Sendable {
        var values: [String: String]
        var preview: Bool
    }

    static let defaultWording = SyncWording(appName: "Notes", documentName: "notes", fileName: "notes file", commandName: "notes")

    var documentURL: URL
    let applied: AppliedState
    /// A document holding this key is invalid and never uploaded.
    var invalidKey = "bad"
    var wording = NotesHost.defaultWording
    var maxSchema = 1

    var namespace = "app"
    let format = "app-text"
    var emptyDocument: NotesDocument { NotesDocument() }

    func schema(of document: NotesDocument) -> Int { document.version }
    func text(of document: NotesDocument) -> String { document.text }
    func parse(_ text: String) throws -> NotesDocument { try NotesDocument.parse(text) }

    func loadLocal() throws -> NotesDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return emptyDocument }
        return try parse(String(contentsOf: documentURL, encoding: .utf8))
    }

    func save(_ document: NotesDocument, backup: SyncBackupPolicy) throws -> URL? {
        try TestFiles.write(document.text, to: documentURL, backup: backup)
    }

    func validationErrors(in document: NotesDocument) -> [String] {
        document.values.keys.contains(invalidKey) ? ["the key '\(invalidKey)' is not allowed"] : []
    }

    func merge(base: NotesDocument, local: NotesDocument, remote: NotesDocument) -> SyncMerge<NotesHost> {
        let result = KeyedMerge.merge(base: base.values, local: local.values, remote: remote.values, order: <)
        let conflicts = result.conflicts.map { Conflict(key: $0.key, local: $0.local, remote: $0.remote, tookRemote: $0.tookRemote) }
        let merged = NotesDocument(result.resolved, version: max(local.version, remote.version))
        if !validationErrors(in: merged).isEmpty {
            return SyncMerge(merged: remote, conflicts: conflicts, fellBackToRemote: true)
        }
        return SyncMerge(merged: merged, conflicts: conflicts)
    }

    func changes(from old: NotesDocument, to new: NotesDocument) -> [Change] {
        Set(old.values.keys).union(new.values.keys).sorted().compactMap { key in
            switch (old.values[key], new.values[key]) {
            case (nil, _?): Change(kind: .added, key: key)
            case (_?, nil): Change(kind: .removed, key: key)
            case let (a?, b?) where a != b: Change(kind: .changed, key: key)
            default: nil
            }
        }
    }

    func summary(of changes: [Change], maxLength: Int) -> String {
        let text = changes.map { change in
            switch change.kind {
            case .added: "+\(change.key)"
            case .removed: "-\(change.key)"
            case .changed: "~\(change.key)"
            }
        }.joined(separator: ", ")
        return text.count <= maxLength ? text : String(text.prefix(maxLength - 1)) + "…"
    }

    func apply(mayPrompt: Bool) throws -> Report {
        let document = try loadLocal()
        applied.record(document.values, mayPrompt: mayPrompt)
        return Report(values: document.values, preview: false)
    }

    func previewApply(of document: NotesDocument) -> Report? { Report(values: document.values, preview: true) }
    func hasEffect(_ report: Report) -> Bool { report.values != applied.values }
}

// MARK: - OrderedTextHost: the document is the file's text

/// Lines are `# comments`, blank, or ordered rules (`allow …` / `deny …`). Order matters (first match
/// wins) and every byte, comments included, must survive a round trip.
struct OrderedTextHost: SyncHost {
    typealias Document = String

    struct Change: Equatable, Sendable {
        enum Kind: String, Sendable { case added, removed, reordered, other }
        var kind: Kind
        var line: String
    }

    struct Conflict: Equatable, Sendable {
        var local: String
        var remote: String
    }

    struct Report: Equatable, Sendable {
        var text: String
        var preview: Bool
    }

    var documentURL: URL
    let applied: AppliedState
    var wording = SyncWording(appName: "Rules", documentName: "rules", fileName: "rules file", commandName: "rules")

    var namespace = "app"
    let format = "ordered-text"
    let maxSchema = 1
    var emptyDocument: String { "" }

    func schema(of document: String) -> Int { 1 }
    func text(of document: String) -> String { document }
    func parse(_ text: String) throws -> String { text }

    func loadLocal() throws -> String {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return emptyDocument }
        return String(decoding: try Data(contentsOf: documentURL), as: UTF8.self)
    }

    func save(_ document: String, backup: SyncBackupPolicy) throws -> URL? {
        try TestFiles.write(document, to: documentURL, backup: backup)
    }

    func validationErrors(in document: String) -> [String] {
        document.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("allow ") || line.hasPrefix("deny ") { return nil }
            return "line \(index + 1): expected allow, deny or a comment"
        }
    }

    func merge(base: String, local: String, remote: String) -> SyncMerge<OrderedTextHost> {
        if local == base || local == remote { return SyncMerge(merged: remote) }
        if remote == base { return SyncMerge(merged: local) }
        return SyncMerge(merged: local, conflicts: [Conflict(local: local, remote: remote)])
    }

    func changes(from old: String, to new: String) -> [Change] {
        if old == new { return [] }
        let before = old.components(separatedBy: "\n"), after = new.components(separatedBy: "\n")
        if before != after, before.sorted() == after.sorted() { return [Change(kind: .reordered, line: "")] }
        let removed = before.filter { !after.contains($0) }.map { Change(kind: .removed, line: $0) }
        let added = after.filter { !before.contains($0) }.map { Change(kind: .added, line: $0) }
        let all = removed + added
        return all.isEmpty ? [Change(kind: .other, line: "")] : all
    }

    func summary(of changes: [Change], maxLength: Int) -> String {
        String(changes.map { "\($0.kind.rawValue) \($0.line)" }.joined(separator: "; ").prefix(maxLength))
    }

    func apply(mayPrompt: Bool) throws -> Report {
        let text = try loadLocal()
        applied.record(["text": text], mayPrompt: mayPrompt)
        return Report(text: text, preview: false)
    }

    func previewApply(of document: String) -> Report? { Report(text: document, preview: true) }
    func hasEffect(_ report: Report) -> Bool { report.text != applied.values["text"] }
}
