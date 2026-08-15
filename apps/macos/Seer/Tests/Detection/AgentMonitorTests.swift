import XCTest
import os
@testable import Seer

/// Exercises `AgentMonitor`'s non-overlapping scan guard, failure/success
/// state transitions, and start/stop cancellation-safety — entirely against
/// a synthetic `AgentDetecting` double and a manually-driven
/// `AgentMonitorScheduler` double. This suite must never sleep on real
/// wall-clock time.
final class AgentMonitorTests: XCTestCase {
    private struct TestError: Error, Equatable, Sendable {}

    /// A scriptable `AgentDetecting` double returning a fixed sequence of
    /// results (success or failure), one per call, and holding the last
    /// result once the queue is exhausted. An `actor` so
    /// `invocationCount`/concurrent `detect(now:)` calls (as exercised by
    /// `testConcurrentScanIsSkipped`) are always safely serialized.
    private actor SequenceDetector: AgentDetecting {
        enum ScriptedResult {
            case success([ActiveAgent])
            case failure(Error)
        }

        private var results: [ScriptedResult]
        private(set) var invocationCount = 0

        init(_ results: [ScriptedResult]) {
            self.results = results
        }

        func detect(now: Int64) async throws -> [ActiveAgent] {
            invocationCount += 1
            guard !results.isEmpty else { return [] }
            let next = results.removeFirst()
            switch next {
            case .success(let agents):
                return agents
            case .failure(let error):
                throw error
            }
        }
    }

    /// A manually-driven `AgentMonitorScheduler` double: `sleep(milliseconds:)`
    /// records the requested delay and parks on a synchronous, lock-guarded
    /// continuation queue until the test calls `advance()` — or the
    /// awaiting task is cancelled, in which case `onCancel` releases every
    /// currently-parked call immediately. This lets tests drive
    /// `AgentMonitor`'s scan loop through an exact, deterministic number of
    /// iterations without ever waiting on real wall-clock time, and lets
    /// `stop()` reliably unblock a loop parked mid-`sleep`. Backed by a
    /// plain lock (not an `actor`) — matching `ManualHistoryScheduler` in
    /// `HistoryStoreTests.swift` — because the synchronous `onCancel`
    /// handler must release parked continuations immediately, with no
    /// ambiguity about whether cancellation has "taken effect" yet by the
    /// time a test calls `stop()`.
    ///
    /// The recorded-delay bookkeeping, the `pendingAdvances` check, and the
    /// continuation's registration (or immediate resume) all happen inside
    /// one single lock acquisition within `withCheckedContinuation`'s
    /// synchronous body — never split across two separate lock
    /// acquisitions. Splitting them (e.g. deciding "should wait" before
    /// entering the continuation, then registering the continuation
    /// afterward) reopens exactly the race this type exists to close: a
    /// concurrent `advance()` landing in the gap between that decision and
    /// the continuation's actual registration would arm a `pendingAdvances`
    /// slot that nothing ever consumes, permanently parking the loop.
    /// Likewise, cancellation is tracked as a `cancelled` flag (checked
    /// under the same lock) rather than relying on `onCancel` racing ahead
    /// of continuation registration — `withTaskCancellationHandler` makes
    /// no ordering guarantee between `onCancel` and `operation` when the
    /// task is already cancelled at entry, so without this flag a
    /// cancellation delivered *before* the continuation is registered
    /// would otherwise be silently missed.
    private final class ManualAgentMonitorScheduler: AgentMonitorScheduler, @unchecked Sendable {
        private struct State {
            var recordedDelays: [Int64] = []
            var waiters: [CheckedContinuation<Void, Never>] = []
            var pendingAdvances = 0
            var cancelled = false
        }

        // `OSAllocatedUnfairLock` (not `NSLock`) because `NSLock.lock()`/
        // `unlock()` are unavailable from `async` contexts under Swift 6's
        // strict concurrency checking, and `sleep(milliseconds:)` is
        // `async` (matching `ManualHistoryScheduler` in
        // `HistoryStoreTests.swift`).
        private let state = OSAllocatedUnfairLock(initialState: State())

