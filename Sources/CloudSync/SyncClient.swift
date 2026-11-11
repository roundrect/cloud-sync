import Foundation

public enum AdoptMode: String, Codable, Sendable, CaseIterable {
    /// Take the synced document; this Mac's file is backed up first.
    case remote
    /// Upload this Mac's file as a new revision.
    case local
    /// Union of both; where they disagree the synced value wins.
    case merge
}

public enum SyncState: String, Codable, Sendable, Equatable {
    case notLinked, inSync, localChanges, remoteChanges, diverged, configMoved, offline, revoked
    case paymentRequired, upgradeRequired, disabled
    /// The synced file can't be read: nothing is pushed and a remote change is held.
    case waitingForValidFile
}

public struct SyncStatus: Sendable {
    public var state: SyncState
    public var record: SyncLinkRecord?
    /// The synced file as this process resolves it.
    public var documentURL: URL
    /// `nil` when the server wasn't asked or couldn't answer.
    public var remoteRev: Int?
    public var localChanges: Bool
    public var detail: String?
}

public struct PairingCode: Sendable, Equatable {
    public var code: String
    public var expiresIn: Int
    public var server: URL
    public var deviceName: String
}

public struct LinkRequest: Sendable {
    public var server: URL
    public var deviceName: String
    /// Set to create the account (first Mac); nil to join an existing one by pairing.
    public var invite: String?
    /// nil: remote when the account has a document, otherwise local.
    public var adopt: AdoptMode?
    /// Contacts nothing; reports what would happen.
    public var dryRun = false
    /// Run `SyncHost.apply` after writing the file.
    public var apply = true
    public var mayPrompt = true
    public var timeout: TimeInterval = 600
    public var pollInterval: TimeInterval = 2

    public init(server: URL, deviceName: String, invite: String? = nil, adopt: AdoptMode? = nil) {
        self.server = server
        self.deviceName = deviceName
        self.invite = invite
        self.adopt = adopt
    }
}

/// What adopting would do, shown before anything is written.
public struct LinkPreview<Host: SyncHost>: Sendable {
    public var adopt: AdoptMode
    public var remoteRev: Int
    public var changes: [Host.Change]
    /// A dry run of `SyncHost.apply` against the adopted document; nil when not applying.
    public var report: Host.Report?
}

public struct LinkResult<Host: SyncHost>: Sendable {
    public enum Outcome: String, Sendable { case linked, alreadyLinked, dryRun }

    public var outcome: Outcome
    public var record: SyncLinkRecord?
    public var documentURL: URL
    public var rev: Int
    /// `remote`, `local`, `merge` or `none`.
    public var adopted: String
    public var backup: URL?
    public var changes: [Host.Change] = []
    public var report: Host.Report?
    public var notes: [String] = []
}

public enum PullOutcome: String, Sendable { case pulled, upToDate, emptyAccount, dryRun }

public struct PullResult<Host: SyncHost>: Sendable {
    public var outcome: PullOutcome
    public var rev: Int
    public var previousRev: Int
    /// What changed in the file (or would, for a dry run).
    public var changes: [Host.Change] = []
    public var conflicts: [Host.Conflict] = []
    public var remoteDevice: String?
    public var backup: URL?
    public var fellBackToRemote = false
    /// This Mac still has edits the server doesn't (they were kept by the merge).
    public var localChanges = false
    public var report: Host.Report?
}

public enum PushOutcome: String, Sendable {
    case pushed, nothingToPush
    /// The server had newer changes; they were merged in and there was nothing left to upload.
    case mergedWithRemote
}

public struct PushResult<Host: SyncHost>: Sendable {
    public var outcome: PushOutcome
    public var rev: Int
    public var changes: [Host.Change] = []
    public var conflicts: [Host.Conflict] = []
    public var remoteDevice: String?
    public var backup: URL?
    public var fellBackToRemote = false
    public var report: Host.Report?
}

public enum RevertOutcome: String, Sendable { case reverted, dryRun }

