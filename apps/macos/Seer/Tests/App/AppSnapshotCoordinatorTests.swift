import XCTest
@testable import Seer

/// Exercises `AppSnapshotCoordinator`'s atomic transitions end to end
/// against real `SettingsStore`/`HistoryStore` actors (backed by the
/// in-memory `InMemorySettingsFileSystem` test double already used by
/// `AtomicJSONStoreTests`/`SettingsStoreTests` — never real Application
/// Support) and a synthetic `PowerAssertionBackend` double — never a real
/// IOKit power assertion.
@MainActor
final class AppSnapshotCoordinatorTests: XCTestCase {
    /// A scriptable `PowerAssertionBackend` double, purpose-built for these
    /// coordinator-level tests (kept separate from
    /// `PowerAssertionServiceTests.FakeAssertionBackend` so this file stays
    /// self-contained). `@unchecked Sendable` for the same reason as that
    /// type: every method here only ever runs synchronously on the main
    /// actor, driven by `PowerAssertionService`.
    final class CoordinatorFakePowerBackend: PowerAssertionBackend, @unchecked Sendable {
        private(set) var createdModes: [KeepAwakeMode] = []
        private(set) var releasedIDs: [UInt32] = []
        private var nextID: UInt32 = 1

        /// One scripted result consumed per `createAssertion` call, in
        /// order; once exhausted, further calls succeed.
        var createResults: [Result<Void, PowerAssertionBackendError>] = []
        /// Consumed (one-shot) per matching id: the next
        /// `releaseAssertion` call for that id throws this error instead
        /// of succeeding.
        var releaseFailuresByID: [UInt32: PowerAssertionBackendError] = [:]

        func createAssertion(mode: KeepAwakeMode, reason: String) throws -> UInt32 {
            createdModes.append(mode)
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
            releasedIDs.append(id)
            if let error = releaseFailuresByID.removeValue(forKey: id) {
                throw error
            }
        }
    }

    /// Collects every `AppSnapshot` the coordinator emits, in order —
    /// exact snapshot values, so tests can assert both the final state and
    /// the precise sequence/count of completed transitions.
    final class FakeRendererSink: AppSnapshotRendererSink {
        private(set) var emittedSnapshots: [AppSnapshot] = []

        func emit(_ snapshot: AppSnapshot) {
            emittedSnapshots.append(snapshot)
        }
    }

    private let settingsURL = URL(fileURLWithPath: "/Seer-Coordinator-Test/ai.opencoven.seer/settings.json")
    private let historyURL = URL(fileURLWithPath: "/Seer-Coordinator-Test/ai.opencoven.seer/history.json")

    private func activeAgent(id: String = "codex:/fixtures/active.jsonl") -> ActiveAgent {
        ActiveAgent(
            id: id,
            name: "Codex",
            detail: "Fixtures · Working",
            source: .session,
            lastActivityAt: 1_700_000_000_000
        )
    }

    private func makeCoordinator(
        settingsFileSystem: InMemorySettingsFileSystem = InMemorySettingsFileSystem(),
        historyFileSystem: InMemorySettingsFileSystem = InMemorySettingsFileSystem(),
        historyScheduler: HistoryScheduler = ManualHistoryScheduler(),
        clock: MutableClock = MutableClock(now: 1_700_000_000_000),
        powerBackend: CoordinatorFakePowerBackend = CoordinatorFakePowerBackend(),
        appVersion: String = "1.0.0-test",
        updateService: any UpdateChecking = FakeUpdateChecking(),
        updateScheduler: any UpdateSchedulerControlling = FakeUpdateSchedulerControlling()
    ) async -> (AppSnapshotCoordinator, FakeRendererSink, CoordinatorFakePowerBackend) {
        let settingsAtomicStore = AtomicJSONStore<SettingsDocument>(
            fileURL: settingsURL,
            fileSystem: settingsFileSystem,
            clock: clock
        )
        let settingsStore = SettingsStore(store: settingsAtomicStore)

        let historyAtomicStore = AtomicJSONStore<HistoryDocument>(
            fileURL: historyURL,
            fileSystem: historyFileSystem,
            clock: clock
        )
        let historyStore = HistoryStore(
            store: historyAtomicStore,
            clock: clock,
            scheduler: historyScheduler,
            idGenerator: SequentialHistorySessionIDGenerator()
        )

        let power = PowerAssertionService(backend: powerBackend)
        let renderer = FakeRendererSink()

        let coordinator = await AppSnapshotCoordinator.makeAtStartup(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: renderer,
            clock: clock,
            appVersion: appVersion,
            updateService: updateService,
            updateScheduler: updateScheduler
        )

        return (coordinator, renderer, powerBackend)
    }


    // MARK: - Plan example: completed scan updates power/history/snapshot together

    func testCompletedScanUpdatesPowerHistoryAndSnapshotTogether() async {
        // Two ticks: `HistoryStore.record`'s first-ever tick opens a
        // session with an empty `agents` list (there is no elapsed delta
        // yet to attribute); the *second* tick is what actually credits
        // per-agent time into `currentSession.agents` — see
        // `HistoryStoreTests.testPerAgentAccumulationSortsDescending`,
        // which this mirrors.
        let clock = MutableClock(now: 1_700_000_000_000)
        let (coordinator, renderer, _) = await makeCoordinator(clock: clock)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 2_000
        await coordinator.applyScan([agent], scannedAt: clock.now)

        XCTAssertTrue(coordinator.snapshot.monitor.active)
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertEqual(coordinator.snapshot.history.currentSession?.agents.first?.id, agent.id)
        XCTAssertEqual(coordinator.snapshot.monitor.agents.first?.id, agent.id)
        XCTAssertEqual(renderer.emittedSnapshots.last, coordinator.snapshot)
        XCTAssertEqual(renderer.emittedSnapshots.count, 2)
    }

