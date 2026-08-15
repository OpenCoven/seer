import Foundation
@testable import Seer

/// A scripted `UpdateChecking` test double, shared by
/// `AppSnapshotCoordinatorTests` and `BridgeMessageHandlerTests` so neither
/// needs a real `UpdateService` (and therefore a live/mocked `URLSession`)
/// just to exercise `AppSnapshotCoordinator`'s own update-integration
/// plumbing. `@unchecked Sendable` for the same reason
/// `AppSnapshotCoordinatorTests.CoordinatorFakePowerBackend` is: every
/// method here only ever runs synchronously on the main actor, driven by
/// `AppSnapshotCoordinator` itself.
final class FakeUpdateChecking: UpdateChecking, @unchecked Sendable {
    /// One scripted result consumed per `check(force:)` call, in order;
    /// once exhausted, further calls succeed with `currentStateValue`
    /// unchanged — matching `UpdateService`'s own "never mutate cached
    /// state on a thrown failure" contract closely enough for coordinator-
    /// level tests, which never assert on `UpdateService`'s own internal
    /// behavior directly.
    var checkResults: [Result<UpdateState, Error>] = []
    /// One scripted result consumed per `setIncludePrerelease(_:)` call,
    /// in the same shape as `checkResults`.
    var setIncludePrereleaseResults: [Result<UpdateState, Error>] = []
    /// What `currentState()` reports, and what a `check(force:)`/
    /// `setIncludePrerelease(_:)` call updates to on success (mirroring
    /// `UpdateService`'s persist-then-report contract) or falls back to
    /// reporting on failure (mirroring "cached state left untouched").
    var currentStateValue = UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: nil)
    var openCurrentReleaseResult = false

    private(set) var checkForceValues: [Bool] = []
    private(set) var setIncludePrereleaseValues: [Bool] = []
    private(set) var openCurrentReleaseCallCount = 0

    func check(force: Bool) async throws -> UpdateState {
        checkForceValues.append(force)
        guard !checkResults.isEmpty else { return currentStateValue }
        switch checkResults.removeFirst() {
        case .success(let state):
            currentStateValue = state
            return state
        case .failure(let error):
            throw error
        }
    }

    func currentState() async -> UpdateState { currentStateValue }

    func setIncludePrerelease(_ value: Bool) async throws -> UpdateState {
        setIncludePrereleaseValues.append(value)
        guard !setIncludePrereleaseResults.isEmpty else { return currentStateValue }
        switch setIncludePrereleaseResults.removeFirst() {
        case .success(let state):
            currentStateValue = state
            return state
        case .failure(let error):
            throw error
        }
    }

    @discardableResult
    func openCurrentRelease() async -> Bool {
        openCurrentReleaseCallCount += 1
        return openCurrentReleaseResult
    }
}

/// A test-only error `FakeUpdateChecking` throws to simulate a failed
/// check/setIncludePrerelease call, distinct from any real
/// `UpdateCheckError` case so tests can assert the coordinator surfaces
/// *some* failure without depending on `UpdateService`'s own error cases.
struct FakeUpdateCheckError: Error, Equatable {
    let message: String
    init(_ message: String = "simulated update check failure") {
        self.message = message
    }
}

/// A scripted `UpdateSchedulerControlling` test double recording exactly
/// how many times `start()`/`stop()` were called — used to assert
/// `AppSnapshotCoordinator` actually owns scheduler lifecycle (starting it
/// at startup, stopping it at shutdown) without needing a real background
/// loop or `Sleeper`.
final class FakeUpdateSchedulerControlling: UpdateSchedulerControlling, @unchecked Sendable {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() async { startCallCount += 1 }
    func stop() async { stopCallCount += 1 }
}

