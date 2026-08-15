import XCTest
@testable import Seer

/// Exercises `PowerAssertionService`'s lifecycle/compensation state machine
/// entirely against a synthetic `PowerAssertionBackend` double. This suite
/// must never construct `IOKitPowerAssertionBackend` — a real
/// `IOPMAssertionCreateWithName` call would actually prevent the test
/// machine from idle-sleeping, which must never happen in a test process.
@MainActor
final class PowerAssertionServiceTests: XCTestCase {
    /// A scriptable `PowerAssertionBackend` double. Records every
    /// created/released id (and, for readability at call sites, a
    /// friendlier mirror of which IOKit assertion type each creation
    /// requested) and lets a test arm specific ids/calls to fail.
    // `@unchecked Sendable` (matching `ManualHistoryScheduler` in
    // `HistoryStoreTests.swift`): every method here only ever runs on the
    // main actor, synchronously, driven by `PowerAssertionService` (itself
    // `@MainActor`) — there is no genuine concurrent access to guard
    // against, only the compiler's inability to verify that statically for
    // a plain mutable class satisfying `PowerAssertionBackend: Sendable`.
    final class FakeAssertionBackend: PowerAssertionBackend, @unchecked Sendable {
        enum RecordedAssertionType: Equatable {
            case preventUserIdleSystemSleep
            case preventUserIdleDisplaySleep
        }

        private(set) var createdTypes: [RecordedAssertionType] = []
        private(set) var releasedIDs: [UInt32] = []
        private(set) var createCallCount = 0
        private(set) var releaseCallCount = 0

        private var nextID: UInt32 = 1

        /// One scripted result consumed per `createAssertion` call, in
        /// order; once exhausted, further calls succeed.
        var createResults: [Result<Void, PowerAssertionBackendError>] = []
        /// Consumed (one-shot) per matching id: the next `releaseAssertion`
        /// call for that id throws this error instead of succeeding.
        var releaseFailuresByID: [UInt32: PowerAssertionBackendError] = [:]

        func createAssertion(mode: KeepAwakeMode, reason: String) throws -> UInt32 {
            createCallCount += 1
            createdTypes.append(mode == .system ? .preventUserIdleSystemSleep : .preventUserIdleDisplaySleep)
            if !createResults.isEmpty {
                let result = createResults.removeFirst()
                if case .failure(let error) = result {
                    throw error
                }
            }
            let id = nextID
            nextID += 1
            return id
        }

        func releaseAssertion(id: UInt32) throws {
            releaseCallCount += 1
            releasedIDs.append(id)
            if let error = releaseFailuresByID.removeValue(forKey: id) {
                throw error
            }
        }
    }

    /// A `PowerAssertionBackend` whose `createAssertion` always fails —
    /// matching the plan's example fixture name exactly.
    struct FailingAssertionBackend: PowerAssertionBackend {
        func createAssertion(mode: KeepAwakeMode, reason: String) throws -> UInt32 {
            throw PowerAssertionBackendError.createFailed(ioReturnCode: -1)
        }

        func releaseAssertion(id: UInt32) throws {}
    }

    /// A foreign (non-`PowerAssertionBackendError`) error a
    /// `PowerAssertionBackend` conformance might throw — exercising the
    /// protocol's actual untyped `throws`, which permits any `Error`, not
    /// only the service's own typed `PowerAssertionBackendError`.
    struct ForeignBackendError: Error, Equatable, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// A scriptable `PowerAssertionBackend` double that throws arbitrary
    /// foreign errors (`ForeignBackendError`, never
    /// `PowerAssertionBackendError`) instead — so tests can verify
    /// `PowerAssertionService` normalizes *any* `Error` into a stable
    /// typed one and still runs every compensating rollback, rather than
    /// only handling errors of its own declared type.
    final class ForeignErrorAssertionBackend: PowerAssertionBackend, @unchecked Sendable {
        private(set) var createdModes: [KeepAwakeMode] = []
        private(set) var releasedIDs: [UInt32] = []
        private var nextID: UInt32 = 1

        /// One scripted foreign error consumed per `createAssertion` call,
        /// in order; once exhausted, further calls succeed.
        var createFailures: [Error] = []
        /// Consumed (one-shot) per matching id: the next `releaseAssertion`
        /// call for that id throws this foreign error instead of succeeding.
        var releaseFailuresByID: [UInt32: Error] = [:]

