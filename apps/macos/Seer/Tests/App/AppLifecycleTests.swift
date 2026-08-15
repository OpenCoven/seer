import XCTest
@testable import Seer

// MARK: - Test doubles

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

    func shutdown() async throws {
        shutdownCallCount += 1
    }
}

/// A scripted `AgentMonitorControlling` double: `scan()` just counts its own
/// invocations — the fixed `state`/`diagnostic` it reports are configured
/// by the test up front, exactly like `AgentMonitor.scan()`'s own contract
/// of publishing whatever the most recent completed scan determined.
final class FakeAgentMonitorControlling: AgentMonitorControlling, @unchecked Sendable {
    var state: AgentMonitorState
    var diagnostic: Diagnostic?

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
    }
}

/// A scripted `BridgeHandlerCancelling` double — counts `cancelAll()` calls.
@MainActor
final class FakeBridgeHandlerCancelling: BridgeHandlerCancelling {
    private(set) var cancelAllCallCount = 0

    func cancelAll() {
        cancelAllCallCount += 1
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
}
