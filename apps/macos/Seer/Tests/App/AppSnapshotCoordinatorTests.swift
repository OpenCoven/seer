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
        clock: MutableClock = MutableClock(now: 1_700_000_000_000),
        powerBackend: CoordinatorFakePowerBackend = CoordinatorFakePowerBackend(),
        appVersion: String = "1.0.0-test"
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
            scheduler: ManualHistoryScheduler(),
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
            appVersion: appVersion
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

    func testSetKeepAwakeModePersistenceFailureDoesNotPublishSuccessShapedModeAndThrows() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsFS = InMemorySettingsFileSystem()
        let (coordinator, renderer, powerBackend) = await makeCoordinator(settingsFileSystem: settingsFS, clock: clock)
        XCTAssertEqual(coordinator.snapshot.monitor.keepAwakeMode, .system)

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
        XCTAssertTrue(coordinator.snapshot.diagnostics.contains { $0.id == CoordinatorDiagnosticID.settingsPersistFailed })
        XCTAssertEqual(powerBackend.createdModes, [], "no power assertion was ever active, so no power call should occur")
        XCTAssertEqual(renderer.emittedSnapshots.count, 1)
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