        func createAssertion(mode: KeepAwakeMode, reason: String) throws -> UInt32 {
            createdModes.append(mode)
            if !createFailures.isEmpty {
                throw createFailures.removeFirst()
            }
            let id = nextID
            nextID += 1
            return id
        }

        func releaseAssertion(id: UInt32) throws {
            releasedIDs.append(id)
            if let error = releaseFailuresByID.removeValue(forKey: id) {
                throw error
            }
        }
    }

    // MARK: - Mode replacement (plan example)

    func testChangingModeReplacesOneActiveAssertion() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)

        try service.setDesired(active: true, mode: .system)
        try service.setDesired(active: true, mode: .display)

        XCTAssertEqual(backend.createdTypes, [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep])
        XCTAssertEqual(backend.releasedIDs, [1])
        XCTAssertEqual(service.activeAssertionID, 2)
        XCTAssertEqual(service.activeMode, .display)
        XCTAssertTrue(service.isActive)
    }

    // MARK: - Creation failure (plan example)

    func testCreationFailureNeverReportsKeepingAwake() {
        let service = PowerAssertionService(backend: FailingAssertionBackend())

        XCTAssertThrowsError(try service.setDesired(active: true, mode: .system)) { error in
            guard case .creationFailed = error as? PowerAssertionServiceError else {
                return XCTFail("expected .creationFailed, got \(error)")
            }
        }
        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.activeAssertionID)
        XCTAssertNil(service.activeMode)
    }

    // MARK: - Idempotent no-ops

    func testInactiveWithNoAssertionIsIdempotentNoOp() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)

        let changed = try service.setDesired(active: false, mode: .system)

        XCTAssertFalse(changed)
        XCTAssertEqual(backend.createCallCount, 0)
        XCTAssertEqual(backend.releaseCallCount, 0)
        XCTAssertFalse(service.isActive)
    }

    func testActivatingSameModeTwiceIsIdempotentWithNoChurn() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)

        try service.setDesired(active: true, mode: .system)
        let changedAgain = try service.setDesired(active: true, mode: .system)

        XCTAssertFalse(changedAgain)
        XCTAssertEqual(backend.createCallCount, 1)
        XCTAssertEqual(backend.releaseCallCount, 0)
        XCTAssertEqual(service.activeAssertionID, 1)
        XCTAssertEqual(service.activeMode, .system)
    }

    func testDuplicateDeactivateCallsAreIdempotent() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)

        _ = try service.setDesired(active: false, mode: .system)
        let secondChanged = try service.setDesired(active: false, mode: .system)

        XCTAssertFalse(secondChanged)
        XCTAssertEqual(backend.releaseCallCount, 1)
        XCTAssertFalse(service.isActive)
    }

    // MARK: - Fresh activation

    func testActivateFreshCreatesAndPublishesOnlyOnSuccess() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)

        let changed = try service.setDesired(active: true, mode: .display)

        XCTAssertTrue(changed)
        XCTAssertEqual(backend.createdTypes, [.preventUserIdleDisplaySleep])
        XCTAssertEqual(service.activeAssertionID, 1)
        XCTAssertEqual(service.activeMode, .display)
        XCTAssertTrue(service.isActive)
    }

    // MARK: - Deactivate

    func testDeactivateReleasesActiveAssertionAndClearsStateOnSuccess() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)

        let changed = try service.setDesired(active: false, mode: .system)

        XCTAssertTrue(changed)
        XCTAssertEqual(backend.releasedIDs, [1])
        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.activeAssertionID)
        XCTAssertNil(service.activeMode)
    }

    func testDeactivateFailureReportsInactiveAndTracksPendingRelease() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)
        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -1)

        XCTAssertThrowsError(try service.setDesired(active: false, mode: .system)) { error in
            guard case .releaseFailed(_, let actualID, let actualMode) = error as? PowerAssertionServiceError else {
                return XCTFail("expected .releaseFailed, got \(error)")
            }
            XCTAssertEqual(actualID, 1)
            XCTAssertEqual(actualMode, .system)
        }
        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.activeAssertionID)
        XCTAssertNil(service.activeMode)
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [1])
    }

    // MARK: - Mode replacement: creation failure

    func testReplacementCreationFailureLeavesOldAssertionActive() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)
        backend.createResults = [.failure(.createFailed(ioReturnCode: -2))]

        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display)) { error in
            guard case .replacementCreationFailed(_, let actualID, let actualMode) = error as? PowerAssertionServiceError else {
                return XCTFail("expected .replacementCreationFailed, got \(error)")
            }
            XCTAssertEqual(actualID, 1)
            XCTAssertEqual(actualMode, .system)
        }
        // The old assertion was never touched by the failed replacement.
        XCTAssertEqual(backend.releasedIDs, [])
        XCTAssertEqual(service.activeAssertionID, 1)
        XCTAssertEqual(service.activeMode, .system)
        XCTAssertTrue(service.isActive)
    }

    // MARK: - Mode replacement: old release fails, rollback succeeds

    func testReplacementOldReleaseFailureRollsBackNewAssertionAndKeepsOldActive() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system) // id 1
        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -3)

        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display)) { error in
            guard case .replacementRolledBack(_, let actualID, let actualMode) = error as? PowerAssertionServiceError else {
                return XCTFail("expected .replacementRolledBack, got \(error)")
            }
            XCTAssertEqual(actualID, 1)
            XCTAssertEqual(actualMode, .system)
        }

        // New assertion (id 2) was created, then rolled back (released)
        // because the old one (id 1) could not be confirmed released.
        XCTAssertEqual(backend.createdTypes, [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep])
        XCTAssertEqual(backend.releasedIDs, [1, 2])
        // Reported state reverts to exactly what it was before the call:
        // never two silently-live ids.
        XCTAssertEqual(service.activeAssertionID, 1)
        XCTAssertEqual(service.activeMode, .system)
        XCTAssertTrue(service.isActive)
    }

    // MARK: - Mode replacement: old release fails, rollback also fails

    func testReplacementDoubleReleaseFailurePinsNewAssertionAndReportsLeak() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system) // id 1
        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -4)
        backend.releaseFailuresByID[2] = .releaseFailed(ioReturnCode: -5)

        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display)) { error in
            guard case .replacementRollbackFailed(
                _, _, let leakedID, let actualID, let actualMode
            ) = error as? PowerAssertionServiceError else {
                return XCTFail("expected .replacementRollbackFailed, got \(error)")
            }
            XCTAssertEqual(leakedID, 1)
            XCTAssertEqual(actualID, 2)
            XCTAssertEqual(actualMode, .display)
        }

        XCTAssertEqual(backend.createdTypes, [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep])
        // Both releases were attempted (old, then the rollback of new).
        XCTAssertEqual(backend.releasedIDs, [1, 2])
        // Both may still be alive at the OS level; the service must not
        // silently report only one, and must not falsely claim the wrong
        // mode — it pins to the newly created (confirmed-created)
        // assertion instead of pretending the old one is still the sole
        // truth.
        XCTAssertEqual(service.activeAssertionID, 2)
        XCTAssertEqual(service.activeMode, .display)
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [1])
        XCTAssertTrue(service.hasPendingReleases)
    }

    func testSameModeReconciliationRetriesForgottenOldAssertionWithoutReleasingDesiredAssertion() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)
        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -4)
        backend.releaseFailuresByID[2] = .releaseFailed(ioReturnCode: -5)
        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display))

        let changed = try service.setDesired(active: true, mode: .display)

        XCTAssertTrue(changed, "releasing a pending assertion is observable reconciliation work")
        XCTAssertEqual(backend.createdTypes, [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep])
        XCTAssertEqual(backend.releasedIDs, [1, 2, 1])
        XCTAssertEqual(service.activeAssertionID, 2)
        XCTAssertEqual(service.activeMode, .display)
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [])
        XCTAssertFalse(service.hasPendingReleases)
    }

    func testDeactivateReportsDesiredInactiveWhileBothPotentiallyLiveAssertionsRemainRetryable() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)
        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -4)
        backend.releaseFailuresByID[2] = .releaseFailed(ioReturnCode: -5)
        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display))

        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -6)
        backend.releaseFailuresByID[2] = .releaseFailed(ioReturnCode: -7)
        XCTAssertThrowsError(try service.setDesired(active: false, mode: .display))

        XCTAssertFalse(service.isActive, "desired inactive semantics must not be overwritten by cleanup uncertainty")
        XCTAssertNil(service.activeAssertionID)
        XCTAssertNil(service.activeMode)
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [1, 2])

        XCTAssertTrue(try service.setDesired(active: false, mode: .display))
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [])
        XCTAssertFalse(service.hasPendingReleases)
        XCTAssertFalse(service.isActive)
    }

    func testMultipleFailedReplacementsAccumulateEveryPotentiallyLiveOrphan() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system) // id 1
        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -1)
        backend.releaseFailuresByID[2] = .releaseFailed(ioReturnCode: -2)
        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display)) // desired id 2, pending id 1

        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -3)
        backend.releaseFailuresByID[2] = .releaseFailed(ioReturnCode: -4)
        backend.releaseFailuresByID[3] = .releaseFailed(ioReturnCode: -5)
        XCTAssertThrowsError(try service.setDesired(active: true, mode: .system))

        XCTAssertEqual(service.activeAssertionID, 3)
        XCTAssertEqual(service.activeMode, .system)
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [1, 2])
        XCTAssertEqual(backend.releasedIDs, [1, 2, 1, 2, 3])

        XCTAssertTrue(try service.setDesired(active: true, mode: .system))
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [])
        XCTAssertEqual(service.activeAssertionID, 3, "pending cleanup must never release the desired assertion")
        XCTAssertEqual(backend.releasedIDs.suffix(2), [1, 2])
    }

    // MARK: - Shutdown

    func testShutdownReleasesActiveAssertion() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)

        try service.shutdown()

        XCTAssertEqual(backend.releasedIDs, [1])
        XCTAssertFalse(service.isActive)
    }

    func testShutdownIsIdempotent() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)
        try service.shutdown()

        try service.shutdown()

        XCTAssertEqual(backend.releaseCallCount, 1)
        XCTAssertFalse(service.isActive)
    }

    func testShutdownWithNoActiveAssertionIsANoOp() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)

        try service.shutdown()

        XCTAssertEqual(backend.releaseCallCount, 0)
        XCTAssertFalse(service.isActive)
    }

    func testShutdownSurfacesReleaseFailureRatherThanSwallowingIt() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)
        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -6)

        XCTAssertThrowsError(try service.shutdown()) { error in
            guard case .releaseFailed = error as? PowerAssertionServiceError else {
                return XCTFail("expected .releaseFailed, got \(error)")
            }
        }
        XCTAssertFalse(service.isActive, "shutdown changes desired state immediately even when OS cleanup is uncertain")
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [1])
    }

    func testShutdownRetriesAllPendingReleasesUntilNoAssertionIsForgotten() throws {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)
        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -1)
        backend.releaseFailuresByID[2] = .releaseFailed(ioReturnCode: -2)
        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display))

        backend.releaseFailuresByID[1] = .releaseFailed(ioReturnCode: -3)
        backend.releaseFailuresByID[2] = .releaseFailed(ioReturnCode: -4)
        XCTAssertThrowsError(try service.shutdown())
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [1, 2])

        try service.shutdown()

        XCTAssertEqual(service.pendingReleaseAssertionIDs, [])
        XCTAssertEqual(backend.releasedIDs.suffix(2), [1, 2])
    }

    // MARK: - Foreign (non-`PowerAssertionBackendError`) error normalization

    /// A foreign error thrown by `createAssertion` (fresh activation, no
    /// assertion active yet) must still be caught — the protocol's
    /// untyped `throws` permits it — and normalized into a typed
    /// `.creationFailed(underlying: .foreign(...))`, preserving the
    /// underlying message, rather than escaping uncaught.
    func testForeignCreationErrorIsNormalizedIntoTypedCreationFailed() {
        let backend = ForeignErrorAssertionBackend()
        backend.createFailures = [ForeignBackendError(message: "unexpected create boom")]
        let service = PowerAssertionService(backend: backend)

        XCTAssertThrowsError(try service.setDesired(active: true, mode: .system)) { error in
            guard case .creationFailed(let underlying) = error as? PowerAssertionServiceError else {
                return XCTFail("expected .creationFailed, got \(error)")
            }
            guard case .foreign(let description) = underlying else {
                return XCTFail("expected a normalized .foreign underlying error, got \(underlying)")
            }
            XCTAssertTrue(description.contains("unexpected create boom"))
        }
        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.activeAssertionID)
        XCTAssertNil(service.activeMode)
    }

    /// A foreign error thrown by `releaseAssertion` during a plain
    /// deactivate must likewise be normalized, and — matching the typed
    /// case's behavior — never assumed to have actually released the
    /// assertion.
    func testForeignDeactivateErrorIsNormalizedAndTracksPendingRelease() throws {
        let backend = ForeignErrorAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system)
        backend.releaseFailuresByID[1] = ForeignBackendError(message: "unexpected release boom")

        XCTAssertThrowsError(try service.setDesired(active: false, mode: .system)) { error in
            guard case .releaseFailed(let underlying, let actualID, let actualMode) = error as? PowerAssertionServiceError else {
                return XCTFail("expected .releaseFailed, got \(error)")
            }
            guard case .foreign(let description) = underlying else {
                return XCTFail("expected a normalized .foreign underlying error, got \(underlying)")
            }
            XCTAssertTrue(description.contains("unexpected release boom"))
            XCTAssertEqual(actualID, 1)
            XCTAssertEqual(actualMode, .system)
        }
        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.activeAssertionID)
        XCTAssertNil(service.activeMode)
        XCTAssertEqual(service.pendingReleaseAssertionIDs, [1])
    }

    /// A foreign error thrown by the *old* assertion's release during a
    /// mode replacement must still trigger the compensating rollback
    /// (releasing the just-created replacement) exactly as a typed
    /// `PowerAssertionBackendError` would — the untyped `catch` here must
    /// not let a foreign error skip the rollback entirely.
    func testForeignOldReleaseErrorDuringReplacementRollsBackSuccessfully() throws {
        let backend = ForeignErrorAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system) // id 1
        backend.releaseFailuresByID[1] = ForeignBackendError(message: "old release boom")

        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display)) { error in
            guard case .replacementRolledBack(let underlying, let actualID, let actualMode) = error as? PowerAssertionServiceError else {
                return XCTFail("expected .replacementRolledBack, got \(error)")
            }
            guard case .foreign(let description) = underlying else {
                return XCTFail("expected a normalized .foreign underlying error, got \(underlying)")
            }
            XCTAssertTrue(description.contains("old release boom"))
            XCTAssertEqual(actualID, 1)
            XCTAssertEqual(actualMode, .system)
        }

        // The rollback release of the newly created id 2 was actually
        // attempted (and succeeded), restoring the old assertion as sole
        // active — never two silently-live ids.
        XCTAssertEqual(backend.createdModes, [.system, .display])
        XCTAssertEqual(backend.releasedIDs, [1, 2])
        XCTAssertEqual(service.activeAssertionID, 1)
        XCTAssertEqual(service.activeMode, .system)
        XCTAssertTrue(service.isActive)
    }

    /// Both the old release *and* the compensating rollback release throw
    /// foreign errors: the service must still pin its reported state to
    /// the newly created (confirmed-created) assertion and surface the
    /// leaked old id, exactly as it does for typed
    /// `PowerAssertionBackendError` failures.
    func testForeignBothReleaseFailuresDuringReplacementPinsNewAssertionAndReportsLeak() throws {
        let backend = ForeignErrorAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        try service.setDesired(active: true, mode: .system) // id 1
        backend.releaseFailuresByID[1] = ForeignBackendError(message: "old release boom")
        backend.releaseFailuresByID[2] = ForeignBackendError(message: "rollback release boom")

        XCTAssertThrowsError(try service.setDesired(active: true, mode: .display)) { error in
            guard case .replacementRollbackFailed(
                let oldUnderlying, let rollbackUnderlying, let leakedID, let actualID, let actualMode
            ) = error as? PowerAssertionServiceError else {
                return XCTFail("expected .replacementRollbackFailed, got \(error)")
            }
            guard case .foreign(let oldDescription) = oldUnderlying, case .foreign(let rollbackDescription) = rollbackUnderlying else {
                return XCTFail("expected both underlying errors normalized as .foreign")
            }
            XCTAssertTrue(oldDescription.contains("old release boom"))
            XCTAssertTrue(rollbackDescription.contains("rollback release boom"))
            XCTAssertEqual(leakedID, 1)
            XCTAssertEqual(actualID, 2)
            XCTAssertEqual(actualMode, .display)
        }

        XCTAssertEqual(backend.createdModes, [.system, .display])
        // Both releases (old, then the rollback attempt of new) were
        // attempted.
        XCTAssertEqual(backend.releasedIDs, [1, 2])
        // Both may still be alive at the OS level; the service pins to
        // the newly created (confirmed-created) assertion instead of
        // pretending the old one is still the sole truth.
        XCTAssertEqual(service.activeAssertionID, 2)
        XCTAssertEqual(service.activeMode, .display)
        XCTAssertTrue(service.isActive)
    }

    // MARK: - Reason string

    func testReasonDefaultsToStableConstant() {
        let backend = FakeAssertionBackend()
        let service = PowerAssertionService(backend: backend)
        XCTAssertFalse(PowerAssertionReason.stable.isEmpty)
        _ = service // constructed successfully with the default reason
    }
}
