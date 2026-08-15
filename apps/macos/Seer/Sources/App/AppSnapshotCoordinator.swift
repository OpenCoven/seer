import Foundation

/// Diagnostic ids `AppSnapshotCoordinator` publishes directly (distinct
/// from ids surfaced verbatim, or via `StorageDiagnosticAlias`, from a
/// lower layer's own `lastDiagnostic`).
public enum CoordinatorDiagnosticID {
    /// Emitted (upserted) whenever `AppSnapshotCoordinator`'s own update
    /// check — at startup (`makeAtStartup`), via the explicit
    /// `checkForUpdates(force:)` entry point, or via
    /// `setIncludePrereleaseUpdates(_:)`'s forced re-check — throws a
    /// typed `UpdateCheckError`; cleared again the moment a subsequent
    /// check succeeds.
    public static let updatesCheckFailed = "updates.check.failed"
}

/// A tiny reference-type box breaking the retain cycle
/// `AppSnapshotCoordinator.makeAtStartupWithScheduledUpdates(...)` would
/// otherwise create between a coordinator and the `UpdateScheduler` it
/// owns. Captured strongly by the scheduler's per-tick closures, but only
/// ever holds `coordinator` weakly, set once the coordinator itself has
/// actually finished constructing. `@unchecked Sendable`: `coordinator` is
/// a `@MainActor`-isolated class, and every access to it happens through
/// an `await` at the isolated member itself (`.snapshot`,
/// `.checkForUpdates(force:)`) — this box never touches any of its
/// non-isolated state concurrently.
private final class CoordinatorWeakBox: @unchecked Sendable {
    weak var coordinator: AppSnapshotCoordinator?
}

/// Remaps the `storage.settings.*` ids `AtomicJSONStore` always emits
/// (regardless of which document type is actually being stored) into
/// their `storage.history.*` counterparts, for diagnostics that actually
/// came from `HistoryStore.lastDiagnostic` rather than `SettingsStore`'s.
///
/// `AtomicJSONStore<Document>` has no notion of "this instance happens to
/// store history, not settings" — its `StorageDiagnosticID` constants are
/// hardcoded with the `settings` word. Without this remap, a corrupt
/// history file and a corrupt settings file would both surface as the
/// exact same `storage.settings.corrupt` id, indistinguishable to the
/// renderer and colliding under the coordinator's per-id dedupe.
enum StorageDiagnosticAlias {
    private static let historyIDsByRawID: [String: String] = [
        StorageDiagnosticID.corrupt: "storage.history.corrupt",
        StorageDiagnosticID.unsupportedVersion: "storage.history.unsupported-version",
        StorageDiagnosticID.readFailed: "storage.history.read-failed"
    ]

    /// Returns `diagnostic` with its id remapped to the `storage.history.*`
    /// equivalent if it is one of the three ids `AtomicJSONStore` can
    /// report from `load()`, preserving `message`/`occurredAt` exactly.
    /// Any other id (e.g. `storage.settings.too-large`, which has no
    /// required history counterpart in the plan's stable id list) passes
    /// through unchanged.
    static func remapForHistory(_ diagnostic: Diagnostic) -> Diagnostic {
        guard let mappedID = historyIDsByRawID[diagnostic.id] else { return diagnostic }
        return Diagnostic(id: mappedID, message: diagnostic.message, occurredAt: diagnostic.occurredAt)
    }

    /// Every diagnostic id `HistoryStore.lastDiagnostic` can ever surface
    /// once mapped through `remapForHistory(_:)` — the three
    /// `storage.history.*` remapped ids plus `HistoryDiagnosticID
    /// .persistFailed` (which needs no remapping, being already history-
    /// specific). Used by `AppSnapshotCoordinator.reconcileHistoryDiagnostic`
    /// to know exactly which ids to clear before conditionally re-upserting
    /// whichever one (if any) is currently current, without duplicating
    /// this id list at each call site.
    static var historyDiagnosticIDs: Set<String> {
        Set(historyIDsByRawID.values).union([HistoryDiagnosticID.persistFailed])
    }
}

/// Where `AppSnapshotCoordinator` pushes every published `AppSnapshot`.
/// Exists so this task's coordinator has no direct dependency on WKWebView
/// or any other UI technology — Task 10 introduces the real
/// WKWebView-backed conformance; tests use a simple collecting fake.
/// `@MainActor` to match the coordinator's own isolation: every `emit`
/// call happens synchronously from a main-actor transition, never from a
/// background thread.
@MainActor
public protocol AppSnapshotRendererSink: AnyObject {
    func emit(_ snapshot: AppSnapshot)
}

/// The `AppSnapshotCoordinator` operations Task 12's app shell (`AppDelegate`,
/// its scan loop, and orderly termination) depends on. Abstracted behind a
/// protocol — rather than the shell depending on the concrete `final class`
/// directly — purely for testability: `AppLifecycleTests` can substitute a
/// scripted fake coordinator to assert exactly when the shell scans, applies
/// results, and shuts down, without standing up a real `SettingsStore`/
/// `HistoryStore`/`PowerAssertionService`/`UpdateService` stack for every
/// lifecycle test. `AppSnapshotCoordinator` conforms via the extension
/// immediately below; production code always uses that real conformance.
@MainActor
public protocol AppSnapshotCoordinating: AnyObject {
    var snapshot: AppSnapshot { get }
    func applyScan(_ agents: [ActiveAgent], scannedAt: Int64) async
    func applyScanFailure(occurredAt: Int64) async
    func setKeepAwakeMode(_ mode: KeepAwakeMode) async throws
    func clearHistory() async throws
    @discardableResult
    func checkForUpdates(force: Bool) async -> Bool
    func setIncludePrereleaseUpdates(_ value: Bool) async throws
    @discardableResult
    func openLatestRelease() async -> Bool
    func performStartupUpdateCheckAndStartScheduler() async
    func shutdown() async throws
}

