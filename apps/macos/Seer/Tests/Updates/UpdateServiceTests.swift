import XCTest
import os
@testable import Seer

// MARK: - MockURLProtocol

/// A scripted `URLProtocol` test double: each `startLoading()` call
/// records the exact `URLRequest` it received (so tests can assert on
/// method/headers/body/URL) and dequeues one canned `Stub` to respond
/// with — or, if no stub is queued, fails with a transport-level error,
/// exercising `UpdateService`'s typed-network-failure path. `Sendable`
/// (via `@unchecked`) and lock-guarded because `URLProtocol` instances are
/// created and driven by `URLSession`'s own internal queues, not the test
/// thread.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let onRequest: (@Sendable (URLRequest) -> Void)?
        /// When set, response delivery for this stub blocks (on a
        /// background queue — never the caller's own thread/task) until
        /// the test explicitly calls `RequestGate.open()`. Lets a test
        /// deterministically control the *completion* order of two
        /// concurrent requests independently of their *start* order (which
        /// is already fixed by this mock's FIFO stub-dequeue-at-
        /// `startLoading()` behavior).
        let gate: RequestGate?
    }

    private struct State {
        var stubs: [Stub] = []
        var recordedRequests: [URLRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func enqueueStub(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        onRequest: (@Sendable (URLRequest) -> Void)? = nil,
        gate: RequestGate? = nil
    ) {
        state.withLock {
            $0.stubs.append(Stub(statusCode: statusCode, headers: headers, body: body, onRequest: onRequest, gate: gate))
        }
    }

    static var recordedRequests: [URLRequest] {
        state.withLock { $0.recordedRequests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let dequeuedStub: Stub? = Self.state.withLock { s in
            s.recordedRequests.append(self.request)
            guard !s.stubs.isEmpty else { return nil }
            return s.stubs.removeFirst()
        }

        guard let stub = dequeuedStub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        // Stub dequeuing (and therefore `recordedRequests` above) happens
        // synchronously, in call order, so tests can rely on it to prove
        // *start* order. Everything from here on — the (possibly gated)
        // response delivery — runs on a background queue instead of
        // blocking the calling thread, so a gated stub can hold its
        // response indefinitely without risking a deadlock against
        // `URLSession`'s own (possibly limited) loading queue.
        DispatchQueue.global().async {
            stub.onRequest?(self.request)
            stub.gate?.wait()

            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A manually-releasable gate letting a test hold a `MockURLProtocol`
/// stub's response open until explicitly opened — used to deterministically
/// prove which of two concurrent `UpdateService.check(force:)` calls'
/// network responses arrives (and is persisted) first, independent of
/// which one was *started* first. `@unchecked Sendable`/lock-free by
/// design: `DispatchSemaphore` itself is safe to signal/wait from any
/// thread, and this type never holds any other mutable state.
final class RequestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    /// Blocks the calling (background, never Swift-Concurrency-cooperative)
    /// thread until `open()` is called.
    func wait() { semaphore.wait() }

    /// Releases exactly one `wait()` call.
    func open() { semaphore.signal() }
}

private actor RecordingReleaseOpener: ReleaseURLOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return true
    }
}

// MARK: - GatedSleeper

/// A test-only `Sleeper` whose `sleep(nanoseconds:)` call suspends
/// indefinitely until the test explicitly calls `release()` — letting a
/// test deterministically control exactly how many times
/// `UpdateScheduler`'s loop has woken up, without any real waiting.
/// `release()` called with nothing yet waiting is remembered (as a
/// "credit") so a `sleep` call that starts immediately afterward returns
/// right away instead of racing the test.
actor GatedSleeper: Sleeper {
    private(set) var requestedCount = 0
    /// Every `nanoseconds` value passed to `sleep(nanoseconds:)`, in call
    /// order — lets a test assert on exactly how long `UpdateScheduler`
    /// intends to sleep next (i.e. its computed due time), not merely that
    /// it slept.
    private(set) var recordedNanoseconds: [UInt64] = []
    private var pendingContinuation: CheckedContinuation<Void, Error>?
    private var availableReleases = 0

    func sleep(nanoseconds: UInt64) async throws {
        requestedCount += 1
        recordedNanoseconds.append(nanoseconds)
        if availableReleases > 0 {
            availableReleases -= 1
            return
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.pendingContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelPending() }
        }
    }

    private func cancelPending() {
        pendingContinuation?.resume(throwing: CancellationError())
        pendingContinuation = nil
    }

    /// Wakes the currently suspended `sleep(nanoseconds:)` call, or — if
    /// none is suspended yet — banks a credit so the *next* call returns
    /// immediately instead of suspending.
    func release() {
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            continuation.resume()
        } else {
            availableReleases += 1
        }
    }
}

// MARK: - UpdateServiceTests

final class UpdateServiceTests: XCTestCase {
    private let settingsURL = URL(fileURLWithPath: "/Update-Service-Test/ai.opencoven.seer/settings.json")

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSettingsStore(fileSystem: InMemorySettingsFileSystem, clock: Clock) -> SettingsStore {
        let atomicStore = AtomicJSONStore<SettingsDocument>(fileURL: settingsURL, fileSystem: fileSystem, clock: clock)
        return SettingsStore(store: atomicStore)
    }