    // MARK: - Empty scan releases the assertion and closes history

    func testEmptyScanReleasesAssertionAndClosesHistory() async {
        let clock = MutableClock(now: 1_700_000_000_000)
        let (coordinator, renderer, powerBackend) = await makeCoordinator(clock: clock)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 2_000
        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 100

        await coordinator.applyScan([], scannedAt: clock.now)

        XCTAssertFalse(coordinator.snapshot.monitor.active)
        XCTAssertFalse(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertNil(coordinator.snapshot.history.currentSession)
        XCTAssertEqual(coordinator.snapshot.history.recentSessions.count, 1)
        XCTAssertEqual(powerBackend.releasedIDs, [1])
        XCTAssertEqual(renderer.emittedSnapshots.count, 3)
    }

    // MARK: - Power creation failure: actual-state reporting + recovery

    func testPowerCreationFailureDuringScanReportsActualStateAndRecoversOnNextSuccess() async {
        let clock = MutableClock(now: 1_700_000_000_000)
        let powerBackend = CoordinatorFakePowerBackend()
        powerBackend.createResults = [.failure(.createFailed(ioReturnCode: -1))]
        let (coordinator, renderer, _) = await makeCoordinator(clock: clock, powerBackend: powerBackend)

        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)

        XCTAssertTrue(coordinator.snapshot.monitor.active)
        XCTAssertFalse(coordinator.snapshot.monitor.keepingAwake, "a failed assertion creation must never report keepingAwake")
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == PowerDiagnosticID.assertionFailed })
        XCTAssertEqual(renderer.emittedSnapshots.count, 1)

        clock.now += 10
        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)

        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake, "the next successful scan must recover")
        XCTAssertFalse(coordinator.snapshot.diagnostics.contains { $0.id == PowerDiagnosticID.assertionFailed })
        XCTAssertEqual(renderer.emittedSnapshots.count, 2)
    }

    // MARK: - Failed monitor scan retains previous state

    func testFailedMonitorScanRetainsPreviousStateAndAddsDiagnosticClearedByNextSuccess() async {
        let clock = MutableClock(now: 1_700_000_000_000)
        let (coordinator, renderer, powerBackend) = await makeCoordinator(clock: clock)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now)
        XCTAssertTrue(coordinator.snapshot.monitor.active)
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)

        clock.now += 10
        await coordinator.applyScanFailure(occurredAt: clock.now)

        // Every previous field is retained untouched — a scan failure is
        // never treated as "zero agents," which would wrongly deactivate
        // the assertion and close the current session.
        XCTAssertTrue(coordinator.snapshot.monitor.active)
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertEqual(coordinator.snapshot.monitor.agents.first?.id, agent.id)
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == AgentMonitorDiagnosticID.scanFailed })
        XCTAssertEqual(powerBackend.createdModes.count, 1, "a failed scan must never touch the power assertion")
        XCTAssertNotNil(coordinator.snapshot.history.currentSession, "a failed scan must never close the current session")

        clock.now += 10
        await coordinator.applyScan([agent], scannedAt: clock.now)

        XCTAssertFalse(coordinator.snapshot.diagnostics.contains { $0.id == AgentMonitorDiagnosticID.scanFailed })
        XCTAssertEqual(renderer.emittedSnapshots.count, 3)
    }

    // MARK: - Startup diagnostics: mapped and deduplicated

    func testStartupDiagnosticsAreMappedAndDeduplicated() async {
        let settingsFS = InMemorySettingsFileSystem()
        let historyFS = InMemorySettingsFileSystem()
        await settingsFS.seedFile(at: settingsURL, contents: Data("{ not valid json".utf8))
        await historyFS.seedFile(at: historyURL, contents: Data("{ not valid json".utf8))

        let (coordinator, renderer, _) = await makeCoordinator(settingsFileSystem: settingsFS, historyFileSystem: historyFS)

        let diagnostics = coordinator.snapshot.diagnostics
        XCTAssertEqual(diagnostics.count, 2, "settings and history corruption must both survive, distinctly")
        XCTAssertTrue(diagnostics.contains { $0.id == StorageDiagnosticID.corrupt })
        XCTAssertTrue(diagnostics.contains { $0.id == "storage.history.corrupt" })
        // No emission yet: seeding startup diagnostics is not itself a
        // "completed transition."
        XCTAssertEqual(renderer.emittedSnapshots.count, 0)
    }

    /// Asserts the coordinator's stable diagnostic id vocabulary is
    /// exactly the approved/reserved set — no more, no less. In
    /// particular there is deliberately no id here for a settings-write
    /// failure during `setKeepAwakeMode`: Task 9's plan approved no such
    /// id, and `CoordinatorDiagnosticID` must never grow one outside that
    /// closed list (see `testSetKeepAwakeModePersistenceFailure...` below
    /// for what a settings persist failure surfaces instead).
    func testStableDiagnosticIDsMatchThePlanExactly() {
        XCTAssertEqual(AgentMonitorDiagnosticID.scanFailed, "monitor.scan.failed")
        XCTAssertEqual(PowerDiagnosticID.assertionFailed, "power.assertion.failed")
        XCTAssertEqual(StorageDiagnosticID.corrupt, "storage.settings.corrupt")
        XCTAssertEqual(StorageDiagnosticID.unsupportedVersion, "storage.settings.unsupported-version")
        XCTAssertEqual(StorageDiagnosticID.readFailed, "storage.settings.read-failed")
        XCTAssertEqual(CoordinatorDiagnosticID.updatesCheckFailed, "updates.check.failed")

        let corrupt = Diagnostic(id: StorageDiagnosticID.corrupt, message: "m", occurredAt: 0)
        let unsupported = Diagnostic(id: StorageDiagnosticID.unsupportedVersion, message: "m", occurredAt: 0)
        let readFailed = Diagnostic(id: StorageDiagnosticID.readFailed, message: "m", occurredAt: 0)
        XCTAssertEqual(StorageDiagnosticAlias.remapForHistory(corrupt).id, "storage.history.corrupt")
        XCTAssertEqual(StorageDiagnosticAlias.remapForHistory(unsupported).id, "storage.history.unsupported-version")
        XCTAssertEqual(StorageDiagnosticAlias.remapForHistory(readFailed).id, "storage.history.read-failed")
    }

    // MARK: - Mode change: persists before publishing, updates active power

    func testSetKeepAwakeModePersistsSettingsBeforePublishingAndUpdatesActivePowerAssertion() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsFS = InMemorySettingsFileSystem()
        let (coordinator, renderer, powerBackend) = await makeCoordinator(settingsFileSystem: settingsFS, clock: clock)

        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system)

        try await coordinator.setKeepAwakeMode(.display)

        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .display)
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertEqual(powerBackend.createdModes, [.system, .display])
        XCTAssertEqual(powerBackend.releasedIDs, [1], "the old .system assertion must be released once the .display replacement succeeds")

        let decoder = JSONDecoder.seer
        let savedBytes = await settingsFS.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .display, "settings must be durably persisted, not just published in memory")
        XCTAssertEqual(renderer.emittedSnapshots.count, 2)
    }

    // MARK: - Mode change: settings persistence failure

    /// An ordinary, transient settings write failure (no accompanying
    /// load-time diagnostic — the settings file loaded cleanly) must
    /// never invent a new coordinator-specific diagnostic id: Task 9's
    /// plan approved no such id (see
    /// `testStableDiagnosticIDsMatchThePlanExactly`). The failure is
    /// still never swallowed — the actual (old, unpublished-as-new) mode
    /// is what gets published, and the original typed error still
    /// propagates to the caller.
    func testSetKeepAwakeModePersistenceFailureDoesNotPublishSuccessShapedModeAndThrows() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsFS = InMemorySettingsFileSystem()
        let (coordinator, renderer, powerBackend) = await makeCoordinator(settingsFileSystem: settingsFS, clock: clock)
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system)
        let diagnosticsBeforeAttempt = coordinator.snapshot.diagnostics

        await settingsFS.setFailNextWrite(SettingsFileSystemError.other("disk full"))

        do {
            try await coordinator.setKeepAwakeMode(.display)
            XCTFail("expected the persistence failure to propagate")
        } catch StorageError.writeFailed {
            // Expected.
        }

        XCTAssertEqual(
            coordinator.snapshot.monitor.keepAwakeMode, .system,
            "must never publish the requested mode as though persistence had succeeded"
        )
        XCTAssertEqual(
            coordinator.snapshot.diagnostics, diagnosticsBeforeAttempt,
            "an ordinary transient write failure with no pre-existing approved diagnostic must not invent one"
        )
        XCTAssertEqual(powerBackend.createdModes, [], "no power assertion was ever active, so no power call should occur")
        XCTAssertEqual(renderer.emittedSnapshots.count, 1)
    }

    /// When a settings write fails *because* the file is read-only from
    /// load time (e.g. a future/unsupported schema version), that
    /// already-approved `storage.settings.unsupported-version` diagnostic
    /// — present since startup — is preserved/refreshed rather than
    /// replaced by (or hidden behind) any invented id.
    func testSetKeepAwakeModePersistenceFailurePreservesExistingApprovedSettingsDiagnostic() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsFS = InMemorySettingsFileSystem()
        let futureBytes = Data(#"{"version":999,"keepAwakeMode":"system","includePrereleaseUpdates":false}"#.utf8)
        await settingsFS.seedFile(at: settingsURL, contents: futureBytes)
        let (coordinator, _, _) = await makeCoordinator(settingsFileSystem: settingsFS, clock: clock)

        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == StorageDiagnosticID.unsupportedVersion })

        do {
            try await coordinator.setKeepAwakeMode(.display)
            XCTFail("expected the read-only (future-version) settings file to reject the write")
        } catch StorageError.writesDisabled {
            // Expected.
        }

        XCTAssertEqual(
            coordinator.snapshot.monitor.keepAwakeMode, .system,
            "a read-only settings file must never accept the requested mode"
        )
        XCTAssertEqual(
            coordinator.snapshot.diagnostics.filter { $0.id == StorageDiagnosticID.unsupportedVersion }.count, 1,
            "the pre-existing approved diagnostic is preserved/refreshed, never duplicated or replaced by an invented id"
        )
    }

    // MARK: - Mode change: power replacement failure reports actual old state

    func testModeReplacementFailureDuringModeChangeReportsActualOldStateNotNewMode() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let powerBackend = CoordinatorFakePowerBackend()
        let (coordinator, renderer, _) = await makeCoordinator(clock: clock, powerBackend: powerBackend)

        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system)

        powerBackend.createResults = [.failure(.createFailed(ioReturnCode: -9))]

        try await coordinator.setKeepAwakeMode(.display)

        // Settings persisted the requested mode, but the live power
        // assertion's replacement failed: the coordinator must reflect the
        // OLD assertion's mode, still active, rather than the requested
        // (but never actually applied) new mode.
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system)
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == PowerDiagnosticID.assertionFailed })
        XCTAssertEqual(powerBackend.releasedIDs, [], "the old assertion must never be released when the replacement's creation failed")
        XCTAssertEqual(renderer.emittedSnapshots.count, 2)
    }

    // MARK: - Mode change: next scan retries the desired persisted mode

    /// Regression test for the desired/effective mode desync: after
    /// `setKeepAwakeMode` persists a new mode but the live IOKit
    /// replacement fails, the *next* `applyScan` must derive its desired
    /// mode from `settingsStore.current` (the durably persisted value),
    /// not from the stale `snapshot.monitor.keepAwakeMode` the failed
    /// attempt actually published — otherwise every subsequent scan would
    /// keep "retrying" the old mode forever and never recover.
    func testApplyScanRetriesDesiredPersistedModeAfterPriorReplacementFailureAndRecoversOnSuccess() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let powerBackend = CoordinatorFakePowerBackend()
        let (coordinator, _, _) = await makeCoordinator(clock: clock, powerBackend: powerBackend)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now)
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system)

        powerBackend.createResults = [.failure(.createFailed(ioReturnCode: -9))]
        try await coordinator.setKeepAwakeMode(.display)

        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system, "the failed replacement leaves the actual old mode published")
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == PowerDiagnosticID.assertionFailed })

        clock.now += 10
        await coordinator.applyScan([agent], scannedAt: clock.now)

        // The retry succeeds this time (no more scripted failures): the
        // effective mode updates to the persisted `.display`, and the
        // diagnostic clears.
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .display, "the next scan must retry the persisted desired mode, not the stale published one")
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertFalse(coordinator.snapshot.diagnostics.contains { $0.id == PowerDiagnosticID.assertionFailed })
        XCTAssertEqual(powerBackend.createdModes, [.system, .display, .display])
        XCTAssertEqual(powerBackend.releasedIDs, [1], "the old .system assertion is released once the retried .display replacement succeeds")
    }

    /// Same setup as above, but the retry also fails: the coordinator
    /// must keep reporting the old actual mode and the diagnostic must
    /// remain, rather than ever reporting a success-shaped state.
    func testApplyScanRetryStillFailingKeepsOldModeAndDiagnostic() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let powerBackend = CoordinatorFakePowerBackend()
        let (coordinator, _, _) = await makeCoordinator(clock: clock, powerBackend: powerBackend)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now)
        powerBackend.createResults = [
            .failure(.createFailed(ioReturnCode: -9)),
            .failure(.createFailed(ioReturnCode: -10))
        ]
        try await coordinator.setKeepAwakeMode(.display)
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system)

        clock.now += 10
        await coordinator.applyScan([agent], scannedAt: clock.now)

        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system, "a still-failing retry must remain on the old actual mode")
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake, "the old assertion remains active throughout")
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == PowerDiagnosticID.assertionFailed })
        XCTAssertEqual(powerBackend.releasedIDs, [], "the old assertion must never be released while every replacement attempt keeps failing")
    }

    // MARK: - History clear

    func testClearHistorySuccessResetsStatsAndEmitsOnce() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let (coordinator, renderer, _) = await makeCoordinator(clock: clock)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 2_000
        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 100
        await coordinator.applyScan([], scannedAt: clock.now)
        XCTAssertGreaterThan(coordinator.snapshot.history.recentSessions.count, 0)
        let emittedBeforeClear = renderer.emittedSnapshots.count

        try await coordinator.clearHistory()

        XCTAssertEqual(coordinator.snapshot.history.recentSessions.count, 0)
        XCTAssertEqual(coordinator.snapshot.history.totalAwakeMs, 0)
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBeforeClear + 1)
    }

    func testClearHistoryFailureStillReflectsResetSurfacesDiagnosticAndThrows() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let (coordinator, renderer, _) = await makeCoordinator(historyFileSystem: historyFS, clock: clock)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 2_000
        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 100
        await coordinator.applyScan([], scannedAt: clock.now)
        XCTAssertGreaterThan(coordinator.snapshot.history.recentSessions.count, 0)

        await historyFS.setFailNextWrite(SettingsFileSystemError.other("disk full"))

        do {
            try await coordinator.clearHistory()
            XCTFail("expected the persistence failure to propagate")
        } catch StorageError.writeFailed {
            // Expected.
        }

        // The in-memory reset still applied even though persistence
        // failed (matching `HistoryStore.clear()`'s documented contract) —
        // the coordinator must reflect that actual reset state, not a
        // stale pre-clear one.
        XCTAssertEqual(coordinator.snapshot.history.recentSessions.count, 0)
        XCTAssertEqual(coordinator.snapshot.history.totalAwakeMs, 0)
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == HistoryDiagnosticID.persistFailed })
        XCTAssertEqual(renderer.emittedSnapshots.last?.history.recentSessions.count, 0)
    }

    // MARK: - History persist failures hidden inside `record(_:)`

    /// A close-session persist failure during a normal `applyScan` (never
    /// surfaced by `clearHistory()`/`shutdown()`, both of which already
    /// have their own explicit persist-failure handling) must not stay
    /// hidden inside `HistoryStore.lastDiagnostic`: the coordinator reads
    /// it back after every `record(_:)` call and reconciles it into the
    /// published snapshot. Also exercises the two companion invariants:
    /// a later tick that never attempts a persist must not falsely clear
    /// a still-current diagnostic, and a later tick that *does* persist
    /// successfully must clear it.
    func testApplyScanCloseSessionPersistFailureSurfacesDiagnosticAndLaterSuccessClearsIt() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let (coordinator, _, _) = await makeCoordinator(historyFileSystem: historyFS, clock: clock)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 100

        await historyFS.setFailNextWrite(SettingsFileSystemError.other("disk full"))
        await coordinator.applyScan([], scannedAt: clock.now) // closes the session -> immediate persist -> fails

        XCTAssertTrue(
            coordinator.snapshot.diagnostics.contains { $0.id == HistoryDiagnosticID.persistFailed },
            "a close-session persist failure during applyScan must become visible, not stay hidden in HistoryStore.lastDiagnostic"
        )
        XCTAssertFalse(coordinator.snapshot.monitor.active, "the actual monitor state is still published even though the history persist failed")
        XCTAssertNil(coordinator.snapshot.history.currentSession)

        clock.now += 100
        await coordinator.applyScan([agent], scannedAt: clock.now) // reopens a session; no persist is attempted this tick

        XCTAssertTrue(
            coordinator.snapshot.diagnostics.contains { $0.id == HistoryDiagnosticID.persistFailed },
            "a tick that never forces a write must not falsely clear a still-current diagnostic"
        )

        clock.now += 100
        await coordinator.applyScan([], scannedAt: clock.now) // closes again -> immediate persist, this time succeeding

        XCTAssertFalse(
            coordinator.snapshot.diagnostics.contains { $0.id == HistoryDiagnosticID.persistFailed },
            "a later successful persist must clear the diagnostic"
        )
    }

    /// A debounced save's failure happens entirely asynchronously,
    /// outside any coordinator-invoked `record(_:)` call. It must still
    /// become visible — on the very next `applyScan`, which reads
    /// `HistoryStore.lastDiagnostic` fresh regardless of whether *that*
    /// particular tick itself attempted a persist.
    func testDebouncedHistorySaveFailureBecomesVisibleOnTheNextScan() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let scheduler = ManualHistoryScheduler()
        let (coordinator, _, _) = await makeCoordinator(historyFileSystem: historyFS, historyScheduler: scheduler, clock: clock)
        let agent = activeAgent()

        await coordinator.applyScan([agent], scannedAt: clock.now) // opens the session; no delta yet, no save scheduled
        clock.now += 2_000
        await coordinator.applyScan([agent], scannedAt: clock.now) // delta 2000 -> schedules a debounced save
        XCTAssertEqual(scheduler.pendingCount, 1)

        await historyFS.setFailNextWrite(SettingsFileSystemError.other("disk full"))
        await scheduler.fireAllPending() // the debounced save now runs (and fails) outside any coordinator call

        XCTAssertFalse(
            coordinator.snapshot.diagnostics.contains { $0.id == HistoryDiagnosticID.persistFailed },
            "the coordinator has not yet reconciled this: no record(_:) call has run since the debounced save failed"
        )

        clock.now += 100
        await coordinator.applyScan([agent], scannedAt: clock.now) // this tick's record() reconciles the now-stale diagnostic

        XCTAssertTrue(
            coordinator.snapshot.diagnostics.contains { $0.id == HistoryDiagnosticID.persistFailed },
            "an earlier debounced save's failure must become visible on the very next applyScan"
        )
    }

    // MARK: - Updates: startup check, scheduler ownership, checkForUpdates, setIncludePrereleaseUpdates

    func testMakeAtStartupStartsTheUpdateSchedulerAndRunsAnUnforcedCheck() async {
        let updateService = FakeUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        updateService.currentStateValue = UpdateState(checking: false, availableVersion: "v9.9.9", releaseURL: "https://github.com/OpenCoven/seer/releases/tag/v9.9.9", lastCheckedAt: 1_700_000_000_000)
        updateService.checkResults = [.success(updateService.currentStateValue)]

        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService, updateScheduler: updateScheduler)

        XCTAssertEqual(updateService.checkForceValues, [false], "the startup check must be unforced, respecting the 24h gate")
        XCTAssertEqual(updateScheduler.startCallCount, 1, "the scheduler must be started exactly once at startup")
        XCTAssertEqual(coordinator.snapshot.update.availableVersion, "v9.9.9", "the startup check's result must seed the initial snapshot")
        XCTAssertEqual(renderer.emittedSnapshots.count, 0, "seeding the startup update state is not itself a completed transition")
    }

    func testMakeAtStartupSurfacesAFailedStartupCheckAsAVisibleDiagnostic() async {
        let updateService = FakeUpdateChecking()
        updateService.checkResults = [.failure(FakeUpdateCheckError())]
        let updateScheduler = FakeUpdateSchedulerControlling()

        let (coordinator, _, _) = await makeCoordinator(updateService: updateService, updateScheduler: updateScheduler)

        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed })
        XCTAssertNil(coordinator.snapshot.update.availableVersion)
    }

    func testCheckForUpdatesPublishesTheResultingUpdateStateAtomically() async {
        let updateService = FakeUpdateChecking()
        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService)
        let emittedBefore = renderer.emittedSnapshots.count

        updateService.checkResults = [.success(UpdateState(
            checking: false,
            availableVersion: "v2.0.0",
            releaseURL: "https://github.com/OpenCoven/seer/releases/tag/v2.0.0",
            lastCheckedAt: 1_700_000_000_500
        ))]

        await coordinator.checkForUpdates(force: true)

        XCTAssertEqual(updateService.checkForceValues.last, true)
        XCTAssertEqual(coordinator.snapshot.update.availableVersion, "v2.0.0")
        XCTAssertEqual(coordinator.snapshot.update.releaseURL, "https://github.com/OpenCoven/seer/releases/tag/v2.0.0")
        XCTAssertFalse(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed })
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore + 1, "checkForUpdates must publish exactly one transition")
        XCTAssertEqual(renderer.emittedSnapshots.last, coordinator.snapshot)
    }

    func testCheckForUpdatesUpsertsAVisibleDiagnosticOnFailureAndClearsItOnTheNextSuccess() async {
        let updateService = FakeUpdateChecking()
        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService)

        updateService.checkResults = [.failure(FakeUpdateCheckError())]
        await coordinator.checkForUpdates(force: true)

        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed })
        let emittedAfterFailure = renderer.emittedSnapshots.count

        updateService.checkResults = [.success(UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: 1_700_000_001_000))]
        await coordinator.checkForUpdates(force: true)

        XCTAssertFalse(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed })
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedAfterFailure + 1)
    }

    func testSetIncludePrereleaseUpdatesForwardsToUpdateServiceAndPublishesTheResult() async throws {
        let updateService = FakeUpdateChecking()
        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService)
        let emittedBefore = renderer.emittedSnapshots.count

        updateService.setIncludePrereleaseResults = [.success(UpdateState(
            checking: false,
            availableVersion: "v3.0.0-beta.1",
            releaseURL: "https://github.com/OpenCoven/seer/releases/tag/v3.0.0-beta.1",
            lastCheckedAt: 1_700_000_002_000
        ))]

        try await coordinator.setIncludePrereleaseUpdates(true)

        XCTAssertEqual(updateService.setIncludePrereleaseValues, [true])
        XCTAssertEqual(coordinator.snapshot.update.availableVersion, "v3.0.0-beta.1")
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore + 1)
    }

    func testSetIncludePrereleaseUpdatesRethrowsAndPublishesAVisibleDiagnosticOnFailure() async throws {
        let updateService = FakeUpdateChecking()
        let (coordinator, _, _) = await makeCoordinator(updateService: updateService)

        updateService.setIncludePrereleaseResults = [.failure(FakeUpdateCheckError())]

        do {
            try await coordinator.setIncludePrereleaseUpdates(true)
            XCTFail("expected the forced check's failure to be rethrown")
        } catch is FakeUpdateCheckError {
            // Expected.
        }

        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed })
    }

    func testOpenLatestReleaseForwardsToUpdateServiceWithoutTouchingTheSnapshot() async {
        let updateService = FakeUpdateChecking()
        updateService.openCurrentReleaseResult = true
        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService)
        let snapshotBefore = coordinator.snapshot
        let emittedBefore = renderer.emittedSnapshots.count

        let opened = await coordinator.openLatestRelease()

        XCTAssertTrue(opened)
        XCTAssertEqual(updateService.openCurrentReleaseCallCount, 1)
        XCTAssertEqual(coordinator.snapshot, snapshotBefore, "opening a release must never itself mutate the snapshot")
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore, "opening a release must never publish a transition")
    }

    func testShutdownStopsTheUpdateScheduler() async throws {
        let updateScheduler = FakeUpdateSchedulerControlling()
        let (coordinator, _, _) = await makeCoordinator(updateScheduler: updateScheduler)

        try await coordinator.shutdown()

        XCTAssertEqual(updateScheduler.stopCallCount, 1)
    }

    // MARK: - Updates: scheduled (periodic) checks route through the coordinator

    /// Builds a coordinator via `makeAtStartupWithScheduledUpdates(...)` —
    /// wiring a *real* `UpdateScheduler` (driven by the returned
    /// `GatedSleeper`, never real wall-clock time) to route every
    /// scheduled, non-forced check through this very coordinator's own
    /// `checkForUpdates(force: false)`, exactly as production wiring
    /// should. `updateService.checkResults`'s first scripted result (if
    /// any) is consumed by the startup check `makeAtStartup` itself always
    /// performs; any later scripted results are consumed by the
    /// scheduler's own periodic ticks once the test releases `sleeper`.
    private func makeCoordinatorWithScheduledUpdates(
        settingsFileSystem: InMemorySettingsFileSystem = InMemorySettingsFileSystem(),
        historyFileSystem: InMemorySettingsFileSystem = InMemorySettingsFileSystem(),
        historyScheduler: HistoryScheduler = ManualHistoryScheduler(),
        clock: MutableClock = MutableClock(now: 1_700_000_000_000),
        powerBackend: CoordinatorFakePowerBackend = CoordinatorFakePowerBackend(),
        appVersion: String = "1.0.0-test",
        updateService: FakeUpdateChecking = FakeUpdateChecking()
    ) async -> (AppSnapshotCoordinator, FakeRendererSink, GatedSleeper) {
        let settingsAtomicStore = AtomicJSONStore<SettingsDocument>(
            fileURL: settingsURL,
            fileSystem: settingsFileSystem,
            clock: clock
        )
        let settingsStore = SettingsStore(store: settingsAtomicStore)

        let historyAtomicStore = AtomicJSONStore<HistoryDocument>(
            fileURL: historyURL,
            fileSystem: historyFileSystem,
            clock: clock
        )
        let historyStore = HistoryStore(
            store: historyAtomicStore,
            clock: clock,
            scheduler: historyScheduler,
            idGenerator: SequentialHistorySessionIDGenerator()
        )

        let power = PowerAssertionService(backend: powerBackend)
        let renderer = FakeRendererSink()
        let sleeper = GatedSleeper()

        let coordinator = await AppSnapshotCoordinator.makeAtStartupWithScheduledUpdates(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: renderer,
            clock: clock,
            appVersion: appVersion,
            updateService: updateService,
            sleeper: sleeper
        )

        return (coordinator, renderer, sleeper)
    }

    /// Polls `condition` (with a short yield between attempts) until it is
    /// true or a generous bound is hit — used to await the real
    /// `UpdateScheduler`'s background loop deterministically without any
    /// fixed sleep. Mirrors `UpdateServiceTests.waitUntil`.
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

    func testScheduledCheckSuccessPublishesUpdateStateExactlyOnceThroughTheCoordinator() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let updateService = FakeUpdateChecking()
        updateService.checkResults = [
            // The startup check: nothing available yet.
            .success(UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: clock.now)),
            // The scheduled check, 24 hours later: a new release appears.
            .success(UpdateState(
                checking: false,
                availableVersion: "v5.0.0",
                releaseURL: "https://github.com/OpenCoven/seer-releases/releases/tag/v5.0.0",
                lastCheckedAt: clock.now + UpdateService.checkIntervalMs
            )),
        ]

        let (coordinator, renderer, sleeper) = await makeCoordinatorWithScheduledUpdates(clock: clock, updateService: updateService)
        let monitorBeforeScheduledCheck = coordinator.snapshot.monitor
        let emittedBeforeScheduledCheck = renderer.emittedSnapshots.count

        try await waitUntil { await sleeper.requestedCount >= 1 }
        XCTAssertEqual(updateService.checkForceValues, [false], "only the startup check must have run before the scheduler's sleep elapses")

        clock.now += UpdateService.checkIntervalMs
        await sleeper.release()

        try await waitUntil { updateService.checkForceValues.count >= 2 }
        try await waitUntil { coordinator.snapshot.update.availableVersion == "v5.0.0" }

        XCTAssertEqual(updateService.checkForceValues, [false, false], "the scheduled check must be unforced, like the startup check")
        XCTAssertEqual(coordinator.snapshot.update.releaseURL, "https://github.com/OpenCoven/seer-releases/releases/tag/v5.0.0")
        XCTAssertFalse(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed })
        XCTAssertEqual(
            renderer.emittedSnapshots.count,
            emittedBeforeScheduledCheck + 1,
            "a scheduled check must publish exactly one transition, like an explicit checkForUpdates(force:) call"
        )
        XCTAssertEqual(renderer.emittedSnapshots.last, coordinator.snapshot)
        XCTAssertEqual(coordinator.snapshot.monitor, monitorBeforeScheduledCheck, "a scheduled update check must never itself alter monitoring state")
    }

    func testScheduledCheckFailureSurfacesTheDiagnosticWhileRetainingMonitoringState() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let updateService = FakeUpdateChecking()
        updateService.checkResults = [
            // The startup check succeeds so the diagnostic below can only
            // have come from the *scheduled* check, not a stale startup one.
            .success(UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: clock.now)),
            .failure(FakeUpdateCheckError("scheduled check network failure")),
        ]

        let (coordinator, renderer, sleeper) = await makeCoordinatorWithScheduledUpdates(clock: clock, updateService: updateService)
        XCTAssertFalse(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed })
        let monitorBeforeScheduledCheck = coordinator.snapshot.monitor
        let historyBeforeScheduledCheck = coordinator.snapshot.history
        let emittedBeforeScheduledCheck = renderer.emittedSnapshots.count

        try await waitUntil { await sleeper.requestedCount >= 1 }

        clock.now += UpdateService.checkIntervalMs
        await sleeper.release()

        try await waitUntil { coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed } }

        XCTAssertEqual(updateService.checkForceValues, [false, false])
        XCTAssertEqual(
            renderer.emittedSnapshots.count,
            emittedBeforeScheduledCheck + 1,
            "a failed scheduled check must still publish exactly one transition"
        )
        XCTAssertEqual(
            coordinator.snapshot.monitor,
            monitorBeforeScheduledCheck,
            "a failed scheduled update check must never disturb monitoring state"
        )
        XCTAssertEqual(
            coordinator.snapshot.history,
            historyBeforeScheduledCheck,
            "a failed scheduled update check must never disturb history state"
        )
        XCTAssertNil(coordinator.snapshot.update.availableVersion, "a failed check must leave the update state falling back to the service's own cached value")
    }

    func testShutdownCancelsARealCoordinatorWiredSchedulerSoNoFurtherScheduledCheckEverRuns() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let updateService = FakeUpdateChecking()
        updateService.checkResults = [.success(UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: clock.now))]

        let (coordinator, _, sleeper) = await makeCoordinatorWithScheduledUpdates(clock: clock, updateService: updateService)
        try await waitUntil { await sleeper.requestedCount >= 1 }

        try await coordinator.shutdown()

        // Releasing after shutdown must not cause any further scheduled
        // check to run — the cancelled scheduler's loop must have already
        // exited rather than merely being "about to" exit.
        clock.now += UpdateService.checkIntervalMs
        await sleeper.release()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(updateService.checkForceValues, [false], "only the startup check must ever have run")
    }

    // MARK: - Shutdown

    func testShutdownAwaitsHistoryFlushAndReleasesPowerBeforeReturning() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let powerBackend = CoordinatorFakePowerBackend()
        let (coordinator, renderer, _) = await makeCoordinator(clock: clock, powerBackend: powerBackend)

        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)

        try await coordinator.shutdown()

        XCTAssertEqual(powerBackend.releasedIDs, [1])
        XCTAssertFalse(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertNil(coordinator.snapshot.history.currentSession, "flush must close any still-open session")
        XCTAssertEqual(renderer.emittedSnapshots.last, coordinator.snapshot)
    }

    func testShutdownSurfacesHistoryFlushFailureAndStillReleasesPower() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let powerBackend = CoordinatorFakePowerBackend()
        let (coordinator, renderer, _) = await makeCoordinator(
            historyFileSystem: historyFS,
            clock: clock,
            powerBackend: powerBackend
        )

        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        await historyFS.setFailNextWrite(SettingsFileSystemError.other("disk full"))

        do {
            try await coordinator.shutdown()
            XCTFail("expected shutdown to surface the history flush failure")
        } catch StorageError.writeFailed {
            // Expected.
        }

        XCTAssertEqual(powerBackend.releasedIDs, [1], "power must still be released even though history flush failed")
        XCTAssertFalse(coordinator.snapshot.monitor.keepingAwake)
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == HistoryDiagnosticID.persistFailed })
        XCTAssertEqual(renderer.emittedSnapshots.count, 2)
    }

    func testShutdownIsIdempotent() async throws {
        let (coordinator, _, powerBackend) = await makeCoordinator()

        try await coordinator.shutdown()
        try await coordinator.shutdown()

        XCTAssertEqual(powerBackend.releasedIDs, [])
    }

    func testShutdownWithActiveAssertionIsIdempotentAfterFirstRelease() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let powerBackend = CoordinatorFakePowerBackend()
        let (coordinator, _, _) = await makeCoordinator(clock: clock, powerBackend: powerBackend)

        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        try await coordinator.shutdown()
        try await coordinator.shutdown()

        XCTAssertEqual(powerBackend.releasedIDs, [1], "the second shutdown must not attempt to release again")
    }

    // MARK: - Concurrency: serialized transitions, no stale overwrite

    func testConcurrentScanAndModeChangeSerializeWithoutStaleOverwrite() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let (coordinator, renderer, _) = await makeCoordinator(historyFileSystem: historyFS, clock: clock)
        let agent = activeAgent()

        // Build up an active session so the closing scan below actually
        // persists (via `flush`'s sibling, the immediate `persistLocked`
        // a session-close triggers) — giving us a real disk write to
        // suspend and create a genuine, controlled concurrency window.
        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 2_000
        await coordinator.applyScan([agent], scannedAt: clock.now)
        clock.now += 100
        let emittedBeforeConcurrency = renderer.emittedSnapshots.count

        await historyFS.armSuspension("writeFileAndSynchronize")

        let scanTask = Task {
            await coordinator.applyScan([], scannedAt: clock.now)
        }
        await historyFS.waitUntilEntered("writeFileAndSynchronize")

        // The closing scan is now suspended mid-write, holding the
        // coordinator's gate. Start a concurrent mode change — it must
        // queue behind the scan rather than interleave with it.
        let modeChangeTask = Task {
            try await coordinator.setKeepAwakeMode(.display)
        }

        for _ in 0..<50 {
            await Task.yield()
        }
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeConcurrency,
            "the queued mode change must not publish while the scan still holds the gate"
        )

        await historyFS.resumeSuspension("writeFileAndSynchronize")
        await scanTask.value
        try await modeChangeTask.value

        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBeforeConcurrency + 2)
        let scanEmission = renderer.emittedSnapshots[emittedBeforeConcurrency]
        let modeChangeEmission = renderer.emittedSnapshots[emittedBeforeConcurrency + 1]
        // The scan's transition (closing the session, deactivating power)
        // must be published first...
        XCTAssertFalse(scanEmission.monitor.active)
        XCTAssertNil(scanEmission.history.currentSession)
        // ...and the mode change, which ran strictly after, must build on
        // top of it rather than overwriting it with stale pre-scan values.
        XCTAssertFalse(modeChangeEmission.monitor.active)
        XCTAssertEqual(modeChangeEmission.monitor.keepAwakeMode, .display)
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .display)
        XCTAssertFalse(coordinator.snapshot.monitor.active)
    }
}
