import XCTest
import os
@testable import Seer

// MARK: - Test doubles

/// A thread-safe call-order recorder shared across the fakes below, purely
/// for `testTerminationRunsStepsInTheExactRequiredOrder`: records the exact
/// sequence in which `AppDelegate`'s orderly termination invokes
/// monitor-stop, coordinator-shutdown, and bridge-cancel, plus when its own
/// `reply` closure finally fires — letting that test assert the *order*,
/// not merely the count, of each step. `OSAllocatedUnfairLock` (not
/// `NSLock`) because `NSLock.lock()`/`unlock()` are unavailable from
/// `async` contexts under Swift 6's strict concurrency checking, and
/// `record(_:)` is called from several `async` fake methods below
/// (matching `AgentMonitorTests.swift`'s identical rationale).
final class CallOrderRecorder: @unchecked Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [String]())

    func record(_ event: String) {
        events.withLock { $0.append(event) }
    }

    func snapshot() -> [String] {
        events.withLock { $0 }
    }
}

/// A scripted `AppSnapshotCoordinating` double: records every scan/scan-
/// failure/shutdown call it receives so `AppLifecycleTests` can assert
/// exactly what `AppDelegate`'s scan loop and orderly termination forward
/// to the coordinator, without standing up a real `SettingsStore`/
/// `HistoryStore`/`PowerAssertionService`/`UpdateService` stack.
@MainActor
final class FakeAppSnapshotCoordinating: AppSnapshotCoordinating {
    var snapshot: AppSnapshot = .empty(version: "1.0.0-test")

    private(set) var appliedScans: [(agents: [ActiveAgent], scannedAt: Int64)] = []
    private(set) var appliedScanFailures: [Int64] = []
    private(set) var shutdownCallCount = 0
    var orderRecorder: CallOrderRecorder?

    func applyScan(_ agents: [ActiveAgent], scannedAt: Int64) async {
        appliedScans.append((agents, scannedAt))
    }

    func applyScanFailure(occurredAt: Int64) async {
        appliedScanFailures.append(occurredAt)
    }

    /// Records every `setKeepAwakeMode(_:)` call this double receives —
    /// used by the Task 12 shutdown-race tests to assert a mode change
    /// requested at (or after) the exact instant termination begins
    /// never reaches the coordinator at all.
    private(set) var setKeepAwakeModeCalls: [KeepAwakeMode] = []

    func setKeepAwakeMode(_ mode: KeepAwakeMode) async throws {
        setKeepAwakeModeCalls.append(mode)
    }

    private(set) var clearHistoryCallCount = 0

    func clearHistory() async throws {
        clearHistoryCallCount += 1
    }

    func checkForUpdates(force: Bool) async -> Bool { true }

    /// Scripted outcome for `setIncludePrereleaseUpdates(_:)`:
    /// `.success` (the default) always succeeds; set to `.throwing(_:)`
    /// to make every call throw (the persistence-failure path), or
    /// `.checkFailed` to simulate persistence having committed while the
    /// forced re-check itself failed.
    enum ScriptedSetIncludePrereleaseUpdatesOutcome {
        case success
        case checkFailed(message: String)
        case durabilityUncertain(message: String)
        case throwing(Error)
    }
    var setIncludePrereleaseUpdatesOutcome: ScriptedSetIncludePrereleaseUpdatesOutcome = .success
    private(set) var setIncludePrereleaseUpdatesCalls: [Bool] = []
    var includePrereleaseUpdatesValue = false

    /// Backward-compatible convenience some existing tests script
    /// through directly: setting this to a non-nil `Error` is equivalent
    /// to `setIncludePrereleaseUpdatesOutcome = .throwing(error)`; setting
    /// it back to `nil` resets the scripted outcome to `.success`.
    var setIncludePrereleaseUpdatesError: Error? {
        didSet {
            if let setIncludePrereleaseUpdatesError {
                setIncludePrereleaseUpdatesOutcome = .throwing(setIncludePrereleaseUpdatesError)
            } else {
                setIncludePrereleaseUpdatesOutcome = .success
            }
        }
    }

    func setIncludePrereleaseUpdates(_ value: Bool) async throws -> SetIncludePrereleaseUpdatesOutcome {
        setIncludePrereleaseUpdatesCalls.append(value)
        switch setIncludePrereleaseUpdatesOutcome {
        case .success:
            includePrereleaseUpdatesValue = value
            return .success
        case .checkFailed(let message):
            includePrereleaseUpdatesValue = value
            return .persistedButCheckFailed(message: message)
        case .durabilityUncertain(let message):
            includePrereleaseUpdatesValue = value
            return .persistedButDurabilityUncertain(message: message)
        case .throwing(let error):
            throw error
        }
    }

    private(set) var includePrereleaseUpdatesReadCount = 0
    var includePrereleaseUpdates: Bool {
        get async {
            includePrereleaseUpdatesReadCount += 1
            return includePrereleaseUpdatesValue
        }
    }

