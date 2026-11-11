import Foundation

/// Where a live session stands.
public enum CloudSessionState: Equatable, Sendable {
    /// Not running: never started, switched off, or stopped by `stop()`.
    case stopped
    case connecting
    /// Connected; `rev` is the revision this Mac is based on.
    case connected(rev: Int)
    /// The connection dropped or couldn't be made; the next try is at `retryAt`.
    case offline(retryAt: Date, reason: String)
    /// This Mac is asleep (or about to be): no connection is held until `wake()`.
    case suspended
    /// 401: this Mac was removed. Also 403 `namespace_mismatch`, where the link can't be used on this
    /// server and the string says why. Not retried.
    case revoked(String)
    /// 402. Not retried.
    case paymentRequired
    /// 426, or a synced document this build can't read. Not retried.
    case upgradeRequired(String)
    /// The synced file is no longer the one this Mac linked. Nothing is sent or applied.
    case configMoved
    /// The synced file can't be read or is invalid, so nothing is pushed and remote changes are held.
    case waitingForValidFile(String)
}

public enum CloudSessionEvent<Host: SyncHost>: Sendable {
    case state(CloudSessionState)
    /// A remote change was merged into the synced file (or a pull found conflicts). The app applies it
    /// through the same path as any edit.
    case pulled(PullResult<Host>)
    case pushed(PushResult<Host>)
}

/// Time as the session sees it, so tests don't wait.
public struct CloudClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = CloudClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}

