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

        do {
            let agents = try await detection.value
            state = AgentMonitorState(
                active: !agents.isEmpty,
                keepingAwake: state.keepingAwake,
                keepAwakeMode: state.keepAwakeMode,
                agents: agents,
                lastScanAt: now
            )
            diagnostic = nil
        } catch {
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

    /// Stops the periodic scan loop if one is running, cancelling it and
    /// awaiting its exit so no detached loop work outlives this call.
    /// Idempotent: calling `stop()` when no loop is running is a no-op.
    public func stop() async {
        guard let loopTask else { return }
        loopTask.cancel()
        await loopTask.value
        self.loopTask = nil
    }
}