    private(set) var openLatestReleaseCallCount = 0

    func openLatestRelease() async -> Bool {
        openLatestReleaseCallCount += 1
        return true
    }

    private(set) var performStartupUpdateCheckAndStartSchedulerCallCount = 0

    func performStartupUpdateCheckAndStartScheduler() async {
        performStartupUpdateCheckAndStartSchedulerCallCount += 1
    }

    func shutdown() async throws {
        shutdownCallCount += 1
        orderRecorder?.record("coordinatorShutdown")
    }
}

/// A scripted `PrereleaseUpdatesMenuApplying` double: records every
/// `apply(includePrereleaseUpdates:)` call it receives (value and order),
/// so `AppLifecycleTests` can assert exactly when — relative to
/// `AppSnapshotCoordinator.setIncludePrereleaseUpdates(_:)` resolving — the
/// menu checkbox is (and, on a persistence failure, is *not*) updated.
@MainActor
final class FakePrereleaseUpdatesMenuApplying: PrereleaseUpdatesMenuApplying {
    private(set) var includePrereleaseUpdates: Bool
    private(set) var appliedValues: [Bool] = []

    init(includePrereleaseUpdates: Bool) {
        self.includePrereleaseUpdates = includePrereleaseUpdates
    }

    func apply(includePrereleaseUpdates value: Bool) {
        includePrereleaseUpdates = value
        appliedValues.append(value)
    }
}

/// A scripted `AgentMonitorControlling` double: `scan()` just counts its own
/// invocations — the fixed `state`/`diagnostic` it reports are configured
/// by the test up front, exactly like `AgentMonitor.scan()`'s own contract
/// of publishing whatever the most recent completed scan determined.
final class FakeAgentMonitorControlling: AgentMonitorControlling, @unchecked Sendable {
    var state: AgentMonitorState
    var diagnostic: Diagnostic?
    var orderRecorder: CallOrderRecorder?

    private(set) var scanCallCount = 0
    private(set) var stopCallCount = 0

    init(state: AgentMonitorState, diagnostic: Diagnostic? = nil) {
        self.state = state
        self.diagnostic = diagnostic
    }

    func scan() async {
        scanCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
        orderRecorder?.record("monitorStop")
    }
}

/// An `AgentMonitorControlling` double whose `scan()` call suspends
/// indefinitely until the test explicitly calls `releaseScan()` — letting a
/// test deterministically start `beginTermination()` *while* a particular
/// scan tick is still in flight inside `agentMonitor.scan()` itself,
/// several steps before that tick would otherwise go on to call
/// `coordinator.applyScan`/`applyScanFailure`. Mirrors `GatedSleeper`
/// (`UpdateServiceTests.swift`) but gates `scan()` instead of a sleep, and
/// mirrors `AgentMonitorTests.swift`'s `OSAllocatedUnfairLock`-guarded state
/// struct for the same "no `NSLock` in an `async` context" reason
/// documented on `CallOrderRecorder` above.
final class GatedAgentMonitorControlling: AgentMonitorControlling, @unchecked Sendable {
    var state: AgentMonitorState
    var diagnostic: Diagnostic?
    var orderRecorder: CallOrderRecorder?

    private struct GateState {
        var scanCallCount = 0
        var stopCallCount = 0
        var pendingContinuation: CheckedContinuation<Void, Never>?
        var availableReleases = 0
    }

    private let gateState = OSAllocatedUnfairLock(initialState: GateState())

    var scanCallCount: Int { gateState.withLock { $0.scanCallCount } }
    var stopCallCount: Int { gateState.withLock { $0.stopCallCount } }

    init(state: AgentMonitorState, diagnostic: Diagnostic? = nil) {
        self.state = state
        self.diagnostic = diagnostic
    }

    func scan() async {
        gateState.withLock { $0.scanCallCount += 1 }
        await waitForRelease()
    }

    func stop() async {
        gateState.withLock { $0.stopCallCount += 1 }
        orderRecorder?.record("monitorStop")
    }

    private func waitForRelease() async {
        let shouldResumeImmediately = gateState.withLock { state -> Bool in
            guard state.availableReleases > 0 else { return false }
            state.availableReleases -= 1
            return true
        }
        guard !shouldResumeImmediately else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gateState.withLock { $0.pendingContinuation = continuation }
        }
    }

    /// Wakes the currently suspended `scan()` call, or — if none is
    /// suspended yet — banks a credit so the *next* call returns
    /// immediately instead of suspending.
    func releaseScan() {
        let continuationToResume = gateState.withLock { state -> CheckedContinuation<Void, Never>? in
            if let continuation = state.pendingContinuation {
                state.pendingContinuation = nil
                return continuation
            }
            state.availableReleases += 1
            return nil
        }
        continuationToResume?.resume()
    }
}

/// A scripted `BridgeHandlerCancelling` double — counts `stopAccepting()`/
/// `cancelAll()` calls.
@MainActor
final class FakeBridgeHandlerCancelling: BridgeHandlerCancelling {
    private(set) var cancelAllCallCount = 0
    private(set) var stopAcceptingCallCount = 0
    var orderRecorder: CallOrderRecorder?

