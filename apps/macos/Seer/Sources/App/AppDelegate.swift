import Cocoa
import WebKit

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

/// The one `BridgeMessageHandler` operation orderly termination depends on.
/// Abstracted the same way as `AgentMonitorControlling` above, so
/// `AppLifecycleTests` can assert "bridge handlers were cancelled at quit"
/// against a fake without needing a real `WKWebView`/router stack.
@MainActor
protocol BridgeHandlerCancelling: AnyObject {
    func cancelAll()
}

extension BridgeMessageHandler: BridgeHandlerCancelling {}

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

    private var scanLoopTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var hasShutDown = false

    private let sleeper: any Sleeper

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
        bridgeMessageHandler: (any BridgeHandlerCancelling)? = nil
    ) {
        self.coordinator = coordinator
        self.agentMonitor = agentMonitor
        self.sleeper = sleeper
        self.bridgeMessageHandler = bridgeMessageHandler
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

    /// The real launch sequence, in order: (1) accessory activation is
    /// already set by `ApplicationRuntime.run()` before `NSApplication.run()`
    /// ever dispatches this method, and reasserted here defensively; (2)
    /// settings/history load and (3) the coordinator/bridge/panel/status
    /// item are created — `AppSnapshotCoordinator
    /// .makeAtStartupWithScheduledUpdates` performs the settings/history
    /// load, folds in startup diagnostics, runs Seer's one-time startup
    /// update check, and starts the periodic update scheduler, all as part
    /// of constructing the coordinator; (4) `beginMonitoring()` then
    /// performs the initial agent scan and (5) begins the recurring
    /// three-second monitor loop.
    private func bootstrapProduction() async {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppMainMenuBuilder.build(appName: "Seer") { [weak self] in
            self?.requestQuit()
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let clock = SystemClock()

        let applicationSupportDirectory: URL
        let settingsURL: URL
        let historyURL: URL
        do {
            applicationSupportDirectory = try SettingsFileLocation.resolveApplicationSupportDirectory()
            settingsURL = try SettingsFileLocation.settingsFileURL(applicationSupportDirectory: applicationSupportDirectory)
            historyURL = try HistoryFileLocation.historyFileURL(applicationSupportDirectory: applicationSupportDirectory)
        } catch {
            // Without a resolvable Application Support location there is
            // nowhere durable to persist settings/history at all; the app
            // cannot usefully continue past this point.
            return
        }

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

        let rendererRoot = SeerRendererRoot(url: Bundle.main.resourceURL!.appendingPathComponent("Renderer", isDirectory: true))
        let panel = PanelController(rendererRoot: rendererRoot, clock: clock)
        let rendererSink = RendererEventSink(javaScriptCaller: panel.webView)

        let initialSettings = await settingsStore.load()
        let statusItem = StatusItemController(
            statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength),
            actions: StatusItemController.Actions(
                togglePanel: { [weak self] in self?.toggleFromStatusItem() },
                setKeepAwakeMode: { [weak self] mode in self?.requestSetKeepAwakeMode(mode) },
                setIncludePrereleaseUpdates: { [weak self] value in self?.requestSetIncludePrereleaseUpdates(value) },
                viewLatestRelease: { [weak self] in self?.requestOpenLatestRelease() },
                quit: { [weak self] in self?.requestQuit() }
            ),
            initialSnapshot: .empty(version: appVersion),
            includePrereleaseUpdates: initialSettings.value.includePrereleaseUpdates
        )

        let broadcastSink = MulticastRendererSink(sinks: [rendererSink, statusItem])

        let coordinator = await AppSnapshotCoordinator.makeAtStartupWithScheduledUpdates(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: broadcastSink,
            clock: clock,
            appVersion: appVersion,
            updateService: updateService
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
        self.bridgeMessageHandler = bridgeMessageHandler
        self.webViewUserContentController = panel.userContentController

        await beginMonitoring()
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

    private func requestSetKeepAwakeMode(_ mode: KeepAwakeMode) {
        guard let coordinator else { return }
        Task { try? await coordinator.setKeepAwakeMode(mode) }
    }

    private func requestSetIncludePrereleaseUpdates(_ value: Bool) {
        guard let coordinator else { return }
        statusItemController?.apply(includePrereleaseUpdates: value)
        Task { try? await coordinator.setIncludePrereleaseUpdates(value) }
    }

    private func requestOpenLatestRelease() {
        guard let coordinator else { return }
        Task { await coordinator.openLatestRelease() }
    }

    private func requestQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Monitor scan loop (steps 4 & 5)

    /// Performs the initial agent scan (step 4), then begins the recurring
    /// three-second monitor loop (step 5). Internal (not `private`) so
    /// `AppLifecycleTests` can drive it directly against injected fakes.
    func beginMonitoring() async {
        guard let agentMonitor, let coordinator else { return }
        await performScanTick(agentMonitor: agentMonitor, coordinator: coordinator)
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
    /// `applyScan(_:scannedAt:)`.
    private func performScanTick(agentMonitor: any AgentMonitorControlling, coordinator: any AppSnapshotCoordinating) async {
        await agentMonitor.scan()
        if let diagnostic = await agentMonitor.diagnostic {
            await coordinator.applyScanFailure(occurredAt: diagnostic.occurredAt)
        } else {
            let state = await agentMonitor.state
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

    /// Stops the monitor scan loop, cancels every in-flight bridge command
    /// and removes the bridge's registration from the web view, then awaits
    /// `AppSnapshotCoordinator.shutdown()` — which itself flushes history
    /// and releases the power assertion. Guarded by `hasShutDown` so a
    /// second concurrent/subsequent quit request never repeats this work.
    private func performOrderlyShutdownOnce() async {
        guard !hasShutDown else { return }
        hasShutDown = true

        scanLoopTask?.cancel()
        scanLoopTask = nil

        await agentMonitor?.stop()
        bridgeMessageHandler?.cancelAll()
        removeBridgeHandlersFromWebView()

        try? await coordinator?.shutdown()
    }

    private func removeBridgeHandlersFromWebView() {
        guard let controller = webViewUserContentController else { return }
        controller.removeScriptMessageHandler(forName: BridgeMessageHandler.messageHandlerName, contentWorld: BridgeContentWorld.bridge)
        controller.removeAllUserScripts()
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