extension AppSnapshotCoordinator: AppSnapshotCoordinating {}

/// The single main-actor authority for Seer's visible state. Owns an
/// immutable-per-publication `AppSnapshot`, cooperates with `SettingsStore`
/// and `HistoryStore` (both already independently testable via their own
/// injectable file systems — no additional adapter layer is needed for
/// them) and a `PowerAssertionService`, and pushes every completed
/// transition to an injected `AppSnapshotRendererSink` exactly once.
///
/// Every public entry point (`applyScan`, `applyScanFailure`,
/// `setKeepAwakeMode`, `clearHistory`, `shutdown`) acquires `gate` — the
/// same FIFO `AsyncGate` pattern `SettingsStore`/`HistoryStore` use — for
/// its *entire* awaited duration, including every underlying actor round
/// trip. Without this, two overlapping calls (each necessarily `async`
/// because they await `SettingsStore`/`HistoryStore`, both actors) could
/// interleave at a suspension point despite both nominally running on the
/// main actor, letting an older call's transition publish *after* a newer
/// one's and silently overwrite it. `gate` makes every transition run to
/// completion, in invocation order, before the next queued one starts.
@MainActor
public final class AppSnapshotCoordinator {
    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let power: PowerAssertionService
    private let renderer: any AppSnapshotRendererSink
    private let clock: Clock
    private let updateService: any UpdateChecking
    private let updateScheduler: any UpdateSchedulerControlling

    /// Serializes every public entry point's full transition — see the
    /// type documentation above.
    private let gate = AsyncGate()

    /// Set synchronously, *before* `shutdown()` ever awaits `gate`'s
    /// (intentionally non-cancellable — see `AsyncGate`) queue, so it is
    /// visible to every other call the instant `shutdown()` begins,
    /// regardless of how long `shutdown()` itself then has to wait for
    /// its own turn at the gate. A scheduler tick's `checkForUpdates`
    /// call is always dispatched — and therefore always already queued
    /// (or running) on `gate` — strictly *before* `shutdown()`'s own
    /// `gate.acquire()` call can even be issued, since `updateScheduler
    /// .stop()` only cancels *future* ticks, never one already past its
    /// cancellation check and blocked on `gate`. Were this flag instead
    /// set only from inside `performShutdown()` (i.e. after `shutdown()`
    /// has itself acquired `gate`), such an already-queued tick would
    /// always be serviced *first* (FIFO) and would have no way to learn
    /// shutdown was ever requested. Checked by both `performCheckForUpdates`
    /// and `performSetIncludePrereleaseUpdates` *twice* each: immediately
    /// after acquiring `gate` — so any check or tray checkbox action,
    /// scheduled or explicit, only granted the gate once shutdown has
    /// already begun is skipped entirely, before ever touching the
    /// network — and again immediately after `updateService.check(force:)`
    /// / `updateService.setIncludePrerelease(_:)` returns/throws, before
    /// any snapshot/diagnostic mutation or publish, since this flag can
    /// just as easily flip `true` *during* that await (i.e. a call already
    /// granted the gate and genuinely in flight when shutdown begins) as
    /// before it. Without that second check, such an in-flight call would
    /// resume — after `shutdown()`'s own queued `gate.acquire()` call has
    /// already run `performShutdown()` to completion and published its
    /// final snapshot — and go on to publish its own (now moot) result on
    /// top of that already-final state. A `checkForUpdates` or
    /// `setIncludePrereleaseUpdates` call already running (or already
    /// queued) *before* `shutdown()` begins is completely unaffected by
    /// either check, since it observes this flag still `false` throughout.
    private var isShutDown = false

    public private(set) var snapshot: AppSnapshot