public struct RevertResult<Host: SyncHost>: Sendable {
    public var outcome: RevertOutcome
    /// The revision created (or, for a dry run, that would be).
    public var rev: Int
    public var revertedTo: Int
    public var changes: [Host.Change]
    public var pull: PullResult<Host>?
}

public struct UnlinkResult: Sendable {
    public var outcome: String
    public var revoked: Bool
    public var documentURL: URL
    public var notes: [String] = []
}

public enum CloudDefaults {
    /// Sent when the host doesn't say which version it is.
    public static let unknownClientVersion = "0.0.0"
}

/// The one-shot sync operations a front-end uses. It writes the synced file only through
/// `SyncHost.save` and changes the Mac only through `SyncHost.apply`.
///
/// One instance may be used from several tasks: a pull or a push holds the link's lock end to end, so
/// they run one at a time, across processes too.
public struct SyncClient<Host: SyncHost>: Sendable {
    public var host: Host
    public var transport: any CloudTransport
    public var tokens: any TokenStore
    public var link: SyncLink
    public var clientVersion: String
    public var now: @Sendable () -> Date
    /// Injected so tests don't wait.
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        host: Host, transport: any CloudTransport, tokens: any TokenStore, link: SyncLink,
        clientVersion: String = CloudDefaults.unknownClientVersion,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.host = host
        self.transport = transport
        self.tokens = tokens
        self.link = link
        self.clientVersion = clientVersion
        self.now = now
        self.sleep = sleep
    }

    /// The synced file.
    public var documentURL: URL { host.documentURL }

    private var wording: SyncWording { host.wording }

    // MARK: - Plumbing

    private func api(server: URL, token: String? = nil) -> CloudAPI {
        CloudAPI(server: server, transport: transport, clientVersion: clientVersion, namespace: host.namespace, token: token)
    }

    private func linkedRecord(requireEnabled: Bool = true) throws -> SyncLinkRecord {
        guard let record = try link.load() else { throw CloudError.notLinked }
        if requireEnabled, !record.enabled { throw CloudError.disabled }
        return record
    }

    private func authed(_ record: SyncLinkRecord) throws -> CloudAPI {
        guard let server = URL(string: record.server) else { throw CloudError.insecureServer("bad server address in sync.json: \(record.server)") }
        guard let token = try tokens.token(for: record.deviceId) else {
            throw CloudError.unauthorized("this Mac's sync token is missing; unlink and link again")
        }
        return api(server: server, token: token)
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    private func isMoved(_ record: SyncLinkRecord) -> Bool {
        !Self.samePath(record.linkedConfigPath, documentURL.path)
    }

    private func requireNotMoved(_ record: SyncLinkRecord) throws {
        if isMoved(record) { throw CloudError.configMoved(linked: record.linkedConfigPath, current: documentURL.path) }
    }

    /// Byte for byte: `String ==` treats canonically equivalent text as equal, which would hide an edit
    /// from a host whose file must survive exactly.
    private func same(_ a: Host.Document, _ b: Host.Document) -> Bool {
        host.text(of: a).utf8.elementsEqual(host.text(of: b).utf8)
    }

    private func isEmpty(_ document: Host.Document) -> Bool { same(document, host.emptyDocument) }

    private func loadLocal() throws -> Host.Document {
        do {
            return try host.loadLocal()
        } catch SyncHostError.unreadable(let reason) {
            throw CloudError.waitingForValidFile(reason)
        }
    }

    private func loadBase() -> Host.Document {
        guard let text = link.loadBase(), let document = try? host.parse(text) else { return host.emptyDocument }
        return document
    }

    private func decode(_ remote: RemoteDoc) throws -> Host.Document {
        guard let document = remote.document else { return host.emptyDocument }
        do {
            let body = try document.verifiedBody(format: host.format, maxSchema: host.maxSchema)
            do {
                return try host.parse(body)
            } catch {
                throw SyncDocumentError.unparseable(String(describing: error))
            }
        } catch let error as SyncDocumentError {
            throw CloudError.document(error)
        }
    }

    private func hasLocalChanges() throws -> Bool {
        !same(try loadLocal(), loadBase())
    }

    /// Records that the server's revision `rev` (`document`) is what this Mac is now based on.
    /// `locked`: the caller already holds the link's lock (a whole pull or push does).
    private func commit(_ record: SyncLinkRecord, rev: Int, base document: Host.Document, locked: Bool = false) throws -> SyncLinkRecord {
        func write() throws -> SyncLinkRecord {
            // Re-read, so a toggle made meanwhile isn't overwritten.
            var updated = (try? link.load()) ?? record
            updated.lastRev = rev
            updated.lastSyncedAt = now()
            updated.linkedConfigPath = documentURL.path
            try link.saveBase(host.text(of: document))
            try link.save(updated)
            return updated
        }
        return locked ? try write() : try link.withLock(write)
    }

    private func put(_ api: CloudAPI, _ document: Host.Document, over base: Host.Document, ifMatch: Int) async throws -> Int {
        let summary = host.summary(of: host.changes(from: base, to: document), maxLength: 200)
        let envelope = SyncDocument(format: host.format, schema: host.schema(of: document), body: host.text(of: document), summary: summary)
        return try await api.put(envelope, ifMatch: ifMatch)
    }

    private func validateForPush(_ document: Host.Document) throws {
        let errors = host.validationErrors(in: document)
        if !errors.isEmpty { throw CloudError.invalidLocalConfig(errors) }
    }

    // MARK: - Status

    /// Decides the state. Doesn't throw for anything the state can express; with `offline` it asks the
    /// server nothing.
    public func status(offline: Bool = false) async throws -> SyncStatus {
        guard let record = try link.load() else {
            return SyncStatus(state: .notLinked, record: nil, documentURL: documentURL, remoteRev: nil, localChanges: false)
        }
        func result(_ state: SyncState, remote: Int? = nil, changes: Bool = false, detail: String? = nil) -> SyncStatus {
            SyncStatus(state: state, record: record, documentURL: documentURL, remoteRev: remote, localChanges: changes, detail: detail)
        }
        guard record.enabled else { return result(.disabled) }
        if isMoved(record) { return result(.configMoved, detail: "linked to \(record.linkedConfigPath)") }

        var changes = false
        do {
            changes = try hasLocalChanges()
        } catch CloudError.waitingForValidFile(let reason) {
            return result(.waitingForValidFile, detail: reason)
        }
        if offline { return result(changes ? .localChanges : .inSync, changes: changes) }

        do {
            let remote = try await authed(record).doc()
            let behind = remote.rev > record.lastRev
            let state: SyncState = switch (changes, behind) {
            case (false, false): .inSync
            case (true, false): .localChanges
            case (false, true): .remoteChanges
            case (true, true): .diverged
            }
            return result(state, remote: remote.rev, changes: changes)
        } catch CloudError.offline(let reason) {
            return result(.offline, changes: changes, detail: reason)
        } catch CloudError.unauthorized(let reason) {
            return result(.revoked, changes: changes, detail: reason)
        } catch CloudError.namespaceMismatch(let reason) {
            return result(.revoked, changes: changes, detail: CloudError.namespaceMismatch(reason).message(wording))
        } catch CloudError.paymentRequired {
            return result(.paymentRequired, changes: changes)
        } catch CloudError.upgradeRequired(let reason) {
            return result(.upgradeRequired, changes: changes, detail: reason)
        }
    }

    // MARK: - Linking

    /// Links this Mac: creates the account (`invite`) or pairs with an already-linked Mac, then adopts
    /// the document. `onCode` shows the pairing code; `confirm` is asked before adopting changes to this
    /// Mac and may throw to refuse.
    public func link(
        _ request: LinkRequest,
        onCode: @Sendable (PairingCode) -> Void = { _ in },
        confirm: (LinkPreview<Host>) async throws -> Bool = { _ in true }
    ) async throws -> LinkResult<Host> {
        if let existing = try link.load() {
            guard let current = URL(string: existing.server), CloudAPI.sameServer(current, request.server) else {
                let hint = wording.command("unlink").map { "; run \($0) first" } ?? ""
                throw CloudError.refused("already linked to \(existing.server)\(hint)")
            }
            return LinkResult(outcome: .alreadyLinked, record: existing, documentURL: documentURL, rev: existing.lastRev, adopted: "none")
        }
        try CloudAPI.requireAllowed(request.server)
        if request.dryRun {
            return LinkResult(outcome: .dryRun, record: nil, documentURL: documentURL, rev: 0, adopted: request.adopt?.rawValue ?? "none",
                              notes: ["dry run: nothing was contacted or written"])
        }

        let anonymous = api(server: request.server)
        let account: CreatedAccount
        if let invite = request.invite {
            account = try await anonymous.createAccount(invite: invite, deviceName: request.deviceName)
        } else {
            account = try await pair(anonymous, request, onCode: onCode)
        }
        try tokens.save(account.token, for: account.device.id)
        var record = SyncLinkRecord(
            server: request.server.absoluteString, accountId: account.accountId, deviceId: account.device.id,
            deviceName: account.device.name, linkedConfigPath: documentURL.path)
        try link.withLock { try link.save(record) }

        // Linked; adoption may still be refused without undoing that.
        let authedAPI = api(server: request.server, token: account.token)
        var result = LinkResult<Host>(outcome: .linked, record: record, documentURL: documentURL, rev: 0, adopted: "none")
        let remote = try await authedAPI.doc()
        let localDocument: Host.Document?
        var localProblem: String?
        do { localDocument = try loadLocal() } catch CloudError.waitingForValidFile(let reason) { localDocument = nil; localProblem = reason }

        if remote.isEmpty {
            if let localDocument, !isEmpty(localDocument) {
                try validateForPush(localDocument)
                let rev = try await put(authedAPI, localDocument, over: host.emptyDocument, ifMatch: 0)
                record = try commit(record, rev: rev, base: localDocument)
                result.rev = rev
                result.adopted = "local"
            } else if let localProblem {
                result.notes.append("the \(wording.fileName) wasn't uploaded: \(localProblem)")
            }
            result.record = record
            return result
        }

        let mode = request.adopt ?? .remote
        let remoteDocument = try decode(remote)
        switch mode {
        case .local:
            guard let localDocument else { throw CloudError.waitingForValidFile(localProblem ?? "") }
            try validateForPush(localDocument)
            let rev = try await put(authedAPI, localDocument, over: remoteDocument, ifMatch: remote.rev)
            record = try commit(record, rev: rev, base: localDocument)
            result.rev = rev
        case .remote, .merge:
            // A local file that can't be read is replaced (and backed up) like any other overwrite.
            let local = localDocument ?? host.emptyDocument
            let target = mode == .remote ? remoteDocument : host.merge(base: host.emptyDocument, local: remoteDocument, remote: local).merged
            let changes = host.changes(from: local, to: target)
            let report = request.apply ? host.previewApply(of: target) : nil
            if !changes.isEmpty || report.map(host.hasEffect) == true {
                let preview = LinkPreview<Host>(adopt: mode, remoteRev: remote.rev, changes: changes, report: report)
                guard try await confirm(preview) else { throw CloudError.refused("cancelled; this Mac is linked but its \(wording.documentName) were not changed") }
            }
            result.backup = try host.save(target, backup: .always)
            result.changes = changes
            var rev = remote.rev
            if !same(target, remoteDocument) {
                rev = try await put(authedAPI, target, over: remoteDocument, ifMatch: remote.rev)
            }
            record = try commit(record, rev: rev, base: target)
            result.rev = rev
            if request.apply { result.report = try host.apply(mayPrompt: request.mayPrompt) }
        }
        result.adopted = mode.rawValue
        result.record = record
        return result
    }

    private func pair(_ api: CloudAPI, _ request: LinkRequest, onCode: @Sendable (PairingCode) -> Void) async throws -> CreatedAccount {
        let start = try await api.pairStart(deviceName: request.deviceName)
        onCode(PairingCode(code: start.code, expiresIn: start.expiresIn, server: request.server, deviceName: request.deviceName))
        var waited: TimeInterval = 0
        while waited < request.timeout {
            switch try await api.pairPoll(start) {
            case .approved(let account): return account
            case .expired: throw CloudError.approvalExpired
            case .pending: break
            }
            try await sleep(request.pollInterval)
            waited += request.pollInterval
        }
        throw CloudError.approvalTimedOut
    }

    /// Approves another Mac's pairing code. `confirm` gets the requesting device's name first.
    @discardableResult
    public func approve(code: String, confirm: (String) async throws -> Bool = { _ in true }) async throws -> String {
        let api = try authed(try linkedRecord())
        let name = try await api.pairApprove(code: code, confirm: false)
        guard try await confirm(name) else { throw CloudError.refused("cancelled; “\(name)” was not approved") }
        try await api.pairApprove(code: code, confirm: true)
        return name
    }

    /// Revokes this device (unless `keepDevice`) and forgets the link. The synced file and the Mac stay
    /// exactly as they are. Works offline.
    public func unlink(keepDevice: Bool = false) async throws -> UnlinkResult {
        guard let record = try link.load() else { return UnlinkResult(outcome: "notLinked", revoked: false, documentURL: documentURL) }
        var revoked = false
        var notes: [String] = []
        if !keepDevice {
            do {
                try await authed(record).revoke(deviceID: record.deviceId)
                revoked = true
            } catch CloudError.unauthorized {
                notes.append("this Mac had already been removed from sync")
            } catch {
                let hint = wording.command("devices revoke").map { " (\($0))" } ?? ""
                notes.append("couldn't reach the sync service: revoke “\(record.deviceName)” from another Mac\(hint)")
            }
        }
        try tokens.delete(for: record.deviceId)
        try link.remove()
        return UnlinkResult(outcome: "unlinked", revoked: revoked, documentURL: documentURL, notes: notes)
    }

    public func setEnabled(_ enabled: Bool) throws -> SyncLinkRecord {
        var record = try linkedRecord(requireEnabled: false)
        record.enabled = enabled
        try link.withLock { try link.save(record) }
        return record
    }

    // MARK: - Pull and push

    /// Fetches the server's document, merges it with any local edits, writes the synced file and (unless
    /// `apply` is false) makes the Mac match through `SyncHost.apply`.
    ///
    /// The link's lock is held from the first request to the last write, so two front-ends can't
    /// interleave a pull or a push (the second waits).
    public func pull(apply: Bool = true, dryRun: Bool = false, mayPrompt: Bool = true) async throws -> PullResult<Host> {
        try await link.withExclusiveAccess { try await pullLocked(apply: apply, dryRun: dryRun, mayPrompt: mayPrompt) }
    }

    private func pullLocked(apply: Bool, dryRun: Bool, mayPrompt: Bool) async throws -> PullResult<Host> {
        let record = try linkedRecord()
        let moved = isMoved(record)
        let api = try authed(record)
        let remote = try await api.doc()

        if remote.isEmpty {
            return PullResult(outcome: .emptyAccount, rev: 0, previousRev: record.lastRev)
        }
        if !moved, remote.rev == record.lastRev {
            var result = PullResult<Host>(outcome: .upToDate, rev: remote.rev, previousRev: record.lastRev)
            result.localChanges = (try? hasLocalChanges()) ?? false
            if apply, !dryRun { result.report = try host.apply(mayPrompt: mayPrompt) }
            return result
        }

        let remoteDocument = try decode(remote)
        let local = try loadLocal()
        let base = loadBase()
        var result = PullResult<Host>(outcome: dryRun ? .dryRun : .pulled, rev: remote.rev, previousRev: record.lastRev)
        result.remoteDevice = remote.deviceName

        let target: Host.Document
        if moved || same(local, base) {
            target = remoteDocument
        } else {
            let merge = host.merge(base: base, local: local, remote: remoteDocument)
            target = merge.merged
            result.conflicts = merge.conflicts
            result.fellBackToRemote = merge.fellBackToRemote
            result.localChanges = !merge.fellBackToRemote && !same(target, remoteDocument)
        }
        result.changes = host.changes(from: local, to: target)
        if dryRun { return result }

        result.backup = try host.save(target, backup: moved || result.fellBackToRemote ? .always : .ifStale)
        _ = try commit(record, rev: remote.rev, base: remoteDocument, locked: true)
        if apply { result.report = try host.apply(mayPrompt: mayPrompt) }
        return result
    }

    /// Uploads this Mac's edits. A stale revision is merged with the server's and retried; the merged
    /// file is written back. `force` is for `configMoved`: it uploads the current file regardless.
    /// Holds the link's lock throughout, like `pull`.
    public func push(force: Bool = false, apply: Bool = true, mayPrompt: Bool = true) async throws -> PushResult<Host> {
        try await link.withExclusiveAccess { try await pushLocked(force: force, apply: apply, mayPrompt: mayPrompt) }
    }

    private func pushLocked(force: Bool, apply: Bool, mayPrompt: Bool) async throws -> PushResult<Host> {
        var record = try linkedRecord()
        let moved = isMoved(record)
        if moved, !force { try requireNotMoved(record) }
        let api = try authed(record)

        var current = try loadLocal()
        try validateForPush(current)
        var base = loadBase()
        var ifMatch = record.lastRev
        if moved {
            // Overwriting whatever the account holds with this file, as asked.
            let head = try await api.doc()
            ifMatch = head.rev
            base = head.isEmpty ? host.emptyDocument : (try? decode(head)) ?? host.emptyDocument
        } else if same(current, base) {
            return PushResult(outcome: .nothingToPush, rev: record.lastRev)
        }

        var result = PushResult<Host>(outcome: .pushed, rev: ifMatch)
        result.changes = host.changes(from: base, to: current)
        var wroteRemoteChanges = false
        for attempt in 1...4 {
            do {
                let rev = try await put(api, current, over: base, ifMatch: ifMatch)
                _ = try commit(record, rev: rev, base: current, locked: true)
                result.rev = rev
                break
            } catch CloudError.conflict(let remote) {
                guard attempt < 4 else { throw CloudError.conflict(remote) }
                let remoteDocument = remote.isEmpty ? host.emptyDocument : try decode(remote)
                let merge = host.merge(base: base, local: current, remote: remoteDocument)
                result.conflicts += merge.conflicts
                result.remoteDevice = remote.deviceName
                result.fellBackToRemote = result.fellBackToRemote || merge.fellBackToRemote
                if let backup = try host.save(merge.merged, backup: merge.fellBackToRemote ? .always : .ifStale) { result.backup = backup }
                wroteRemoteChanges = true
                record = try commit(record, rev: remote.rev, base: remoteDocument, locked: true)
                base = remoteDocument
                ifMatch = remote.rev
                current = merge.merged
                result.rev = remote.rev
                if merge.fellBackToRemote || same(current, remoteDocument) {
                    result.outcome = .mergedWithRemote
                    break
                }
            }
        }
        if apply, wroteRemoteChanges { result.report = try host.apply(mayPrompt: mayPrompt) }
        return result
    }

    // MARK: - Live connection

    /// Opens the live WebSocket (`CloudSession` is the only caller). Reads the device token, so it
    /// happens only while sync is on.
    public func openSocket() async throws -> any CloudSocket {
        try await authed(try linkedRecord()).openSocket()
    }

    // MARK: - History

    public func history(limit: Int = 20, before: Int? = nil) async throws -> HistoryPage {
        try await authed(try linkedRecord()).history(before: before, limit: limit)
    }

    /// The change from the current document to revision `rev`.
    public func revisionDiff(_ rev: Int) async throws -> (revision: RemoteDoc, changes: [Host.Change]) {
        let api = try authed(try linkedRecord())
        async let head = api.doc()
        let target = try await api.revision(rev)
        let current = try await head
        let changes = host.changes(from: current.isEmpty ? host.emptyDocument : try decode(current), to: try decode(target))
        return (target, changes)
    }

    /// What `rev` changed from the version before it; for version 1, everything in it. `nil` when the
    /// version before has been pruned.
    public func changesMade(in rev: Int) async throws -> [Host.Change]? {
        let api = try authed(try linkedRecord())
        let target = try decode(try await api.revision(rev))
        guard rev > 1 else { return host.changes(from: host.emptyDocument, to: target) }
        do {
            return host.changes(from: try decode(try await api.revision(rev - 1)), to: target)
        } catch CloudError.notFound {
            return nil
        }
    }

    /// Creates a new revision with the body of `rev`, then pulls it. A dry run makes no write on the
    /// server (it does read the current document and that revision to show the diff).
    public func revert(to rev: Int, dryRun: Bool = false, apply: Bool = true, mayPrompt: Bool = true) async throws -> RevertResult<Host> {
        guard rev >= 1 else { throw CloudError.refused("revision numbers start at 1") }
        let record = try linkedRecord()
        try requireNotMoved(record)
        let api = try authed(record)
        let head = try await api.doc()
        let target = try await api.revision(rev)
        let changes = host.changes(from: head.isEmpty ? host.emptyDocument : try decode(head), to: try decode(target))
        if dryRun { return RevertResult(outcome: .dryRun, rev: head.rev + 1, revertedTo: rev, changes: changes, pull: nil) }

        var summary = "Reverted to rev \(rev)"
        let detail = host.summary(of: changes, maxLength: 150)
        if !detail.isEmpty { summary += ": " + detail }
        let newRev = try await api.revert(to: rev, ifMatch: head.rev, summary: summary)
        let pulled = try await pull(apply: apply, mayPrompt: mayPrompt)
        return RevertResult(outcome: .reverted, rev: newRev, revertedTo: rev, changes: changes, pull: pulled)
    }

    // MARK: - Devices

    /// The Macs linked to this account. By default only this app's: the list spans the account, so one Mac shows once
    /// for every app it links, and another app's devices cannot be revoked or renamed from here. Pass
    /// `includingOtherApps` for the whole account; each device's `namespace` says which app it belongs to.
    public func devices(includingOtherApps: Bool = false) async throws -> [DeviceInfo] {
        let all = try await authed(try linkedRecord(requireEnabled: false)).devices()
        return includingOtherApps ? all : all.filter { $0.namespace == host.namespace }
    }

    /// Revokes another device by id or (case-insensitive) name. Revoking this Mac is `unlink`.
    @discardableResult
    public func revoke(_ nameOrID: String) async throws -> DeviceInfo {
        let api = try authed(try linkedRecord(requireEnabled: false))
        // The list spans the account, and one Mac has the same name in every app it links; only this app's can be revoked.
        let all = try await api.devices().filter { $0.namespace == host.namespace }
        let matches = all.filter { $0.id == nameOrID } + all.filter { $0.id != nameOrID && $0.name.lowercased() == nameOrID.lowercased() }
        let listing = wording.command("devices")
        guard let device = matches.first else { throw CloudError.notFound("no device named “\(nameOrID)”" + (listing.map { " (see \($0))" } ?? "")) }
        guard matches.count == 1 else { throw CloudError.refused("“\(nameOrID)” matches \(matches.count) devices" + (listing.map { "; use the id from \($0)" } ?? "")) }
        guard !device.current else { throw CloudError.refused("that is this Mac" + (wording.command("unlink").map { "; \($0) removes it" } ?? "")) }
        try await api.revoke(deviceID: device.id)
        return device
    }
}