/// A controllable `UpdateChecking` test double whose `check(force:)` call
/// suspends indefinitely — genuinely, via a `CheckedContinuation`, not
/// merely a `Task.yield()` loop — until the test explicitly resolves it
/// (`resolve(with:)`) or rejects it (`reject(with:)`). Lets a test hold a
/// coordinator's in-flight update check open across some other operation
/// (e.g. `shutdown()`) before letting it complete, to reproduce races that
/// only manifest when the update service's own network round-trip is
/// still outstanding at the exact moment shutdown happens — something
/// `FakeUpdateChecking`'s always-synchronous `check(force:)` can never
/// model. An `actor` (not `@unchecked Sendable`) since, unlike the other
/// fakes here, its state genuinely is accessed from more than one
/// concurrent caller (the coordinator's in-flight call and the test's own
/// `resolve`/`reject`/`waitForCall`).
///
/// The very first `check(force:)` call resolves immediately with
/// `currentStateValue` rather than suspending: `AppSnapshotCoordinator
/// .makeAtStartup(...)` (which `AppSnapshotCoordinatorTests.makeCoordinator`
/// always goes through) itself performs one synchronous startup check as
/// part of *constructing* the coordinator, awaiting its result before
/// ever returning — so a fake that suspended unconditionally on every call
/// would hang that construction forever, with no continuation ever
/// registered for a test to resolve. Only the *second* and later calls
/// (i.e. whichever explicit `checkForUpdates(force:)`/scheduled call a
/// test itself triggers, once it already holds a constructed coordinator)
/// actually suspend.
actor SuspendableUpdateChecking: UpdateChecking {
    private(set) var checkCallCount = 0
    private(set) var checkForceValues: [Bool] = []
    var currentStateValue = UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: nil)

    private var pendingCheckContinuation: CheckedContinuation<UpdateState, Error>?
    private var waitingForCallContinuation: CheckedContinuation<Void, Never>?
    /// How many suspended (i.e. not auto-resolved) calls have been made so
    /// far — distinct from `checkCallCount`, which also counts the
    /// auto-resolved startup call. `waitForCall()` waits on this, not on
    /// `checkCallCount`, since a test only ever cares about the call it
    /// can actually still `resolve`/`reject`.
    private var suspendedCallCount = 0

    func check(force: Bool) async throws -> UpdateState {
        checkCallCount += 1
        checkForceValues.append(force)

        // The first call — the coordinator's own automatic startup check —
        // resolves immediately; see this type's documentation above.
        guard checkCallCount > 1 else {
            return currentStateValue
        }

        suspendedCallCount += 1
        waitingForCallContinuation?.resume()
        waitingForCallContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingCheckContinuation = continuation
        }
    }

    func currentState() async -> UpdateState { currentStateValue }

    private(set) var setIncludePrereleaseCallCount = 0
    private(set) var setIncludePrereleaseValues: [Bool] = []
    private var pendingSetIncludePrereleaseContinuation: CheckedContinuation<UpdateState, Error>?
    private var waitingForSetIncludePrereleaseCallContinuation: CheckedContinuation<Void, Never>?

    /// Unlike `check(force:)`, every call here suspends — there is no
    /// automatic startup call to special-case, since
    /// `AppSnapshotCoordinator.makeAtStartup(...)` never calls
    /// `setIncludePrerelease(_:)` itself.
    func setIncludePrerelease(_ value: Bool) async throws -> UpdateState {
        setIncludePrereleaseCallCount += 1
        setIncludePrereleaseValues.append(value)
        waitingForSetIncludePrereleaseCallContinuation?.resume()
        waitingForSetIncludePrereleaseCallContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingSetIncludePrereleaseContinuation = continuation
        }
    }

    @discardableResult
    func openCurrentRelease() async -> Bool { false }

    /// Suspends until a (non-startup) `check(force:)` call has actually
    /// been made — and is therefore itself now suspended awaiting
    /// `resolve`/`reject` — at least once, so a test can be certain that
    /// call has already passed any pre-await guard before proceeding.
    func waitForCall() async {
        if suspendedCallCount > 0 { return }
        await withCheckedContinuation { continuation in
            self.waitingForCallContinuation = continuation
        }
    }

    /// Resolves the currently-suspended `check(force:)` call (if any)
    /// successfully with `state`.
    func resolve(with state: UpdateState) {
        currentStateValue = state
        pendingCheckContinuation?.resume(returning: state)
        pendingCheckContinuation = nil
    }

    /// Resolves the currently-suspended `check(force:)` call (if any) by
    /// throwing `error`.
    func reject(with error: Error) {
        pendingCheckContinuation?.resume(throwing: error)
        pendingCheckContinuation = nil
    }

    /// Suspends until a `setIncludePrerelease(_:)` call has actually been
    /// made — and is therefore itself now suspended awaiting
    /// `resolveSetIncludePrerelease`/`rejectSetIncludePrerelease` — at
    /// least once, mirroring `waitForCall()` above for `check(force:)`.
    func waitForSetIncludePrereleaseCall() async {
        if setIncludePrereleaseCallCount > 0 { return }
        await withCheckedContinuation { continuation in
            self.waitingForSetIncludePrereleaseCallContinuation = continuation
        }
    }

    /// Resolves the currently-suspended `setIncludePrerelease(_:)` call
    /// (if any) successfully with `state`.
    func resolveSetIncludePrerelease(with state: UpdateState) {
        currentStateValue = state
        pendingSetIncludePrereleaseContinuation?.resume(returning: state)
        pendingSetIncludePrereleaseContinuation = nil
    }

    /// Resolves the currently-suspended `setIncludePrerelease(_:)` call
    /// (if any) by throwing `error`.
    func rejectSetIncludePrerelease(with error: Error) {
        pendingSetIncludePrereleaseContinuation?.resume(throwing: error)
        pendingSetIncludePrereleaseContinuation = nil
    }
}