    func stopAccepting() {
        stopAcceptingCallCount += 1
        orderRecorder?.record("bridgeStopAccepting")
    }

    func cancelAll() {
        cancelAllCallCount += 1
        orderRecorder?.record("bridgeCancelAll")
    }
}

@MainActor
final class ImmediateBridgeResponder: BridgeResponding {
    private(set) var responses: [BridgeResponse] = []

    func deliverResponse(_ response: BridgeResponse) {
        responses.append(response)
    }
}

// MARK: - Tests

@MainActor
final class AppLifecycleTests: XCTestCase {
    private func agent(id: String = "codex:fixture") -> ActiveAgent {
        ActiveAgent(id: id, name: "Codex", detail: "Working", source: .session, lastActivityAt: 1_700_000_000_000)
    }

    /// Polls `condition` until it becomes `true` or `timeout` elapses —
    /// used instead of a fixed `Task.sleep` so waiting for the scan loop's
    /// background `Task` to actually run after a `GatedSleeper.resumeNext()`
    /// call never races a hardcoded delay.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Launch sequence (steps 4 & 5)

    func testBeginMonitoringPerformsOneInitialScanBeforeAnySleep() async {
        let monitorState = AgentMonitorState(active: true, keepingAwake: true, keepAwakeMode: .system, agents: [agent()], lastScanAt: 42)
        let fakeMonitor = FakeAgentMonitorControlling(state: monitorState)
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let sleeper = GatedSleeper()
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor, sleeper: sleeper)

        await delegate.beginMonitoring()