    /// Plain, non-async initializer: takes an already-computed
    /// `initialSnapshot` rather than loading anything itself, so
    /// constructing a coordinator never awaits. Use `makeAtStartup(...)`
    /// to seed that initial snapshot from `settingsStore`/`historyStore`'s
    /// real loaded state plus startup diagnostics.
    public init(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        power: PowerAssertionService,
        renderer: any AppSnapshotRendererSink,
        clock: Clock,
        initialSnapshot: AppSnapshot,
        updateService: any UpdateChecking,
        updateScheduler: any UpdateSchedulerControlling
    ) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.power = power
        self.renderer = renderer
        self.clock = clock
        self.snapshot = initialSnapshot
        self.updateService = updateService
        self.updateScheduler = updateScheduler
    }

    /// Async factory: loads `settingsStore`/`historyStore` exactly once
    /// each, seeds the initial `AppSnapshot` from their loaded values, and
    /// folds in every startup diagnostic (a corrupt/future-version/
    /// unreadable settings or history file) with stable, deduplicated,
    /// history-remapped ids — so the renderer's diagnostics region can
    /// visibly report a startup failure the very first time it reads
    /// `snapshot`, without waiting for any scan.
    ///
    /// Also performs Seer's one-time startup update check: an *unforced*
    /// `updateService.check(force: false)` (so a very recent check, e.g.
    /// from the previous run, still respects the 24-hour gate rather than
    /// re-hitting the network every launch), whose resulting `UpdateState`
    /// seeds `snapshot.update` directly — never left at a stale hardcoded
    /// empty value regardless of what was actually last known. A failed
    /// startup check folds a `CoordinatorDiagnosticID.updatesCheckFailed`
    /// diagnostic into the same startup diagnostics list as the settings/
    /// history ones above (and `snapshot.update` falls back to whatever
    /// `updateService.currentState()` reports), rather than throwing or
    /// silently losing the failure. This mirrors, but is distinct from,
    /// `updateScheduler`'s own periodic background checks: the scheduler
    /// intentionally does *not* check immediately on a fresh install (its
    /// first tick is due a full 24h out — see `UpdateScheduler`), so this
    /// explicit startup check is what actually surfaces an already-known
    /// or newly-discovered update the moment the app launches. Finally,
    /// `updateScheduler` itself is started (never left uncreated/unused)
    /// so periodic checks continue for as long as the coordinator lives;
    /// `shutdown()` is responsible for stopping it again.
    public static func makeAtStartup(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        power: PowerAssertionService,
        renderer: any AppSnapshotRendererSink,
        clock: Clock,
        appVersion: String,
        updateService: any UpdateChecking,
        updateScheduler: any UpdateSchedulerControlling
    ) async -> AppSnapshotCoordinator {
        let coordinator = await makeCoordinatorWithoutStartingScheduler(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: renderer,
            clock: clock,
            appVersion: appVersion,
            updateService: updateService,
            updateScheduler: updateScheduler
        )

        await updateScheduler.start()

        return coordinator
    }

    /// The shared first half of `makeAtStartup(...)`/
    /// `makeAtStartupWithScheduledUpdates(...)`: loads `settingsStore`/
    /// `historyStore`, folds in startup diagnostics, runs the one-time
    /// startup update check, and constructs the coordinator — but,
    /// deliberately, does **not** start `updateScheduler`. Split out so
    /// `makeAtStartupWithScheduledUpdates(...)` can register the
    /// coordinator with its scheduler's callback closures *before* the
    /// scheduler's background loop ever starts, rather than racing an
    /// already-started scheduler task against that registration.
    private static func makeCoordinatorWithoutStartingScheduler(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        power: PowerAssertionService,
        renderer: any AppSnapshotRendererSink,
        clock: Clock,
        appVersion: String,
        updateService: any UpdateChecking,
        updateScheduler: any UpdateSchedulerControlling
    ) async -> AppSnapshotCoordinator {
        let settingsResult = await settingsStore.load()
        _ = await historyStore.load()
        let historyDiagnostic = await historyStore.lastDiagnostic
        let historyStats = await historyStore.stats()

        var diagnostics: [Diagnostic] = []
        if let settingsDiagnostic = settingsResult.diagnostic {
            diagnostics.append(settingsDiagnostic)
        }
        if let historyDiagnostic {
            diagnostics.append(StorageDiagnosticAlias.remapForHistory(historyDiagnostic))
        }

        let monitor = AgentMonitorState(
            active: false,
            keepingAwake: false,
            keepAwakeMode: settingsResult.value.keepAwakeMode,
            agents: [],
            lastScanAt: 0
        )

        let updateState: UpdateState
        do {
            updateState = try await updateService.check(force: false)
        } catch {
            updateState = await updateService.currentState()
            diagnostics.append(Diagnostic(
                id: CoordinatorDiagnosticID.updatesCheckFailed,
                message: "Startup update check failed: \(error)",
                occurredAt: clock.nowMilliseconds()
            ))
        }

        let snapshot = AppSnapshot(
            monitor: monitor,
            history: historyStats,
            update: updateState,
            diagnostics: dedupedByID(diagnostics),
            appVersion: appVersion
        )

        return AppSnapshotCoordinator(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: renderer,
            clock: clock,
            initialSnapshot: snapshot,
            updateService: updateService,
            updateScheduler: updateScheduler
        )
    }

    /// Builds a fully wired `AppSnapshotCoordinator` whose periodic,
    /// scheduled (non-forced) update checks route through *this*
    /// coordinator's own `checkForUpdates(force: false)` — publishing the
    /// resulting `UpdateState` in a single atomic transition and
    /// surfacing any failure as `CoordinatorDiagnosticID.updatesCheckFailed`
    /// — rather than a bare `UpdateService.check(force:)` call whose
    /// result would be silently discarded. This is the composition every
    /// real caller should use instead of hand-assembling an
    /// `UpdateScheduler` bound directly to `updateService` and passing it
    /// to `makeAtStartup(...)` verbatim, which would bypass the
    /// coordinator's transition/publish/diagnostic behavior entirely for
    /// every *scheduled* check (an explicit `checkForUpdates(force:)` call
    /// — e.g. from the `updates.check` bridge command — is already
    /// unaffected either way, since it always calls the coordinator
    /// directly).
    ///
    /// Loads `settingsStore`/`historyStore` exactly once each (never
    /// re-loaded by any later step) and folds in every startup diagnostic,
    /// exactly like `makeCoordinatorWithoutStartingScheduler(...)` above —
    /// but, deliberately, performs **no** update-check network request and
    /// does **not** start the scheduler: `snapshot.update` is seeded purely
    /// from `updateService.currentState()`'s already-cached value. Callers
    /// (in production, `AppDelegate.bootstrapProduction()`) must run the
    /// app shell's own initial agent scan and start its recurring monitor
    /// loop first, and only then call the returned coordinator's
    /// `performStartupUpdateCheckAndStartScheduler()` to perform Seer's
    /// one-time startup check and start the periodic scheduler — so a slow
    /// or hanging network request can never delay the very first thing the
    /// menu bar icon/panel need to show.
    ///
    /// Internally breaks the coordinator/scheduler reference cycle this
    /// wiring would otherwise create: the coordinator strongly owns the
    /// scheduler (so `shutdown()` can stop it), and the scheduler's
    /// per-tick callback needs to call back into the coordinator. A small
    /// weak box mediates this — the scheduler's closures capture the box
    /// strongly, but the box only ever holds `coordinator` *weakly*, set
    /// once construction has actually completed — so neither the
    /// coordinator nor the scheduler ever keeps the other alive past its
    /// own natural lifetime. The box is populated before this factory
    /// returns, so the scheduler's very first background tick (only
    /// possible once a later `performStartupUpdateCheckAndStartScheduler()`
    /// call actually starts it) can never observe an unregistered (`nil`)
    /// coordinator.
    public static func makeAtStartupWithScheduledUpdates(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        power: PowerAssertionService,
        renderer: any AppSnapshotRendererSink,
        clock: Clock,
        appVersion: String,
        updateService: any UpdateChecking,
        sleeper: Sleeper = TaskSleeper()
    ) async -> AppSnapshotCoordinator {
        let startupSnapshot = await loadStartupSnapshot(
            settingsStore: settingsStore,
            historyStore: historyStore,
            updateService: updateService,
            appVersion: appVersion
        )

        return makeWithScheduledUpdates(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: renderer,
            clock: clock,
            updateService: updateService,
            sleeper: sleeper,
            startupSnapshot: startupSnapshot
        )
    }

    /// The shared first half of `makeAtStartupWithScheduledUpdates(...)`
    /// above: loads `settingsStore`/`historyStore` exactly once each,
    /// folds in every startup diagnostic (a corrupt/future-version/
    /// unreadable settings or history file, plus any caller-supplied
    /// `extraDiagnostics` — e.g. `AppDelegate.bootstrapProduction()`
    /// folding in a failure to resolve its own Application Support
    /// directory, rather than aborting bootstrap silently) with stable,
    /// deduplicated, history-remapped ids, and returns the resulting
    /// initial `AppSnapshot` — with `update` seeded purely from
    /// `updateService.currentState()`'s already-cached value, never a
    /// fresh network check (see `makeAtStartupWithScheduledUpdates`'s own
    /// documentation above for why).
    ///
    /// Exposed as its own entry point — distinct from
    /// `makeAtStartupWithScheduledUpdates(...)`, which simply calls this
    /// and then `makeWithScheduledUpdates(...)` in sequence — so
    /// `AppDelegate.bootstrapProduction()` can `await` exactly this load
    /// *before* ever constructing any settings/history-dependent UI
    /// (panel, status item, bridge): the app's required launch order is
    /// accessory activation, then this load, then the coordinator/bridge/
    /// panel/status item, in that order. Never called a second time for
    /// the same store by any later step.
    public static func loadStartupSnapshot(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        updateService: any UpdateChecking,
        appVersion: String,
        extraDiagnostics: [Diagnostic] = []
    ) async -> AppSnapshot {
        let settingsResult = await settingsStore.load()
        _ = await historyStore.load()
        let historyDiagnostic = await historyStore.lastDiagnostic
        let historyStats = await historyStore.stats()

        var diagnostics = extraDiagnostics
        if let settingsDiagnostic = settingsResult.diagnostic {
            diagnostics.append(settingsDiagnostic)
        }
        if let historyDiagnostic {
            diagnostics.append(StorageDiagnosticAlias.remapForHistory(historyDiagnostic))
        }

        let monitor = AgentMonitorState(
            active: false,
            keepingAwake: false,
            keepAwakeMode: settingsResult.value.keepAwakeMode,
            agents: [],
            lastScanAt: 0
        )

        return AppSnapshot(
            monitor: monitor,
            history: historyStats,
            update: await updateService.currentState(),
            diagnostics: dedupedByID(diagnostics),
            appVersion: appVersion
        )
    }

    /// The shared second half of `makeAtStartupWithScheduledUpdates(...)`
    /// above: builds the fully wired coordinator/scheduler pair from an
    /// already-computed `startupSnapshot` — see `loadStartupSnapshot(...)`
    /// above — without ever loading `settingsStore`/`historyStore` again.
    /// Deliberately synchronous (no `await` anywhere in its body): every
    /// step it performs — allocating the coordinator/scheduler weak box,
    /// constructing `UpdateScheduler`, and the coordinator's own plain
    /// (non-async) initializer — is itself synchronous; only the
    /// *loading* step this omits ever needs to await anything. Exists so
    /// `AppDelegate.bootstrapProduction()` can build settings/history-
    /// dependent UI (panel/status item) from `startupSnapshot` first, and
    /// only then call this to finish constructing the coordinator itself.
    static func makeWithScheduledUpdates(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        power: PowerAssertionService,
        renderer: any AppSnapshotRendererSink,
        clock: Clock,
        updateService: any UpdateChecking,
        sleeper: Sleeper = TaskSleeper(),
        startupSnapshot: AppSnapshot
    ) -> AppSnapshotCoordinator {
        let box = CoordinatorWeakBox()
        let scheduler = UpdateScheduler(
            clock: clock,
            sleeper: sleeper,
            lastCompletedCheckAt: { await box.coordinator?.snapshot.update.lastCheckedAt },
            performScheduledCheck: { await box.coordinator?.checkForUpdates(force: false) ?? true }
        )

        let coordinator = AppSnapshotCoordinator(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: renderer,
            clock: clock,
            initialSnapshot: startupSnapshot,
            updateService: updateService,
            updateScheduler: scheduler
        )

        box.coordinator = coordinator
        return coordinator
    }

    /// Performs Seer's one-time startup update check (unforced —
    /// `checkForUpdates(force: false)`, so a very recent check still
    /// respects the 24-hour gate) and starts the periodic `updateScheduler`
    /// — the two steps `makeAtStartupWithScheduledUpdates(...)` above
    /// deliberately defers out of construction. Must only be called once
    /// the app shell's own initial agent scan has already applied and its
    /// recurring monitor loop has already started, so a slow/hanging
    /// startup network check can never delay either of those.
    ///
    /// Rechecks `isShutDown` immediately after `checkForUpdates(force:)`
    /// returns and *before* ever calling `updateScheduler.start()`.
    /// `checkForUpdates(force:)` genuinely awaits (acquiring `gate`, then
    /// the network round-trip itself), so `shutdown()` — which flags
    /// `isShutDown` and calls `updateScheduler.stop()` synchronously,
    /// ahead of its own `gate.acquire()` call, precisely so it need not
    /// wait for whatever else is already queued or in flight — can fully
    /// complete on some other concurrent caller entirely within that
    /// window. Without this recheck, this call would resume from its own
    /// `checkForUpdates(force:)` await and unconditionally start the
    /// scheduler back up, undoing a shutdown that had already stopped it.
    /// Reads `isShutDown` directly (no additional `gate` acquisition):
    /// once `shutdown()` has set it, it can only ever have been set on
    /// this same main actor, synchronously, with no way to un-set it
    /// again — so a single read here needs no further serialization to be
    /// race-free.
    public func performStartupUpdateCheckAndStartScheduler() async {
        await checkForUpdates(force: false)
        guard !isShutDown else { return }
        await updateScheduler.start()
    }

    // MARK: - Monitor scan results

    /// Applies one completed, successful scan as a single atomic
    /// transition: monitor `active` becomes `!agents.isEmpty`, the power
    /// assertion is created/replaced/released to match (using the
    /// currently selected mode), `HistoryStore` records the *actual*
    /// resulting state (never the merely-desired one), and the rebuilt
    /// snapshot is emitted exactly once. Clears any prior
    /// `monitor.scan.failed` diagnostic (a completed scan, by definition,
    /// succeeded).
    public func applyScan(_ agents: [ActiveAgent], scannedAt: Int64) async {
        await gate.acquire()
        await performApplyScan(agents, scannedAt: scannedAt)
        await gate.release()
    }

    private func performApplyScan(_ agents: [ActiveAgent], scannedAt: Int64) async {
        let desiredActive = !agents.isEmpty
        // Read the desired mode from `settingsStore.current` — the
        // durably persisted source of truth — never from
        // `snapshot.monitor.keepAwakeMode`. The latter is the last
        // *effective* mode a power call actually settled on, which after
        // a mode-replacement failure in `setKeepAwakeMode` stays pinned
        // to the old mode even though the new one was already
        // successfully persisted. Reading the desired mode from
        // `snapshot.monitor` there would make every subsequent scan keep
        // "retrying" the stale old mode forever instead of the actually
        // requested one; reading it from `settingsStore.current` instead
        // means the very next scan retries the real desired mode, and
        // recovers (clearing `PowerDiagnosticID.assertionFailed`) the
        // moment the backend accepts it.
        let requestedMode = await settingsStore.current.keepAwakeMode

        var idsToClear: Set<String> = [AgentMonitorDiagnosticID.scanFailed]
        var upserts: [Diagnostic] = []
        let (keepingAwake, effectiveMode) = applyDesiredPowerState(
            active: desiredActive,
            mode: requestedMode,
            occurredAt: scannedAt,
            idsToClear: &idsToClear,
            upserts: &upserts
        )

        let monitorState = AgentMonitorState(
            active: desiredActive,
            keepingAwake: keepingAwake,
            keepAwakeMode: effectiveMode,
            agents: agents,
            lastScanAt: scannedAt
        )

        await historyStore.record(monitorState)
        await reconcileHistoryDiagnostic(idsToClear: &idsToClear, upserts: &upserts)
        let historyStats = await historyStore.stats()

        publish(monitor: monitorState, history: historyStats, clearing: idsToClear, upserting: upserts)
    }

    /// Applies one completed, *failed* scan: retains every previous
    /// monitor field (agents, keep-awake state/mode, active flag,
    /// `lastScanAt`) untouched — a scan failure must never be
    /// misinterpreted as "zero agents active," which would falsely
    /// deactivate the power assertion and close the current history
    /// session — and adds/refreshes the `monitor.scan.failed` diagnostic.
    /// The next successful `applyScan` clears it.
    public func applyScanFailure(occurredAt: Int64) async {
        await gate.acquire()
        performApplyScanFailure(occurredAt: occurredAt)
        await gate.release()
    }

    private func performApplyScanFailure(occurredAt: Int64) {
        let diagnostic = Diagnostic(
            id: AgentMonitorDiagnosticID.scanFailed,
            message: "Agent scan failed; retaining the last known agent state.",
            occurredAt: occurredAt
        )
        publish(monitor: snapshot.monitor, history: snapshot.history, clearing: [], upserting: [diagnostic])
    }

    // MARK: - Mode changes

    /// Persists `mode` before publishing anything (matching
    /// `SettingsStore.setKeepAwakeMode`'s own persist-then-publish
    /// contract), then — if the monitor currently has agents active —
    /// updates the live power assertion to the new mode. The mode this
    /// coordinator actually publishes is always read back from
    /// `settingsStore.current` *after* the persist attempt, never assumed
    /// from the requested value: a `StorageError.durabilityUncertain`
    /// throw still leaves the new value durably committed and cached, so
    /// blindly reverting to the old mode in that case would itself be a
    /// lie, while an ordinary write failure leaves `current` at the old
    /// mode, so nothing "success-shaped" is ever falsely published. The
    /// original thrown error (if any) is always rethrown to the caller
    /// after the resulting state is published, so the failure remains
    /// visible synchronously as well as through the diagnostics list.
    ///
    /// A persist failure here is never reported under an invented
    /// coordinator-specific diagnostic id — Task 9's stable diagnostic
    /// vocabulary has no such id. If `settingsStore.lastDiagnostic` is
    /// already non-nil (e.g. a load-time `storage.settings.read-failed`/
    /// `.unsupported-version` diagnostic explains *why* every write is
    /// failing), that existing approved diagnostic is preserved/refreshed
    /// instead; otherwise (an ordinary transient write failure with no
    /// accompanying diagnostic) none is added — the thrown error alone
    /// still carries the failure to the caller.
    public func setKeepAwakeMode(_ mode: KeepAwakeMode) async throws {
        await gate.acquire()
        do {
            try await performSetKeepAwakeMode(mode)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performSetKeepAwakeMode(_ requestedMode: KeepAwakeMode) async throws {
        var settingsError: Error?
        do {
            try await settingsStore.setKeepAwakeMode(requestedMode)
        } catch {
            settingsError = error
        }

        let actualMode = await settingsStore.current.keepAwakeMode
        let monitor = snapshot.monitor

        var idsToClear: Set<String> = []
        var upserts: [Diagnostic] = []

        // Always reconciles power against `monitor.active`, even when it
        // is `false` and no backend call is expected: this is what lets a
        // mode change also self-heal a previously degraded state (e.g. an
        // earlier scan's deactivate-release failure left an assertion
        // lingering while `monitor.active` had already gone `false`) —
        // `PowerAssertionService.setDesired(active: false, ...)` is a safe
        // idempotent no-op whenever nothing is actually left active.
        let (keepingAwake, effectiveMode) = applyDesiredPowerState(
            active: monitor.active,
            mode: actualMode,
            occurredAt: clock.nowMilliseconds(),
            idsToClear: &idsToClear,
            upserts: &upserts
        )

        if settingsError != nil, let existingDiagnostic = await settingsStore.lastDiagnostic {
            upserts.append(existingDiagnostic)
        }

        let updatedMonitor = AgentMonitorState(
            active: monitor.active,
            keepingAwake: keepingAwake,
            keepAwakeMode: effectiveMode,
            agents: monitor.agents,
            lastScanAt: monitor.lastScanAt
        )

        await historyStore.record(updatedMonitor)
        await reconcileHistoryDiagnostic(idsToClear: &idsToClear, upserts: &upserts)
        let historyStats = await historyStore.stats()

        publish(monitor: updatedMonitor, history: historyStats, clearing: idsToClear, upserting: upserts)

        if let settingsError {
            throw settingsError
        }
    }

    // MARK: - History clear

    /// Clears history via `HistoryStore.clearOrThrow()` — awaiting
    /// persistence rather than the fire-and-forget-shaped `clear()` —
    /// and republishes exactly once either way. `HistoryStore.clear()`'s
    /// documented contract never rolls back the in-memory reset on a
    /// failed persist, so even on failure the snapshot published here
    /// reflects the *actual* (now-empty) in-memory history plus a visible
    /// diagnostic; the original error is still rethrown afterward so the
    /// immediate caller (e.g. a bridge promise) also observes the failure
    /// synchronously.
    public func clearHistory() async throws {
        await gate.acquire()
        do {
            try await performClearHistory()
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performClearHistory() async throws {
        do {
            let stats = try await historyStore.clearOrThrow()
            publish(monitor: snapshot.monitor, history: stats, clearing: [HistoryDiagnosticID.persistFailed], upserting: [])
        } catch let error as StorageError {
            let stats = await historyStore.stats()
            let diagnostic = Diagnostic(
                id: HistoryDiagnosticID.persistFailed,
                message: "Failed to persist cleared history: \(error)",
                occurredAt: clock.nowMilliseconds()
            )
            publish(monitor: snapshot.monitor, history: stats, clearing: [], upserting: [diagnostic])
            throw error
        }
    }

    // MARK: - Updates

    /// Runs one update check via the owned `UpdateService` and publishes
    /// its resulting `UpdateState` into a single atomic transition — the
    /// same `gate`-serialized, publish-once-per-call pattern every other
    /// entry point above uses. On success, clears any previously visible
    /// `CoordinatorDiagnosticID.updatesCheckFailed` diagnostic; on a
    /// thrown `UpdateCheckError`, upserts a fresh one (with the update
    /// state falling back to `updateService.currentState()`, which itself
    /// is guaranteed unchanged by a failed check) instead of silently
    /// dropping the failure. Used both by the `updates.check` bridge
    /// command (with `force: true`, matching an explicit user request)
    /// and — with `force: false` — as the basis of `makeAtStartup`'s
    /// startup check. Returns whether the check succeeded (`true`) or
    /// threw (`false`); `makeAtStartupWithScheduledUpdates` routes this
    /// return value straight back to `UpdateScheduler` so a failed
    /// scheduled attempt reschedules a bounded 24h from its own
    /// completion instead of recomputing from a stale, already-past
    /// `lastCheckedAt` (see `UpdateScheduler.runLoop`).
    @discardableResult
    public func checkForUpdates(force: Bool) async -> Bool {
        await gate.acquire()
        let succeeded = await performCheckForUpdates(force: force)
        await gate.release()
        return succeeded
    }

    private func performCheckForUpdates(force: Bool) async -> Bool {
        // Granted the gate only after `shutdown()` has already begun (see
        // `isShutDown`'s documentation): never network-check or publish
        // once shutdown is underway, however long this call was queued.
        guard !isShutDown else { return false }

        var idsToClear: Set<String> = []
        var upserts: [Diagnostic] = []
        let updateState: UpdateState
        let succeeded: Bool
        do {
            updateState = try await updateService.check(force: force)
            idsToClear.insert(CoordinatorDiagnosticID.updatesCheckFailed)
            succeeded = true
        } catch {
            updateState = await updateService.currentState()
            upserts.append(Diagnostic(
                id: CoordinatorDiagnosticID.updatesCheckFailed,
                message: "Update check failed: \(error)",
                occurredAt: clock.nowMilliseconds()
            ))
            succeeded = false
        }

        // `isShutDown` is only checked once, above, *before* the
        // `updateService.check(force:)` await — but `shutdown()` can flip
        // it `true` at any point during that await (it is set
        // synchronously, ahead of `shutdown()`'s own `gate.acquire()` call,
        // specifically so an already-*queued* check observes it the
        // moment it is granted the gate — see `isShutDown`'s
        // documentation). That guards a check still *queued* behind
        // `gate` when shutdown begins, but not one that had already been
        // granted the gate and was genuinely in flight inside
        // `updateService.check(force:)` at that moment: without
        // re-checking here, such a call would resume — after
        // `shutdown()`'s own `gate.acquire()` call (queued directly behind
        // this one) has already run `performShutdown()` to completion and
        // published its final snapshot — and go on to mutate/publish its
        // own (now moot) result on top of that already-final state.
        // Bailing out here, before any snapshot/diagnostic mutation or
        // publish, keeps shutdown's own final transition the last word
        // regardless of how this call resolves.
        guard !isShutDown else { return false }

        publish(monitor: snapshot.monitor, history: snapshot.history, update: updateState, clearing: idsToClear, upserting: upserts)
        return succeeded
    }

    /// Persists `value` as `includePrereleaseUpdates` — which also clears
    /// the cached release ETag/`lastRelease` (see `UpdateService
    /// .setIncludePrerelease(_:)`) — and immediately forces a fresh check
    /// against the newly selected release stream, publishing the result
    /// through the exact same atomic transition/diagnostic handling as
    /// `checkForUpdates(force:)`. Mirrors `setKeepAwakeMode`'s persist-
    /// then-publish-then-rethrow contract: the persisted toggle is never
    /// rolled back even if the forced check itself fails, but the thrown
    /// `UpdateCheckError` still propagates to the caller after the
    /// resulting (failure) state has been published, so the failure
    /// remains visible both synchronously and in `snapshot.diagnostics`.
    public func setIncludePrereleaseUpdates(_ value: Bool) async throws {
        await gate.acquire()
        do {
            try await performSetIncludePrereleaseUpdates(value)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performSetIncludePrereleaseUpdates(_ value: Bool) async throws {
        // Granted the gate only after `shutdown()` has already begun (see
        // `isShutDown`'s documentation, and `performCheckForUpdates`'s
        // identical guard): never persist the toggle, network-check, or
        // publish once shutdown is underway, however long this tray
        // checkbox action was queued behind `gate`.
        guard !isShutDown else { return }

        var idsToClear: Set<String> = []
        var upserts: [Diagnostic] = []
        var thrownError: Error?
        let updateState: UpdateState
        do {
            updateState = try await updateService.setIncludePrerelease(value)
            idsToClear.insert(CoordinatorDiagnosticID.updatesCheckFailed)
        } catch {
            thrownError = error
            updateState = await updateService.currentState()
            upserts.append(Diagnostic(
                id: CoordinatorDiagnosticID.updatesCheckFailed,
                message: "Update check failed: \(error)",
                occurredAt: clock.nowMilliseconds()
            ))
        }

        // `isShutDown` is only checked once, above, *before* the
        // `updateService.setIncludePrerelease(_:)` await — but
        // `shutdown()` can flip it `true` at any point during that await
        // (it is set synchronously, ahead of `shutdown()`'s own
        // `gate.acquire()` call, specifically so an already-*queued*
        // action observes it the moment it is granted the gate — see
        // `isShutDown`'s documentation). That guards a call still
        // *queued* behind `gate` when shutdown begins, but not one that
        // had already been granted the gate and was genuinely in flight
        // inside `updateService.setIncludePrerelease(_:)` at that moment:
        // without re-checking here, such a call would resume — after
        // `shutdown()`'s own `gate.acquire()` call (queued directly
        // behind this one) has already run `performShutdown()` to
        // completion and published its final snapshot — and go on to
        // mutate/publish its own (now moot) result on top of that
        // already-final state. Bailing out here, before any snapshot/
        // diagnostic mutation or publish, keeps shutdown's own final
        // transition the last word regardless of how this call resolves,
        // and without rethrowing `thrownError` either: a failure that
        // only matters because shutdown made it moot must stay silent,
        // exactly as `performCheckForUpdates` does for the same race.
        guard !isShutDown else { return }

        publish(monitor: snapshot.monitor, history: snapshot.history, update: updateState, clearing: idsToClear, upserting: upserts)
        if let thrownError {
            throw thrownError
        }
    }

    /// Opens the most recently cached, already-validated release URL via
    /// `UpdateService.openCurrentRelease()` — never a URL supplied by any
    /// caller (there is no `URL`/`String` parameter here at all), and
    /// never one that has not already passed `UpdateService
    /// .isValidReleaseURL(_:)` at persist time. Does not touch `snapshot`
    /// at all: opening a release page has no effect on any published
    /// state, so this deliberately does not go through `gate`/`publish`.
    @discardableResult
    public func openLatestRelease() async -> Bool {
        await updateService.openCurrentRelease()
    }

    // MARK: - Shutdown

    /// Awaits `HistoryStore.flush(at:)` and then releases the active
    /// power assertion (`PowerAssertionService.shutdown()`), publishing
    /// the fully reconciled final state exactly once regardless of
    /// outcome, before rethrowing the first failure encountered (history
    /// takes priority over power, matching the order the two operations
    /// ran in). A caller awaiting `shutdown()` — e.g. app termination —
    /// is guaranteed both cleanups have already been attempted, and their
    /// results published, by the time this call returns.
    ///
    /// Marks `isShutDown` and stops `updateScheduler`'s background loop
    /// (see `UpdateScheduler.stop()`) *before* ever awaiting `gate`, not
    /// as part of `performShutdown()` — deliberately outside/ahead of the
    /// gate wait. `UpdateScheduler.stop()` only prevents *future* ticks
    /// from ever starting; it cannot recall a tick already dispatched and
    /// currently queued (or running) behind `gate`, since `AsyncGate` is
    /// intentionally non-cancellable. Setting `isShutDown` here, ahead of
    /// this call's own (possibly long) wait for `gate`, guarantees any
    /// such already-queued scheduled check observes it — via
    /// `performCheckForUpdates`'s own guard — the moment that check is
    /// finally granted the gate, however that ordering falls out, so no
    /// queued or in-flight scheduled check can ever network-check or
    /// publish once shutdown has begun. Idempotent: a second `shutdown()`
    /// call finds `isShutDown` already `true` and skips re-stopping the
    /// scheduler, but still proceeds through `gate` to flush/release/
    /// publish again, exactly as before this change.
    public func shutdown() async throws {
        if !isShutDown {
            isShutDown = true
            await updateScheduler.stop()
        }

        await gate.acquire()
        do {
            try await performShutdown()
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performShutdown() async throws {
        // `updateScheduler.stop()` (and `isShutDown`) are already set by
        // `shutdown()` itself, ahead of its `gate.acquire()` call above —
        // see that function's documentation for why this must happen
        // outside/before the gate wait rather than here.
        let now = clock.nowMilliseconds()

        var historyError: Error?
        var stats: HistoryStats
        do {
            stats = try await historyStore.flush(at: now)
        } catch {
            historyError = error
            stats = await historyStore.stats()
        }

        var powerError: Error?
        do {
            try power.shutdown()
        } catch {
            powerError = error
        }

        let updatedMonitor = AgentMonitorState(
            active: snapshot.monitor.active,
            keepingAwake: power.isActive,
            keepAwakeMode: power.activeMode ?? snapshot.monitor.keepAwakeMode,
            agents: snapshot.monitor.agents,
            lastScanAt: snapshot.monitor.lastScanAt
        )

        var upserts: [Diagnostic] = []
        if let historyError {
            upserts.append(Diagnostic(
                id: HistoryDiagnosticID.persistFailed,
                message: "Failed to flush history at shutdown: \(historyError)",
                occurredAt: now
            ))
        }
        if let powerError {
            upserts.append(Diagnostic(
                id: PowerDiagnosticID.assertionFailed,
                message: "Failed to release power assertion at shutdown: \(powerError)",
                occurredAt: now
            ))
        }

        publish(monitor: updatedMonitor, history: stats, clearing: [], upserting: upserts)

        if let historyError {
            throw historyError
        }
        if let powerError {
            throw powerError
        }
    }

    // MARK: - Shared history-diagnostic helper

    /// Reads `historyStore.lastDiagnostic` — its own authoritative,
    /// currently-in-effect diagnostic state — and reconciles it into
    /// `idsToClear`/`upserts` so a persistence failure that would
    /// otherwise stay hidden inside `HistoryStore` (a close-session
    /// persist from *this* `record(_:)` call, or an earlier tick's
    /// asynchronous debounced save that failed after this coordinator had
    /// already moved on) always surfaces in the very next published
    /// snapshot, and clears the moment a later persist actually succeeds.
    ///
    /// Deliberately re-reads the store's own state directly rather than
    /// inferring success/failure from `record(_:)`'s own (`Void`) return
    /// value: a tick that only accumulates a delta into an
    /// already-pending debounced save touches neither `HistoryStore`'s
    /// data nor its `lastDiagnostic` at all, so asking the store itself
    /// — every time, unconditionally — can never mistake "no persist was
    /// even attempted this tick" for "succeeded," and can therefore never
    /// falsely clear a still-current diagnostic just because this
    /// particular call didn't force a write.
    private func reconcileHistoryDiagnostic(idsToClear: inout Set<String>, upserts: inout [Diagnostic]) async {
        idsToClear.formUnion(StorageDiagnosticAlias.historyDiagnosticIDs)
        if let diagnostic = await historyStore.lastDiagnostic {
            upserts.append(StorageDiagnosticAlias.remapForHistory(diagnostic))
        }
    }

    // MARK: - Shared power-transition helper

    /// Applies `power.setDesired(active:mode:)` and returns the *actual*
    /// resulting `(keepingAwake, effectiveMode)` pair — read back from the
    /// service's own `isActive`/`activeMode` after the call, regardless of
    /// whether it threw. On success, `PowerDiagnosticID.assertionFailed`
    /// is queued for clearing (via `idsToClear`); on failure, a fresh
    /// diagnostic describing the error is queued for upsert (via
    /// `upserts`) instead. This is the single place that guarantees
    /// `keepingAwake` never reports the *desired* state after a failure —
    /// only whatever the service verifiably settled on (e.g. still `true`
    /// with the old mode, for a mode-replacement creation failure that
    /// left the prior assertion active).
    private func applyDesiredPowerState(
        active: Bool,
        mode: KeepAwakeMode,
        occurredAt: Int64,
        idsToClear: inout Set<String>,
        upserts: inout [Diagnostic]
    ) -> (keepingAwake: Bool, effectiveMode: KeepAwakeMode) {
        do {
            try power.setDesired(active: active, mode: mode)
            idsToClear.insert(PowerDiagnosticID.assertionFailed)
        } catch {
            upserts.append(Diagnostic(
                id: PowerDiagnosticID.assertionFailed,
                message: "Failed to update the power assertion: \(error)",
                occurredAt: occurredAt
            ))
        }
        return (power.isActive, power.activeMode ?? mode)
    }

    // MARK: - Publish

    /// Rebuilds `snapshot` from `monitor`/`history` (and `update`, if
    /// provided), removes every diagnostic whose id is in `idsToClear`,
    /// upserts every diagnostic in `newDiagnostics` (replacing any
    /// existing entry with the same id so a repeated failure's
    /// message/timestamp always reflects the most recent attempt), then
    /// emits the result to `renderer` exactly once. Every public entry
    /// point above calls this at most once per invocation — the single
    /// place a completed transition becomes visible.
    private func publish(
        monitor: AgentMonitorState,
        history: HistoryStats,
        update: UpdateState? = nil,
        clearing idsToClear: Set<String>,
        upserting newDiagnostics: [Diagnostic]
    ) {
        var diagnostics = snapshot.diagnostics
        if !idsToClear.isEmpty {
            diagnostics.removeAll { idsToClear.contains($0.id) }
        }
        for diagnostic in newDiagnostics {
            diagnostics.removeAll { $0.id == diagnostic.id }
            diagnostics.append(diagnostic)
        }

        snapshot = AppSnapshot(
            monitor: monitor,
            history: history,
            update: update ?? snapshot.update,
            diagnostics: diagnostics,
            appVersion: snapshot.appVersion
        )
        renderer.emit(snapshot)
    }

    /// Keeps only the first `Diagnostic` for each distinct `id`,
    /// preserving relative order — used once, at startup, to combine the
    /// (already history-remapped, so non-colliding in practice) settings
    /// and history load diagnostics deterministically.
    private static func dedupedByID(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        var seenIDs = Set<String>()
        var result: [Diagnostic] = []
        for diagnostic in diagnostics where !seenIDs.contains(diagnostic.id) {
            seenIDs.insert(diagnostic.id)
            result.append(diagnostic)
        }
        return result
    }
}