/// A controllable `UpdateSchedulerControlling` test double whose `start()`
/// call suspends indefinitely — genuinely, via a `CheckedContinuation`, not
/// merely a `Task.yield()` loop — until the test explicitly `releaseStart()`s
/// it. Lets a test hold a coordinator's `performStartupUpdateCheckAndStartScheduler()`
/// suspended *inside* `updateScheduler.start()` itself (as opposed to
/// `SuspendableUpdateChecking`, which holds it suspended inside the
/// preceding `checkForUpdates(force:)` call) so it can reproduce the
/// narrower Task 12 race: `shutdown()` — and its own `updateScheduler
/// .stop()` call — running to completion *while a `start()` call is still
/// genuinely in flight*, rather than only ever before or after it. An
/// `actor` (not `@unchecked Sendable`) since its state is genuinely
/// accessed both by the coordinator's in-flight `start()`/`stop()` calls
/// and by the test's own `waitForStartCall()`/`releaseStart()`.
///
/// The very first `start()` call resolves immediately: `AppSnapshotCoordinator
/// .makeAtStartup(...)` (which `AppSnapshotCoordinatorTests.makeCoordinator`
/// always goes through) itself calls `updateScheduler.start()` once as part
/// of *constructing* the coordinator, awaiting its result before ever
/// returning — so a fake that suspended unconditionally on every call would
/// hang that construction forever, with no continuation ever registered for
/// a test to resolve. Only the *second* and later calls (i.e. whichever
/// explicit `performStartupUpdateCheckAndStartScheduler()` call a test
/// itself triggers, once it already holds a constructed coordinator)
/// actually suspend.
actor SuspendableUpdateSchedulerControlling: UpdateSchedulerControlling {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    /// Whether the scheduler is currently active — set `true` only once a
    /// `start()` call has actually *returned* (not merely been called),
    /// and `false` the instant a `stop()` call is made — so a test can
    /// assert the final settled state regardless of how `start()`/`stop()`
    /// calls happened to interleave.
    private(set) var isActive = false

    private var pendingStartContinuation: CheckedContinuation<Void, Never>?
    private var waitingForStartCallContinuation: CheckedContinuation<Void, Never>?
    /// How many suspended (i.e. not auto-resolved) `start()` calls have
    /// been made so far — distinct from `startCallCount`, which also
    /// counts the auto-resolved construction-time call.
    private var suspendedStartCallCount = 0

    func start() async {
        startCallCount += 1

        // The first call — `makeAtStartup(...)`'s own construction-time
        // start — resolves immediately; see this type's documentation
        // above.
        guard startCallCount > 1 else {
            isActive = true
            return
        }

        suspendedStartCallCount += 1
        waitingForStartCallContinuation?.resume()
        waitingForStartCallContinuation = nil
        await withCheckedContinuation { continuation in
            self.pendingStartContinuation = continuation
        }
        isActive = true
    }

    func stop() async {
        stopCallCount += 1
        isActive = false
    }

    /// Suspends until a (non-construction) `start()` call has actually
    /// been made — and is therefore itself now suspended awaiting
    /// `releaseStart()` — at least once, so a test can be certain that
    /// call has already passed the coordinator's own pre-await
    /// `!isShutDown` guard before proceeding.
    func waitForStartCall() async {
        if suspendedStartCallCount > 0 { return }
        await withCheckedContinuation { continuation in
            self.waitingForStartCallContinuation = continuation
        }
    }

    /// Resolves the currently-suspended `start()` call (if any), letting
    /// it proceed to set `isActive = true`.
    func releaseStart() {
        pendingStartContinuation?.resume()
        pendingStartContinuation = nil
    }
}
