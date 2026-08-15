import XCTest
import WebKit
@testable import Seer

// MARK: - The real, bundled production renderer

/// Locates the exact production standalone renderer this suite loads —
/// never a synthetic fixture. `SeerTests` runs hosted inside `Seer.app`
/// (`TEST_HOST` in `Seer.xcodeproj`), so `Bundle.main` here *is* the built
/// `Seer.app` bundle, and its own `Resources` build phase already copies
/// `build/standalone-renderer/Renderer` — built from `renderer/standalone/
/// index.tsx` by `npm run build:standalone-renderer` — into it under the
/// name `Renderer`. This is precisely the same expression
/// `AppDelegate.bootstrapServices(...)`'s own `rendererRoot` default
/// parameter uses (see `Sources/App/AppDelegate.swift`), so every test in
/// this file drives the real `SeerSchemeHandler` serving the real,
/// Vite-built React app that ships in production, through the real
/// `PanelController` wiring — nothing here is stood in for.
private enum BundledRenderer {
    static let root = SeerRendererRoot(
        url: Bundle.main.resourceURL!.appendingPathComponent("Renderer", isDirectory: true)
    )

    private static let documentFileName = "standalone-window.html"

    /// Thrown whenever the bundled renderer document cannot be produced or
    /// located, even after a genuine build attempt — surfaced as a real
    /// XCTest setup failure (never `XCTSkip`), so a missing or failed
    /// renderer build is always visible as a failing required-coverage
    /// test, never silently allowed to "pass" with no renderer under test.
    struct SetupFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// A deterministic precondition, run once before any test in this file:
    /// fail fast with an actionable message rather than letting a missing
    /// build artifact surface later as an opaque `WKWebView` load timeout.
    /// If the bundled document is missing (a clean checkout that has never
    /// run the renderer build), this builds it exactly once, entirely
    /// offline — `npm run build:standalone-renderer` only ever invokes the
    /// already-installed local Vite toolchain in `node_modules`, never a
    /// network fetch — checking the real process' termination
    /// status/reason and capturing its stdout/stderr, and, if the build
    /// fails or the document is still absent afterward, throws
    /// `SetupFailure` with the captured diagnostics — which XCTest reports
    /// as a genuine setup failure of every test in this file, never a skip
    /// that would let "no renderer" quietly count as "renderer coverage
    /// passed".
    static func ensureAvailable(file: StaticString = #filePath) throws {
        let documentURL = root.url.appendingPathComponent(documentFileName)
        guard !FileManager.default.fileExists(atPath: documentURL.path) else { return }

        let repoRoot = try repoRootURL(fromTestFile: file)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.currentDirectoryURL = repoRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npm", "run", "build:standalone-renderer"]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SetupFailure(description: """
                Failed to launch `npm run build:standalone-renderer` from \(repoRoot.path): \(error)
                """)
        }
        process.waitUntilExit()

        let stdoutText = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SetupFailure(description: """
                `npm run build:standalone-renderer` (run from \(repoRoot.path)) did not succeed \
                (terminationReason: \(process.terminationReason), status: \(process.terminationStatus)).
                --- stdout ---
                \(stdoutText)
                --- stderr ---
                \(stderrText)
                """)
        }

        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            throw SetupFailure(description: """
                Bundled renderer document not found at \(documentURL.path) even though \
                `npm run build:standalone-renderer` (run from \(repoRoot.path)) reported success.
                --- stdout ---
                \(stdoutText)
                --- stderr ---
                \(stderrText)
                """)
        }
    }

    /// Derives the repository root by walking upward from this very
    /// source file's own on-disk location (`apps/macos/Seer/Tests/
    /// Integration/RendererIntegrationTests.swift`) until it finds the
    /// directory that actually contains both `package.json` and
    /// `vite.standalone.config.ts` — the two files that mark the real
    /// repository root `npm run build:standalone-renderer` must be
    /// invoked from — rather than a brittle fixed count of
    /// `deleteLastPathComponent()` calls (which previously undershot by
    /// one level, resolving to `<repo>/apps` instead of `<repo>`, so
    /// `npm run` there always failed with "no such file or directory:
    /// package.json") or any assumption about the current working
    /// directory `xcodebuild` happens to invoke tests from. Deterministic
    /// regardless of caller; throws rather than looping forever if it
    /// ever walks past the filesystem root without finding a match.
    /// `fileprivate` (not `private`) so `RendererIntegrationTests`' own
    /// `testBundledRendererRepoRootDiscoveryFindsTheActualRepoRoot`
    /// characterization test — in this same file — can exercise it
    /// directly.
    fileprivate static func repoRootURL(fromTestFile file: StaticString) throws -> URL {
        let markers = ["package.json", "vite.standalone.config.ts"]
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()

        while true {
            let isRepoRoot = markers.allSatisfy {
                fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            if isRepoRoot { return directory }

            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw SetupFailure(description: """
                    Could not locate the repository root (a directory containing both \
                    \(markers.joined(separator: " and "))) by walking upward from \(file).
                    """)
            }
            directory = parent
        }
    }
}

// MARK: - Test doubles

/// A scripted `AgentDetecting` double whose `detect(now:)` result is set by
/// the test *before* `AgentMonitor.scan()` is invoked, and only ever read
/// afterward (`AgentMonitor.scan()` runs the detector inside a detached
/// task — see its own documentation — so this must genuinely be safe to
/// read cross-thread). `@unchecked Sendable` on the same "call ordering,
/// never true concurrent access" basis already documented by this
/// codebase's other single-writer-then-many-reader fakes (e.g.
/// `AppSnapshotCoordinatorTests.CoordinatorFakePowerBackend`).
private final class FakeAgentDetecting: AgentDetecting, @unchecked Sendable {
    var nextAgents: [ActiveAgent] = []

    func detect(now: Int64) async throws -> [ActiveAgent] {
        nextAgents
    }
}

/// An always-succeeding `PowerAssertionBackend` double, additionally
/// tracking every assertion it ever created/released — this suite's
/// lifecycle assertions use these counts to prove
/// `AppSnapshotCoordinator.shutdown()` actually released whatever it had
/// created, never leaving one retained past a test.
private final class FakePowerAssertionBackend: PowerAssertionBackend, @unchecked Sendable {
    private var nextID: UInt32 = 1
    private(set) var createdCount = 0
    private(set) var releasedIDs: [UInt32] = []

    func createAssertion(mode: KeepAwakeMode, reason: String) throws -> UInt32 {
        defer { nextID += 1 }
        createdCount += 1
        return nextID
    }

    func releaseAssertion(id: UInt32) throws {
        releasedIDs.append(id)
    }
}

/// The typed, closed `BridgeCommandHandling` fake this suite's real-UI
/// bridge-path test routes `BridgeMessageHandler` through — recording the
/// *exact* commands/arguments it receives, rather than standing up a real
/// `AppSnapshotCoordinator` (whose real side effects — power assertions,
/// disk-backed history — are irrelevant to proving the wire path itself
/// works end to end).
@MainActor
private final class RecordingBridgeCommandRouter: BridgeCommandHandling {
    private(set) var keepAwakeModeSetCalls: [KeepAwakeMode] = []
    private(set) var historyClearCallCount = 0
    private let snapshot: AppSnapshot

    init(snapshot: AppSnapshot) {
        self.snapshot = snapshot
    }

    func snapshotGet() async -> BridgeSnapshotOutcome { .success(snapshot) }

    func keepAwakeModeSet(_ mode: KeepAwakeMode) async -> BridgeSnapshotOutcome {
        keepAwakeModeSetCalls.append(mode)
        return .success(snapshot)
    }

    func historyClear() async -> BridgeSnapshotOutcome {
        historyClearCallCount += 1
        return .success(snapshot)
    }

    func updatesCheck() async -> BridgeSnapshotOutcome { .success(snapshot) }
    func updatesOpen() async -> BridgeVoidOutcome { .success(()) }
    func panelHide() async -> BridgeVoidOutcome { .success(()) }
    func appQuit() async -> BridgeVoidOutcome { .success(()) }
}

// MARK: - RendererIntegrationTests

@MainActor
final class RendererIntegrationTests: XCTestCase {
    private let settingsURL = URL(fileURLWithPath: "/Renderer-Integration-Test/ai.opencoven.seer/settings.json")
    private let historyURL = URL(fileURLWithPath: "/Renderer-Integration-Test/ai.opencoven.seer/history.json")

    override func setUpWithError() throws {
        try super.setUpWithError()
        try BundledRenderer.ensureAvailable()
    }

    /// A characterization test for `BundledRenderer.repoRootURL`
    /// independent of the renderer build itself: proves the walk-upward
    /// discovery actually lands on the real repository root (a directory
    /// containing both `package.json` and `vite.standalone.config.ts`),
    /// not merely "some ancestor directory" — the previous fixed
    /// `deleteLastPathComponent()` count silently resolved one level too
    /// shallow (`<repo>/apps`) and this test would have caught that
    /// regression directly, without needing a full `npm` build to surface
    /// the failure downstream.
    func testBundledRendererRepoRootDiscoveryFindsTheActualRepoRoot() throws {
        let discovered = try BundledRenderer.repoRootURL(fromTestFile: #filePath)

        let fileManager = FileManager.default
        XCTAssertTrue(
            fileManager.fileExists(atPath: discovered.appendingPathComponent("package.json").path),
            "discovered root \(discovered.path) must contain package.json"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: discovered.appendingPathComponent("vite.standalone.config.ts").path),
            "discovered root \(discovered.path) must contain vite.standalone.config.ts"
        )
        XCTAssertFalse(
            discovered.path.hasSuffix("/apps"),
            "must not undershoot to <repo>/apps, the previous fixed-depth bug's exact failure mode"
        )
    }

    /// One full, real Swift-side stack: a real `PanelController` (and
    /// therefore real `SeerWebViewFactory`/`SeerSchemeHandler`/
    /// `SeerWebViewNavigationDelegate` wiring) serving the *real bundled*
    /// `BundledRenderer.root`, a real `RendererEventSink`, and a real
    /// `BridgeMessageHandler` registered via the real
    /// `BridgeMessageHandlerRegistration.register(_:on:)` — i.e. exactly
    /// production's own `AppDelegate.bootstrapServices(...)` wiring, minus
    /// the status item/agent-monitor-loop/update-scheduler pieces this
    /// suite does not need. `router` is the only seam a test controls
    /// directly.
    @MainActor
    private struct Harness {
        let panel: PanelController
        let bridgeMessageHandler: BridgeMessageHandler
        let coordinator: AppSnapshotCoordinator?

        var webView: WKWebView { panel.webView }

        /// Fully, deterministically releases every real resource this
        /// harness acquired: stops accepting/cancels in-flight bridge
        /// work, runs the real `AppSnapshotCoordinator.shutdown()` path
        /// (releasing its power assertion and stopping its update
        /// scheduler) when a real coordinator backs this harness, removes
        /// the exact registration `BridgeMessageHandlerRegistration
        /// .register` installed (the isolated-world script message
        /// handler and the relay user script), and finally stops loading
        /// and closes the panel/web view. Idempotent — every step here is
        /// safe to run more than once — so callers may invoke this both
        /// explicitly at the end of a passing test *and* register it via
        /// `XCTestCase.addTeardownBlock`, which XCTest guarantees runs
        /// after the test method returns whether it passed, failed an
        /// assertion, or threw partway through — so a thrown error can
        /// never skip this and leak a webview/power assertion/update
        /// scheduler.
        func tearDown() async {
            bridgeMessageHandler.stopAccepting()
            bridgeMessageHandler.cancelAll()
            try? await coordinator?.shutdown()
            panel.userContentController.removeScriptMessageHandler(
                forName: BridgeMessageHandler.messageHandlerName,
                contentWorld: BridgeContentWorld.bridge
            )
            panel.userContentController.removeAllUserScripts()
            panel.webView.stopLoading()
            panel.panel.close()
        }
    }

    private func makeHarness(router: any BridgeCommandHandling) -> Harness {
        let panel = PanelController(rendererRoot: BundledRenderer.root)
        let rendererSink = RendererEventSink(javaScriptCaller: panel.webView)
        let bridgeMessageHandler = BridgeMessageHandler(router: router, responder: rendererSink)
        BridgeMessageHandlerRegistration.register(bridgeMessageHandler, on: panel.userContentController)
        panel.loadInitialDocument()

        return Harness(panel: panel, bridgeMessageHandler: bridgeMessageHandler, coordinator: nil)
    }

    /// Builds the same harness, but with a *real* `AppSnapshotCoordinator`
    /// (backed by in-memory settings/history storage, a fake power
    /// backend, and a fake update service — the "fake detector, storage,
    /// history, power, and update services" this task's requirements
    /// name) routed through `StandaloneBridgeCommandRouter.forCoordinator`
    /// — exactly the router production wiring builds.
    private func makeRealCoordinatorHarness(
        clock: MutableClock = MutableClock(now: 1_700_000_000_000)
    ) async throws -> (
        harness: Harness,
        coordinator: AppSnapshotCoordinator,
        detector: FakeAgentDetecting,
        agentMonitor: AgentMonitor,
        power: PowerAssertionService,
        powerBackend: FakePowerAssertionBackend,
        updateScheduler: FakeUpdateSchedulerControlling
    ) {
        let settingsStore = SettingsStore(
            store: AtomicJSONStore<SettingsDocument>(fileURL: settingsURL, fileSystem: InMemorySettingsFileSystem(), clock: clock)
        )
        let historyStore = HistoryStore(
            store: AtomicJSONStore<HistoryDocument>(fileURL: historyURL, fileSystem: InMemorySettingsFileSystem(), clock: clock),
            clock: clock
        )
        let powerBackend = FakePowerAssertionBackend()
        let power = PowerAssertionService(backend: powerBackend)
        let updateService = FakeUpdateChecking()
        let updateScheduler = FakeUpdateSchedulerControlling()
        let detector = FakeAgentDetecting()
        let agentMonitor = AgentMonitor(detector: detector, clock: clock)

        let panel = PanelController(rendererRoot: BundledRenderer.root)
        let rendererSink = RendererEventSink(javaScriptCaller: panel.webView)

        let coordinator = await AppSnapshotCoordinator.makeAtStartup(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: rendererSink,
            clock: clock,
            appVersion: "1.0.0-integration-test",
            updateService: updateService,
            updateScheduler: updateScheduler
        )

        let router = StandaloneBridgeCommandRouter.forCoordinator(coordinator)
        let bridgeMessageHandler = BridgeMessageHandler(router: router, responder: rendererSink)
        BridgeMessageHandlerRegistration.register(bridgeMessageHandler, on: panel.userContentController)
        panel.loadInitialDocument()

        let harness = Harness(panel: panel, bridgeMessageHandler: bridgeMessageHandler, coordinator: coordinator)
        return (harness, coordinator, detector, agentMonitor, power, powerBackend, updateScheduler)
    }

    // MARK: - JS helpers

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func evaluateString(_ webView: WKWebView, _ expression: String) async -> String? {
        (try? await webView.evaluateJavaScript(expression)) as? String
    }

    /// The real `HomeView`'s status title text node (`renderer/main/
    /// home-view.tsx`'s `statusTitle`) — exactly "Idle" or "Keeping Mac
    /// awake", nothing else in the bundled app renders either string.
    /// Never a test-fixture stand-in element.
    private func statusTitleText(_ webView: WKWebView) async -> String? {
        let expression = """
            (function () {
              var nodes = Array.from(document.querySelectorAll('span'));
              var match = nodes.find(function (node) {
                return node.textContent === 'Idle' || node.textContent === 'Keeping Mac awake';
              });
              return match ? match.textContent : null;
            })()
            """
        return await evaluateString(webView, expression)
    }

    /// Clicks the first real `<button>` whose exact, trimmed text content
    /// matches `text` (e.g. the real `PanelTabs`/`SegmentedControlItem`
    /// buttons) — driving the actual production React UI, never a
    /// directly-injected wire-protocol event. Returns whether a match was
    /// found and clicked.
    private func clickButtonWithText(_ webView: WKWebView, _ text: String) async -> Bool {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let expression = """
            (function () {
              var buttons = Array.from(document.querySelectorAll('button'));
              var match = buttons.find(function (button) {
                return button.textContent && button.textContent.trim() === '\(escaped)';
              });
              if (!match) { return false; }
              match.click();
              return true;
            })()
            """
        return (try? await webView.evaluateJavaScript(expression)) as? Bool ?? false
    }

    /// Clicks the real, non-disabled `<button aria-label="…">` matching
    /// `label` (e.g. `HistoryView`'s real "Clear history" button) — again
    /// driving actual production UI, not a synthetic stand-in. Returns
    /// `false` (and never clicks) while the button is still disabled, so
    /// callers can `waitUntil` it becomes clickable.
    private func clickButtonWithAriaLabel(_ webView: WKWebView, _ label: String) async -> Bool {
        let escaped = label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let expression = """
            (function () {
              var match = document.querySelector('[aria-label=\\'\(escaped)\\']');
              if (!match || match.disabled) { return false; }
              match.click();
              return true;
            })()
            """
        return (try? await webView.evaluateJavaScript(expression)) as? Bool ?? false
    }

    // MARK: 1. Bundled document loads, exposes the exact bridge version

    /// Full, real stack (real `PanelController`, real `SeerSchemeHandler`
    /// serving the *actual bundled* `standalone-window.html` from
    /// `build/standalone-renderer/Renderer`, real navigation policy) with
    /// fake detector/storage/history/power/update services backing a real
    /// `AppSnapshotCoordinator`. Waits for the bundled document to
    /// actually finish loading through `seer://app/standalone-window.html`
    /// before asserting `document.title`/`window.seerNative.version`, and
    /// confirms the real coordinator's shutdown lifecycle (power
    /// assertion released, update scheduler stopped) leaves nothing
    /// retained once this test's own harness tears down.
    func testBundledDocumentLoadsAndExposesBridgeVersion() async throws {
        let (harness, _, _, _, power, powerBackend, updateScheduler) = try await makeRealCoordinatorHarness()
        addTeardownBlock { await harness.tearDown() }

        await waitUntil { await self.evaluateString(harness.webView, "document.title") == "Seer" }

        let title = await evaluateString(harness.webView, "document.title")
        XCTAssertEqual(title, "Seer")

        let version = await evaluateString(harness.webView, "window.seerNative && window.seerNative.version")
        XCTAssertEqual(version, bridgeVersion)

        await harness.tearDown()
        XCTAssertFalse(power.isActive, "the coordinator's shutdown() must release the power assertion, leaving none retained")
        XCTAssertEqual(
            powerBackend.releasedIDs.count, powerBackend.createdCount,
            "every power assertion this test's coordinator created must have been released"
        )
        XCTAssertEqual(updateScheduler.stopCallCount, 1, "the coordinator's shutdown() must stop the update scheduler exactly once")
    }

    // MARK: 2. A synthetic AppSnapshot visibly updates the real Status UI

    /// Drives a real scan through a fake `AgentDetecting`/`AgentMonitor`
    /// pair, exactly mirroring `AppDelegate.performScanTick(agentMonitor:
    /// coordinator:)`'s own two-step handoff (`agentMonitor.scan()` then
    /// `coordinator.applyScan(state.agents, scannedAt:)`), then confirms
    /// the resulting `snapshot.changed` event — delivered through the
    /// real `RendererEventSink` → `window.seerNative.receive` path, into
    /// the real bundled React app's own `useAppSnapshot`/`HomeView` —
    /// is visibly reflected in the real, rendered status title text.
    func testSyntheticSnapshotUpdatesVisibleStatusText() async throws {
        let (harness, coordinator, detector, agentMonitor, power, powerBackend, updateScheduler) = try await makeRealCoordinatorHarness()
        addTeardownBlock { await harness.tearDown() }

        await waitUntil { await self.evaluateString(harness.webView, "document.title") == "Seer" }
        await waitUntil { await self.statusTitleText(harness.webView) != nil }

        let initialStatus = await statusTitleText(harness.webView)
        XCTAssertEqual(initialStatus, "Idle", "the real HomeView status title must read Idle before any agent is detected")

        detector.nextAgents = [
            ActiveAgent(
                id: "codex:/fixtures/active.jsonl",
                name: "Codex",
                detail: "Fixtures · Working",
                source: .session,
                lastActivityAt: 1_700_000_000_000
            ),
        ]
        await agentMonitor.scan()
        let state = await agentMonitor.state
        XCTAssertTrue(state.active, "the fake detector's scripted agent must have made the monitor report active")
        await coordinator.applyScan(state.agents, scannedAt: state.lastScanAt)

        await waitUntil { await self.statusTitleText(harness.webView) == "Keeping Mac awake" }
        let updatedStatus = await statusTitleText(harness.webView)
        XCTAssertEqual(
            updatedStatus, "Keeping Mac awake",
            "a real snapshot.changed event must visibly update the real HomeView's status title"
        )
        XCTAssertTrue(coordinator.snapshot.monitor.active)

        await harness.tearDown()
        XCTAssertFalse(power.isActive, "the coordinator's shutdown() must release the power assertion, leaving none retained")
        XCTAssertEqual(
            powerBackend.releasedIDs.count, powerBackend.createdCount,
            "every power assertion this test's coordinator created must have been released"
        )
        XCTAssertEqual(updateScheduler.stopCallCount, 1, "the coordinator's shutdown() must stop the update scheduler exactly once")
    }

    // MARK: 3. keepAwakeMode.set / history.clear reach the typed fake coordinator

    /// Triggers both commands by clicking real, rendered buttons in the
    /// actual bundled React app — the "System + Display" segmented-control
    /// option (`HomeView`) and the "Clear history" toolbar button
    /// (`HistoryView`) — never by injecting a hand-rolled wire-protocol
    /// event. Each click flows through the real `RendererBridge` →
    /// `createDomRelayPort` → `BridgeRelayUserScript`'s isolated
    /// content-world listener → real `BridgeMessageHandler`, and is
    /// asserted to have reached the typed `RecordingBridgeCommandRouter`
    /// fake with the exact commands/arguments — never
    /// `BridgeMessageHandler.handle(body:)` called directly, and no bridge
    /// logic of any kind duplicated in this test file.
    func testKeepAwakeModeSetAndHistoryClearReachTypedFakeCoordinatorThroughRealBridgePath() async throws {
        // Seeded with non-empty history so `HistoryView`'s real
        // "Clear history" button (disabled while there is nothing to
        // clear) is actually clickable from the moment the page loads.
        let seededSnapshot = AppSnapshot(
            monitor: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0),
            history: HistoryStats(
                totalAwakeMs: 3_600_000,
                todayAwakeMs: 1_800_000,
                sessionCount: 1,
                perAgent: [],
                currentSession: nil,
                recentSessions: [
                    AwakeSession(
                        id: "session-1",
                        startedAt: 1_699_999_000_000,
                        endedAt: 1_700_000_000_000,
                        durationMs: 1_000_000,
                        mode: .system,
                        agents: []
                    ),
                ]
            ),
            update: UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: nil),
            diagnostics: [],
            appVersion: "1.0.0-integration-test"
        )
        let router = RecordingBridgeCommandRouter(snapshot: seededSnapshot)
        let harness = makeHarness(router: router)
        addTeardownBlock { await harness.tearDown() }

        await waitUntil { await self.evaluateString(harness.webView, "document.title") == "Seer" }

        await waitUntil { await self.clickButtonWithText(harness.webView, "System + Display") }
        await waitUntil { router.keepAwakeModeSetCalls.count == 1 }

        await waitUntil { await self.clickButtonWithText(harness.webView, "History") }
        await waitUntil { await self.clickButtonWithAriaLabel(harness.webView, "Clear history") }
        await waitUntil { router.historyClearCallCount == 1 }

        XCTAssertEqual(router.keepAwakeModeSetCalls, [.display], "the exact requested mode must reach the typed fake coordinator")
        XCTAssertEqual(router.historyClearCallCount, 1, "history.clear must reach the typed fake coordinator exactly once")

        await harness.tearDown()
    }
}
