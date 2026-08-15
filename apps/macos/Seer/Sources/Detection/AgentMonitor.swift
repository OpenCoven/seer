import Foundation

/// Diagnostic ids `AgentMonitor` itself publishes (as opposed to ids
/// surfaced verbatim from a lower layer).
public enum AgentMonitorDiagnosticID {
    /// A `scan()` invocation's detector call threw. The previous
    /// successful `state.agents` is retained rather than replaced with an
    /// empty list, and this diagnostic is cleared automatically the next
    /// time a scan succeeds.
    public static let scanFailed = "monitor.scan.failed"
}

/// Abstraction over "sleep for N milliseconds between completed scans,"
/// injected so `AgentMonitor`'s three-second scan cadence is deterministic
/// and testable without ever waiting on real wall-clock time. Mirrors the
/// `HistoryScheduler` pattern in `HistoryStore.swift`.
public protocol AgentMonitorScheduler: Sendable {
    func sleep(milliseconds: Int64) async
}

/// Production `AgentMonitorScheduler`, backed by `Task.sleep`. Swallows
/// `CancellationError` silently (matching `RealTimeHistoryScheduler`) so a
/// cancelled sleep simply returns early rather than throwing out of the
/// monitor's scan loop.
public struct RealTimeAgentMonitorScheduler: AgentMonitorScheduler {
    public init() {}

    public func sleep(milliseconds: Int64) async {
        guard milliseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}

/// Runs `AgentDetecting.detect(now:)` on a fixed cadence, publishing the
/// merged `AgentMonitorState` and never letting two scans overlap. Ports the
/// resilience contract of `main/services/agent-detector.ts`'s consumer (the
/// state coordinator described in the standalone design spec): a failed
/// scan must never be reported as "no agents active," only as a retained
/// prior state plus a diagnostic.
///
/// An `actor` so `scan()`'s overlap guard (`isScanning`) and `state`/
/// `diagnostic` mutations are always serialized — see `scan()` for exactly
/// where detection itself runs off-actor.
public actor AgentMonitor {
    /// How long the loop sleeps *after* a scan completes (successfully or
    /// not) before starting the next one — never a fixed-rate timer that
    /// could stack up overlapping scans if a single scan runs long.
    public static let scanIntervalMilliseconds: Int64 = 3_000

    private let detector: any AgentDetecting
    private let clock: Clock
    private let scheduler: any AgentMonitorScheduler

    public private(set) var state: AgentMonitorState
    /// The most recent scan-failure diagnostic, or `nil` once a later scan
    /// has succeeded.
    public private(set) var diagnostic: Diagnostic?

    private var isScanning = false
    private var loopTask: Task<Void, Never>?
    /// The currently in-flight detached detection task, if any — tracked
    /// separately from `loopTask` specifically so `stop()` can cancel *it*
    /// directly. `Task.detached` work is not a child of `loopTask`, so
    /// cancelling `loopTask` alone never propagates to this task; without
    /// this reference `stop()` would have no way to signal cancellation to
    /// a detector that is currently running.
    private var activeDetection: Task<[ActiveAgent], Error>?
    /// Monotonically incremented by `stop()` (never by `scan()` itself).
    /// `scan()` captures the generation in effect when it starts and, once
    /// its detection resolves (successfully, by throwing, or by being
    /// cancelled), only applies the result to `state`/`diagnostic` if the
    /// generation is unchanged. This is what makes a stale result from a
    /// non-cooperative detector — one that keeps running well past
    /// `stop()` having already returned — provably unable to mutate
    /// published state: `stop()` bumps the generation *before* it returns,
    /// so no later-resolving scan from before that point can ever match.
    private var generation: UInt64 = 0

    public init(
        detector: any AgentDetecting,
        clock: Clock = SystemClock(),
        scheduler: any AgentMonitorScheduler = RealTimeAgentMonitorScheduler()
    ) {
        self.detector = detector
        self.clock = clock
        self.scheduler = scheduler
        self.state = AgentMonitorState(
            active: false,
            keepingAwake: false,
            keepAwakeMode: .system,
            agents: [],
            lastScanAt: 0
        )
    }

    /// Runs exactly one detection pass and applies its result as a single
    /// transition, unless a scan is already in flight — in which case this
    /// call returns immediately without invoking the detector again. Since
    /// `isScanning` is checked and set before this method's first
    /// suspension point, a concurrently-arriving `scan()` call is
    /// guaranteed to observe the flag already set (actor isolation runs
    /// this synchronous prologue to completion before yielding), so the
    /// detector is never invoked twice for overlapping calls.
    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        // Snapshot the generation in effect *before* detection starts.
        // `stop()` only ever increments `generation` (never `scan()`
        // itself), so a later `stop()` call racing this in-flight scan
        // deterministically invalidates the result this call is about to
        // await — see the generation check below.
        let myGeneration = generation
        defer { isScanning = false }

        let now = clock.nowMilliseconds()
        let detector = self.detector

        // Detection itself runs off this actor, in a detached,
        // utility-priority task. Only `Sendable` values are captured
        // (`detector` is a `Sendable` existential, `now` is an `Int64`) —
        // no actor-isolated mutable state crosses into the detached
        // closure. Awaiting the task's `.value` suspends this actor method
        // (letting other actor work, like a concurrent `scan()` call's
        // guard check, run in the meantime) without re-entering detection
        // logic on the actor itself.
        let detection = Task.detached(priority: .utility) {
            try await detector.detect(now: now)
        }
        // Recorded so `stop()` can cancel this specific detached task
        // directly. Since `isScanning` guarantees only one `scan()` call
        // ever runs at a time, this property is exclusively owned by this
        // call for its entire duration — nothing else writes it until this
        // call's `defer` below clears it.
        activeDetection = detection
        defer { activeDetection = nil }

        do {
            let agents = try await detection.value
            // A `stop()` that ran while this call was suspended above has
            // already cancelled `detection` and bumped `generation` — its
            // (possibly successful, possibly-thrown-CancellationError)
            // result must never reach `state`/`diagnostic` at this point,
            // regardless of how long the detector itself took to actually
            // notice the cancellation. This is what keeps a non-cooperative
            // detector's eventual, stale result from mutating published
            // state after `stop()` has already returned to its caller.
            guard generation == myGeneration else { return }
            state = AgentMonitorState(
                active: !agents.isEmpty,
                keepingAwake: state.keepingAwake,
                keepAwakeMode: state.keepAwakeMode,
                agents: agents,
                lastScanAt: now
            )
            diagnostic = nil
        } catch {
            guard generation == myGeneration else { return }
            // Intentionally leave `state` untouched: the last successful
            // agent list is retained rather than replaced by an empty
            // list, so a transient scan failure never falsely reports
            // every agent as idle.
            diagnostic = Diagnostic(
                id: AgentMonitorDiagnosticID.scanFailed,
                message: String(describing: error),
                occurredAt: now
            )
        }
    }

