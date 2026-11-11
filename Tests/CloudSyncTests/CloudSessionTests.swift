import Foundation
import Testing
@testable import CloudSync

private let groceries = "groceries"
private let todo = "todo"
private let ideas = "ideas"

// MARK: - Fakes

/// A scripted WebSocket: the test pushes frames in, and can drop it.
final class FakeSocket: CloudSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<String, any Error>] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var _closed = false
    private var _pings = 0
    var failPings = false

    var closed: Bool { lock.withLock { _closed } }
    var pings: Int { lock.withLock { _pings } }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { register($0) }
    }

    private func register(_ continuation: CheckedContinuation<String, any Error>) {
        lock.lock()
        if !queue.isEmpty {
            let next = queue.removeFirst()
            lock.unlock()
            continuation.resume(with: next)
        } else if _closed {
            lock.unlock()
            continuation.resume(throwing: CloudError.offline("closed"))
        } else {
            waiter = continuation
            lock.unlock()
        }
    }

    func sendPing() async throws {
        if failPings { throw CloudError.offline("ping failed") }
        lock.withLock { _pings += 1 }
    }

    func close() async { shut() }

    private func shut() {
        lock.lock()
        _closed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: CloudError.offline("closed"))
    }

    private func deliver(_ result: Result<String, any Error>) {
        lock.lock()
        if let pending = waiter {
            waiter = nil
            lock.unlock()
            pending.resume(with: result)
        } else {
            queue.append(result)
            lock.unlock()
        }
    }

    func send(_ text: String) { deliver(.success(text)) }
    func hello(_ rev: Int) { send(#"{"type":"hello","rev":\#(rev)}"#) }
    func doc(_ rev: Int, from deviceId: String = "dev_other") { send(#"{"type":"doc","rev":\#(rev),"deviceId":"\#(deviceId)","deviceName":"Other Mac"}"#) }
    func drop() { deliver(.failure(CloudError.offline("connection lost"))) }
}

/// HTTP goes to the fake server; sockets come from a script.
final class SessionTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let server: FakeCloudServer
    private var plan: [Result<FakeSocket, CloudError>] = []
    private var _opened: [FakeSocket] = []
    private var _attempts = 0

    init(_ server: FakeCloudServer) { self.server = server }

    /// Queues the outcome of the next `openSocket` and returns the socket when it will succeed.
    @discardableResult
    func expectSocket() -> FakeSocket {
        let socket = FakeSocket()
        lock.withLock { plan.append(.success(socket)) }
        return socket
    }

    func expectFailure(_ error: CloudError = .offline("no route")) { lock.withLock { plan.append(.failure(error)) } }

    var attempts: Int { lock.withLock { _attempts } }
    var opened: [FakeSocket] { lock.withLock { _opened } }

    func send(_ request: CloudRequest) async throws -> CloudResponse { try await server.send(request) }

    func openSocket(_ request: CloudRequest) async throws -> any CloudSocket {
        let next: Result<FakeSocket, CloudError>? = lock.withLock {
            _attempts += 1
            let next = plan.isEmpty ? nil : plan.removeFirst()
            if case .success(let socket)? = next { _opened.append(socket) }
            return next
        }
        guard let next else { throw CloudError.offline("nothing scripted") }
        return try next.get()
    }
}

/// Time that only moves when the test says so.
final class FakeClock: @unchecked Sendable {
    private struct Waiter {
        var id: UUID
        var deadline: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []
    private var _sleeps: [TimeInterval] = []

    var cloudClock: CloudClock { CloudClock(now: { self.now() }, sleep: { try await self.sleep($0) }) }

    func now() -> Date { lock.withLock { current } }
    var sleepers: Int { lock.withLock { waiters.count } }
    /// Every duration anything asked to sleep, minus the keep-alive's.
    func backoffs(pingInterval: TimeInterval = 45) -> [TimeInterval] { lock.withLock { _sleeps.filter { $0 != pingInterval } } }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                register(id, seconds, continuation)
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func register(_ id: UUID, _ seconds: TimeInterval, _ continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        _sleeps.append(seconds)
        if cancelled.remove(id) != nil {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            waiters.append(Waiter(id: id, deadline: current.addingTimeInterval(seconds), continuation: continuation))
            lock.unlock()
        }
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
            lock.unlock()
        }
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = waiters.filter { $0.deadline <= current }
        waiters.removeAll { $0.deadline <= current }
        lock.unlock()
        for waiter in due { waiter.continuation.resume() }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CloudSessionEvent<NotesHost>] = []

    func add(_ event: CloudSessionEvent<NotesHost>) { lock.withLock { events.append(event) } }

    var states: [CloudSessionState] { lock.withLock { events.compactMap { if case .state(let state) = $0 { state } else { nil } } } }
    var last: CloudSessionState? { states.last }
    var pulled: [PullResult<NotesHost>] { lock.withLock { events.compactMap { if case .pulled(let result) = $0 { result } else { nil } } } }
    var pushed: [PushResult<NotesHost>] { lock.withLock { events.compactMap { if case .pushed(let result) = $0 { result } else { nil } } } }
}

/// Polls (in real time, briefly) until `condition` holds.
func eventually(_ seconds: TimeInterval = 3, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(4))
    }
    return condition()
}

