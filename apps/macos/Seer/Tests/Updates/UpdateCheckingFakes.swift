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