    /// Starts the periodic scan loop if it is not already running.
    /// Idempotent: calling `start()` again while a loop is already active
    /// is a no-op (it does not spawn a second concurrent loop).
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            // `weak self` avoids the loop task holding this actor alive
            // forever purely to keep looping — once every other strong
            // reference to the monitor is released, the loop simply stops
            // on its next iteration instead of creating a retain cycle.
            while !Task.isCancelled {
                guard let self else { return }
                await self.scan()
                guard !Task.isCancelled else { return }
                await self.sleepBetweenScans()
            }
        }
    }

    private func sleepBetweenScans() async {
        await scheduler.sleep(milliseconds: Self.scanIntervalMilliseconds)
    }

    /// Stops the periodic scan loop if one is running, and — regardless of
    /// whether a loop is running at all — always cancels any currently
    /// in-flight detached detection and bumps `generation`, so a scan
    /// already in flight can never publish its result to `state`/
    /// `diagnostic` once this method returns. This is deliberately *not*
    /// scoped to loop-driven scans only: a caller that manages its own
    /// external scan cadence via bare `scan()` calls (e.g. `AppDelegate`,
    /// which performs an initial scan directly and then dispatches
    /// further ticks from its own timer loop, never calling `start()` at
    /// all) must still be able to rely on `stop()` to own and invalidate
    /// that in-flight work at shutdown — otherwise a non-cooperative
    /// detector could let a stale scan apply after the caller believes
    /// shutdown is complete.
    ///
    /// Cancels the loop task *and* the currently in-flight detached
    /// detection directly, but deliberately never awaits either — a
    /// non-cooperative detector (one that never checks `Task.isCancelled`)
    /// must never be able to make `stop()` hang. `generation` is bumped
    /// first so that if a scan is currently in flight, its eventual result
    /// (success, thrown error, or `CancellationError`) can never be
    /// applied to `state`/`diagnostic` once this method returns — see the
    /// generation check in `scan()`.
    ///
    /// `loopTask` is cleared immediately (not from within the loop itself)
    /// so `start()` can begin a fresh loop right away; the old loop's task
    /// keeps running in the background purely to notice its own
    /// cancellation and exit — it never touches `loopTask` again, so it
    /// can never clobber a newer loop's identity. Overlap between the old,
    /// still-draining detection and any new loop's scans is prevented by
    /// `isScanning`, which the old `scan()` call continues to hold until
    /// its detection actually resolves, regardless of how long that takes.
    ///
    /// Idempotent: calling `stop()` repeatedly, or when no loop is
    /// running, is always safe — the generation bump/detection
    /// cancellation simply have no further effect once nothing is in
    /// flight.
    public func stop() async {
        generation &+= 1
        activeDetection?.cancel()
        activeDetection = nil
        if let loopTask {
            loopTask.cancel()
            self.loopTask = nil
        }
    }
}