/// The one live connection to the sync service: connect, `hello` → catch up, then listen for other
/// Macs' writes; protocol pings keep it alive; reconnect with `Backoff`.
///
/// It exists only while sync is on and linked. Remote changes are merged into the synced file with
/// `apply: false`; the app then applies them like any other edit.
public actor CloudSession<Host: SyncHost> {
    private struct Message: Decodable {
        var type: String
        var rev: Int?
        var deviceId: String?
    }

    private let cloud: SyncClient<Host>
    private let clock: CloudClock
    private let random: @Sendable () -> Double
    private let pingInterval: TimeInterval
    private let onEvent: @Sendable (CloudSessionEvent<Host>) -> Void

    private var loopTask: Task<Void, Never>?
    private var backoffTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var wakeWaiter: CheckedContinuation<Void, Never>?
    private var socket: (any CloudSocket)?
    private var stopped = true
    private var paused = false
    private var attempt = 0
    private var lastState: CloudSessionState?

    // Work in hand for the current connection.
    private var needsPull = false
    private var needsPush = false
    private var working = false
    private var terminal: CloudSessionState?

    public init(
        cloud: SyncClient<Host>, clock: CloudClock = .system, pingInterval: TimeInterval = 45,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        onEvent: @escaping @Sendable (CloudSessionEvent<Host>) -> Void
    ) {
        self.cloud = cloud
        self.clock = clock
        self.pingInterval = pingInterval
        self.random = random
        self.onEvent = onEvent
    }

    // MARK: - Control

    public func start() {
        guard stopped else { return }
        stopped = false
        paused = false
        attempt = 0
        loopTask = Task { await self.loop() }
    }

    /// Tears everything down. When this returns no request is in flight and none will follow.
    public func stop() async {
        stopped = true
        backoffTask?.cancel()
        pingTask?.cancel()
        wakeWaiter?.resume()
        wakeWaiter = nil
        await socket?.close()
        let task = loopTask
        loopTask = nil
        task?.cancel()
        await task?.value
        socket = nil
        needsPull = false
        needsPush = false
        emit(.stopped)
    }

    /// The Mac is going to sleep: drop the connection and stay down until `wake()`.
    public func suspend() async {
        guard !stopped, !paused else { return }
        paused = true
        backoffTask?.cancel()
        await socket?.close()
    }

    /// The Mac woke up: reconnect now, with a fresh backoff.
    public func wake() {
        guard !stopped else { return }
        paused = false
        attempt = 0
        backoffTask?.cancel()
        wakeWaiter?.resume()
        wakeWaiter = nil
    }

    /// The network came back (or changed). Reconnects at once if the session is waiting out a backoff;
    /// if it believes it is connected, checks with a ping.
    public func pathSatisfied() async {
        guard !stopped, !paused else { return }
        attempt = 0
        if let socket {
            do { try await socket.sendPing() } catch { await socket.close() }
        } else {
            backoffTask?.cancel()
        }
    }

    /// The synced file changed. Pushes it (the work is a no-op when it equals the last synced
    /// version). When not connected nothing is sent: the catch-up after the next `hello` finds the edit.
    public func localFileChanged() async {
        guard !stopped, !paused, socket != nil, terminal == nil else { return }
        needsPush = true
        await work()
    }

    // MARK: - The loop

    private func emit(_ state: CloudSessionState) {
        guard state != lastState else { return }
        lastState = state
        onEvent(.state(state))
    }

    private func lastRev() -> Int { (try? cloud.link.load())?.lastRev ?? 0 }

    private func loop() async {
        while !stopped {
            if paused {
                emit(.suspended)
                await waitForWake()
                continue
            }
            emit(.connecting)
            var reason = "connection lost"
            do {
                let status = try await cloud.status(offline: true)
                switch status.state {
                case .notLinked, .disabled:
                    emit(.stopped)
                    stopped = true
                    return
                case .configMoved:
                    emit(.configMoved)
                    return
                default: break
                }
                let opened = try await cloud.openSocket()
                if stopped || paused {
                    await opened.close()
                    continue
                }
                socket = opened
                let connectedAt = clock.now()
                let ended = await serve(opened)
                socket = nil
                if let ended {
                    emit(ended)
                    return
                }
                if clock.now().timeIntervalSince(connectedAt) >= Backoff.healthyAfter { attempt = 0 }
            } catch let error as CloudError {
                switch error {
                case .unauthorized(let message): emit(.revoked(message)); return
                case .namespaceMismatch: emit(.revoked(error.message(cloud.host.wording))); return
                case .paymentRequired: emit(.paymentRequired); return
                case .upgradeRequired(let message): emit(.upgradeRequired(message)); return
                default: reason = error.message(cloud.host.wording)
                }
            } catch is CancellationError {
                return
            } catch {
                reason = error.localizedDescription
            }
            guard !stopped else { return }
            if paused { continue }
            let delay = Backoff.delay(attempt: attempt, random: random())
            attempt += 1
            emit(.offline(retryAt: clock.now().addingTimeInterval(delay), reason: reason))
            let clock = clock
            let sleeper = Task { _ = try? await clock.sleep(delay) }
            backoffTask = sleeper
            await sleeper.value
            backoffTask = nil
        }
    }

    private func waitForWake() async {
        guard paused, !stopped else { return }
        await withCheckedContinuation { wakeWaiter = $0 }
    }

    /// Listens until the socket ends. Returns the state to stop in, or `nil` to reconnect.
    private func serve(_ socket: any CloudSocket) async -> CloudSessionState? {
        terminal = nil
        let interval = pingInterval
        let clock = clock
        pingTask = Task {
            while !Task.isCancelled {
                do {
                    try await clock.sleep(interval)
                    try await socket.sendPing()
                } catch {
                    await socket.close()
                    return
                }
            }
        }
        do {
            while !stopped, terminal == nil {
                await handle(try await socket.receive())
            }
        } catch {}
        pingTask?.cancel()
        pingTask = nil
        needsPull = false
        needsPush = false
        await socket.close()
        return terminal
    }

    private func handle(_ text: String) async {
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { return }
        let record = try? cloud.link.load()
        switch message.type {
        case "hello":
            needsPull = (message.rev ?? 0) > (record?.lastRev ?? 0)
            // An edit made while offline is simply a file that differs from the last synced version.
            needsPush = (try? await cloud.status(offline: true))?.localChanges ?? false
            emit(.connected(rev: record?.lastRev ?? 0))
            await work()
        case "doc":
            guard let rev = message.rev, rev > (record?.lastRev ?? 0), message.deviceId != record?.deviceId else { return }
            needsPull = true
            await work()
        default:
            break   // pong, and anything a newer server adds
        }
    }

    /// Pull then push, one at a time; requests that arrive meanwhile are folded into the next round.
    private func work() async {
        guard !working else { return }
        working = true
        defer { working = false }
        while !stopped, terminal == nil, needsPull || needsPush {
            let wantsPull = needsPull
            var wantsPush = needsPush
            needsPull = false
            needsPush = false
            do {
                if wantsPull {
                    let result = try await cloud.pull(apply: false, mayPrompt: false)
                    if result.outcome == .pulled || !result.conflicts.isEmpty { onEvent(.pulled(result)) }
                    if result.localChanges { wantsPush = true }
                }
                if wantsPush {
                    let result = try await cloud.push(apply: false, mayPrompt: false)
                    if result.outcome != .nothingToPush { onEvent(.pushed(result)) }
                    if !result.conflicts.isEmpty || result.outcome == .mergedWithRemote { onEvent(.pulled(PullResult<Host>(outcome: .pulled, rev: result.rev, previousRev: result.rev, changes: [], conflicts: result.conflicts, remoteDevice: result.remoteDevice))) }
                }
                emit(.connected(rev: lastRev()))
            } catch let error as CloudError {
                switch error {
                case .unauthorized(let message): terminal = .revoked(message)
                case .namespaceMismatch: terminal = .revoked(error.message(cloud.host.wording))
                case .paymentRequired: terminal = .paymentRequired
                case .upgradeRequired(let message): terminal = .upgradeRequired(message)
                case .document(let problem): terminal = .upgradeRequired(problem.message(cloud.host.wording))
                case .configMoved: terminal = .configMoved
                case .notLinked, .disabled: terminal = .stopped
                case .waitingForValidFile(let reason):
                    // Held, not dropped: the next local change retries.
                    needsPull = wantsPull
                    needsPush = wantsPush
                    emit(.waitingForValidFile(reason))
                    return
                case .invalidLocalConfig(let problems):
                    needsPull = wantsPull
                    needsPush = wantsPush
                    emit(.waitingForValidFile(problems.first ?? "the \(cloud.host.wording.fileName) has errors"))
                    return
                default:
                    // Offline, a server hiccup, a push that kept losing the race: drop the connection;
                    // the reconnect's catch-up starts again from what is actually on disk.
                    await socket?.close()
                    return
                }
            } catch {
                await socket?.close()
                return
            }
        }
    }
}
