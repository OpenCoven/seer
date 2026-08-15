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

    func setKeepAwakeMode(_ mode: KeepAwakeMode) async throws {}

    func clearHistory() async throws {}

    func checkForUpdates(force: Bool) async -> Bool { true }

    func setIncludePrereleaseUpdates(_ value: Bool) async throws {}

    func openLatestRelease() async -> Bool { true }

    private(set) var performStartupUpdateCheckAndStartSchedulerCallCount = 0

    func performStartupUpdateCheckAndStartScheduler() async {
        performStartupUpdateCheckAndStartSchedulerCallCount += 1
    }

    func shutdown() async throws {
        shutdownCallCount += 1
        orderRecorder?.record("coordinatorShutdown")
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

/// A scripted `BridgeHandlerCancelling` double — counts `cancelAll()` calls.
@MainActor
final class FakeBridgeHandlerCancelling: BridgeHandlerCancelling {
    private(set) var cancelAllCallCount = 0
    var orderRecorder: CallOrderRecorder?

    func cancelAll() {
        cancelAllCallCount += 1
        orderRecorder?.record("bridgeCancelAll")
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
    /// monitor work, await coordinator shutdown (history flush/update
    /// cancel/power release), remove bridge handlers, only then reply —
    /// rather than merely that each step happened once (already covered by
    /// `testTerminationStopsMonitorCancelsBridgeAndShutsDownCoordinatorThenReplies`).
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
            ["monitorStop", "coordinatorShutdown", "bridgeCancelAll", "reply"],
            "termination must stop monitor work, then shut down the coordinator, then remove bridge handlers, then reply"
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
    /// `beginMonitoring()`'s initial one — so `performOrderlyShutdownOnce`
    /// *does* have a `scanLoopTask` to await, and must block on that
    /// in-flight tick fully finishing (never merely cancelling and moving
    /// on) before it proceeds to `coordinator.shutdown()`. Once released,
    /// that same in-flight tick's own `hasShutDown` guard must still
    /// prevent it from ever applying to the coordinator.
    func testTerminationAwaitsInFlightLoopScanBeforeShuttingDownAndThatScanNeverApplies() async {
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

        // Give the termination task a moment to actually start; it must
        // block awaiting the loop task's completion rather than
        // proceeding, since the loop's second scan is still suspended.
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(replies.isEmpty, "termination must wait for the in-flight loop scan to finish before completing shutdown")
        XCTAssertEqual(fakeCoordinator.shutdownCallCount, 0)

        fakeMonitor.releaseScan()
        await waitUntil { !replies.isEmpty }

        XCTAssertEqual(replies, [true])
        XCTAssertEqual(fakeCoordinator.shutdownCallCount, 1)
        XCTAssertEqual(
            fakeCoordinator.appliedScans.count,
            1,
            "the second scan tick — in flight when termination began — must never apply to the coordinator"
        )
        XCTAssertEqual(fakeMonitor.stopCallCount, 1)
    }
}
