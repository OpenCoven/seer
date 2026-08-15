import Cocoa
import WebKit
import os

// MARK: - Testable service seams

/// The `AgentMonitor` operations `AppDelegate`'s scan loop depends on.
/// Abstracted behind a protocol — rather than the shell depending on the
/// concrete `actor` directly — purely for testability: `AppLifecycleTests`
/// can substitute a scripted fake to assert exactly when/how often the
/// shell scans, without ever running real process/session detection.
/// `AgentMonitor` conforms via the extension immediately below with no
/// additional code — every member here already exists on the real actor.
/// Deliberately *not* `@MainActor`-isolated: `AgentMonitor` is its own
/// independent actor (never the main actor), so every requirement here is
/// declared `async` instead, letting any actor — real or fake — satisfy it
/// via an ordinary cross-actor call.
public protocol AgentMonitorControlling: AnyObject, Sendable {
    var state: AgentMonitorState { get async }
    var diagnostic: Diagnostic? { get async }
    func scan() async
    func stop() async
}

extension AgentMonitor: AgentMonitorControlling {}

/// The `BridgeMessageHandler` operations orderly termination depends on.
/// Abstracted the same way as `AgentMonitorControlling` above, so
/// `AppLifecycleTests` can assert "bridge handlers stop accepting new
/// commands, then are cancelled, at quit" against a fake without needing
/// a real `WKWebView`/router stack.
@MainActor
protocol BridgeHandlerCancelling: AnyObject {
    /// Stops accepting any *new* bridge command dispatch — see
    /// `BridgeMessageHandler.stopAccepting()`'s own documentation.
    /// Called synchronously at the very start of orderly termination,
    /// before ever awaiting monitor-stop/coordinator-shutdown, so a
    /// bridge command dispatched at (or after) that exact instant can
    /// never be accepted in the first place.
    func stopAccepting()
    func cancelAll()
}

extension BridgeMessageHandler: BridgeHandlerCancelling {}

/// The one `StatusItemController` operation the prerelease-updates menu
/// checkbox depends on. Abstracted the same way as `AgentMonitorControlling`/
/// `BridgeHandlerCancelling` above, so `AppLifecycleTests` can substitute a
/// scripted fake to assert exactly when the menu checkbox is (and is not)
/// updated relative to `AppSnapshotCoordinator.setIncludePrereleaseUpdates(_:)`
/// resolving, without needing a real `NSStatusItem`.
@MainActor
protocol PrereleaseUpdatesMenuApplying: AnyObject {
    var includePrereleaseUpdates: Bool { get }
    func apply(includePrereleaseUpdates value: Bool)
}

extension StatusItemController: PrereleaseUpdatesMenuApplying {}

/// Broadcasts one published `AppSnapshot` to every listed sink, in order.
/// Lets `AppSnapshotCoordinator` — which accepts exactly one `renderer` at
/// construction — publish to both the renderer's `WKWebView` (via
/// `RendererEventSink`) and the tray icon/tooltip (via
/// `StatusItemController`, itself an `AppSnapshotRendererSink`) from a
/// single atomic transition.
@MainActor
final class MulticastRendererSink: AppSnapshotRendererSink {
    private let sinks: [any AppSnapshotRendererSink]

    init(sinks: [any AppSnapshotRendererSink]) {
        self.sinks = sinks
    }

    func emit(_ snapshot: AppSnapshot) {
        for sink in sinks {
            sink.emit(snapshot)
        }
    }
}

/// Diagnostic ids `AppDelegate.bootstrapProduction()` folds directly into
/// the coordinator's own startup diagnostics — distinct from every id
/// `AppSnapshotCoordinator`/`AtomicJSONStore` surface themselves — for
/// bootstrap-level failures that must still let the app launch, visibly
/// flagged, rather than aborting silently before any UI exists at all.
enum AppBootstrapDiagnosticID {
    /// Emitted when the real, user-domain Application Support directory
    /// could not be resolved at all, so `bootstrapProduction()` fell back
    /// to a temporary directory for settings/history instead.
    static let applicationSupportUnresolved = "bootstrap.application-support.unresolved"

    /// Emitted when `settings.json`/`history.json`'s containing directory
    /// could not be created under the (already-resolved, possibly already
    /// temporary-fallback) Application Support directory — e.g. disk full
    /// or a permissions failure — so `StorageBootstrap.resolveLocations`
    /// fell back to a second, dedicated temporary directory instead.
    static let storageLocationUnresolved = "bootstrap.storage-location.unresolved"

    /// Emitted when `StorageBootstrap.pruneStaleFallbackDirectories(...)`
    /// found a stale, this-app-owned fallback directory left behind by a
    /// previous run (e.g. one that crashed before its own orderly
    /// shutdown could remove it) but failed to actually remove it —
    /// logged/diagnosed rather than thrown, since a failed best-effort
    /// prune must never block the current launch.
    static let fallbackPruneFailed = "bootstrap.fallback-prune.failed"
}