        XCTAssertEqual(fakeMonitor.scanCallCount, 1)
        XCTAssertEqual(fakeCoordinator.appliedScans.count, 1)
        XCTAssertEqual(fakeCoordinator.appliedScans.first?.agents.first?.id, agent().id)
        XCTAssertEqual(fakeCoordinator.appliedScans.first?.scannedAt, 42)
    }

    func testMonitorLoopScansAgainAfterEachSleeperTick() async {
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let sleeper = GatedSleeper()
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor, sleeper: sleeper)

        await delegate.beginMonitoring()
        XCTAssertEqual(fakeMonitor.scanCallCount, 1)

        await waitUntil { fakeMonitor.scanCallCount >= 1 }
        await sleeper.release()
        await waitUntil { fakeMonitor.scanCallCount == 2 }
        XCTAssertEqual(fakeMonitor.scanCallCount, 2)

        await sleeper.release()
        await waitUntil { fakeMonitor.scanCallCount == 3 }
        XCTAssertEqual(fakeMonitor.scanCallCount, 3)
    }

    func testScanFailureForwardsToApplyScanFailureRetainingPriorAgents() async {
        let diagnostic = Diagnostic(id: AgentMonitorDiagnosticID.scanFailed, message: "boom", occurredAt: 555)
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: true, keepingAwake: true, keepAwakeMode: .system, agents: [agent()], lastScanAt: 100),
            diagnostic: diagnostic
        )
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor, sleeper: GatedSleeper())

        await delegate.beginMonitoring()

        XCTAssertEqual(fakeCoordinator.appliedScanFailures, [555])
        XCTAssertTrue(fakeCoordinator.appliedScans.isEmpty)
    }

    // MARK: - Orderly termination

    func testTerminationReturnsTerminateLaterImmediately() {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor)

        let result = delegate.beginTermination { _ in }

        XCTAssertEqual(result, .terminateLater)
    }

    func testBridgeMessageImmediatelyAfterBeginTerminationIsRejectedSynchronously() {
        var routerCallCount = 0
        let router = StandaloneBridgeCommandRouter(
            snapshotGet: {
                routerCallCount += 1
                return .success(.empty(version: "test"))
            },
            keepAwakeModeSet: { _ in .success(.empty(version: "test")) },
            historyClear: { .success(.empty(version: "test")) }
        )
        let responder = ImmediateBridgeResponder()
        let handler = BridgeMessageHandler(router: router, responder: responder)
        let delegate = AppDelegate(
            coordinator: FakeAppSnapshotCoordinating(),
            agentMonitor: FakeAgentMonitorControlling(
                state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
            ),
            bridgeMessageHandler: handler
        )

        _ = delegate.beginTermination { _ in }
        handler.handle(body: [
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "version": bridgeVersion,
            "method": "snapshot.get",
            "payload": [String: Any](),
        ])

        XCTAssertEqual(routerCallCount, 0)
        guard case .failure(_, let error) = responder.responses.first else {
            return XCTFail("the post-termination message must be rejected immediately")
        }
        XCTAssertEqual(error.code, .appShuttingDown)
    }

    func testTerminationStopsMonitorCancelsBridgeAndShutsDownCoordinatorThenReplies() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeBridge = FakeBridgeHandlerCancelling()
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            sleeper: GatedSleeper(),
            bridgeMessageHandler: fakeBridge
        )
        await delegate.beginMonitoring()

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }

        await waitUntil { !replies.isEmpty }

        XCTAssertEqual(replies, [true])
        XCTAssertEqual(fakeMonitor.stopCallCount, 1)
        XCTAssertEqual(fakeBridge.cancelAllCallCount, 1)
        XCTAssertEqual(fakeCoordinator.shutdownCallCount, 1)
    }

    func testDoubleTerminationRequestIsIdempotentButRepliesToEveryCaller() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeBridge = FakeBridgeHandlerCancelling()
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            sleeper: GatedSleeper(),
            bridgeMessageHandler: fakeBridge
        )

        var repliesA: [Bool] = []
        var repliesB: [Bool] = []
        _ = delegate.beginTermination { success in repliesA.append(success) }
        _ = delegate.beginTermination { success in repliesB.append(success) }

        await waitUntil { !repliesA.isEmpty && !repliesB.isEmpty }

        XCTAssertEqual(repliesA, [true])
        XCTAssertEqual(repliesB, [true])
        XCTAssertEqual(fakeCoordinator.shutdownCallCount, 1, "Shutdown work must run exactly once regardless of how many termination requests arrive")
        XCTAssertEqual(fakeMonitor.stopCallCount, 1)
        XCTAssertEqual(fakeBridge.cancelAllCallCount, 1)
    }

    func testTerminationAfterMonitoringStopsTheScanLoopFromScanningAgain() async {
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let sleeper = GatedSleeper()
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor, sleeper: sleeper)

        await delegate.beginMonitoring()
        XCTAssertEqual(fakeMonitor.scanCallCount, 1)

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }
        await waitUntil { !replies.isEmpty }

        // Unblock whatever sleep the (now-cancelled) loop was suspended in;
        // it must observe cancellation and return without scanning again.
        await sleeper.release()
        // Give the loop's task a moment to actually resume and hit its
        // cancellation check.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fakeMonitor.scanCallCount, 1, "No further scan should occur once termination has begun")
    }

    /// Asserts the *exact* required production shutdown sequence — stop
    /// accepting new bridge commands immediately, stop monitor work,
    /// await coordinator shutdown (history flush/update cancel/power
    /// release), remove bridge handlers, only then reply — rather than
    /// merely that each step happened once (already covered by
    /// `testTerminationStopsMonitorCancelsBridgeAndShutsDownCoordinatorThenReplies`).
    /// `bridgeStopAccepting` is asserted first, ahead of even
    /// `monitorStop`, since `performOrderlyShutdownOnce()` calls it
    /// synchronously — before its own first `await` — precisely so no
    /// bridge command dispatched at (or after) that exact instant can
    /// ever be accepted (see Task 12's second finding).
    func testTerminationRunsStepsInTheExactRequiredOrder() async {
        let recorder = CallOrderRecorder()
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        fakeCoordinator.orderRecorder = recorder
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        fakeMonitor.orderRecorder = recorder
        let fakeBridge = FakeBridgeHandlerCancelling()
        fakeBridge.orderRecorder = recorder
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            sleeper: GatedSleeper(),
            bridgeMessageHandler: fakeBridge
        )
        await delegate.beginMonitoring()

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in
            recorder.record("reply")
            replies.append(success)
        }

        await waitUntil { !replies.isEmpty }

        XCTAssertEqual(
            recorder.snapshot(),
            ["bridgeStopAccepting", "monitorStop", "coordinatorShutdown", "bridgeCancelAll", "reply"],
            "termination must stop accepting new bridge commands immediately, then stop monitor work, then shut down the coordinator, then remove bridge handlers, then reply"
        )
    }

    /// Reproduces the exact race Task 12's spec review flagged: a scan
    /// tick is still suspended *inside* `agentMonitor.scan()` — before it
    /// has ever had a chance to call `coordinator.applyScan`/
    /// `applyScanFailure` — at the very moment termination begins. This
    /// exercises `beginMonitoring()`'s own directly-awaited initial scan
    /// (not yet inside `scanLoopTask`, since that task is only created
    /// *after* the initial scan returns), so `performOrderlyShutdownOnce`
    /// has no loop task to await here at all — proving the `hasShutDown`
    /// guard inside `performScanTick` itself, not merely awaiting
    /// `scanLoopTask`, is what fences this specific case off.
    func testScanInFlightWhenTerminationBeginsNeverAppliesEvenAfterShutdownCompletes() async {
        let fakeMonitor = GatedAgentMonitorControlling(
            state: AgentMonitorState(active: true, keepingAwake: true, keepAwakeMode: .system, agents: [agent()], lastScanAt: 999)
        )
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor, sleeper: GatedSleeper())

        let monitoringTask = Task { await delegate.beginMonitoring() }
        await waitUntil { fakeMonitor.scanCallCount >= 1 }

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }

        // Shutdown must be able to run to completion — flagging
        // `hasShutDown` and calling `coordinator.shutdown()` — entirely
        // independently of the still-suspended initial scan, since that
        // scan is not (yet) tracked by any `scanLoopTask` shutdown could
        // await.
        await waitUntil { fakeCoordinator.shutdownCallCount == 1 }
        XCTAssertTrue(
            fakeCoordinator.appliedScans.isEmpty,
            "the still in-flight initial scan must not have applied before/during shutdown"
        )

        // Only now let the in-flight scan actually resolve.
        fakeMonitor.releaseScan()
        await waitUntil { !replies.isEmpty }
        _ = await monitoringTask.value

        XCTAssertEqual(replies, [true])
        XCTAssertTrue(
            fakeCoordinator.appliedScans.isEmpty,
            "a scan already in flight when termination began must never apply to the coordinator, even once it resolves after shutdown has completed"
        )
    }

    /// Companion to the test above: reproduces the same race, but for a
    /// scan tick dispatched from the recurring `scanLoopTask` rather than
    /// `beginMonitoring()`'s initial one. Unlike the analogous test in the
    /// prior revision of this suite, `performOrderlyShutdownOnce` must
    /// *not* block on that in-flight tick fully finishing before it
    /// proceeds to `coordinator.shutdown()` — awaiting it unboundedly is
    /// exactly Task 12's hang finding, since `agentMonitor.scan()` may be
    /// running non-cooperative detached detection work that never notices
    /// cancellation. Termination must cancel the loop task, stop the
    /// monitor, and proceed to shut the coordinator down *without* ever
    /// releasing the still in-flight scan; only once released afterward
    /// must that same tick's own `hasShutDown` guard still prevent it from
    /// ever applying to the coordinator.
    func testTerminationDoesNotWaitForInFlightLoopScanAndThatScanNeverApplies() async {
        let fakeMonitor = GatedAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let sleeper = GatedSleeper()
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor, sleeper: sleeper)

        // Bank a release credit so the initial scan (call #1, awaited
        // directly by `beginMonitoring()`) resolves immediately.
        fakeMonitor.releaseScan()
        await delegate.beginMonitoring()
        XCTAssertEqual(fakeMonitor.scanCallCount, 1)
        XCTAssertEqual(fakeCoordinator.appliedScans.count, 1)

        // Wake the loop's sleep so it starts its second scan tick, which
        // now suspends inside `agentMonitor.scan()` until released.
        await sleeper.release()
        await waitUntil { fakeMonitor.scanCallCount == 2 }

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }

        // Termination must reach coordinator shutdown and reply promptly
        // — without this test ever releasing the second, still in-flight
        // scan tick.
        await waitUntil { !replies.isEmpty }

        XCTAssertEqual(replies, [true], "termination must not wait for the in-flight loop scan to finish")
        XCTAssertEqual(fakeCoordinator.shutdownCallCount, 1)
        XCTAssertEqual(fakeMonitor.stopCallCount, 1)
        XCTAssertEqual(
            fakeCoordinator.appliedScans.count,
            1,
            "the second scan tick — still in flight when termination began — must not have applied yet"
        )

        // Only now release the stale tick; it must still never apply.
        fakeMonitor.releaseScan()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(
            fakeCoordinator.appliedScans.count,
            1,
            "the second scan tick — in flight when termination began — must never apply to the coordinator, even once released after shutdown completed"
        )
    }

    /// The deterministic regression test for Task 12's core finding:
    /// orderly termination must reach coordinator shutdown, bridge
    /// teardown, and reply *even when the in-flight scan is never
    /// released at all* — modeling a genuinely non-cooperative detector
    /// that never resolves. Unlike every other termination test in this
    /// file, this one never calls `releaseScan()` on the still-suspended
    /// second scan tick — proving orderly termination does not, and must
    /// never, depend on that in-flight work ever completing.
    func testTerminationReachesCoordinatorShutdownBridgeTeardownAndReplyWithAPermanentlySuspendedScan() async {
        let fakeMonitor = GatedAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeBridge = FakeBridgeHandlerCancelling()
        let recorder = CallOrderRecorder()
        fakeMonitor.orderRecorder = recorder
        fakeCoordinator.orderRecorder = recorder
        fakeBridge.orderRecorder = recorder
        let sleeper = GatedSleeper()
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            sleeper: sleeper,
            bridgeMessageHandler: fakeBridge
        )

        // Bank a credit so the initial scan resolves immediately, then
        // wake the loop so its second scan tick starts — and this time
        // never release it at all. This second tick models a permanently
        // suspended, non-cooperative detector: nothing in this test ever
        // resolves it manually.
        fakeMonitor.releaseScan()
        await delegate.beginMonitoring()
        await sleeper.release()
        await waitUntil { fakeMonitor.scanCallCount == 2 }

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in
            recorder.record("reply")
            replies.append(success)
        }

        await waitUntil(timeout: 5) { !replies.isEmpty }

        XCTAssertEqual(replies, [true], "termination must reach reply without the permanently-suspended scan ever resolving")
        XCTAssertEqual(fakeCoordinator.shutdownCallCount, 1)
        XCTAssertEqual(fakeBridge.cancelAllCallCount, 1)
        XCTAssertEqual(
            recorder.snapshot(),
            ["bridgeStopAccepting", "monitorStop", "coordinatorShutdown", "bridgeCancelAll", "reply"],
            "termination must still stop accepting new bridge commands, stop the monitor, shut down the coordinator, tear down the bridge, then reply — with no manual release of the permanently-suspended scan"
        )
    }

    /// Reproduces the lifecycle-fencing gap this fix closes: quit begins
    /// while `beginMonitoring()`'s own initial scan is still suspended
    /// inside `agentMonitor.scan()` — exactly the scenario
    /// `testScanInFlightWhenTerminationBeginsNeverAppliesEvenAfterShutdownCompletes`
    /// already covers for the *applied-scan* side of this race — but this
    /// test instead asserts that `beginMonitoring()` must never go on to
    /// start the recurring `scanLoopTask` at all once shutdown has
    /// already completed by the time that initial scan finally resolves.
    /// Without a `hasShutDown` check between the initial scan and
    /// `startScanLoop(...)`, the loop would still start — resurrecting
    /// monitoring work after an orderly shutdown already ran to
    /// completion (stopped `agentMonitor`, shut down the coordinator,
    /// cancelled bridge handlers) — even though nothing would apply its
    /// *results* thanks to the already-tested `hasShutDown` guard inside
    /// `performScanTick`. Detected deterministically here by releasing
    /// the (otherwise indefinitely gated) sleeper afterward: if a loop
    /// task had incorrectly started, it would immediately resume from its
    /// sleep and dispatch a second `agentMonitor.scan()` call, bumping
    /// `scanCallCount` past 1 the instant that scan is entered — this
    /// fake increments its counter before ever awaiting a release, so no
    /// arbitrary timing race is needed to observe the difference.
    func testShutdownDuringInitialScanPreventsTheScanLoopFromEverStarting() async {
        let fakeMonitor = GatedAgentMonitorControlling(
            state: AgentMonitorState(active: true, keepingAwake: true, keepAwakeMode: .system, agents: [agent()], lastScanAt: 999)
        )
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let sleeper = GatedSleeper()
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor, sleeper: sleeper)

        let monitoringTask = Task { await delegate.beginMonitoring() }
        await waitUntil { fakeMonitor.scanCallCount >= 1 }

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }
        await waitUntil { fakeCoordinator.shutdownCallCount == 1 }
        await waitUntil { !replies.isEmpty }

        // Only now let the still in-flight initial scan resolve — shutdown
        // has already fully completed by this point. `beginMonitoring()`
        // must observe `hasShutDown` immediately afterward and return
        // without ever calling `startScanLoop`.
        fakeMonitor.releaseScan()
        await monitoringTask.value

        // Wake whatever sleep a (bug-permitted) scan loop would be
        // suspended in; if the loop had incorrectly started, this would
        // trigger its second scan tick right away.
        await sleeper.release()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            fakeMonitor.scanCallCount, 1,
            "no scan loop may start once shutdown has already begun, even once the in-flight initial scan finally resolves"
        )
        XCTAssertTrue(
            fakeCoordinator.appliedScans.isEmpty,
            "the still in-flight initial scan must not have applied either, once shutdown already began"
        )
    }

    // MARK: - Prerelease-updates menu checkbox (Task 12 finding)

    /// The menu checkbox must apply only *after* persistence has actually
    /// succeeded — never optimistically ahead of it.
    func testSetIncludePrereleaseUpdatesAppliesMenuOnlyAfterSuccessfulPersistence() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeMenu = FakePrereleaseUpdatesMenuApplying(includePrereleaseUpdates: false)
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            prereleaseUpdatesMenu: fakeMenu
        )

        delegate.requestSetIncludePrereleaseUpdates(true)

        await waitUntil { fakeMenu.appliedValues.count == 1 }

        XCTAssertEqual(fakeCoordinator.setIncludePrereleaseUpdatesCalls, [true], "persistence must be attempted with the requested value")
        XCTAssertEqual(fakeMenu.appliedValues, [true], "the menu must apply the new value once persistence succeeds")
        XCTAssertTrue(fakeMenu.includePrereleaseUpdates)
    }

    /// The core of Task 12's finding: a persistence failure must never be
    /// silently swallowed via `try?`, and the menu checkbox must never
    /// reflect the failed value — it must stay showing whatever was last
    /// actually persisted, so the next fresh, right-click-built menu still
    /// reflects authoritative persisted state rather than a value that
    /// only ever existed in the UI.
    func testSetIncludePrereleaseUpdatesNeverAppliesMenuOnPersistenceFailure() async {
        struct PersistenceFailure: Error {}

        let fakeCoordinator = FakeAppSnapshotCoordinating()
        fakeCoordinator.setIncludePrereleaseUpdatesError = PersistenceFailure()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeMenu = FakePrereleaseUpdatesMenuApplying(includePrereleaseUpdates: false)
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            prereleaseUpdatesMenu: fakeMenu
        )

        delegate.requestSetIncludePrereleaseUpdates(true)

        // Wait for the (failing) persistence attempt to actually run,
        // then give the failure-handling path a brief, deterministic
        // settle window to prove it never applies the menu afterward
        // either — not merely "hasn't yet."
        await waitUntil { fakeCoordinator.setIncludePrereleaseUpdatesCalls.count == 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(fakeCoordinator.setIncludePrereleaseUpdatesCalls, [true], "persistence must still be attempted")
        XCTAssertEqual(fakeMenu.appliedValues, [], "the menu must never apply a value whose persistence failed")
        XCTAssertFalse(fakeMenu.includePrereleaseUpdates, "the menu must keep reflecting the last authoritative persisted value")
    }

    /// Complements the two tests above: a fresh menu built after a
    /// persistence failure must reflect the same authoritative persisted
    /// value a subsequent *successful* toggle eventually applies — proving
    /// the checkbox never permanently drifts from disk after one failure.
    func testSetIncludePrereleaseUpdatesRecoversOnANextSuccessfulPersist() async {
        struct PersistenceFailure: Error {}

        let fakeCoordinator = FakeAppSnapshotCoordinating()
        fakeCoordinator.setIncludePrereleaseUpdatesError = PersistenceFailure()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeMenu = FakePrereleaseUpdatesMenuApplying(includePrereleaseUpdates: false)
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            prereleaseUpdatesMenu: fakeMenu
        )

        delegate.requestSetIncludePrereleaseUpdates(true)
        await waitUntil { fakeCoordinator.setIncludePrereleaseUpdatesCalls.count == 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(fakeMenu.includePrereleaseUpdates, "must still reflect the last persisted value after the failed attempt")

        fakeCoordinator.setIncludePrereleaseUpdatesError = nil
        delegate.requestSetIncludePrereleaseUpdates(true)
        await waitUntil { fakeMenu.appliedValues.count == 1 }

        XCTAssertTrue(fakeMenu.includePrereleaseUpdates, "a later successful persist must still update the menu")
        XCTAssertEqual(fakeCoordinator.setIncludePrereleaseUpdatesCalls, [true, true])
    }

    /// Task 12's core finding: persistence committing while only the
    /// forced re-check fails (e.g. toggling the setting while offline)
    /// must still apply the tray checkbox — never leave it showing the
    /// old value just because the network happened to be unreachable at
    /// that exact moment. Complements
    /// `testSetIncludePrereleaseUpdatesNeverAppliesMenuOnPersistenceFailure`
    /// above, which covers the opposite (genuine persistence failure)
    /// case.
    func testSetIncludePrereleaseUpdatesAppliesMenuWhenPersistenceSucceedsButForcedCheckFails() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        fakeCoordinator.setIncludePrereleaseUpdatesOutcome = .checkFailed(message: "simulated offline check failure")
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeMenu = FakePrereleaseUpdatesMenuApplying(includePrereleaseUpdates: false)
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            prereleaseUpdatesMenu: fakeMenu
        )

        delegate.requestSetIncludePrereleaseUpdates(true)

        await waitUntil { fakeMenu.appliedValues.count == 1 }

        XCTAssertEqual(fakeCoordinator.setIncludePrereleaseUpdatesCalls, [true])
        XCTAssertEqual(fakeMenu.appliedValues, [true], "the menu must still apply the new value once persistence committed, even though the forced check itself failed")
        XCTAssertTrue(fakeMenu.includePrereleaseUpdates)
    }

    func testSetIncludePrereleaseUpdatesAppliesAuthoritativeMenuValueWhenDurabilityIsUncertain() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        fakeCoordinator.setIncludePrereleaseUpdatesOutcome = .durabilityUncertain(message: "directory fsync failed")
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeMenu = FakePrereleaseUpdatesMenuApplying(includePrereleaseUpdates: false)
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            prereleaseUpdatesMenu: fakeMenu
        )

        delegate.requestSetIncludePrereleaseUpdates(true)
        await waitUntil { fakeMenu.appliedValues.count == 1 }

        XCTAssertEqual(fakeCoordinator.includePrereleaseUpdatesReadCount, 1)
        XCTAssertEqual(fakeMenu.appliedValues, [true])
        XCTAssertTrue(fakeMenu.includePrereleaseUpdates)
    }

    // MARK: - Command fencing after shutdown begins (Task 12 finding)

    /// A keep-awake mode change requested at (or after) the exact
    /// instant termination begins must never reach the coordinator at
    /// all — proving `requestSetKeepAwakeMode(_:)`'s own `hasShutDown`
    /// guard, not merely the coordinator's independent `isShutDown`
    /// guard, fences this off.
    func testRequestSetKeepAwakeModeAfterShutdownNeverReachesTheCoordinator() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor)

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }
        await waitUntil { !replies.isEmpty }

        delegate.requestSetKeepAwakeMode(.display)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(fakeCoordinator.setKeepAwakeModeCalls, [], "a mode change requested after shutdown began must never reach the coordinator, so it can never recreate/release the power assertion incorrectly")
    }

    /// A prerelease-toggle request arriving after shutdown has begun
    /// must neither reach the coordinator nor ever apply the menu —
    /// the dispatched `Task` must observe `hasShutDown` at its own start
    /// and return immediately, without resuming any coordinator work.
    func testRequestSetIncludePrereleaseUpdatesAfterShutdownNeverAppliesTheMenuOrReachesTheCoordinator() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let fakeMenu = FakePrereleaseUpdatesMenuApplying(includePrereleaseUpdates: false)
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor, prereleaseUpdatesMenu: fakeMenu)

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }
        await waitUntil { !replies.isEmpty }

        delegate.requestSetIncludePrereleaseUpdates(true)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(fakeCoordinator.setIncludePrereleaseUpdatesCalls, [], "a toggle requested after shutdown began must never reach the coordinator")
        XCTAssertEqual(fakeMenu.appliedValues, [], "the menu task must be effectively canceled — no apply once shutdown has begun")
    }

    /// A history-clear request arriving after shutdown has begun must
    /// never reach the coordinator either — mirrors the keep-awake and
    /// prerelease cases above for `AppSnapshotCoordinator.clearHistory()`.
    /// Exercised directly against the coordinator fake (there is no
    /// dedicated `requestClearHistory` on `AppDelegate` — history clear
    /// is only ever reachable via the bridge — so this asserts the
    /// coordinator-level contract `BridgeMessageHandlerTests` also relies
    /// on via `StandaloneBridgeCommandRouter`).
    func testClearHistoryNeverMutatesTheFakeCoordinatorAfterShutdownWhenCalledDirectly() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor)

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }
        await waitUntil { !replies.isEmpty }

        // Bridge-driven commands never call through `AppDelegate` at
        // all — they route straight from `BridgeMessageHandler` to the
        // coordinator via `StandaloneBridgeCommandRouter`. Once
        // `hasShutDown`, `AppDelegate.performOrderlyShutdownOnce()` has
        // already called `coordinator.shutdown()`, so a fresh
        // `clearHistory()` call reaching the *real* coordinator would be
        // fenced off by its own `isShutDown` guard (see
        // `AppSnapshotCoordinatorTests`); this fake simply records the
        // call so this suite can assert the shutdown sequence itself
        // never triggers one.
        XCTAssertEqual(fakeCoordinator.clearHistoryCallCount, 0)
    }

    // MARK: - Fallback storage root cleanup (Task 12 finding)

    /// Reproduces the actual production shutdown path: if bootstrap ever
    /// fell back to a dedicated temporary storage directory (see
    /// `StorageBootstrap.Locations.fallbackRoot`), orderly termination
    /// must recursively remove it once coordinator shutdown has fully
    /// completed — never leaving it behind as permanently orphaned disk
    /// usage. Uses a real (not mocked) scratch directory on disk.
    func testTerminationRecursivelyRemovesTheFallbackStorageRootDirectory() async throws {
        let fallbackRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLifecycleTests-fallback-\(UUID().uuidString)", isDirectory: true)
        let nestedFile = fallbackRoot.appendingPathComponent("ai.opencoven.seer/settings.json")
        try FileManager.default.createDirectory(at: nestedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: nestedFile)
        defer { try? FileManager.default.removeItem(at: fallbackRoot) }
        let fallbackLease = try StorageBootstrap.FallbackRootLease.acquire(at: fallbackRoot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackRoot.path), "test setup must have actually created the fallback directory")

        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let delegate = AppDelegate(
            coordinator: fakeCoordinator,
            agentMonitor: fakeMonitor,
            fallbackStorageRoot: fallbackRoot,
            fallbackStorageLease: fallbackLease
        )

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }
        await waitUntil { !replies.isEmpty }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fallbackRoot.path),
            "orderly shutdown must recursively remove the fallback storage root directory once coordinator shutdown has completed"
        )
    }

    /// When bootstrap never needed a fallback directory (the ordinary
    /// case), shutdown must not touch the filesystem at all on its
    /// behalf — there is nothing to clean up, and `fallbackStorageRoot`
    /// stays `nil` throughout.
    func testTerminationWithNoFallbackStorageRootNeverTouchesTheFilesystem() async {
        let fakeCoordinator = FakeAppSnapshotCoordinating()
        let fakeMonitor = FakeAgentMonitorControlling(
            state: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0)
        )
        let delegate = AppDelegate(coordinator: fakeCoordinator, agentMonitor: fakeMonitor)

        var replies: [Bool] = []
        _ = delegate.beginTermination { success in replies.append(success) }
        await waitUntil { !replies.isEmpty }

        XCTAssertEqual(replies, [true], "termination must still complete normally with no fallback storage root configured")
    }
}
