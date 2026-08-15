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
    /// the approved/reserved values, including Task 12's distinct
    /// committed-but-durability-uncertain settings diagnostic.
    func testStableDiagnosticIDsMatchThePlanExactly() {
        XCTAssertEqual(AgentMonitorDiagnosticID.scanFailed, "monitor.scan.failed")
        XCTAssertEqual(PowerDiagnosticID.assertionFailed, "power.assertion.failed")
        XCTAssertEqual(StorageDiagnosticID.corrupt, "storage.settings.corrupt")
        XCTAssertEqual(StorageDiagnosticID.unsupportedVersion, "storage.settings.unsupported-version")
        XCTAssertEqual(StorageDiagnosticID.readFailed, "storage.settings.read-failed")
        XCTAssertEqual(StorageDiagnosticID.durabilityUncertain, "storage.settings.durability-uncertain")
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

        let outcome = try await coordinator.setIncludePrereleaseUpdates(true)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(updateService.setIncludePrereleaseValues, [true])
        XCTAssertEqual(coordinator.snapshot.update.availableVersion, "v3.0.0-beta.1")
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore + 1)
    }

    /// Task 12's finding: a failure from the forced re-check alone — with
    /// persistence of the toggle having already committed — must never
    /// be rethrown to the caller. It is instead surfaced only via the
    /// returned `.persistedButCheckFailed` outcome and a visible
    /// `CoordinatorDiagnosticID.updatesCheckFailed` diagnostic, exactly
    /// like an ordinary `checkForUpdates(force:)` failure — so a caller
    /// (`AppDelegate`) can still apply its tray checkbox to the
    /// already-durably-persisted value even though the network happened
    /// to be unreachable at that exact moment (e.g. toggling the setting
    /// while offline).
    func testSetIncludePrereleaseUpdatesReturnsCheckFailedWithoutThrowingWhenOnlyTheForcedCheckFails() async throws {
        let updateService = FakeUpdateChecking()
        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService)
        let emittedBefore = renderer.emittedSnapshots.count

        updateService.setIncludePrereleaseResults = [.failure(FakeUpdateCheckError())]

        let outcome = try await coordinator.setIncludePrereleaseUpdates(true)

        guard case .persistedButCheckFailed = outcome else {
            XCTFail("expected .persistedButCheckFailed, got \(outcome)")
            return
        }
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed })
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore + 1, "a check-only failure must still publish exactly one transition")
    }

    /// The other half of Task 12's finding: a failure from the
    /// *persistence* step itself — `UpdateService.setIncludePrerelease
    /// (_:)`'s own `SetIncludePrereleasePersistError` — must always be
    /// rethrown, before any snapshot mutation/publish, so the caller
    /// knows the toggle never actually committed and must leave its UI
    /// showing the old, still-authoritative value.
    func testSetIncludePrereleaseUpdatesRethrowsAndNeverPublishesOnAPersistenceFailure() async throws {
        let updateService = FakeUpdateChecking()
        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService)
        let emittedBefore = renderer.emittedSnapshots.count

        let persistError = SetIncludePrereleasePersistError(underlying: .writeFailed)
        updateService.setIncludePrereleaseResults = [.failure(persistError)]

        do {
            _ = try await coordinator.setIncludePrereleaseUpdates(true)
            XCTFail("expected the persistence failure to be rethrown")
        } catch let error as SetIncludePrereleasePersistError {
            XCTAssertEqual(error, persistError)
        }

        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore, "a persistence failure must never publish any transition")
        XCTAssertFalse(
            coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed },
            "a persistence failure is not a check failure and must never surface that diagnostic"
        )
    }

    func testSetIncludePrereleaseUpdatesPublishesCommittedValueAndDurabilityDiagnosticWhenDirectorySyncFails() async throws {
        let settingsFileSystem = InMemorySettingsFileSystem()
        let historyFileSystem = InMemorySettingsFileSystem()
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = SettingsStore(store: AtomicJSONStore<SettingsDocument>(
            fileURL: settingsURL,
            fileSystem: settingsFileSystem,
            clock: clock
        ))
        let historyStore = HistoryStore(
            store: AtomicJSONStore<HistoryDocument>(
                fileURL: historyURL,
                fileSystem: historyFileSystem,
                clock: clock
            ),
            clock: clock,
            scheduler: ManualHistoryScheduler(),
            idGenerator: SequentialHistorySessionIDGenerator()
        )
        let updateService = UpdateService(
            settingsStore: settingsStore,
            session: UpdateService.makeDefaultSession(),
            clock: clock,
            currentVersion: "1.0.0"
        )
        let startupSnapshot = await AppSnapshotCoordinator.loadStartupSnapshot(
            settingsStore: settingsStore,
            historyStore: historyStore,
            updateService: updateService,
            appVersion: "1.0.0-test"
        )
        let renderer = FakeRendererSink()
        let coordinator = AppSnapshotCoordinator.makeWithScheduledUpdates(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: PowerAssertionService(backend: CoordinatorFakePowerBackend()),
            renderer: renderer,
            clock: clock,
            updateService: updateService,
            startupSnapshot: startupSnapshot
        )
        await settingsFileSystem.setFailNextDirectorySync(SettingsFileSystemError.other("directory fsync failed"))

        let outcome = try await coordinator.setIncludePrereleaseUpdates(true)

        guard case .persistedButDurabilityUncertain = outcome else {
            return XCTFail("expected committed durability-uncertain outcome, got \(outcome)")
        }
        let authoritativeValue = await coordinator.includePrereleaseUpdates
        XCTAssertTrue(authoritativeValue)
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == StorageDiagnosticID.durabilityUncertain })
        XCTAssertEqual(renderer.emittedSnapshots.last, coordinator.snapshot)
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
    /// should — then immediately calls `performStartupUpdateCheckAndStartScheduler()`
    /// itself, mirroring `AppDelegate.bootstrapProduction()`'s required
    /// ordering (construct without starting updates, *then* run the
    /// startup check and start the scheduler) rather than relying on
    /// construction to do it inline. `updateService.checkResults`'s first
    /// scripted result (if any) is consumed by that startup check; any
    /// later scripted results are consumed by the scheduler's own periodic
    /// ticks once the test releases `sleeper`.
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
        await coordinator.performStartupUpdateCheckAndStartScheduler()

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

    /// Reproduces the exact race `isShutDown` exists to close: a
    /// scheduled check (in production, `UpdateScheduler`'s own tick
    /// calling `checkForUpdates(force: false)`) is already queued behind
    /// `gate` — held here by a suspended empty scan, so no real
    /// `UpdateScheduler`/`Sleeper` is needed to force the ordering
    /// deterministically — when `shutdown()` is requested. `shutdown()`
    /// queues *behind* that already-queued check (strict gate FIFO), yet
    /// must still flag `isShutDown` (and stop the scheduler)
    /// *immediately*, before ever waiting its own turn, so that once the
    /// scan finally releases the gate — handing it straight to the
    /// queued check, ahead of shutdown, exactly as `AsyncGate` documents
    /// — that check observes shutdown already underway and skips its
    /// network request and publish entirely, rather than running to
    /// completion and publishing a scheduled check's result after
    /// shutdown was requested.
    func testShutdownFlagsAnAlreadyQueuedScheduledCheckSoItNeverNetworkChecksOrPublishesAfterward() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let updateService = FakeUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        let (coordinator, renderer, _) = await makeCoordinator(
            historyFileSystem: historyFS,
            clock: clock,
            updateService: updateService,
            updateScheduler: updateScheduler
        )

        // Build up an open history session so the empty scan below
        // actually performs a real disk write worth suspending — giving
        // a genuine, controlled window in which the coordinator's gate
        // is held by something other than the scheduled check or
        // shutdown itself.
        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        clock.now += 2_000
        let checkForceValuesBeforeRace = updateService.checkForceValues.count
        let emittedBeforeRace = renderer.emittedSnapshots.count

        await historyFS.armSuspension("writeFileAndSynchronize")

        // The closing scan holds the gate, suspended mid-write.
        let scanTask = Task {
            await coordinator.applyScan([], scannedAt: clock.now)
        }
        await historyFS.waitUntilEntered("writeFileAndSynchronize")

        // The scheduler's tick fires — exactly like a real
        // `UpdateScheduler` calling `checkForUpdates(force:)` — while
        // the gate is held elsewhere, and queues behind the scan.
        let tickTask = Task {
            await coordinator.checkForUpdates(force: false)
        }
        for _ in 0..<50 { await Task.yield() }

        // Shutdown is requested next. Its own `gate.acquire()` call
        // necessarily queues *behind* the already-queued tick — yet it
        // must still flag `isShutDown` and stop the scheduler
        // synchronously, without waiting for the gate.
        let shutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(
            updateScheduler.stopCallCount, 1,
            "shutdown must stop the scheduler immediately, without waiting for its own turn at the gate"
        )

        await historyFS.resumeSuspension("writeFileAndSynchronize")
        await scanTask.value
        let tickSucceeded = await tickTask.value
        try await shutdownTask.value

        XCTAssertFalse(
            tickSucceeded,
            "a scheduled check only granted the gate after shutdown began must report failure rather than actually running"
        )
        XCTAssertEqual(
            updateService.checkForceValues.count, checkForceValuesBeforeRace,
            "the already-queued scheduled check must never call through to the update service once shutdown has begun"
        )
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace + 2,
            "only the scan's own transition and shutdown's final transition may publish — the skipped scheduled check must publish nothing"
        )
        XCTAssertFalse(
            coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed },
            "a check skipped for shutdown, not one that actually failed, must never surface a check-failed diagnostic"
        )
    }

    /// Closes the *other* half of the `isShutDown` race the previous test
    /// covers. That test proves a check only ever *queued* behind `gate`
    /// before shutdown begins is skipped outright (never even calling
    /// through to the update service). This test instead proves the check
    /// that has *already* passed that pre-await guard and called through
    /// to the update service — whose network round-trip is still
    /// genuinely in flight, not merely queued — must also never publish
    /// once shutdown completes while it was still suspended.
    /// `performCheckForUpdates` only ever re-examines `isShutDown` once,
    /// *before* calling `updateService.check(force:)`; without a second
    /// check immediately after that `await` returns, this in-flight call
    /// would resume — after `shutdown()` has already flagged `isShutDown`,
    /// stopped the scheduler, flushed history, released power, and
    /// published its own final snapshot — and go on to publish its own
    /// (successful) update result on top of that already-final state.
    func testInFlightUpdateCheckDoesNotPublishAfterShutdownCompletesWhileItWasStillSuspended() async throws {
        let updateService = SuspendableUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        let (coordinator, renderer, _) = await makeCoordinator(
            updateService: updateService,
            updateScheduler: updateScheduler
        )
        let emittedBeforeRace = renderer.emittedSnapshots.count

        // A scheduled (or explicit) check starts, passes the pre-await
        // `!isShutDown` guard, and calls through to the update service —
        // whose response genuinely never arrives until the test resolves
        // it below. This holds the coordinator's `gate` open the entire
        // time.
        let checkTask = Task {
            await coordinator.checkForUpdates(force: false)
        }
        await updateService.waitForCall()

        // Shutdown is requested next. Its own `gate.acquire()` call
        // necessarily queues behind the still-in-flight check above, so
        // it must run concurrently (not be awaited directly here) — but
        // it still flags `isShutDown` and stops the scheduler
        // synchronously, without waiting for its own turn at the gate.
        let shutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(
            updateScheduler.stopCallCount, 1,
            "shutdown must stop the scheduler immediately, without waiting for the still-in-flight check to release the gate"
        )
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace,
            "shutdown's own final transition must not publish yet — it is still queued behind the in-flight check"
        )

        // Only now does the long-suspended update check resolve — with a
        // *successful* result that, without a post-await recheck of
        // `isShutDown`, would be published once this call resumes.
        await updateService.resolve(with: UpdateState(
            checking: false,
            availableVersion: "v9.9.9",
            releaseURL: "https://github.com/OpenCoven/seer/releases/tag/v9.9.9",
            lastCheckedAt: 1_700_000_000_000
        ))
        let succeeded = await checkTask.value
        try await shutdownTask.value

        XCTAssertFalse(succeeded, "a check that resolves after shutdown began must report failure, not success")
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace + 1,
            "only shutdown's own final transition may publish — the check that resolved after shutdown began must publish nothing of its own"
        )
        XCTAssertNil(
            coordinator.snapshot.update.availableVersion,
            "the update state resolved after shutdown began must never reach the coordinator's published snapshot"
        )
        XCTAssertFalse(
            coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed },
            "a check skipped for shutdown must never surface a check-failed diagnostic either"
        )
    }

    /// The rejection-shaped mirror of the test above: an in-flight check
    /// that *throws* after shutdown has already completed must be just as
    /// silent as one that succeeds — no diagnostic upsert, no publish.
    func testInFlightUpdateCheckFailureDoesNotPublishAfterShutdownCompletesWhileItWasStillSuspended() async throws {
        let updateService = SuspendableUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        let (coordinator, renderer, _) = await makeCoordinator(
            updateService: updateService,
            updateScheduler: updateScheduler
        )
        let emittedBeforeRace = renderer.emittedSnapshots.count

        let checkTask = Task {
            await coordinator.checkForUpdates(force: false)
        }
        await updateService.waitForCall()

        let shutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(updateScheduler.stopCallCount, 1)

        await updateService.reject(with: FakeUpdateCheckError())
        let succeeded = await checkTask.value
        try await shutdownTask.value

        XCTAssertFalse(succeeded)
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace + 1,
            "only shutdown's own final transition may publish — the check that rejected after shutdown began must publish nothing further"
        )
        XCTAssertFalse(
            coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed },
            "a post-shutdown failure must never surface a check-failed diagnostic — shutdown's own final state is already published"
        )
    }

    /// Confirms the fix above doesn't regress the ordinary case: a check
    /// resolving *before* shutdown ever begins must still publish and
    /// report success exactly as before.
    func testInFlightUpdateCheckStillPublishesWhenItResolvesBeforeShutdownBegins() async throws {
        let updateService = SuspendableUpdateChecking()
        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService)
        let emittedBefore = renderer.emittedSnapshots.count

        let checkTask = Task {
            await coordinator.checkForUpdates(force: false)
        }
        await updateService.waitForCall()

        await updateService.resolve(with: UpdateState(
            checking: false,
            availableVersion: "v9.9.9",
            releaseURL: "https://github.com/OpenCoven/seer/releases/tag/v9.9.9",
            lastCheckedAt: 1_700_000_000_000
        ))
        let succeeded = await checkTask.value

        XCTAssertTrue(succeeded)
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore + 1)
        XCTAssertEqual(coordinator.snapshot.update.availableVersion, "v9.9.9")

        try await coordinator.shutdown()
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore + 2, "shutdown must still publish its own final transition afterward")
    }

    /// Confirms `shutdown()` remains idempotent even when the *first*
    /// call has to outlast an in-flight update check the way the tests
    /// above exercise: a second `shutdown()` call, made after the first
    /// has already completed, must not re-stop the scheduler or publish
    /// again.
    func testShutdownRemainsIdempotentAfterOutlastingAnInFlightUpdateCheck() async throws {
        let updateService = SuspendableUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        let (coordinator, renderer, _) = await makeCoordinator(
            updateService: updateService,
            updateScheduler: updateScheduler
        )
        let emittedBefore = renderer.emittedSnapshots.count

        let checkTask = Task {
            await coordinator.checkForUpdates(force: false)
        }
        await updateService.waitForCall()

        let firstShutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(updateScheduler.stopCallCount, 1)

        let secondShutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(updateScheduler.stopCallCount, 1, "a second shutdown must not stop the scheduler again")
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBefore,
            "neither shutdown call may publish yet — both are still queued behind the in-flight check"
        )

        await updateService.resolve(with: UpdateState(
            checking: false,
            availableVersion: "v9.9.9",
            releaseURL: "https://github.com/OpenCoven/seer/releases/tag/v9.9.9",
            lastCheckedAt: 1_700_000_000_000
        ))
        let succeeded = await checkTask.value
        try await firstShutdownTask.value
        try await secondShutdownTask.value

        XCTAssertFalse(succeeded, "the still-in-flight check resolving after shutdown began must report failure")
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBefore + 2,
            "each of the two shutdown calls still publishes its own final transition, exactly as before this fix — only the skipped check contributes nothing"
        )
    }

    /// Reproduces the Task 12 race `performStartupUpdateCheckAndStartScheduler()`
    /// must fence: the app shell calls it right after its own initial
    /// scan/recurring loop have started (mirroring `AppDelegate
    /// .bootstrapProduction()`), but shutdown begins — and fully
    /// completes, stopping the scheduler — while that method's own
    /// startup `checkForUpdates(force: false)` call is still genuinely
    /// suspended inside the update service. Without rechecking
    /// `isShutDown` immediately after that call returns and before ever
    /// calling `updateScheduler.start()`, this method would resume and
    /// unconditionally restart the scheduler shutdown had just stopped —
    /// resurrecting periodic background checks after an orderly shutdown
    /// already ran to completion.
    func testPerformStartupUpdateCheckAndStartSchedulerNeverRestartsTheSchedulerAfterShutdownStoppedItWhileTheStartupCheckWasStillInFlight() async throws {
        let updateService = SuspendableUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        let (coordinator, _, _) = await makeCoordinator(
            updateService: updateService,
            updateScheduler: updateScheduler
        )
        // `makeAtStartup(...)` (via `makeCoordinator`) already starts the
        // scheduler once, and its own construction-time check already
        // consumed `SuspendableUpdateChecking`'s one auto-resolving call —
        // establishing the baseline this test's own startup call/scheduler
        // start must not exceed.
        let startCallCountBeforeStartupPhase = updateScheduler.startCallCount
        XCTAssertEqual(startCallCountBeforeStartupPhase, 1)

        // Mirrors `AppDelegate.bootstrapProduction()`'s own step (6): the
        // startup update check/scheduler start, called once the initial
        // scan and recurring monitor loop have already begun. Its
        // `checkForUpdates(force: false)` call passes the pre-await
        // `!isShutDown` guard and calls through to the update service,
        // whose response genuinely never arrives until this test resolves
        // it below.
        let startupTask = Task {
            await coordinator.performStartupUpdateCheckAndStartScheduler()
        }
        await updateService.waitForCall()

        // Shutdown is requested next — and, being able to complete
        // without waiting for its own turn at `gate` for the parts that
        // matter here, stops the scheduler and finishes entirely while
        // the startup check above is still suspended.
        let shutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(
            updateScheduler.stopCallCount, 1,
            "shutdown must stop the scheduler immediately, without waiting for the still-in-flight startup check to release the gate"
        )

        // Only now does the long-suspended startup check resolve.
        await updateService.resolve(with: UpdateState(
            checking: false,
            availableVersion: nil,
            releaseURL: nil,
            lastCheckedAt: 1_700_000_000_000
        ))
        await startupTask.value
        try await shutdownTask.value

        XCTAssertEqual(
            updateScheduler.startCallCount, startCallCountBeforeStartupPhase,
            "the startup phase must never (re)start the scheduler once shutdown has already stopped it, even after its own in-flight check resolves"
        )
    }

    /// The `setIncludePrereleaseUpdates` counterpart of
    /// `testShutdownFlagsAnAlreadyQueuedScheduledCheckSoItNeverNetworkChecksOrPublishesAfterward`:
    /// a tray checkbox toggle already queued behind `gate` when
    /// `shutdown()` begins must be skipped entirely — never calling
    /// through to `updateService.setIncludePrerelease(_:)`, never
    /// mutating the persisted toggle, and never publishing — exactly
    /// like an already-queued scheduled check.
    func testShutdownFlagsAnAlreadyQueuedSetIncludePrereleaseUpdatesCallSoItNeverMutatesOrPublishesAfterward() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let updateService = FakeUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        let (coordinator, renderer, _) = await makeCoordinator(
            historyFileSystem: historyFS,
            clock: clock,
            updateService: updateService,
            updateScheduler: updateScheduler
        )

        // Build up an open history session so the empty scan below
        // actually performs a real disk write worth suspending — giving
        // a genuine, controlled window in which the coordinator's gate
        // is held by something other than the toggle or shutdown itself.
        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        clock.now += 2_000
        let setIncludePrereleaseValuesBeforeRace = updateService.setIncludePrereleaseValues.count
        let emittedBeforeRace = renderer.emittedSnapshots.count

        await historyFS.armSuspension("writeFileAndSynchronize")

        // The closing scan holds the gate, suspended mid-write.
        let scanTask = Task {
            await coordinator.applyScan([], scannedAt: clock.now)
        }
        await historyFS.waitUntilEntered("writeFileAndSynchronize")

        // The tray checkbox toggle fires while the gate is held
        // elsewhere, and queues behind the scan.
        let toggleTask = Task<Error?, Never> {
            do {
                try await coordinator.setIncludePrereleaseUpdates(true)
                return nil
            } catch {
                return error
            }
        }
        for _ in 0..<50 { await Task.yield() }

        // Shutdown is requested next. Its own `gate.acquire()` call
        // necessarily queues *behind* the already-queued toggle — yet it
        // must still flag `isShutDown` and stop the scheduler
        // synchronously, without waiting for the gate.
        let shutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(
            updateScheduler.stopCallCount, 1,
            "shutdown must stop the scheduler immediately, without waiting for its own turn at the gate"
        )

        await historyFS.resumeSuspension("writeFileAndSynchronize")
        await scanTask.value
        let toggleError = await toggleTask.value
        try await shutdownTask.value

        XCTAssertNil(
            toggleError,
            "a tray checkbox action only granted the gate after shutdown began must silently do nothing, not throw"
        )
        XCTAssertEqual(
            updateService.setIncludePrereleaseValues.count, setIncludePrereleaseValuesBeforeRace,
            "the already-queued tray checkbox action must never call through to the update service once shutdown has begun"
        )
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace + 2,
            "only the scan's own transition and shutdown's final transition may publish — the skipped toggle must publish nothing"
        )
        XCTAssertFalse(
            coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed },
            "a toggle skipped for shutdown, not one that actually failed, must never surface a check-failed diagnostic"
        )
    }

    /// The `setIncludePrereleaseUpdates` counterpart of
    /// `testInFlightUpdateCheckDoesNotPublishAfterShutdownCompletesWhileItWasStillSuspended`:
    /// a tray checkbox toggle that has already passed the pre-await
    /// `!isShutDown` guard and called through to
    /// `updateService.setIncludePrerelease(_:)` — whose round-trip is
    /// still genuinely in flight, not merely queued — must also never
    /// mutate/publish once shutdown completes while it was still
    /// suspended.
    func testInFlightSetIncludePrereleaseUpdatesDoesNotMutateOrPublishAfterShutdownCompletesWhileItWasStillSuspended() async throws {
        let updateService = SuspendableUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        let (coordinator, renderer, _) = await makeCoordinator(
            updateService: updateService,
            updateScheduler: updateScheduler
        )
        let emittedBeforeRace = renderer.emittedSnapshots.count

        // A tray checkbox toggle starts, passes the pre-await
        // `!isShutDown` guard, and calls through to the update service —
        // whose response genuinely never arrives until the test resolves
        // it below. This holds the coordinator's `gate` open the entire
        // time.
        let toggleTask = Task<Error?, Never> {
            do {
                try await coordinator.setIncludePrereleaseUpdates(true)
                return nil
            } catch {
                return error
            }
        }
        await updateService.waitForSetIncludePrereleaseCall()

        // Shutdown is requested next. Its own `gate.acquire()` call
        // necessarily queues behind the still-in-flight toggle above, so
        // it must run concurrently (not be awaited directly here) — but
        // it still flags `isShutDown` and stops the scheduler
        // synchronously, without waiting for its own turn at the gate.
        let shutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(
            updateScheduler.stopCallCount, 1,
            "shutdown must stop the scheduler immediately, without waiting for the still-in-flight toggle to release the gate"
        )
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace,
            "shutdown's own final transition must not publish yet — it is still queued behind the in-flight toggle"
        )

        // Only now does the long-suspended toggle resolve — with a
        // *successful* result that, without a post-await recheck of
        // `isShutDown`, would be published once this call resumes.
        await updateService.resolveSetIncludePrerelease(with: UpdateState(
            checking: false,
            availableVersion: "v9.9.9",
            releaseURL: "https://github.com/OpenCoven/seer/releases/tag/v9.9.9",
            lastCheckedAt: 1_700_000_000_000
        ))
        let toggleError = await toggleTask.value
        try await shutdownTask.value

        XCTAssertNil(toggleError, "a toggle that resolves after shutdown began must silently do nothing, not throw")
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace + 1,
            "only shutdown's own final transition may publish — the toggle that resolved after shutdown began must publish nothing of its own"
        )
        XCTAssertNil(
            coordinator.snapshot.update.availableVersion,
            "the update state resolved after shutdown began must never reach the coordinator's published snapshot"
        )
        XCTAssertFalse(
            coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.updatesCheckFailed },
            "a toggle skipped for shutdown must never surface a check-failed diagnostic either"
        )
    }

    /// Confirms the fix above doesn't regress the ordinary case: a tray
    /// checkbox toggle resolving *before* shutdown ever begins must still
    /// publish exactly as before — the `setIncludePrereleaseUpdates`
    /// counterpart of `testInFlightUpdateCheckStillPublishesWhenItResolvesBeforeShutdownBegins`.
    func testSetIncludePrereleaseUpdatesStillPublishesWhenItResolvesBeforeShutdownBegins() async throws {
        let updateService = SuspendableUpdateChecking()
        let (coordinator, renderer, _) = await makeCoordinator(updateService: updateService)
        let emittedBefore = renderer.emittedSnapshots.count

        let toggleTask = Task {
            try await coordinator.setIncludePrereleaseUpdates(true)
        }
        await updateService.waitForSetIncludePrereleaseCall()

        await updateService.resolveSetIncludePrerelease(with: UpdateState(
            checking: false,
            availableVersion: "v9.9.9",
            releaseURL: "https://github.com/OpenCoven/seer/releases/tag/v9.9.9",
            lastCheckedAt: 1_700_000_000_000
        ))
        try await toggleTask.value

        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore + 1)
        XCTAssertEqual(coordinator.snapshot.update.availableVersion, "v9.9.9")

        try await coordinator.shutdown()
        XCTAssertEqual(renderer.emittedSnapshots.count, emittedBefore + 2, "shutdown must still publish its own final transition afterward")
    }

    // MARK: - Task 12 finding: setKeepAwakeMode/clearHistory must also fence off after shutdown begins

    /// The `setKeepAwakeMode` counterpart of
    /// `testShutdownFlagsAnAlreadyQueuedScheduledCheckSoItNeverNetworkChecksOrPublishesAfterward`:
    /// a keep-awake mode change already queued behind `gate` when
    /// `shutdown()` begins must be skipped entirely — never persisting
    /// the new mode, never touching the power assertion (so it can
    /// neither incorrectly create nor release one), and never
    /// publishing — exactly like an already-queued scheduled check.
    /// Closes Task 12's finding that `setKeepAwakeMode`/`clearHistory`
    /// had no `isShutDown` guard at all, unlike `checkForUpdates`/
    /// `setIncludePrereleaseUpdates`.
    func testShutdownFlagsAnAlreadyQueuedSetKeepAwakeModeCallSoItNeverTouchesPowerOrPublishesAfterward() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let powerBackend = CoordinatorFakePowerBackend()
        let (coordinator, renderer, _) = await makeCoordinator(
            historyFileSystem: historyFS,
            clock: clock,
            powerBackend: powerBackend
        )

        // Build up an open history session so the empty scan below
        // actually performs a real disk write worth suspending — giving
        // a genuine, controlled window in which the coordinator's gate
        // is held by something other than the mode change or shutdown
        // itself.
        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        clock.now += 2_000
        let createdModesBeforeRace = powerBackend.createdModes.count
        let emittedBeforeRace = renderer.emittedSnapshots.count
        let modeBeforeRace = coordinator.snapshot.monitor.keepAwakeMode

        await historyFS.armSuspension("writeFileAndSynchronize")

        // The closing scan holds the gate, suspended mid-write.
        let scanTask = Task {
            await coordinator.applyScan([], scannedAt: clock.now)
        }
        await historyFS.waitUntilEntered("writeFileAndSynchronize")

        // The keep-awake mode change fires while the gate is held
        // elsewhere, and queues behind the scan.
        let modeChangeTask = Task<Error?, Never> {
            do {
                try await coordinator.setKeepAwakeMode(.display)
                return nil
            } catch {
                return error
            }
        }
        for _ in 0..<50 { await Task.yield() }

        // Shutdown is requested next. Its own `gate.acquire()` call
        // necessarily queues *behind* the already-queued mode change —
        // yet it must still flag `isShutDown` immediately, without
        // waiting for the gate.
        let shutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }

        await historyFS.resumeSuspension("writeFileAndSynchronize")
        await scanTask.value
        let modeChangeError = await modeChangeTask.value
        try await shutdownTask.value

        XCTAssertNil(
            modeChangeError,
            "a mode change only granted the gate after shutdown began must silently do nothing, not throw"
        )
        XCTAssertEqual(
            powerBackend.createdModes.count, createdModesBeforeRace,
            "the already-queued mode change must never touch the power backend once shutdown has begun — it must not incorrectly create or release an assertion"
        )
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace + 2,
            "only the scan's own transition and shutdown's final transition may publish — the skipped mode change must publish nothing"
        )
        XCTAssertEqual(
            coordinator.snapshot.monitor.keepAwakeMode, modeBeforeRace,
            "a mode change skipped for shutdown must never actually change the published mode"
        )
    }

    /// The `clearHistory` counterpart of the same race: a history-clear
    /// request already queued behind `gate` when `shutdown()` begins
    /// must never mutate history or publish afterward.
    func testShutdownFlagsAnAlreadyQueuedClearHistoryCallSoItNeverMutatesOrPublishesAfterward() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let historyFS = InMemorySettingsFileSystem()
        let (coordinator, renderer, _) = await makeCoordinator(
            historyFileSystem: historyFS,
            clock: clock
        )

        // Three ticks: the first opens a session with an empty `agents`
        // list (there is no elapsed delta yet to attribute — see
        // `HistoryStoreTests.testPerAgentAccumulationSortsDescending`);
        // the second actually accumulates >= `HistoryStore
        // .minimumSessionMs` of elapsed duration into that session; only
        // the third (below, suspended mid-write) closes it, so it is
        // actually recorded into `sessionCount` — a session with no
        // accumulated duration is discarded entirely and would make this
        // test's own `sessionCount` assertion vacuous regardless of the
        // race being exercised.
        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        clock.now += 2_000
        await coordinator.applyScan([activeAgent()], scannedAt: clock.now)
        clock.now += 2_000
        let emittedBeforeRace = renderer.emittedSnapshots.count

        await historyFS.armSuspension("writeFileAndSynchronize")

        // The closing scan holds the gate, suspended mid-write.
        let scanTask = Task {
            await coordinator.applyScan([], scannedAt: clock.now)
        }
        await historyFS.waitUntilEntered("writeFileAndSynchronize")

        // The history-clear request fires while the gate is held
        // elsewhere, and queues behind the scan.
        let clearTask = Task<Error?, Never> {
            do {
                try await coordinator.clearHistory()
                return nil
            } catch {
                return error
            }
        }
        for _ in 0..<50 { await Task.yield() }

        let shutdownTask = Task {
            try await coordinator.shutdown()
        }
        for _ in 0..<50 { await Task.yield() }

        await historyFS.resumeSuspension("writeFileAndSynchronize")
        await scanTask.value
        let clearError = await clearTask.value
        try await shutdownTask.value

        XCTAssertNil(
            clearError,
            "a history-clear request only granted the gate after shutdown began must silently do nothing, not throw"
        )
        XCTAssertEqual(
            renderer.emittedSnapshots.count, emittedBeforeRace + 2,
            "only the scan's own transition and shutdown's final transition may publish — the skipped clear must publish nothing"
        )
        XCTAssertGreaterThan(
            coordinator.snapshot.history.sessionCount, 0,
            "a history clear skipped for shutdown must never actually reset the recorded session count to zero"
        )
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