/// Resolves the on-disk settings/history file locations `bootstrapProduction()`
/// needs before any `SettingsStore`/`HistoryStore` can be constructed,
/// retrying once against a fresh, uniquely-named temporary directory if the
/// primary `applicationSupportDirectory` cannot yield usable file URLs at
/// all (e.g. `settings.json`'s containing directory cannot be created due
/// to a permissions failure or a full disk). Isolated from
/// `bootstrapProduction()` itself, with every filesystem interaction
/// injected, specifically so this retry/fallback decision is directly
/// unit-testable against a real (not mocked) filesystem failure.
enum StorageBootstrap {
    /// The fixed, safe naming prefix every temporary fallback directory
    /// `makeTemporaryFallbackDirectory`'s default ever mints is named
    /// with, and the *only* prefix `pruneStaleFallbackDirectories(...)`
    /// below will ever consider removing — matching entries by anything
    /// else (a differently-prefixed directory some other process/app
    /// placed in the same shared temporary directory) is never touched,
    /// no matter how old it is.
    static let fallbackDirectoryPrefix = "ai.opencoven.seer-fallback-"

    /// The successfully resolved settings/history file URLs, plus any
    /// diagnostic that should be folded into the coordinator's own
    /// startup diagnostics because resolving them required falling back
    /// to the dedicated temporary directory below.
    struct Locations {
        let settingsURL: URL
        let historyURL: URL
        let diagnostics: [Diagnostic]
        /// The dedicated temporary directory settings/history were
        /// actually relocated under, if (and only if) the primary
        /// `applicationSupportDirectory` could not be used at all —
        /// `nil` whenever the primary directory itself resolved usable
        /// locations directly. `AppDelegate` retains this as its own
        /// `fallbackStorageRoot` so it can be recursively removed once
        /// orderly shutdown completes, and passes it as
        /// `pruneStaleFallbackDirectories(...)`'s `excluding:` argument
        /// so this session's own in-use fallback directory is never
        /// mistaken for a stale one left behind by some earlier run.
        let fallbackRoot: URL?
    }

    /// Attempts to resolve `settings.json`/`history.json` under
    /// `applicationSupportDirectory` first; if either throws, retries
    /// once against a fresh directory from `makeTemporaryFallbackDirectory`
    /// — mirroring `bootstrapProduction()`'s own Application Support
    /// fallback above — folding that retry into the returned
    /// `Locations.diagnostics` so it is still visibly surfaced once the
    /// UI exists. Returns `.failure` only when even that dedicated
    /// temporary directory could not yield usable file locations: at
    /// that point there is truly nowhere to persist settings/history at
    /// all, and the caller must terminate cleanly rather than continue
    /// running as an invisible accessory process with no status item and
    /// no way to quit. In that doubly-failed case, whatever was already
    /// partially created under the dedicated fallback directory (e.g. a
    /// successful `settingsFileURL` call having already created the
    /// containing directory before a subsequent `historyFileURL` call
    /// failed) is recursively removed before returning, rather than left
    /// behind as a permanently orphaned, incomplete directory tree —
    /// best-effort: a failure removing it is silently ignored here, since
    /// there is already a more specific originating `error` to report and
    /// this is purely housekeeping.
    static func resolveLocations(
        applicationSupportDirectory: URL,
        now: Int64,
        makeTemporaryFallbackDirectory: () -> URL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("\(fallbackDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        },
        settingsFileURL: (URL) throws -> URL = { try SettingsFileLocation.settingsFileURL(applicationSupportDirectory: $0) },
        historyFileURL: (URL) throws -> URL = { try HistoryFileLocation.historyFileURL(applicationSupportDirectory: $0) },
        fileManager: FileManager = .default
    ) -> Result<Locations, Error> {
        do {
            let settingsURL = try settingsFileURL(applicationSupportDirectory)
            let historyURL = try historyFileURL(applicationSupportDirectory)
            return .success(Locations(settingsURL: settingsURL, historyURL: historyURL, diagnostics: [], fallbackRoot: nil))
        } catch let primaryError {
            let fallbackDirectory = makeTemporaryFallbackDirectory()
            do {
                let settingsURL = try settingsFileURL(fallbackDirectory)
                let historyURL = try historyFileURL(fallbackDirectory)
                let diagnostic = Diagnostic(
                    id: AppBootstrapDiagnosticID.storageLocationUnresolved,
                    message: "Failed to prepare the settings/history storage directory; falling back to a dedicated temporary location: \(primaryError)",
                    occurredAt: now
                )
                return .success(Locations(settingsURL: settingsURL, historyURL: historyURL, diagnostics: [diagnostic], fallbackRoot: fallbackDirectory))
            } catch {
                try? fileManager.removeItem(at: fallbackDirectory)
                return .failure(error)
            }
        }
    }

    /// The outcome of one `pruneStaleFallbackDirectories(...)` call:
    /// how many stale directories were actually removed, plus any
    /// diagnostic for a directory this call *tried but failed* to
    /// remove — folded into `bootstrapProduction()`'s own startup
    /// diagnostics so a persistent prune failure (e.g. permissions) is
    /// still visible once the UI exists, rather than silently retried
    /// forever with no trace.
    struct PruneResult {
        let removedCount: Int
        let diagnostics: [Diagnostic]
    }

    /// Bounded, defensive startup housekeeping: removes directories
    /// under `temporaryDirectory` that (a) this app itself created as a
    /// dedicated fallback (name begins with `fallbackDirectoryPrefix` —
    /// no other entry, however old, is ever even considered), (b) are
    /// actually directories (never a same-named file), (c) are not
    /// `excluding` (this session's own currently-active fallback root,
    /// if any — always preserved regardless of age), and (d) are older
    /// than `maxAge` seconds (a fresh, still-in-use directory from a
    /// still-running process — vanishingly unlikely to be anything other
    /// than `excluding` itself, but defended anyway — is left alone).
    /// Bounded by `maxDirectoriesToPrune`: at most that many *matching*
    /// directories are ever removed in a single call, so a temporary
    /// directory somehow containing an enormous number of stale entries
    /// cannot make a single launch's pruning pass unbounded.
    ///
    /// A directory that fails to remove is diagnosed (see `PruneResult
    /// .diagnostics`) rather than thrown/crashed on — startup must always
    /// proceed regardless of whether housekeeping fully succeeds.
    /// Directories this app never created (any other name at all) are
    /// never touched, matching or not — this is deliberately never a
    /// broad "clean the whole temporary directory" sweep.
    static func pruneStaleFallbackDirectories(
        in temporaryDirectory: URL,
        excluding activeFallbackRoot: URL?,
        now: Date,
        maxAge: TimeInterval = 3600,
        maxDirectoriesToPrune: Int = 50,
        fileManager: FileManager = .default
    ) -> PruneResult {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return PruneResult(removedCount: 0, diagnostics: [])
        }

        var removedCount = 0
        var diagnostics: [Diagnostic] = []

        for entry in entries {
            guard removedCount < maxDirectoriesToPrune else { break }
            guard entry.lastPathComponent.hasPrefix(fallbackDirectoryPrefix) else { continue }
            guard entry.standardizedFileURL != activeFallbackRoot?.standardizedFileURL else { continue }

            let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard resourceValues?.isDirectory == true else { continue }

            let creationDate = resourceValues?.creationDate ?? .distantPast
            guard now.timeIntervalSince(creationDate) >= maxAge else { continue }

            do {
                try fileManager.removeItem(at: entry)
                removedCount += 1
            } catch {
                diagnostics.append(Diagnostic(
                    id: AppBootstrapDiagnosticID.fallbackPruneFailed,
                    message: "Failed to prune stale fallback directory at \(entry.path): \(error)",
                    occurredAt: Int64(now.timeIntervalSince1970 * 1000)
                ))
            }
        }

        return PruneResult(removedCount: removedCount, diagnostics: diagnostics)
    }
}