/// A linked fake Mac with a session over a scripted transport. Linked at rev 1 holding one note.
final class SessionHarness: @unchecked Sendable {
    let server = FakeCloudServer()
    let transport: SessionTransport
    let mac: NotesMac
    let clock = FakeClock()
    let log = EventLog()
    private(set) var session: CloudSession<NotesHost>!

    init(text: String? = notes([groceries: "milk"]), link: Bool = true) async throws {
        transport = SessionTransport(server)
        mac = try NotesMac(transport: transport, server: server, text: text)
        if link { _ = try await mac.linkCreate() }
        let log = log
        session = CloudSession(cloud: mac.cloud, clock: clock.cloudClock, random: { 1.0 }, onEvent: { log.add($0) })
    }

    /// Starts the session against one successful socket and says hello at the Mac's own revision.
    @discardableResult
    func connect(helloRev: Int? = nil) async -> FakeSocket {
        let socket = transport.expectSocket()
        await session.start()
        _ = await eventually { self.transport.opened.contains { $0 === socket } }
        socket.hello(helloRev ?? ((try? mac.link.load())?.lastRev ?? 0))
        _ = await eventually { if case .connected = self.log.last { true } else { false } }
        return socket
    }

    func lastRev() -> Int { (try? mac.link.load())?.lastRev ?? -1 }

    func waitForOffline() async -> Bool {
        await eventually { if case .offline = self.log.last { true } else { false } }
    }

    /// Waits until the session is sleeping out a backoff, so the clock can be advanced.
    func waitForBackoffSleeper() async -> Bool {
        await eventually { self.clock.sleepers >= 1 && { if case .offline = self.log.last { true } else { false } }() }
    }
}

// MARK: - Tests

@Suite("CloudSession")
struct CloudSessionTests {
    @Test func helloWithAHigherRevisionPullsTheDocument() async throws {
        let h = try await SessionHarness()
        h.server.writeAsOtherDevice([ideas: "boat"], name: "Mac mini")
        let before = h.server.count("GET", "/v1/doc")
        await h.connect(helloRev: 2)
        #expect(await eventually { h.lastRev() == 2 })
        #expect(h.server.count("GET", "/v1/doc") == before + 1)
        #expect(try h.mac.canonical().contains(ideas))
        // The session writes the file only. Applying to the Mac is the app's job.
        #expect(h.mac.applied.applyCount == 0)
        #expect(await eventually { h.log.pulled.count == 1 })
        #expect(h.log.pulled.first?.remoteDevice == "Mac mini")
        #expect(await eventually { h.log.last == .connected(rev: 2) })
        await h.session.stop()
    }

    @Test func aHelloAtTheSameRevisionDoesNothing() async throws {
        let h = try await SessionHarness()
        let before = h.server.requests.count
        await h.connect()
        #expect(h.server.requests.count == before)
        #expect(h.log.pulled.isEmpty && h.log.pushed.isEmpty)
        await h.session.stop()
    }

    @Test func broadcastsOfOurOwnWritesAndOldRevisionsAreIgnored() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        let deviceId = try #require(try h.mac.link.load()).deviceId
        let before = h.server.count("GET", "/v1/doc")

