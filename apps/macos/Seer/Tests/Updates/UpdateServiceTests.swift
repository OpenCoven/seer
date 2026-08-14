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
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) {
        state.withLock {
            $0.stubs.append(Stub(statusCode: statusCode, headers: headers, body: body, onRequest: onRequest))
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
        stub.onRequest?(request)

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
    private var pendingContinuation: CheckedContinuation<Void, Error>?
    private var availableReleases = 0

    func sleep(nanoseconds: UInt64) async throws {
        requestedCount += 1
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