/// Root application delegate. Wires every service from Tasks 2–11 into the
/// real menu-bar app shell: an accessory-activation launch that loads
/// settings/history, builds the coordinator/bridge/panel/status item,
/// performs an initial agent scan, then keeps scanning every three seconds
/// for as long as the app runs — and an orderly `.terminateLater` shutdown
/// that stops that scanning, flushes history, releases the power assertion,
/// and removes every bridge handler before finally allowing the app to
/// quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: (any AppSnapshotCoordinating)?
    private var agentMonitor: (any AgentMonitorControlling)?
    private var bridgeMessageHandler: (any BridgeHandlerCancelling)?
    private weak var webViewUserContentController: WKUserContentController?
    private var panelController: PanelController?
    private var statusItemController: StatusItemController?
    /// The narrow seam `requestSetIncludePrereleaseUpdates(_:)` applies
    /// the persisted toggle through — set to the same `StatusItemController`
    /// instance as `statusItemController` in production, but injected
    /// separately (and independently fakeable) so `AppLifecycleTests` can
    /// assert exactly when the menu checkbox is (and is not) updated
    /// relative to persistence succeeding, without needing a real
    /// `NSStatusItem`.
    private var prereleaseUpdatesMenu: (any PrereleaseUpdatesMenuApplying)?

    private var scanLoopTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var hasShutDown = false

    /// The dedicated temporary storage directory `bootstrapProduction()`
    /// fell back to (via `StorageBootstrap.resolveLocations`), if any —
    /// `nil` whenever the real Application Support directory resolved
    /// settings/history locations directly. Recursively removed by
    /// `cleanUpFallbackStorageRootIfNeeded()` once orderly shutdown has
    /// fully completed, so a fallback session never leaves its directory
    /// permanently orphaned on disk.
    private var fallbackStorageRoot: URL?

    private let sleeper: any Sleeper

    /// Surfaces failures that have no `AppSnapshotCoordinator`/`AppSnapshot`
    /// to attach a `Diagnostic` to — either because no coordinator has
    /// been constructed yet (bootstrap-level failures) or because the
    /// failure itself never reaches the coordinator at all (e.g. a
    /// persistence failure inside `requestSetIncludePrereleaseUpdates(_:)`
    /// that is deliberately not forwarded into an optimistic UI update).
    private static let logger = Logger(subsystem: "ai.opencoven.seer", category: "AppDelegate")

    /// `true` only when this instance was built via the test initializer
    /// below, with every lifecycle-relevant service already injected —
    /// guards `applicationDidFinishLaunching` (which never actually fires
    /// in a unit test, since there is no real `NSApplication.run()` loop,
    /// but is guarded regardless for defense-in-depth) against ever
    /// re-running production bootstrap over already-injected fakes.
    private let skipsProductionBootstrap: Bool

    /// Production initializer: every service is built for real inside
    /// `applicationDidFinishLaunching` → `bootstrapProduction()`.
    override init() {
        self.sleeper = TaskSleeper()
        self.skipsProductionBootstrap = false
        super.init()
    }

    /// Test-only seam: constructs a delegate with every lifecycle-relevant
    /// service already injected, so `AppLifecycleTests` can exercise the
    /// scan-loop/termination sequencing directly (via `beginMonitoring()`/
    /// `beginTermination(reply:)`) against scripted fakes, without ever
    /// standing up a real `SettingsStore`/`HistoryStore`/
    /// `PowerAssertionService`/`UpdateService`/`WKWebView`/`NSStatusItem`
    /// stack.
    init(
        coordinator: any AppSnapshotCoordinating,
        agentMonitor: any AgentMonitorControlling,
        sleeper: any Sleeper = TaskSleeper(),
        bridgeMessageHandler: (any BridgeHandlerCancelling)? = nil,
        prereleaseUpdatesMenu: (any PrereleaseUpdatesMenuApplying)? = nil,
        fallbackStorageRoot: URL? = nil
    ) {
        self.coordinator = coordinator
        self.agentMonitor = agentMonitor
        self.sleeper = sleeper
        self.bridgeMessageHandler = bridgeMessageHandler
        self.prereleaseUpdatesMenu = prereleaseUpdatesMenu
        self.fallbackStorageRoot = fallbackStorageRoot
        self.skipsProductionBootstrap = true
        super.init()
    }

    /// Seer is a menu-bar-only accessory app with no primary window, so it
    /// must never be terminated just because its (nonexistent) last window
    /// closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !skipsProductionBootstrap else { return }
        Task { await bootstrapProduction() }
    }

    // MARK: - Production bootstrap

    /// The real launch sequence, in the exact order the spec requires:
    /// (1) accessory activation is already set by `ApplicationRuntime
    /// .run()` before `NSApplication.run()` ever dispatches this method,
    /// and reasserted here defensively; (2) settings/history are loaded
    /// exactly once each — via `AppSnapshotCoordinator
    /// .loadStartupSnapshot(...)`, awaited directly by this method,
    /// before any settings/history-dependent UI exists at all — with any
    /// bootstrap-level failure (e.g. an unresolvable Application Support
    /// directory) folded in as a startup diagnostic rather than aborting
    /// silently; (3) only once that load has completed are the panel,
    /// status item, bridge, and coordinator (via `AppSnapshotCoordinator
    /// .makeWithScheduledUpdates(...)`, which never reloads either store)
    /// actually constructed — performing no update-check network request
    /// and starting no scheduler yet; (4) `beginMonitoring()` then
    /// performs the initial agent scan/apply and (5) begins the recurring
    /// three-second monitor loop; only once both of those have happened,
    /// and only if shutdown has not already begun in the meantime, does
    /// (6) `coordinator.performStartupUpdateCheckAndStartScheduler()` run
    /// Seer's one-time startup update check and start the periodic
    /// scheduler — so a slow/hanging network request can never delay the
    /// menu bar icon or panel showing real monitoring state. Because step
    /// (2) genuinely awaits disk I/O before any tray icon exists, a quit
    /// requested during that narrow window will simply find no tray to
    /// show at all until this method reaches step (3) — the approved
    /// tradeoff for never showing UI ahead of the state it depends on.
    private func bootstrapProduction() async {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppMainMenuBuilder.build(appName: "Seer") { [weak self] in
            self?.requestQuit()
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let clock = SystemClock()

        // Resolves the real Application Support directory, falling back
        // to a temporary directory — rather than aborting bootstrap
        // silently — if it cannot be resolved at all; the failure is
        // folded into the coordinator's own startup diagnostics below so
        // it is still visibly surfaced once the UI exists.
        var bootstrapDiagnostics: [Diagnostic] = []
        let applicationSupportDirectory: URL
        do {
            applicationSupportDirectory = try SettingsFileLocation.resolveApplicationSupportDirectory()
        } catch {
            applicationSupportDirectory = FileManager.default.temporaryDirectory
            bootstrapDiagnostics.append(Diagnostic(
                id: AppBootstrapDiagnosticID.applicationSupportUnresolved,
                message: "Failed to resolve the Application Support directory; falling back to a temporary location: \(error)",
                occurredAt: clock.nowMilliseconds()
            ))
        }

        let settingsURL: URL
        let historyURL: URL
        switch StorageBootstrap.resolveLocations(applicationSupportDirectory: applicationSupportDirectory, now: clock.nowMilliseconds()) {
        case .success(let locations):
            settingsURL = locations.settingsURL
            historyURL = locations.historyURL
            bootstrapDiagnostics.append(contentsOf: locations.diagnostics)
            fallbackStorageRoot = locations.fallbackRoot
        case .failure(let error):
            // Even a dedicated, freshly-minted temporary directory could
            // not be prepared — there is truly nowhere to persist
            // settings/history at all, so no `SettingsStore`/
            // `HistoryStore` can even be constructed. Rather than
            // returning silently here — which would leave an invisible
            // accessory process running forever, with no status item and
            // no way to quit — surface the native failure and terminate
            // cleanly.
            terminateBootstrapFailure(reason: "Seer could not prepare a location to store its settings and history: \(error)")
            return
        }

        // Bounded, defensive housekeeping: removes stale, this-app-owned
        // fallback directories orphaned by a previous run that never
        // reached its own orderly shutdown (e.g. a crash) — never this
        // session's own `fallbackStorageRoot` (excluded explicitly,
        // regardless of age), and never anything not matching
        // `StorageBootstrap.fallbackDirectoryPrefix`. Any prune failure
        // is folded into `bootstrapDiagnostics` rather than blocking
        // launch.
        let pruneResult = StorageBootstrap.pruneStaleFallbackDirectories(
            in: FileManager.default.temporaryDirectory,
            excluding: fallbackStorageRoot,
            now: Date()
        )
        bootstrapDiagnostics.append(contentsOf: pruneResult.diagnostics)

        let settingsFileSystem = FileManagerSettingsFileSystem()
        let settingsStore = SettingsStore(store: AtomicJSONStore(fileURL: settingsURL, fileSystem: settingsFileSystem, clock: clock))
        let historyStore = HistoryStore(store: AtomicJSONStore(fileURL: historyURL, fileSystem: settingsFileSystem, clock: clock), clock: clock)
        let power = PowerAssertionService(backend: IOKitPowerAssertionBackend())
        let updateService = UpdateService(
            settingsStore: settingsStore,
            session: UpdateService.makeDefaultSession(),
            clock: clock,
            currentVersion: appVersion
        )

        // Step (2) of the required launch order: settings/history are
        // loaded exactly once each, here, before any panel/status item/
        // bridge — every one of which is genuine user-visible UI — is
        // ever constructed. `startupSnapshot` seeds both the coordinator
        // built below and the status item's initial prerelease-updates
        // toggle; no later step ever reloads either store.
        let startupSnapshot = await AppSnapshotCoordinator.loadStartupSnapshot(
            settingsStore: settingsStore,
            historyStore: historyStore,
            updateService: updateService,
            appVersion: appVersion,
            extraDiagnostics: bootstrapDiagnostics
        )

        let rendererRoot = SeerRendererRoot(url: Bundle.main.resourceURL!.appendingPathComponent("Renderer", isDirectory: true))
        let panel = PanelController(rendererRoot: rendererRoot, clock: clock)
        let rendererSink = RendererEventSink(javaScriptCaller: panel.webView)

        let statusItem = StatusItemController(
            statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength),
            actions: StatusItemController.Actions(
                togglePanel: { [weak self] in self?.toggleFromStatusItem() },
                setKeepAwakeMode: { [weak self] mode in self?.requestSetKeepAwakeMode(mode) },
                setIncludePrereleaseUpdates: { [weak self] value in self?.requestSetIncludePrereleaseUpdates(value) },
                viewLatestRelease: { [weak self] in self?.requestOpenLatestRelease() },
                quit: { [weak self] in self?.requestQuit() }
            ),
            initialSnapshot: startupSnapshot,
            includePrereleaseUpdates: await settingsStore.current.includePrereleaseUpdates
        )

        let broadcastSink = MulticastRendererSink(sinks: [rendererSink, statusItem])

        // Builds the coordinator/bridge target from the already-loaded
        // `startupSnapshot` — never a second settings/history load —
        // performing no update-check network request and starting no
        // scheduler yet (see this method's own documentation above for
        // why).
        let coordinator = AppSnapshotCoordinator.makeWithScheduledUpdates(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: broadcastSink,
            clock: clock,
            updateService: updateService,
            startupSnapshot: startupSnapshot
        )

        let router = StandaloneBridgeCommandRouter(
            snapshotGet: {
                .success(coordinator.snapshot)
            },
            keepAwakeModeSet: { mode in
                do {
                    try await coordinator.setKeepAwakeMode(mode)
                    return .success(coordinator.snapshot)
                } catch {
                    return .failure(BridgeCommandError(code: .commandFailed, message: "Failed to update keep-awake mode"))
                }
            },
            historyClear: {
                do {
                    try await coordinator.clearHistory()
                    return .success(coordinator.snapshot)
                } catch {
                    return .failure(BridgeCommandError(code: .commandFailed, message: "Failed to clear history"))
                }
            },
            updatesCheck: {
                await coordinator.checkForUpdates(force: true)
                return .success(coordinator.snapshot)
            },
            updatesOpen: {
                let opened = await coordinator.openLatestRelease()
                return opened
                    ? .success(())
                    : .failure(BridgeCommandError(code: .commandFailed, message: "No update release is available to open"))
            },
            panelHide: { [weak panel] in
                panel?.hide()
                return .success(())
            },
            appQuit: { [weak self] in
                self?.requestQuit()
                return .success(())
            }
        )

        let bridgeMessageHandler = BridgeMessageHandler(router: router, responder: rendererSink)
        BridgeMessageHandlerRegistration.register(bridgeMessageHandler, on: panel.userContentController)
        panel.loadInitialDocument()

        let detector = AgentDetector(
            processes: NativeProcessSnapshotSource(backend: LibProcProcessBackend()),
            sessions: NativeSessionSnapshotSource(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        )
        let agentMonitor = AgentMonitor(detector: detector, clock: clock)

        self.coordinator = coordinator
        self.agentMonitor = agentMonitor
        self.panelController = panel
        self.statusItemController = statusItem
        self.prereleaseUpdatesMenu = statusItem
        self.bridgeMessageHandler = bridgeMessageHandler
        self.webViewUserContentController = panel.userContentController

        await beginMonitoring()

        // Only now — after the initial agent scan has applied and the
        // recurring monitor loop has started — run Seer's one-time
        // startup update check and start the periodic scheduler; but
        // only if shutdown has not already begun in the meantime (e.g.
        // quit requested while the initial scan above was still in
        // flight). `hasShutDown` is set synchronously, ahead of any
        // await, the instant `performOrderlyShutdownOnce()` begins (see
        // that method's own documentation), so this check reliably
        // observes a shutdown that started at any point up to and
        // including `beginMonitoring()`'s own await above. Once
        // shutdown has begun, `coordinator.shutdown()` may already have
        // stopped the scheduler; starting a fresh network check/
        // scheduler run here would silently undo that.
        guard !hasShutDown else { return }
        await coordinator.performStartupUpdateCheckAndStartScheduler()
    }

    /// Surfaces an unrecoverable bootstrap failure (one that
    /// `StorageBootstrap.resolveLocations` could not recover from even via
    /// its own temporary-directory fallback) via a native, user-visible
    /// alert, then terminates the app cleanly. Reached only when there is
    /// truly nowhere to persist settings/history at all — a case this
    /// method must never let pass silently, since `bootstrapProduction()`
    /// has not yet built a status item or any other way for the user to
    /// quit on their own; without this, the process would otherwise keep
    /// running forever as an invisible accessory with no UI at all.
    private func terminateBootstrapFailure(reason: String) {
        Self.logger.fault("Seer bootstrap failed and cannot continue: \(reason, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Seer failed to start"
        alert.informativeText = reason
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Status item action wiring

    private func toggleFromStatusItem() {
        guard let panelController, let button = statusItemController?.statusItem.button else { return }
        panelController.toggle(trayFrame: Self.screenFrame(of: button), screen: button.window?.screen)
    }

    private static func screenFrame(of button: NSStatusBarButton) -> CGRect {
        guard let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Internal (not `private`) so `AppLifecycleTests` can drive it
    /// directly against injected fakes, matching
    /// `requestSetIncludePrereleaseUpdates(_:)` below.
    func requestSetKeepAwakeMode(_ mode: KeepAwakeMode) {
        // Gated by `hasShutDown` both here (so a request arriving once
        // termination has already begun never even queues a `Task`) and
        // again inside the `Task` itself (so one dispatched *just*
        // before `hasShutDown` flips cannot resume afterward and still
        // reach the coordinator) — see `performOrderlyShutdownOnce()`'s
        // documentation for why `hasShutDown` is exactly the right,
        // synchronously-set-ahead-of-any-await flag for this. The
        // coordinator's own `setKeepAwakeMode(_:)` independently guards
        // on its own `isShutDown` too, so a call that slips past both
        // checks here (a vanishingly narrow window) still can never
        // recreate the power assertion or publish once shutdown is
        // underway.
        guard let coordinator, !hasShutDown else { return }
        Task { [weak self] in
            guard let self, !self.hasShutDown else { return }
            try? await coordinator.setKeepAwakeMode(mode)
        }
    }

    /// Persists `value` via `AppSnapshotCoordinator.setIncludePrereleaseUpdates(_:)`
    /// and applies the menu checkbox (`prereleaseUpdatesMenu.apply(
    /// includePrereleaseUpdates:)`) whenever that call reports persistence
    /// actually committed — whether or not the immediately-following
    /// forced re-check against the newly selected release stream itself
    /// succeeded. `includePrereleaseUpdates` has no representation in
    /// `AppSnapshot` at all (unlike, say, `keepAwakeMode`, which rides
    /// the coordinator's normal snapshot-publish pipeline), so it is the
    /// only settings toggle whose menu state `AppDelegate` must apply
    /// directly rather than merely forwarding a coordinator mutation and
    /// letting a later snapshot publish reflect it.
    ///
    /// Task 12's finding: previously the menu was only ever applied once
    /// the *entire* call — persistence *and* the forced check — resolved
    /// without throwing, so toggling the setting while offline left the
    /// change durably saved to disk yet the checkbox still showing the
    /// old value. `AppSnapshotCoordinator.setIncludePrereleaseUpdates(_:)`
    /// now distinguishes the two failure shapes: a thrown error here
    /// means persistence itself never committed — the menu is correctly
    /// left untouched, matching whatever is still actually on disk, and
    /// the failure is logged (never swallowed via `try?`) since there is
    /// no `AppSnapshot`/`Diagnostic` this specific failure can attach to.
    /// `.persistedButCheckFailed`, by contrast, means the toggle *did*
    /// commit — the menu is applied exactly as on outright success, with
    /// only the check failure logged for diagnosability (it is also
    /// already visible as a `CoordinatorDiagnosticID.updatesCheckFailed`
    /// diagnostic on the published snapshot).
    ///
    /// Gated the same way as `requestSetKeepAwakeMode(_:)` above: skipped
    /// entirely once `hasShutDown`, both before the `Task` is created and
    /// again at its very start, so a toggle requested at (or after) the
    /// exact instant termination begins can never apply the menu or
    /// reach the coordinator. Internal (not `private`) so
    /// `AppLifecycleTests` can drive it directly against injected fakes.
    func requestSetIncludePrereleaseUpdates(_ value: Bool) {
        guard let coordinator, !hasShutDown else { return }
        Task { [weak self] in
            guard let self, !self.hasShutDown else { return }
            do {
                let outcome = try await coordinator.setIncludePrereleaseUpdates(value)
                self.prereleaseUpdatesMenu?.apply(includePrereleaseUpdates: value)
                if case .persistedButCheckFailed(let message) = outcome {
                    Self.logger.error("Persisted includePrereleaseUpdates=\(value, privacy: .public) but the forced update check failed: \(message, privacy: .public)")
                }
            } catch {
                Self.logger.error("Failed to persist includePrereleaseUpdates=\(value, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func requestOpenLatestRelease() {
        guard let coordinator, !hasShutDown else { return }
        Task { [weak self] in
            guard let self, !self.hasShutDown else { return }
            await coordinator.openLatestRelease()
        }
    }

    private func requestQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Monitor scan loop (steps 4 & 5)

    /// Performs the initial agent scan (step 4), then begins the recurring
    /// three-second monitor loop (step 5) — unless shutdown has already
    /// begun by the time the initial scan returns. `hasShutDown` is set
    /// synchronously, ahead of any await, the instant
    /// `performOrderlyShutdownOnce()` begins (see that method's own
    /// documentation), so a quit requested while the initial scan above
    /// was still in flight is reliably observed here, immediately after
    /// that scan resolves and before the recurring loop is ever started.
    /// Without this check, `startScanLoop` would still start the
    /// recurring loop even though `performOrderlyShutdownOnce()` may
    /// already have stopped `agentMonitor`/`coordinator` and finished
    /// running — resurrecting monitoring work after shutdown. Internal
    /// (not `private`) so `AppLifecycleTests` can drive it directly
    /// against injected fakes.
    func beginMonitoring() async {
        guard let agentMonitor, let coordinator else { return }
        await performScanTick(agentMonitor: agentMonitor, coordinator: coordinator)
        guard !hasShutDown else { return }
        startScanLoop(agentMonitor: agentMonitor, coordinator: coordinator)
    }

    private func startScanLoop(agentMonitor: any AgentMonitorControlling, coordinator: any AppSnapshotCoordinating) {
        guard scanLoopTask == nil else { return }
        scanLoopTask = Task { [weak self, sleeper] in
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(nanoseconds: UInt64(AgentMonitor.scanIntervalMilliseconds) * 1_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.performScanTick(agentMonitor: agentMonitor, coordinator: coordinator)
            }
        }
    }

    /// Runs one `AgentMonitor.scan()` and forwards its outcome into the
    /// coordinator: a scan-failure diagnostic forwards to
    /// `applyScanFailure(occurredAt:)` (retaining the last known agent
    /// state); anything else forwards the freshly scanned agent list to
    /// `applyScan(_:scannedAt:)`. Checked against `hasShutDown` both
    /// immediately after `agentMonitor.scan()` resolves and again
    /// immediately before the resulting coordinator call — `hasShutDown`
    /// is set synchronously, ahead of any await, the instant
    /// `performOrderlyShutdownOnce()` begins (see that method's own
    /// documentation), so a scan already in flight (whether the very
    /// first, directly-awaited call from `beginMonitoring()`, or one
    /// dispatched from the recurring loop) can never publish an
    /// `applyScan`/`applyScanFailure` transition into the coordinator once
    /// termination has begun, however long that in-flight scan itself
    /// takes to actually resolve.
    private func performScanTick(agentMonitor: any AgentMonitorControlling, coordinator: any AppSnapshotCoordinating) async {
        await agentMonitor.scan()
        guard !hasShutDown else { return }
        if let diagnostic = await agentMonitor.diagnostic {
            guard !hasShutDown else { return }
            await coordinator.applyScanFailure(occurredAt: diagnostic.occurredAt)
        } else {
            let state = await agentMonitor.state
            guard !hasShutDown else { return }
            await coordinator.applyScan(state.agents, scannedAt: state.lastScanAt)
        }
    }

    // MARK: - Orderly termination

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginTermination { success in
            sender.reply(toApplicationShouldTerminate: success)
        }
    }

    /// Begins (or joins an already-in-flight) orderly shutdown and always
    /// returns `.terminateLater`: the underlying shutdown work
    /// (`performOrderlyShutdownOnce()`) runs at most once no matter how
    /// many times this is called, but every caller's own `reply` closure
    /// is still invoked exactly once, after that shared shutdown work has
    /// fully completed. Internal (not `private`) so `AppLifecycleTests`
    /// can call this directly with a capturing `reply` closure instead of
    /// ever driving real `NSApplication`/`NSApp.reply(
    /// toApplicationShouldTerminate:)` termination machinery.
    @discardableResult
    func beginTermination(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        let sharedTask: Task<Void, Never>
        if let existing = terminationTask {
            sharedTask = existing
        } else {
            let newTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.performOrderlyShutdownOnce()
            }
            terminationTask = newTask
            sharedTask = newTask
        }

        Task {
            _ = await sharedTask.value
            reply(true)
        }
        return .terminateLater
    }

    /// Cancels the monitor scan loop and stops `agentMonitor` — never
    /// awaiting the loop task's own completion — before proceeding to
    /// `AppSnapshotCoordinator.shutdown()`. `agentMonitor.scan()` may run
    /// off-actor, detached detection work that never notices cancellation
    /// (a non-cooperative detector); awaiting `scanLoopTask.value` here
    /// would let such a scan hang orderly termination indefinitely. Instead,
    /// `scanLoopTask` is merely signalled to cancel and `agentMonitor.stop()`
    /// is awaited — which itself never awaits the in-flight detection
    /// either (see `AgentMonitor.stop()`'s own documentation) — so this
    /// method always proceeds promptly regardless of how long that
    /// detection actually takes to resolve, if it ever does. Any scan tick
    /// already in flight at the moment termination began can still never
    /// apply to the coordinator: `performScanTick`'s own `hasShutDown`
    /// check (already flipped `true` above) and `AgentMonitor`'s
    /// generation-based invalidation both independently fence that off,
    /// however long that stale scan keeps running afterward.
    ///
    /// `hasShutDown` itself is flipped `true` as the very first statement,
    /// ahead of any await — it is what every `requestX` menu/bridge-menu
    /// entry point (`requestSetKeepAwakeMode`,
    /// `requestSetIncludePrereleaseUpdates`, `requestOpenLatestRelease`)
    /// checks, both before ever creating its own `Task` and again at that
    /// `Task`'s very start, so none of them can queue (or resume) a fresh
    /// coordinator call once termination has begun. `bridgeMessageHandler
    /// ?.stopAccepting()` is called immediately afterward, for the exact
    /// same reason on the bridge side: any bridge command dispatched at
    /// or after this instant is rejected with a typed
    /// `BridgeCommandError.shuttingDown` before it can ever reach the
    /// router. Both of these run synchronously, before this method's own
    /// first `await` — unlike `bridgeMessageHandler?.cancelAll()` below,
    /// which stays at its existing required position, later in the
    /// sequence, and only cancels/clears whatever was already in flight
    /// *before* that point.
    ///
    /// Only once monitor work has been cancelled/stopped does this await
    /// `AppSnapshotCoordinator.shutdown()`, which flushes history, cancels
    /// the update scheduler, and releases the power assertion; bridge
    /// handlers are removed from the web view only after that coordinator
    /// shutdown has fully completed, exactly matching the required
    /// production order (stop monitor work → coordinator shutdown →
    /// remove bridge handlers → reply). Guarded by `hasShutDown` so a
    /// second concurrent/subsequent quit request never repeats this work.
    /// Finally, if bootstrap ever had to fall back to a dedicated
    /// temporary storage directory (see `StorageBootstrap.Locations
    /// .fallbackRoot`), that directory is recursively removed here, once
    /// the coordinator's own shutdown has fully flushed history to it —
    /// never before, and never left behind to accumulate as permanent
    /// orphaned disk usage across every future launch that also falls
    /// back (each such launch mints its own fresh, uniquely-named
    /// fallback directory, so an old one is never reused/needed again
    /// once this process exits normally).
    private func performOrderlyShutdownOnce() async {
        guard !hasShutDown else { return }
        hasShutDown = true
        bridgeMessageHandler?.stopAccepting()

        scanLoopTask?.cancel()
        scanLoopTask = nil
        await agentMonitor?.stop()

        try? await coordinator?.shutdown()

        bridgeMessageHandler?.cancelAll()
        removeBridgeHandlersFromWebView()

        cleanUpFallbackStorageRootIfNeeded()
    }

    private func removeBridgeHandlersFromWebView() {
        guard let controller = webViewUserContentController else { return }
        controller.removeScriptMessageHandler(forName: BridgeMessageHandler.messageHandlerName, contentWorld: BridgeContentWorld.bridge)
        controller.removeAllUserScripts()
    }

    /// Recursively removes `fallbackStorageRoot` (if bootstrap ever fell
    /// back to one — see `StorageBootstrap.Locations.fallbackRoot`) from
    /// disk. Best-effort: a failure here is logged, never thrown/crashed
    /// on, since by this point in shutdown there is no `AppSnapshot`/
    /// `Diagnostic` left to attach it to and no further recovery is
    /// possible or necessary — `StorageBootstrap
    /// .pruneStaleFallbackDirectories(...)`'s own bounded startup pruning
    /// (run at the *next* launch) is the backstop for whatever a failure
    /// here leaves behind.
    private func cleanUpFallbackStorageRootIfNeeded() {
        guard let fallbackStorageRoot else { return }
        do {
            try FileManager.default.removeItem(at: fallbackStorageRoot)
        } catch {
            Self.logger.error("Failed to clean up temporary fallback storage directory at shutdown: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Owns the strong reference to `AppDelegate` for the entire duration of
/// `NSApplication.run()`. `NSApplication.delegate` is a `weak` property, so
/// assigning `application.delegate = AppDelegate()` with no other strong
/// reference to the delegate would leave it eligible for deallocation at any
/// point during the run loop. Callers must keep the `ApplicationRuntime`
/// itself alive — e.g. via `withExtendedLifetime` — around the call to
/// `run()`.
@MainActor
final class ApplicationRuntime {
    let delegate: AppDelegate

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    /// Configures `application` to use `delegate`, forces an accessory
    /// (menu-bar-only, no Dock icon) activation policy — matching the Glaze
    /// host's `appConfig.macOS.activationPolicy` setting in `package.json` —
    /// and runs the main event loop.
    func run(application: NSApplication = .shared) -> Never {
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        // `NSApplication.run()` blocks until the app terminates but is not
        // itself typed as `Never`; this is unreachable in practice.
        fatalError("NSApplication.run() returned unexpectedly")
    }
}
