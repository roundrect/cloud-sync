import Foundation

/// Everything that can go wrong talking to, or syncing with, the sync service.
public enum CloudError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server couldn't be reached (no network, DNS, timeout).
    case offline(String)
    /// 401: the token is wrong or this Mac was revoked. Never retried.
    case unauthorized(String)
    /// 401 on account creation: the invite is wrong.
    case invalidInvite
    /// 403 `namespace_mismatch`: this Mac's token belongs to another app on the server, or the request
    /// named another app's routes. Never retried.
    case namespaceMismatch(String)
    /// 402: the account needs a subscription. Never retried.
    case paymentRequired
    /// 426: this build is older than the server's `minClient`. Never retried.
    case upgradeRequired(String)
    /// 409: the document moved on; carries the current one so the caller can merge without another round trip.
    case conflict(RemoteDoc)
    case rateLimited(String)
    case notFound(String)
    /// A pairing code that is wrong, expired or already used.
    case invalidCode
    case server(status: Int, message: String)
    /// A plain-http or otherwise unacceptable server URL.
    case insecureServer(String)
    case document(SyncDocumentError)
    case notLinked
    /// Linked, but switched off.
    case disabled
    /// The synced file is no longer the file this Mac linked.
    case configMoved(linked: String, current: String)
    /// The synced file can't be read, so nothing is pushed and a remote change is held.
    case waitingForValidFile(String)
    /// The synced file reads but has validation errors; it is never pushed.
    case invalidLocalConfig([String])
    case approvalTimedOut
    case approvalExpired
    /// Declined or not allowed (no confirmation, a name that matches several devices, …).
    case refused(String)
    /// Keychain / token store trouble.
    case local(String)

    public var description: String { message(.neutral) }

    public func message(_ wording: SyncWording) -> String {
        switch self {
        case .offline(let reason): "can't reach the sync service: \(reason)"
        case .unauthorized(let message): "not authorised: \(message)"
        case .namespaceMismatch(let message): "this Mac's sync link belongs to a different app on the sync service: \(message)"
        case .invalidInvite: "that invite is not valid"
        case .paymentRequired: "Sync needs a subscription"
        case .upgradeRequired(let message): "Update \(wording.appName) to keep syncing (\(message))"
        case .conflict: "the synced \(wording.documentName) changed on another Mac; try again"
        case .rateLimited(let message): message
        case .notFound(let message): message
        case .invalidCode: "that code is wrong or has expired"
        case .server(let status, let message): "the sync service answered \(status): \(message)"
        case .insecureServer(let message): message
        case .document(let error): error.message(wording)
        case .notLinked:
            "this Mac isn't linked to sync" + (wording.command("link").map { " (run \($0))" } ?? "")
        case .disabled:
            "sync is switched off on this Mac" + (wording.command("sync enable").map { " (\($0) turns it on)" } ?? "")
        case .configMoved(let linked, let current):
            "this Mac's \(wording.fileName) changed from \(linked) to \(current)"
                + (wording.command("pull").flatMap { pull in
                    wording.command("push --force").map { "; \(pull) uses the synced \(wording.documentName) there, \($0) uploads that file" }
                } ?? "")
        case .waitingForValidFile(let reason): "waiting: fix the \(wording.fileName) first (\(reason))"
        case .invalidLocalConfig(let problems): "the \(wording.fileName) has errors, so it was not uploaded:\n" + problems.joined(separator: "\n")
        case .approvalTimedOut: "timed out waiting for another Mac to approve this one"
        case .approvalExpired: "the pairing code expired before it was approved"
        case .refused(let message): message
        case .local(let message): message
        }
    }
}