        socket.doc(5, from: deviceId)          // our own
        socket.doc(1)                          // not newer than what we have
        h.server.writeAsOtherDevice([ideas: "boat"])
        socket.doc(2)                          // a real one, processed after the two above
        #expect(await eventually { h.lastRev() == 2 })
        #expect(h.server.count("GET", "/v1/doc") == before + 1)
        await h.session.stop()
    }

    @Test func aDroppedSocketBacksOffThenReconnectsAndCatchesUp() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        socket.drop()
        #expect(await h.waitForBackoffSleeper())
        // Random is pinned to 1, so the first retry waits the ceiling: 1 s.
        #expect(h.log.last == .offline(retryAt: h.clock.now().addingTimeInterval(1), reason: "connection lost"))
        #expect(h.transport.attempts == 1)

        h.server.writeAsOtherDevice([ideas: "boat"])
        let second = h.transport.expectSocket()
        h.clock.advance(1)
        #expect(await eventually { h.transport.opened.contains { $0 === second } })
        second.hello(2)
        #expect(await eventually { h.lastRev() == 2 })
        #expect(try h.mac.canonical().contains(ideas))
        await h.session.stop()
    }

    @Test func wakeReconnectsImmediately() async throws {
        let h = try await SessionHarness()
        let first = await h.connect()
        await h.session.suspend()
        #expect(first.closed)
        #expect(await eventually { h.log.last == .suspended })
        h.clock.advance(1000)
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.transport.attempts == 1, "asleep: no reconnecting")

        let second = h.transport.expectSocket()
        await h.session.wake()
        #expect(await eventually { h.transport.opened.contains { $0 === second } })   // the clock never moved
        second.hello(1)
        #expect(await eventually { h.log.last == .connected(rev: 1) })
        await h.session.stop()
    }

    @Test func wakeCutsABackoffShort() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        socket.drop()
        #expect(await h.waitForBackoffSleeper())
        let next = h.transport.expectSocket()
        await h.session.wake()
        #expect(await eventually { h.transport.opened.contains { $0 === next } })
        await h.session.stop()
    }

    @Test func aPathComingBackResetsTheBackoff() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        socket.drop()
        h.transport.expectFailure()
        h.transport.expectFailure()
        #expect(await h.waitForBackoffSleeper())          // 1 s
        h.clock.advance(1)
        #expect(await eventually { h.transport.attempts == 2 && h.clock.backoffs().count == 2 })   // fails, waits 2 s
        h.clock.advance(2)
        #expect(await eventually { h.transport.attempts == 3 && h.clock.backoffs().count == 3 })   // fails, waits 4 s
        #expect(h.clock.backoffs() == [1, 2, 4])

        h.transport.expectFailure()
        await h.session.pathSatisfied()                    // no clock movement: tries now
        #expect(await eventually { h.transport.attempts == 4 && h.clock.backoffs().count == 4 })
        #expect(h.clock.backoffs() == [1, 2, 4, 1], "the backoff started over")
        await h.session.stop()
    }

    @Test func aConnectionThatStayedUpResetsTheBackoff() async throws {
        let h = try await SessionHarness()
        let first = await h.connect()
        first.drop()
        h.transport.expectFailure()
        #expect(await h.waitForBackoffSleeper())
        h.clock.advance(1)                                 // retry fails
        #expect(await eventually { h.clock.backoffs().count == 2 })
        let second = h.transport.expectSocket()
        h.clock.advance(2)
        #expect(await eventually { h.transport.opened.contains { $0 === second } })
        second.hello(1)
        #expect(await eventually { h.log.last == .connected(rev: 1) && h.clock.sleepers >= 1 })
        h.clock.advance(61)                                // healthy for over a minute
        second.drop()
        #expect(await eventually { h.clock.backoffs().count == 3 })
        #expect(h.clock.backoffs() == [1, 2, 1])
        await h.session.stop()
    }

    @Test func aPingGoesOutEveryInterval() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        #expect(await eventually { h.clock.sleepers >= 1 })
        h.clock.advance(45)
        #expect(await eventually { socket.pings == 1 })
        #expect(await eventually { h.clock.sleepers >= 1 })
        h.clock.advance(45)
        #expect(await eventually { socket.pings == 2 })
        await h.session.stop()
    }

    @Test func aFailedPingReconnects() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        socket.failPings = true
        #expect(await eventually { h.clock.sleepers >= 1 })
        h.clock.advance(45)
        #expect(await eventually { socket.closed })
        #expect(await h.waitForOffline())
        await h.session.stop()
    }

    @Test func unauthorizedDuringASessionStopsIt() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        h.server.forcedStatus = 401
        socket.doc(2)
        #expect(await eventually { if case .revoked = h.log.last { true } else { false } })
        #expect(socket.closed)
        let requests = h.server.requests.count
        let attempts = h.transport.attempts
        h.clock.advance(1000)
        await h.session.wake()
        await h.session.pathSatisfied()
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.transport.attempts == attempts, "no retry after a 401")
        #expect(h.server.requests.count == requests)
        await h.session.stop()
    }

    @Test func aNamespaceMismatchDuringASessionStopsItToo() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        h.server.forcedStatus = 403
        socket.doc(2)
        #expect(await eventually { if case .revoked = h.log.last { true } else { false } })
        #expect(socket.closed)
        let requests = h.server.requests.count
        let attempts = h.transport.attempts
        h.clock.advance(1000)
        await h.session.wake()
        await h.session.pathSatisfied()
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.transport.attempts == attempts, "no retry after a 403 namespace_mismatch")
        #expect(h.server.requests.count == requests)
        await h.session.stop()
    }

    @Test(arguments: [
        (CloudError.unauthorized("gone"), CloudSessionState.revoked("gone")),
        (CloudError.namespaceMismatch("other app"), CloudSessionState.revoked(CloudError.namespaceMismatch("other app").message(.neutral))),
        (CloudError.paymentRequired, CloudSessionState.paymentRequired),
        (CloudError.upgradeRequired("old"), CloudSessionState.upgradeRequired("old")),
    ])
    func aRefusedUpgradeStopsAndIsNotRetried(error: CloudError, state: CloudSessionState) async throws {
        let h = try await SessionHarness()
        h.transport.expectFailure(error)
        await h.session.start()
        #expect(await eventually { h.log.last == state })
        h.clock.advance(1000)
        await h.session.wake()
        await h.session.pathSatisfied()
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.transport.attempts == 1)
        await h.session.stop()
    }

    @Test func stoppingTearsEverythingDown() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        await h.session.stop()
        #expect(socket.closed)
        #expect(h.log.last == .stopped)

        let requests = h.server.requests.count
        let attempts = h.transport.attempts
        h.transport.expectSocket()
        await h.session.wake()
        await h.session.pathSatisfied()
        await h.session.localFileChanged()
        try h.mac.write([groceries: "oat milk"])
        h.clock.advance(10_000)
        try await Task.sleep(for: .milliseconds(60))
        #expect(h.server.requests.count == requests, "no request after stop")
        #expect(h.transport.attempts == attempts, "no connection after stop")
        #expect(h.clock.sleepers == 0)
    }

    @Test func aLocalEditIsPushedWhileConnected() async throws {
        let h = try await SessionHarness()
        await h.connect()
        try h.mac.write([groceries: "milk", ideas: "boat"])
        await h.session.localFileChanged()
        #expect(h.server.headRev == 2)
        #expect(h.lastRev() == 2)
        #expect(h.log.pushed.count == 1)
        // A second notification with nothing new sends nothing.
        let puts = h.server.count("PUT", "/v1/doc")
        await h.session.localFileChanged()
        #expect(h.server.count("PUT", "/v1/doc") == puts)
        await h.session.stop()
    }

    @Test func anOfflineEditIsPushedAfterReconnecting() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        socket.drop()
        #expect(await h.waitForBackoffSleeper())
        try h.mac.write([groceries: "milk", ideas: "boat"])
        let puts = h.server.count("PUT", "/v1/doc")
        await h.session.localFileChanged()
        #expect(h.server.count("PUT", "/v1/doc") == puts, "not connected: nothing is sent")

        // Meanwhile another Mac edited a different app.
        h.server.writeAsOtherDevice([groceries: "milk", todo: "call Sam"])
        let next = h.transport.expectSocket()
        h.clock.advance(1)
        #expect(await eventually { h.transport.opened.contains { $0 === next } })
        next.hello(2)
        #expect(await eventually { h.server.headRev == 3 })
        let merged = try h.mac.canonical()
        #expect(merged.contains(ideas) && merged.contains(todo))
        #expect(h.log.pulled.allSatisfy { $0.conflicts.isEmpty }, "different keys: no conflict")
        #expect(h.server.body(of: 3)?.contains(todo) == true && h.server.body(of: 3)?.contains(ideas) == true)
        await h.session.stop()
    }

    @Test func anInvalidFileHoldsTheSessionUntilItIsFixed() async throws {
        let h = try await SessionHarness()
        let socket = await h.connect()
        try h.mac.write("this is: not valid")
        h.server.writeAsOtherDevice([ideas: "boat"])
        socket.doc(2)
        #expect(await eventually { if case .waitingForValidFile = h.log.last { true } else { false } })
        #expect(h.lastRev() == 1)

        try h.mac.write([groceries: "milk"])
        await h.session.localFileChanged()
        #expect(h.lastRev() == 2)
        #expect(h.log.last == .connected(rev: 2))
        #expect(!socket.closed)
        await h.session.stop()
    }

    @Test func aMovedConfigNeverConnects() async throws {
        let h = try await SessionHarness()
        var record = try #require(try h.mac.link.load())
        record.linkedConfigPath = "/somewhere/else.txt"
        try h.mac.link.save(record)
        h.transport.expectSocket()
        await h.session.start()
        #expect(await eventually { h.log.last == .configMoved })
        #expect(h.transport.attempts == 0)
        await h.session.stop()
    }

    @Test func switchedOffOrUnlinkedNeverConnectsNorAsksTheServer() async throws {
        let h = try await SessionHarness()
        _ = try h.mac.cloud.setEnabled(false)
        let requests = h.server.requests.count
        h.transport.expectSocket()
        await h.session.start()
        #expect(await eventually { h.log.last == .stopped })
        #expect(h.transport.attempts == 0)
        #expect(h.server.requests.count == requests)
        await h.session.stop()

        let unlinked = try await SessionHarness(link: false)
        unlinked.transport.expectSocket()
        await unlinked.session.start()
        #expect(await eventually { unlinked.log.last == .stopped })
        #expect(unlinked.transport.attempts == 0)
        #expect(unlinked.server.requests.isEmpty)
        await unlinked.session.stop()
    }
}