        var recordedDelays: [Int64] {
            state.withLock { $0.recordedDelays }
        }

        var sleepCallCount: Int { recordedDelays.count }

        func sleep(milliseconds: Int64) async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let shouldResumeImmediately = state.withLock { state -> Bool in
                        state.recordedDelays.append(milliseconds)
                        if state.cancelled { return true }
                        if state.pendingAdvances > 0 {
                            state.pendingAdvances -= 1
                            return true
                        }
                        state.waiters.append(continuation)
                        return false
                    }
                    if shouldResumeImmediately {
                        continuation.resume()
                    }
                }
            } onCancel: {
                self.markCancelledAndReleaseAllWaiters()
            }
        }

        private func markCancelledAndReleaseAllWaiters() {
            let pending = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.cancelled = true
                let pending = state.waiters
                state.waiters.removeAll()
                return pending
            }
            for continuation in pending { continuation.resume() }
        }

        /// Releases exactly one currently-parked call to
        /// `sleep(milliseconds:)`, or arms one future call to return
        /// immediately if none is parked yet.
        func advance() {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if !state.waiters.isEmpty {
                    return state.waiters.removeFirst()
                }
                state.pendingAdvances += 1
                return nil
            }
            continuation?.resume()
        }
    }


    /// A detector double whose `detect(now:)` suspends on a continuation
    /// that only this test's explicit `release(with:)` call resumes — it
    /// never observes or reacts to the surrounding task's cancellation.
    /// Deliberately built without `withTaskCancellationHandler`, so
    /// cancelling the task that calls `detect(now:)` (as `AgentMonitor`'s
    /// detached detection task is, once the fix under test lands) has zero
    /// effect on when this continuation resumes. This models a
    /// non-cooperative detector that does not call
    /// `Task.checkCancellation()` or otherwise poll `Task.isCancelled` —
    /// exactly the failure mode the finding describes, where `stop()` must
    /// not depend on the detector's cooperation to return promptly.
    ///
    /// Mirrors `ManualAgentMonitorScheduler` above: every state
    /// transition (recording an entry, deciding whether to park or resume
    /// immediately) happens inside one single lock acquisition, never
    /// split across two, so a `release(with:)` racing a `detect(now:)`
    /// call can never arm a pending release that nothing consumes nor
    /// leave a continuation parked that nothing ever resumes.
    private final class BlockingDetector: AgentDetecting, @unchecked Sendable {
        private struct State {
            var entryWaiters: [CheckedContinuation<Void, Never>] = []
            var enteredCount = 0
            var resultWaiters: [CheckedContinuation<[ActiveAgent], Never>] = []
            var pendingReleases: [[ActiveAgent]] = []
            var invocationCount = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var invocationCount: Int { state.withLock { $0.invocationCount } }

        /// Suspends until `detect(now:)` has been entered at least `count`
        /// times — a continuation-based rendezvous, never a wall-clock
        /// sleep or timeout, so tests can deterministically observe "the
        /// detector is now blocked inside `detect(now:)`."
        func waitUntilEntered(count: Int = 1) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.enteredCount >= count { return true }
                    s.entryWaiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        /// Releases the currently-parked `detect(now:)` call with `result`,
        /// or — if none is parked yet — arms the *next* call to return
        /// `result` immediately, matching `ManualAgentMonitorScheduler
        /// .advance()`'s semantics above.
        func release(with result: [ActiveAgent]) {
            let continuation = state.withLock { s -> CheckedContinuation<[ActiveAgent], Never>? in
                if !s.resultWaiters.isEmpty {
                    return s.resultWaiters.removeFirst()
                }
                s.pendingReleases.append(result)
                return nil
            }
            continuation?.resume(returning: result)
        }

        func detect(now: Int64) async throws -> [ActiveAgent] {
            let entryWaiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.invocationCount += 1
                s.enteredCount += 1
                let waiters = s.entryWaiters
                s.entryWaiters.removeAll()
                return waiters
            }
            for waiter in entryWaiters { waiter.resume() }

            return await withCheckedContinuation { (continuation: CheckedContinuation<[ActiveAgent], Never>) in
                let immediate = state.withLock { s -> [ActiveAgent]? in
                    if !s.pendingReleases.isEmpty {
                        return s.pendingReleases.removeFirst()
                    }
                    s.resultWaiters.append(continuation)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        }
    }

    private let fixedNow: Int64 = 1_700_000_000_000

    private func activeAgent(id: String = "codex:/fixtures/a.jsonl") -> ActiveAgent {
        ActiveAgent(
            id: id,
            name: "Codex",
            detail: "Fixtures · Working",
            source: .session,
            lastActivityAt: fixedNow
        )
    }

    // MARK: - Failed scan retains last successful state

    func testFailedScanRetainsLastSuccessfulState() async {
        let agents = [activeAgent()]
        let detector = SequenceDetector([.success(agents), .failure(TestError())])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.scan()
        await monitor.scan()

        let state = await monitor.state
        XCTAssertEqual(state.agents, agents)
        XCTAssertTrue(state.active)
        let diagnostic = await monitor.diagnostic
        XCTAssertEqual(diagnostic?.id, AgentMonitorDiagnosticID.scanFailed)
    }

    func testSuccessAfterFailureClearsDiagnostic() async {
        let detector = SequenceDetector([.failure(TestError()), .success([activeAgent()])])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.scan()
        let afterFailure = await monitor.diagnostic
        XCTAssertEqual(afterFailure?.id, AgentMonitorDiagnosticID.scanFailed)

        await monitor.scan()
        let afterSuccess = await monitor.diagnostic
        XCTAssertNil(afterSuccess, "a later successful scan must clear the retained diagnostic")
    }

    func testFirstScanFailureReportsEmptyAgentsButKeepsDiagnostic() async {
        let detector = SequenceDetector([.failure(TestError())])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.scan()

        let state = await monitor.state
        XCTAssertEqual(state.agents, [], "no prior success exists yet, so the initial empty state is retained")
        XCTAssertFalse(state.active)
        let diagnostic = await monitor.diagnostic
        XCTAssertEqual(diagnostic?.id, AgentMonitorDiagnosticID.scanFailed)
    }

    // MARK: - Overlap exclusion

    func testConcurrentScanIsSkipped() async {
        let detector = SequenceDetector([.success([]), .success([])])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await monitor.scan() }
            group.addTask { await monitor.scan() }
            await group.waitForAll()
        }

        let invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 1, "a scan already in flight must cause a concurrent scan() call to be a no-op")
    }

    func testSequentialScansEachInvokeTheDetector() async {
        let detector = SequenceDetector([.success([]), .success([]), .success([])])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.scan()
        await monitor.scan()
        await monitor.scan()

        let invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 3, "non-overlapping sequential scans must each invoke the detector")
    }

    // MARK: - State wire fields

    func testSuccessfulScanUpdatesLastScanAtAndActiveFlag() async {
        let detector = SequenceDetector([.success([activeAgent()])])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.scan()

        let state = await monitor.state
        XCTAssertEqual(state.lastScanAt, fixedNow)
        XCTAssertTrue(state.active)
        XCTAssertEqual(state.agents, [activeAgent()])
    }

    func testEmptyAgentListReportsInactive() async {
        let detector = SequenceDetector([.success([])])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.scan()

        let state = await monitor.state
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.agents, [])
    }

    func testInitialStateBeforeAnyScanIsEmptyAndInactive() async {
        let detector = SequenceDetector([])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        let state = await monitor.state
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.agents, [])
        XCTAssertEqual(state.lastScanAt, 0)
        let diagnostic = await monitor.diagnostic
        XCTAssertNil(diagnostic)
    }

    // MARK: - Scheduler cadence

    func testStartSleepsThreeSecondsBetweenCompletedScans() async {
        let detector = SequenceDetector([.success([]), .success([])])
        let scheduler = ManualAgentMonitorScheduler()
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow), scheduler: scheduler)

        await monitor.start()
        // Let the loop's first scan + first sleep call land.
        while scheduler.sleepCallCount < 1 { await Task.yield() }
        XCTAssertEqual(scheduler.recordedDelays, [AgentMonitor.scanIntervalMilliseconds])
        XCTAssertEqual(AgentMonitor.scanIntervalMilliseconds, 3_000)

        await monitor.stop()
    }

    func testStopUnblocksALoopParkedInSleep() async {
        let detector = SequenceDetector([.success([])])
        let scheduler = ManualAgentMonitorScheduler()
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow), scheduler: scheduler)

        await monitor.start()
        while scheduler.sleepCallCount < 1 { await Task.yield() }

        // The loop is now parked inside scheduler.sleep(...); stop() must
        // cancel and unblock it rather than hanging forever.
        await monitor.stop()

        let invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 1, "stop() must not allow another scan to start once cancelled")
    }

    func testStartIsIdempotentAndDoesNotSpawnASecondLoop() async {
        let detector = SequenceDetector([.success([]), .success([]), .success([])])
        let scheduler = ManualAgentMonitorScheduler()
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow), scheduler: scheduler)

        await monitor.start()
        while scheduler.sleepCallCount < 1 { await Task.yield() }
        await monitor.start() // second call must be a no-op, not a second loop

        scheduler.advance() // release the single parked loop for one more iteration
        while scheduler.sleepCallCount < 2 { await Task.yield() }

        await monitor.stop()

        let invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 2, "a redundant start() must never spawn a second concurrent loop")
    }

    func testStopIsIdempotentWhenNoLoopIsRunning() async {
        let detector = SequenceDetector([])
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.stop()
        await monitor.stop()

        let invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testMultipleAdvancesDriveExactIterationCount() async {
        let detector = SequenceDetector([.success([]), .success([]), .success([]), .success([])])
        let scheduler = ManualAgentMonitorScheduler()
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow), scheduler: scheduler)

        await monitor.start()
        while scheduler.sleepCallCount < 1 { await Task.yield() }
        var invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 1)

        scheduler.advance()
        while scheduler.sleepCallCount < 2 { await Task.yield() }
        invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 2)

        scheduler.advance()
        while scheduler.sleepCallCount < 3 { await Task.yield() }
        invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 3)

        await monitor.stop()
        // No further scans after stop(), even though the detector still
        // has a fourth scripted result queued.
        invocationCount = await detector.invocationCount
        XCTAssertEqual(invocationCount, 3)
    }

    // MARK: - stop() must not hang on a non-cooperative in-flight detection

    /// Reproduces the finding directly: `scan()`'s detached detection task
    /// has independent cancellation from `loopTask`, so a detector that
    /// never notices cancellation must not be able to make `stop()` hang.
    /// Synchronization is entirely continuation/expectation-driven — the
    /// `timeout:` below is only a safety net bound on the assertion, never
    /// the mechanism proving promptness (a regressed `stop()` awaiting the
    /// detector directly would still hang past it).
    func testStopReturnsPromptlyWhileDetachedDetectionIsBlockedNonCooperatively() async {
        let detector = BlockingDetector()
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.start()
        await detector.waitUntilEntered() // the loop's first scan() is now blocked inside detect(now:)

        let stopReturned = expectation(description: "stop() returns while the detector is still blocked")
        Task {
            await monitor.stop()
            stopReturned.fulfill()
        }
        await fulfillment(of: [stopReturned], timeout: 5)

        // stop() returned without the detector ever cooperating — prove
        // the monitor's published state was never touched by the still-
        // in-flight (now merely canceled, not resolved) detection.
        let stateAfterStop = await monitor.state
        XCTAssertEqual(stateAfterStop.agents, [], "no scan has resolved yet, so state must remain untouched")
        let diagnosticAfterStop = await monitor.diagnostic
        XCTAssertNil(diagnosticAfterStop)

        // Now release the stale detector call and prove its result cannot
        // mutate state/diagnostic after the fact, then prove the monitor
        // is fully usable again afterward (no continuation left dangling,
        // no permanent lockout).
        let staleAgents = [activeAgent(id: "codex:/fixtures/stale.jsonl")]
        detector.release(with: staleAgents)

        // Drive a fresh, manual scan() to prove the monitor recovers.
        // scan() silently no-ops while `isScanning` is still held by the
        // stale, just-released call settling on the actor — so poll via
        // cooperative yields (never a wall-clock sleep) until the second
        // invocation actually lands, then arm its immediate result.
        let freshAgents = [activeAgent(id: "codex:/fixtures/fresh.jsonl")]
        detector.release(with: freshAgents) // arms the *next* call to return immediately
        while await detector.invocationCount < 2 {
            await monitor.scan()
            await Task.yield()
        }

        let finalState = await monitor.state
        XCTAssertEqual(finalState.agents, freshAgents, "only the fresh, post-stop scan may ever be published")
        XCTAssertNotEqual(finalState.agents, staleAgents, "the stale, pre-stop detection must never win")
    }

    /// Complements the previous test: proves that a *second* `start()`
    /// while the prior, canceled loop's detector call is still draining
    /// does not create an overlapping second detector invocation — the
    /// generation/`isScanning` isolation must hold even across a fresh
    /// loop, not just within the original one.
    func testStartAfterStopWhileDetectorStillDrainingNeverOverlaps() async {
        let detector = BlockingDetector()
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        await monitor.start()
        await detector.waitUntilEntered()

        await monitor.stop()

        // Immediately start a new loop while the first (canceled) call is
        // still parked inside detect(now:) — a naive implementation could
        // let this spawn a second concurrent detector invocation.
        await monitor.start()

        // Give the new loop's own scan() attempts a chance to run; they
        // must observe the still in-flight stale call and no-op rather
        // than invoke the detector a second time.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(detector.invocationCount, 1, "starting a new loop must never overlap with a still-draining prior detection")

        detector.release(with: [])
        await monitor.stop()
    }

    // MARK: - stop() also owns/cancels a directly-invoked manual scan

    /// `stop()` must not be scoped to loop-driven scans only: a caller
    /// that manages its own external scan cadence via bare `scan()` calls
    /// (e.g. `AppDelegate`'s own timer-driven monitor loop, which never
    /// calls `start()` at all) still relies on `stop()` to own and
    /// invalidate whatever scan is currently in flight at shutdown. This
    /// reproduces exactly that shape — a manual `scan()` call with no loop
    /// ever started — and proves `stop()` still cancels the detached
    /// detection and bumps `generation`, so the stale, non-cooperative
    /// detector's eventual result can never reach published state once
    /// `stop()` has returned, no matter how long that detector keeps
    /// running in the background afterward.
    func testStopWithNoLoopRunningStillInvalidatesAConcurrentManualScan() async {
        let detector = BlockingDetector()
        let monitor = AgentMonitor(detector: detector, clock: FixedClock(fixedMilliseconds: fixedNow))

        let manualScan = Task { await monitor.scan() }
        await detector.waitUntilEntered()

        // No loop was ever started, but `stop()` must still promptly
        // cancel/invalidate this directly-invoked, still in-flight scan.
        let stopReturned = expectation(description: "stop() returns promptly even though the manual scan's detector is still blocked")
        Task {
            await monitor.stop()
            stopReturned.fulfill()
        }
        await fulfillment(of: [stopReturned], timeout: 5)

        // Release the stale detector call and prove its result can never
        // mutate published state, since `stop()` already invalidated it.
        let staleAgents = [activeAgent(id: "codex:/fixtures/manual-stale.jsonl")]
        detector.release(with: staleAgents)
        await manualScan.value

        let state = await monitor.state
        XCTAssertEqual(state.agents, [], "a manual scan already in flight when stop() runs must never publish its result")
        let diagnostic = await monitor.diagnostic
        XCTAssertNil(diagnostic)
    }
}