    private func makeService(
        fileSystem: InMemorySettingsFileSystem = InMemorySettingsFileSystem(),
        clock: Clock,
        currentVersion: String = "1.0.0"
    ) -> UpdateService {
        UpdateService(
            settingsStore: makeSettingsStore(fileSystem: fileSystem, clock: clock),
            session: makeMockSession(),
            clock: clock,
            currentVersion: currentVersion
        )
    }

    private func releaseJSON(tag: String, htmlURL: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"\(htmlURL)","draft":\(draft),"prerelease":\(prerelease)}
        """.utf8)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: 1. Stable mode requests /releases/latest

    func testStableModeRequestsReleasesLatest() async throws {
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        let state = try await service.check(force: true)

        XCTAssertEqual(state.availableVersion, "v1.1.0")
        XCTAssertEqual(state.releaseURL, "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        XCTAssertFalse(state.checking)

        let recorded = MockURLProtocol.recordedRequests
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].url?.absoluteString, "https://api.github.com/repos/OpenCoven/seer-releases/releases/latest")
        XCTAssertEqual(recorded[0].httpMethod, "GET")
    }

    // MARK: 2. Prerelease mode requests bounded /releases?per_page=20

    func testPrereleaseModeRequestsBoundedReleasesList() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        try await settingsStore.setIncludePrereleaseUpdates(true)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )

        let arrayBody = Data("""
        [{"tag_name":"v1.2.0-beta.1","html_url":"https://github.com/OpenCoven/seer/releases/tag/v1.2.0-beta.1","draft":false,"prerelease":true}]
        """.utf8)
        MockURLProtocol.enqueueStub(statusCode: 200, body: arrayBody)

        let state = try await service.check(force: true)

        XCTAssertEqual(state.availableVersion, "v1.2.0-beta.1")

        let recorded = MockURLProtocol.recordedRequests
        XCTAssertEqual(recorded.count, 1)
        let url = try XCTUnwrap(recorded[0].url)
        XCTAssertEqual(url.host, "api.github.com")
        XCTAssertEqual(url.path, "/repos/OpenCoven/seer-releases/releases")
        XCTAssertEqual(url.query, "per_page=20")
        XCTAssertFalse(url.absoluteString.contains("/latest"))
    }

    // MARK: 3. Drafts ignored

    func testDraftsIgnoredInPrereleaseMode() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        try await settingsStore.setIncludePrereleaseUpdates(true)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )

        // The draft is a *higher* version than the non-draft release — if
        // drafts were not ignored, it would incorrectly win.
        let arrayBody = Data("""
        [
          {"tag_name":"v9.9.9","html_url":"https://github.com/OpenCoven/seer/releases/tag/v9.9.9","draft":true,"prerelease":false},
          {"tag_name":"v1.2.0","html_url":"https://github.com/OpenCoven/seer/releases/tag/v1.2.0","draft":false,"prerelease":false}
        ]
        """.utf8)
        MockURLProtocol.enqueueStub(statusCode: 200, body: arrayBody)

        let state = try await service.check(force: true)

        XCTAssertEqual(state.availableVersion, "v1.2.0")
    }

    /// Regression test: candidate selection must validate/filter releases
    /// (draft, parseable tag, *and* trusted URL) before ranking by
    /// version — not rank first and only then discover the highest
    /// candidate's URL is untrustworthy. Previously, an invalid-URL
    /// highest-versioned release (`v9.9.9` here) would be chosen as
    /// "best" and then rejected wholesale for its bad URL, suppressing
    /// the lower but perfectly valid `v1.2.0` release instead of falling
    /// through to it.
    func testInvalidURLOnHighestVersionedReleaseDoesNotSuppressALowerValidRelease() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        try await settingsStore.setIncludePrereleaseUpdates(true)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )

        // v9.9.9 is the higher version but has an untrusted (non-github.com)
        // URL; v1.2.0 is lower but has a fully valid, trusted URL. The
        // valid, lower release must still be selected.
        let arrayBody = Data("""
        [
          {"tag_name":"v9.9.9","html_url":"https://evil.example.com/releases/tag/v9.9.9","draft":false,"prerelease":false},
          {"tag_name":"v1.2.0","html_url":"https://github.com/OpenCoven/seer/releases/tag/v1.2.0","draft":false,"prerelease":false}
        ]
        """.utf8)
        MockURLProtocol.enqueueStub(statusCode: 200, body: arrayBody)

        let state = try await service.check(force: true)

        XCTAssertEqual(state.availableVersion, "v1.2.0")
        XCTAssertEqual(state.releaseURL, "https://github.com/OpenCoven/seer/releases/tag/v1.2.0")
    }

    // MARK: 4. ETag forwarded via If-None-Match

    func testETagForwardedViaIfNoneMatch() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            headers: ["Etag": "\"first-etag\""],
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        _ = try await service.check(force: true)

        clock.now += 1
        MockURLProtocol.enqueueStub(statusCode: 304)
        _ = try await service.check(force: true)

        let recorded = MockURLProtocol.recordedRequests
        XCTAssertEqual(recorded.count, 2)
        XCTAssertNil(recorded[0].value(forHTTPHeaderField: "If-None-Match"), "no cached ETag exists for the first request")
        XCTAssertEqual(recorded[1].value(forHTTPHeaderField: "If-None-Match"), "\"first-etag\"")
    }

    // MARK: 5. HTTP 304 retains previous result and updates check time

    func testHTTP304RetainsPreviousResultAndUpdatesCheckTime() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            headers: ["Etag": "\"abc\""],
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        let first = try await service.check(force: true)
        XCTAssertEqual(first.lastCheckedAt, 1_700_000_000_000)

        clock.now = 1_700_100_000_000
        MockURLProtocol.enqueueStub(statusCode: 304)
        let second = try await service.check(force: true)

        XCTAssertEqual(second.availableVersion, first.availableVersion)
        XCTAssertEqual(second.releaseURL, first.releaseURL)
        XCTAssertEqual(second.lastCheckedAt, 1_700_100_000_000)
    }

    func testHTTP304RecordsTheCompletionTimeRatherThanRequestStartTime() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            headers: ["Etag": "\"abc\""],
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        _ = try await service.check(force: true)

        clock.now += UpdateService.checkIntervalMs
        let completionTime = clock.now + 5_000
        MockURLProtocol.enqueueStub(statusCode: 304, onRequest: { _ in
            clock.now = completionTime
        })

        let state = try await service.check(force: true)

        XCTAssertEqual(state.lastCheckedAt, completionTime)
    }

    // MARK: 6. A second check inside 24 hours skips network unless forced

    func testSecondCheckInside24HoursSkipsNetworkUnlessForced() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        _ = try await service.check(force: true)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1)

        // Less than 24 hours later, not forced: no network call at all.
        clock.now += 60 * 60 * 1000
        let unforced = try await service.check(force: false)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1, "an unforced check inside the 24h window must not touch the network")
        XCTAssertEqual(unforced.availableVersion, "v1.1.0")

        // Forced, still inside the window: network is queried again.
        MockURLProtocol.enqueueStub(statusCode: 304)
        _ = try await service.check(force: true)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 2)
    }

    // MARK: 6b. Extreme persisted `lastUpdateCheckAt` cannot crash or permanently suppress the 24h gate

    /// Regression test for a corrupted/future-dated persisted
    /// `lastUpdateCheckAt` (e.g. `Int64.max`). Before the fix, `now -
    /// lastCheckedAt` for such a value is still representable (no trap),
    /// but is always deeply negative — so the unforced gate (`elapsed <
    /// checkIntervalMs`) is satisfied forever, permanently suppressing
    /// every future check. The normalized gate instead clamps a
    /// future-dated value down to "now" the moment it's read, so it
    /// becomes due exactly one bounded interval later — never
    /// permanently.
    func testCheckGateExtremeFutureLastCheckedAtClampsToABoundedNextDueTimeInsteadOfPermanentSuppression() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        try await settingsStore.recordUpdateCheck(etag: nil, lastCheckedAt: Int64.max, release: nil)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )

        let suppressed = try await service.check(force: false)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 0, "a corrupted future timestamp must still gate the very next call")
        // Self-healed to "now" (not left at the corrupt `Int64.max`) so
        // every subsequent gate check measures real elapsed time from
        // this point forward instead of re-deriving a fresh "just
        // checked" verdict from "now" on every call, which would suppress
        // checks forever.
        XCTAssertEqual(suppressed.lastCheckedAt, 1_700_000_000_000)

        // Bounded: exactly one interval later, the gate must have
        // cleared — never suppressed forever.
        clock.now += UpdateService.checkIntervalMs
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        let due = try await service.check(force: false)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1, "an extreme future persisted timestamp must not suppress checks forever")
        XCTAssertEqual(due.availableVersion, "v1.1.0")
    }

    /// Regression test for a corrupted/extreme-past persisted
    /// `lastUpdateCheckAt` (e.g. `Int64.min`). Before the fix, `now -
    /// Int64.min` overflows `Int64` and traps, crashing the app on the
    /// very first gate check. The safe gate uses saturating subtraction,
    /// which reports a huge-but-finite elapsed time instead — always past
    /// the gate, so the check proceeds immediately, with no crash.
    func testCheckGateExtremePastLastCheckedAtIsImmediatelyDueWithoutOverflowing() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        try await settingsStore.recordUpdateCheck(etag: nil, lastCheckedAt: Int64.min, release: nil)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        let state = try await service.check(force: false)

        XCTAssertEqual(
            MockURLProtocol.recordedRequests.count,
            1,
            "Int64.min must never trap the gate's arithmetic and must be treated as immediately due"
        )
        XCTAssertEqual(state.availableVersion, "v1.1.0")
    }

    /// An extreme *clock* value (not a persisted one) must not trap the
    /// gate's arithmetic either, and ordinary "elapsed way more than 24h
    /// ago, so due now" semantics must still hold.
    func testCheckGatePreservesOrdinary24HourSemanticsWithAnExtremeClockNow() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: Int64.max - 1_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        try await settingsStore.recordUpdateCheck(etag: nil, lastCheckedAt: 0, release: nil)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        let state = try await service.check(force: false)

        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1, "an extreme clock 'now' must not trap the elapsed-time computation")
        XCTAssertEqual(state.availableVersion, "v1.1.0")
    }

    // MARK: 7. A running app's scheduler starts one new check at 24 hours

    func testRunningAppSchedulerStartsOneNewCheckAt24Hours() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )
        let sleeper = GatedSleeper()
        let scheduler = UpdateScheduler(service: service, clock: clock, sleeper: sleeper)

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )

        await scheduler.start()
        try await waitUntil { await sleeper.requestedCount >= 1 }
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 0, "no check must run before the scheduler's sleep elapses")

        // Simulate 24 hours passing, then let the scheduler's sleep return.
        clock.now += UpdateService.checkIntervalMs
        await sleeper.release()

        try await waitUntil { MockURLProtocol.recordedRequests.count == 1 }
        try await waitUntil { await sleeper.requestedCount >= 2 }

        // Exactly one new check ran at the 24-hour mark — not zero, not more.
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1)

        await scheduler.stop()
    }

    func testSchedulerIsCancellableAtShutdown() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )
        let sleeper = GatedSleeper()
        let scheduler = UpdateScheduler(service: service, clock: clock, sleeper: sleeper)

        await scheduler.start()
        try await waitUntil { await sleeper.requestedCount >= 1 }

        await scheduler.stop()

        // Releasing after shutdown must not cause any check to run.
        clock.now += UpdateService.checkIntervalMs
        await sleeper.release()

        // Give the (cancelled) loop a moment to react, then confirm no
        // request was ever made.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 0)
    }

    /// A test-only, actor-isolated stand-in for whatever a real
    /// `lastCompletedCheckAt`/`performScheduledCheck` pair would capture
    /// (e.g. a coordinator's own state or a bare `UpdateService`), letting
    /// a test simulate a manual/forced check completing out-of-band —
    /// updating `lastCheckedAt` — without `UpdateScheduler`'s own wake
    /// having run yet.
    private actor FakeScheduledCheckTracker {
        private(set) var lastCheckedAt: Int64?
        private(set) var performCallCount = 0
        /// When `true`, `recordPerformScheduledCheck()` reports the attempt
        /// as failed (mirroring a coordinator's `checkForUpdates(force:)`
        /// returning `false` after catching a thrown `UpdateCheckError`)
        /// without ever touching `lastCheckedAt` — exactly like a real
        /// failed check, which never persists a new `lastCheckedAt` either.
        var shouldFail = false

        func setShouldFail(to value: Bool) {
            shouldFail = value
        }

        func recordManualCheckCompletion(at time: Int64) {
            lastCheckedAt = time
        }

        @discardableResult
        func recordPerformScheduledCheck() -> Bool {
            performCallCount += 1
            return !shouldFail
        }
    }

    // MARK: 7b. Scheduler reschedules from the latest completed check, not a stale wake

    /// Regression test for the scheduler deferring its *next* wake from
    /// whenever it happened to wake up (even a stale wake, suppressed by
    /// the 24h gate) instead of from the most recently completed check.
    /// Models: the scheduler starts with no prior check (so its first
    /// sleep targets `now + 24h`); a manual/forced check completes 1 hour
    /// into that sleep (e.g. the user opened the updates panel while the
    /// Mac was briefly awake); the scheduler's original timer still fires
    /// at the stale `now + 24h` mark and its non-forced check is
    /// suppressed by the 24h gate (only 23h having elapsed since the
    /// manual check). The scheduler must then sleep for only 1 more hour —
    /// 24h after the manual check's own completion — not another full 24h
    /// from this stale wake (which would leave ~47h between real network
    /// checks instead of 24h).
    func testSchedulerReschedulesFromLatestCompletedCheckNotFromAStaleWake() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let sleeper = GatedSleeper()
        let tracker = FakeScheduledCheckTracker()
        let scheduler = UpdateScheduler(
            clock: clock,
            sleeper: sleeper,
            lastCompletedCheckAt: { await tracker.lastCheckedAt },
            performScheduledCheck: { await tracker.recordPerformScheduledCheck() }
        )

        await scheduler.start()
        try await waitUntil { await sleeper.requestedCount >= 1 }

        // No check has ever completed yet, so the first sleep must target
        // exactly 24h from now.
        let initialNanoseconds = await sleeper.recordedNanoseconds.last
        XCTAssertEqual(initialNanoseconds, UInt64(UpdateService.checkIntervalMs) * 1_000_000)

        // A manual/forced check completes 1 hour into the scheduler's
        // sleep, independent of the scheduler's own loop.
        let oneHourMs: Int64 = 60 * 60 * 1000
        clock.now += oneHourMs
        await tracker.recordManualCheckCompletion(at: clock.now)

        // The scheduler's original timer still fires at the stale 24h
        // mark (23h after the manual check completed) — its non-forced
        // check is expected to be suppressed by the 24h gate upstream, so
        // it merely records that it *attempted* a scheduled check here.
        clock.now = 1_700_000_000_000 + UpdateService.checkIntervalMs
        await sleeper.release()

        try await waitUntil { await tracker.performCallCount >= 1 }
        try await waitUntil { await sleeper.requestedCount >= 2 }

        // The next sleep must target 24h after the manual check's own
        // completion (1h from "now") — not another 24h from this stale
        // wake (which would be 24h from "now").
        let expectedRemainingMs = oneHourMs
        let rescheduledNanoseconds = await sleeper.recordedNanoseconds.last
        XCTAssertEqual(
            rescheduledNanoseconds,
            UInt64(expectedRemainingMs) * 1_000_000,
            "must reschedule from the latest completed check's time, not from this stale wake"
        )

        await scheduler.stop()
    }

    // MARK: 7c. A failed scheduled attempt reschedules a bounded 24h — never a zero-delay retry loop

    /// Regression test for the scheduler tight-looping with zero-delay
    /// retries after a scheduled attempt fails. A failed check never
    /// persists a new `lastCheckedAt` (mirroring the real
    /// `AppSnapshotCoordinator.checkForUpdates(force:)`/`UpdateService
    /// .check(force:)` contract), so `lastCompletedCheckAt` stays fixed at
    /// whatever stale, already-past value made this attempt due in the
    /// first place. Recomputing the next due time from that same stale
    /// value would still be in the past, producing an immediate,
    /// zero-delay retry — this test asserts the scheduler instead
    /// reschedules a full, bounded 24h from the failed attempt's own
    /// completion, and never invokes `performScheduledCheck` a second time
    /// until that full sleep is released.
    func testFailedScheduledCheckDoesNotLoopAndReschedulesABounded24HoursFromItsOwnCompletion() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let sleeper = GatedSleeper()
        let tracker = FakeScheduledCheckTracker()
        let scheduler = UpdateScheduler(
            clock: clock,
            sleeper: sleeper,
            lastCompletedCheckAt: { await tracker.lastCheckedAt },
            performScheduledCheck: { await tracker.recordPerformScheduledCheck() }
        )

        // A prior check completed a full 24h ago, so the scheduler's very
        // first computed due time is already in the past (i.e. this
        // attempt is already overdue when the loop starts).
        await tracker.recordManualCheckCompletion(at: clock.now - UpdateService.checkIntervalMs)
        await tracker.setShouldFail(to: true)

        await scheduler.start()
        try await waitUntil { await sleeper.requestedCount >= 1 }

        // Already overdue, so the first sleep must request zero delay.
        let initialNanoseconds = await sleeper.recordedNanoseconds.last
        XCTAssertEqual(initialNanoseconds, 0)

        // Let the (already-due) scheduled check run; it fails, and
        // `lastCheckedAt` is left completely untouched by that failure.
        await sleeper.release()
        try await waitUntil { await tracker.performCallCount >= 1 }

        // The scheduler must request its *next* sleep for a full, bounded
        // 24h from this failed attempt's own completion — never another
        // zero-delay retry computed from the still-stale, still-past
        // `lastCheckedAt`.
        try await waitUntil { await sleeper.requestedCount >= 2 }
        let rescheduledNanoseconds = await sleeper.recordedNanoseconds.last
        XCTAssertEqual(
            rescheduledNanoseconds,
            UInt64(UpdateService.checkIntervalMs) * 1_000_000,
            "a failed scheduled attempt must reschedule a full 24h from its own completion, not loop with a zero-delay retry"
        )

        // Give the loop a moment to react in case the fix above is wrong
        // and it raced ahead anyway, then confirm no second attempt ran.
        try await Task.sleep(nanoseconds: 50_000_000)
        let performCallCountAfterSettling = await tracker.performCallCount
        XCTAssertEqual(performCallCountAfterSettling, 1, "one failed scheduled attempt must not immediately trigger another")

        await scheduler.stop()
    }

    /// Polls `condition` (with a short yield between attempts) until it is
    /// true or a generous bound is hit — used instead of a fixed sleep to
    /// keep the scheduler tests both deterministic and fast.
    private func waitUntil(
        timeoutSeconds: Double = 2,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met before timeout")
    }

    // MARK: 7d. Extreme persisted `lastCheckedAt` cannot crash or permanently suppress the scheduler

    /// Regression test for `UpdateScheduler.nextDueAt` given a corrupted/
    /// future-dated `lastCompletedCheckAt` (e.g. `Int64.max`). Before the
    /// fix, adding `checkIntervalMs` to such a value overflows and traps;
    /// even a naive saturating add alone would leave the due time pinned
    /// at `Int64.max` forever — i.e. the scheduler would never check
    /// again. The normalized computation clamps the value down to "now"
    /// first, so the very next sleep is a single, bounded 24h — never
    /// "forever".
    func testSchedulerExtremeFutureLastCheckedAtSchedulesABounded24HourSleepInsteadOfNeverChecking() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let sleeper = GatedSleeper()
        let tracker = FakeScheduledCheckTracker()
        let scheduler = UpdateScheduler(
            clock: clock,
            sleeper: sleeper,
            lastCompletedCheckAt: { await tracker.lastCheckedAt },
            performScheduledCheck: { await tracker.recordPerformScheduledCheck() }
        )

        await tracker.recordManualCheckCompletion(at: Int64.max)

        await scheduler.start()
        try await waitUntil { await sleeper.requestedCount >= 1 }

        let nanoseconds = await sleeper.recordedNanoseconds.last
        XCTAssertEqual(
            nanoseconds,
            UInt64(UpdateService.checkIntervalMs) * 1_000_000,
            "a corrupted future persisted timestamp must schedule a bounded 24h sleep, never 'forever'"
        )

        await scheduler.stop()
    }

    /// Regression test for `UpdateScheduler.nextDueAt`/its loop given a
    /// corrupted/extreme-past `lastCompletedCheckAt` (e.g. `Int64.min`).
    /// Before the fix, `dueAt - now` (needed to compute how long to
    /// sleep) overflows `Int64` and traps, crashing the scheduler's
    /// background loop. The safe computation reports the check as
    /// immediately due (a zero-length sleep) instead, with no crash.
    func testSchedulerExtremePastLastCheckedAtSchedulesAnImmediateCheckWithoutOverflowing() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let sleeper = GatedSleeper()
        let tracker = FakeScheduledCheckTracker()
        let scheduler = UpdateScheduler(
            clock: clock,
            sleeper: sleeper,
            lastCompletedCheckAt: { await tracker.lastCheckedAt },
            performScheduledCheck: { await tracker.recordPerformScheduledCheck() }
        )

        await tracker.recordManualCheckCompletion(at: Int64.min)

        await scheduler.start()
        try await waitUntil { await sleeper.requestedCount >= 1 }

        let nanoseconds = await sleeper.recordedNanoseconds.last
        XCTAssertEqual(nanoseconds, 0, "Int64.min must never trap the scheduler's arithmetic and must schedule an immediate check")

        await scheduler.stop()
    }

    /// An extreme *clock* value (not a persisted one) must not trap the
    /// scheduler's arithmetic either — a long-overdue check (by any
    /// measure) must still be reported as immediately due.
    func testSchedulerHandlesAnExtremeClockNowWithoutOverflowing() async throws {
        let clock = MutableClock(now: Int64.max - 10)
        let sleeper = GatedSleeper()
        let tracker = FakeScheduledCheckTracker()
        let scheduler = UpdateScheduler(
            clock: clock,
            sleeper: sleeper,
            lastCompletedCheckAt: { await tracker.lastCheckedAt },
            performScheduledCheck: { await tracker.recordPerformScheduledCheck() }
        )

        await tracker.recordManualCheckCompletion(at: 0)

        await scheduler.start()
        try await waitUntil { await sleeper.requestedCount >= 1 }

        let nanoseconds = await sleeper.recordedNanoseconds.last
        XCTAssertEqual(
            nanoseconds,
            0,
            "an extreme clock 'now' must not trap and must report the long-overdue check as immediately due"
        )

        await scheduler.stop()
    }

    // MARK: 8. Release URLs must be HTTPS on github.com

    func testReleaseURLsMustBeHTTPSGithubCom() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v9.9.9", htmlURL: "http://github.com/OpenCoven/seer/releases/tag/v9.9.9")
        )
        let httpState = try await service.check(force: true)
        XCTAssertNil(httpState.availableVersion, "a non-https release URL must never be trusted")
        XCTAssertNil(httpState.releaseURL)

        clock.now += 1
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v9.9.9", htmlURL: "https://evil.example.com/releases/tag/v9.9.9")
        )
        let wrongHostState = try await service.check(force: true)
        XCTAssertNil(wrongHostState.availableVersion, "a release URL on a non-github.com host must never be trusted")
        XCTAssertNil(wrongHostState.releaseURL)

        clock.now += 1
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v9.9.9", htmlURL: "https://github.com.evil.example/releases/tag/v9.9.9")
        )
        let deceptiveHostState = try await service.check(force: true)
        XCTAssertNil(deceptiveHostState.availableVersion)
        XCTAssertNil(deceptiveHostState.releaseURL)
    }

    // MARK: 9. No request body or local-state header is sent

    func testNoRequestBodyOrLocalStateHeaderSent() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        _ = try await service.check(force: true)

        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys)
        XCTAssertTrue(headerNames.isSubset(of: ["User-Agent", "Accept", "If-None-Match"]), "unexpected header(s): \(headerNames)")
    }

    // MARK: 10. User-Agent Seer/1.0.0, body nil, timeout 10 seconds

    func testUserAgentBodyNilTimeout10Seconds() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        _ = try await service.check(force: true)

        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Seer/1.0.0")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testMakeDefaultSessionHasNoCookiesOrCredentialStorageAndA10SecondTimeout() {
        let session = UpdateService.makeDefaultSession()
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 10)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 10)
        XCTAssertEqual(session.configuration.httpCookieAcceptPolicy, .never)
    }

    // MARK: - Network failure is typed and does not affect monitoring

    func testNetworkFailureThrowsTypedErrorAndLeavesCachedStateUnaffected() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        // No stub enqueued: MockURLProtocol fails with a transport error.
        let before = await service.currentState()

        do {
            _ = try await service.check(force: true)
            XCTFail("expected check(force:) to throw")
        } catch let error as UpdateCheckError {
            guard case .network = error else {
                return XCTFail("expected .network, got \(error)")
            }
        }

        let after = await service.currentState()
        XCTAssertEqual(before, after, "a network failure must never mutate the cached update state")
    }

    // MARK: - setIncludePrerelease forces an immediate check

    func testSetIncludePrereleaseForcesImmediateCheckIgnoringTheGate() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        _ = try await service.check(force: true)
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1)

        clock.now += 1
        let prereleaseArrayBody = Data("""
        [{"tag_name":"v1.2.0-beta.1","html_url":"https://github.com/OpenCoven/seer/releases/tag/v1.2.0-beta.1","draft":false,"prerelease":true}]
        """.utf8)
        MockURLProtocol.enqueueStub(statusCode: 200, body: prereleaseArrayBody)
        let state = try await service.setIncludePrerelease(true)

        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 2, "toggling prerelease mode must force an immediate check, bypassing the 24h gate")
        let secondRequestURL = try XCTUnwrap(MockURLProtocol.recordedRequests.last?.url)
        XCTAssertEqual(secondRequestURL.query, "per_page=20")
        XCTAssertEqual(state.availableVersion, "v1.2.0-beta.1")
    }

    // MARK: - Concurrency: the later-started check wins, never the later-completed one

    /// `UpdateService` is an actor, but actors are reentrant across
    /// `await` — so two overlapping `check(force:)` calls can both pass
    /// the gate above and both have a `session.data(for:)` request in
    /// flight at once (e.g. a manual/scheduled stable-stream check racing
    /// a `setIncludePrerelease(true)` switch to the prerelease stream).
    /// Persisting whichever response merely *returns* first — rather than
    /// whichever call *started* last — lets an older, slower request stomp
    /// a newer one's fresher ETag/release, or let a stable-stream ETag
    /// land after a prerelease-stream switch (or vice versa).
    ///
    /// This test starts a stable-stream check, lets it reach the network
    /// (and suspend there), *then* switches to prerelease mode and starts
    /// a second, later check against the prerelease stream — and resolves
    /// the *later-started* (prerelease) request's response first, only
    /// letting the *earlier-started* (stable) request's now-stale response
    /// arrive afterward. The later-started prerelease check must win: its
    /// ETag/release must be exactly what ends up persisted, and the
    /// earlier, stale stable response must never overwrite it or leak its
    /// own ETag into the persisted state.
    func testOverlappingStableAndPrereleaseChecksTheLaterStartedCheckWinsAndETagsDoNotCross() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )

        let stableGate = RequestGate()
        let prereleaseGate = RequestGate()

        // Stub #1 answers whichever request is sent first — the
        // stable-stream check, started before prerelease mode is toggled
        // on — and is held open on `stableGate`.
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            headers: ["Etag": "\"stable-etag\""],
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0"),
            gate: stableGate
        )
        // Stub #2 answers the prerelease-stream check, started second,
        // held open on `prereleaseGate`.
        let prereleaseBody = Data("""
        [{"tag_name":"v1.2.0-beta.1","html_url":"https://github.com/OpenCoven/seer/releases/tag/v1.2.0-beta.1","draft":false,"prerelease":true}]
        """.utf8)
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            headers: ["Etag": "\"prerelease-etag\""],
            body: prereleaseBody,
            gate: prereleaseGate
        )

        // 1. Start the stable check; its request reaches the network and
        //    suspends there, gated on `stableGate`.
        let stableTask = Task { try await service.check(force: true) }
        try await waitUntil { MockURLProtocol.recordedRequests.count >= 1 }

        // 2. While that stable check is still in flight, switch to
        //    prerelease mode (clearing the cached ETag/release for the
        //    newly selected stream) and start a second, later check
        //    against it — its request also reaches the network and
        //    suspends, gated on `prereleaseGate`.
        try await settingsStore.setIncludePrereleaseUpdates(true)
        let prereleaseTask = Task { try await service.check(force: true) }
        try await waitUntil { MockURLProtocol.recordedRequests.count >= 2 }

        // 3. Let the *later-started* (prerelease) request's response
        //    arrive — and be persisted — first.
        prereleaseGate.open()
        let prereleaseState = try await prereleaseTask.value

        // 4. Only afterward let the *earlier-started* (stable) request's
        //    now-stale response arrive.
        stableGate.open()
        let stableResult = try await stableTask.value

        XCTAssertEqual(prereleaseState.availableVersion, "v1.2.0-beta.1")

        let finalState = await service.currentState()
        XCTAssertEqual(finalState.availableVersion, "v1.2.0-beta.1", "the later-started prerelease check must win over the earlier, now-stale stable response")

        let finalSettings = await settingsStore.current
        XCTAssertTrue(finalSettings.includePrereleaseUpdates)
        XCTAssertEqual(
            finalSettings.updateETag, "\"prerelease-etag\"",
            "the stale stable-stream ETag must never overwrite the later prerelease-stream ETag"
        )
        XCTAssertEqual(finalSettings.lastRelease?.version, "v1.2.0-beta.1")

        // The earlier (now-stale) stable check's own return value must
        // reflect whatever is actually persisted (the prerelease winner),
        // never its own now-discarded stable-stream result.
        XCTAssertEqual(stableResult.availableVersion, "v1.2.0-beta.1", "a stale, superseded check must never report its own discarded result")
        XCTAssertFalse(finalState.checking, "no check remains in flight once both overlapping calls have completed")
    }

    /// Regression test for a race `setIncludePrerelease(_:)`'s own
    /// synchronous `generation` bump exists to close. Before that fix,
    /// `generation` only ever advanced later — inside the forced
    /// `check(force: true)` call `setIncludePrerelease(_:)` itself makes,
    /// *after* awaiting `settingsStore.setIncludePrereleaseUpdates(_:)` —
    /// so an older stable-stream check already in flight when the switch
    /// began still held a valid `myGeneration` ticket throughout that
    /// settings-mutation await. Were that older check's response to
    /// arrive during exactly that window, it would pass the (unchanged)
    /// generation check, queue behind `SettingsStore`'s own gate (already
    /// held by the in-progress settings mutation), and — the instant that
    /// mutation released it — persist its stale stable-stream ETag/
    /// release right back on top of the freshly cleared settings. If the
    /// forced check against the *new* (prerelease) stream that follows
    /// then itself fails, nothing else would ever overwrite that
    /// resurrected stale state, silently leaking the old stream's cached
    /// release across the switch.
    ///
    /// This test reproduces exactly that window deterministically: it
    /// arms a suspension on the settings file write so
    /// `setIncludePrerelease`'s own settings mutation is caught
    /// genuinely mid-flight, only then resolves the older stable check's
    /// held-open response, and finally lets the forced new-stream check
    /// fail (no stub is queued for it). With the fix, the older check's
    /// `myGeneration` ticket is already stale by the time its response
    /// arrives — invalidated synchronously, before `setIncludePrerelease`
    /// ever reached that settings-mutation await — so it never even
    /// attempts to persist, and the cleared ETag/release/lastUpdateCheckAt
    /// survive the forced check's failure untouched.
    func testSetIncludePrereleaseInvalidatesAnInFlightOldStreamCheckBeforeItsFirstAwaitEvenWhenTheForcedNewStreamCheckFails() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )

        let stableGate = RequestGate()

        // The old stable-stream check's response: held open on
        // `stableGate` until explicitly released below, well after the
        // switch to prerelease has already begun.
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            headers: ["Etag": "\"stable-etag\""],
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0"),
            gate: stableGate
        )

        // 1. Start the old stable-stream check; its request reaches the
        //    network and suspends there.
        let staleCheckTask = Task { try await service.check(force: true) }
        try await waitUntil { MockURLProtocol.recordedRequests.count >= 1 }

        // 2. Arm a suspension on the settings file write and start the
        //    switch to prerelease — deterministically catching
        //    `setIncludePrerelease`'s own settings mutation genuinely
        //    mid-flight, proving the fix's `generation` bump happens
        //    strictly *before* this await is ever reached.
        await fileSystem.armSuspension("writeFileAndSynchronize")
        let switchTask = Task<Void, Error> {
            _ = try await service.setIncludePrerelease(true)
        }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        // 3. Only now let the old, now-stale stable-stream response
        //    resolve — while the switch is still suspended inside its
        //    own settings mutation, well before it ever reaches the
        //    forced check against the new stream.
        stableGate.open()
        let staleResult = try await staleCheckTask.value

        // 4. Let the settings mutation complete, and — with no stub
        //    queued for the new prerelease-stream request — let the
        //    forced check that follows fail with a transport error.
        await fileSystem.resumeSuspension("writeFileAndSynchronize")
        do {
            try await switchTask.value
            XCTFail("expected the forced new-stream check to throw")
        } catch let error as UpdateCheckError {
            guard case .network = error else {
                return XCTFail("expected .network, got \(error)")
            }
        }

        XCTAssertEqual(
            staleResult.availableVersion, nil,
            "the stale stable-stream check must never report its own discarded result once invalidated by the switch"
        )

        let finalSettings = await settingsStore.current
        XCTAssertTrue(finalSettings.includePrereleaseUpdates, "the toggle itself is never rolled back, even though the forced check failed")
        XCTAssertNil(
            finalSettings.updateETag,
            "the stale stable-stream ETag must never be restored after the switch cleared it, even though the forced new-stream check failed"
        )
        XCTAssertNil(
            finalSettings.lastRelease,
            "the stale stable-stream release must never be restored after the switch cleared it, even though the forced new-stream check failed"
        )
        XCTAssertNil(
            finalSettings.lastUpdateCheckAt,
            "the stale check must never record its own completion time either, once invalidated by the switch"
        )
    }

    // MARK: - openCurrentRelease only ever opens the stored, validated URL

    func testOpenCurrentReleaseReturnsFalseWhenNoReleaseIsCached() async {
        let clock = MutableClock(now: 1_700_000_000_000)
        let service = makeService(clock: clock)

        let opened = await service.openCurrentRelease()
        XCTAssertFalse(opened)
    }

    func testOpenCurrentReleaseUsesOnlyTheValidatedStoredURL() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = makeSettingsStore(fileSystem: fileSystem, clock: clock)
        let opener = RecordingReleaseOpener()
        let service = UpdateService(
            settingsStore: settingsStore,
            session: makeMockSession(),
            clock: clock,
            currentVersion: "1.0.0",
            releaseOpener: opener
        )
        MockURLProtocol.enqueueStub(
            statusCode: 200,
            body: releaseJSON(tag: "v1.1.0", htmlURL: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")
        )
        _ = try await service.check(force: true)

        let opened = await service.openCurrentRelease()
        let openedURLs = await opener.openedURLs
        XCTAssertTrue(opened)
        XCTAssertEqual(openedURLs, [URL(string: "https://github.com/OpenCoven/seer/releases/tag/v1.1.0")!])
    }
}
