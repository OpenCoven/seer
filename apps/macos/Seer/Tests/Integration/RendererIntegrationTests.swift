import XCTest
import WebKit
@testable import Seer

// MARK: - Fixture renderer document

/// Writes a small, self-contained fixture document into `root` that fills
/// exactly the same contract Seer's real bundled renderer
/// (`renderer/standalone/index.tsx`) fills — a `<title>Seer</title>`
/// document that freezes `window.seerNative` with the exact production
/// `bridgeVersion`, renders a visible "Status" element driven by
/// `snapshot.changed` events, and sends outbound bridge requests through
/// the *exact* wire contract `renderer/bridge/dom-relay-port.ts` uses
/// (`BridgeRelayUserScript.attributeName`/`.eventName`, interpolated here
/// rather than duplicated as literals, so this fixture cannot silently
/// drift from the native relay it is exercising). Deliberately never the
/// real Vite-built bundle (`build/standalone-renderer/Renderer`, a
/// gitignored build artifact `SeerSchemeHandlerTests` also never depends
/// on) — every real production Swift component this test exercises
/// (`SeerSchemeHandler`, `PanelController`, `BridgeRelayUserScript`,
/// `BridgeMessageHandler`) is exercised for real; only the renderer's own
/// TypeScript/React implementation is stood in for by this fixture.
private enum RendererFixture {
    static func write(into root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let html = """
        <!doctype html>
        <html>
          <head><title>Seer</title></head>
          <body>
            <div id="status">Idle</div>
            <script src="./app.js"></script>
          </body>
        </html>
        """

        let js = """
        window.__seerTestReceived = [];
        window.seerNative = Object.freeze({
          version: "\(bridgeVersion)",
          receive: function (message) {
            window.__seerTestReceived.push(message);
            if (message && message.kind === "event" && message.type === "snapshot.changed") {
              var el = document.getElementById("status");
              if (el) {
                el.textContent = message.snapshot.monitor.active ? "Active" : "Idle";
              }
            }
          }
        });
        window.__seerSendBridgeRequest = function (id, method, payload) {
          var request = { id: id, version: "\(bridgeVersion)", method: method, payload: payload };
          document.documentElement.setAttribute("\(BridgeRelayUserScript.attributeName)", JSON.stringify(request));
          document.documentElement.dispatchEvent(new Event("\(BridgeRelayUserScript.eventName)", { bubbles: false }));
        };
        """

        try html.write(to: root.appendingPathComponent("standalone-window.html"), atomically: true, encoding: .utf8)
        try js.write(to: root.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
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

/// An always-succeeding `PowerAssertionBackend` double — this test never
/// exercises power-assertion failure handling, only that a synthetic scan
/// can flow all the way through `AppSnapshotCoordinator.applyScan(_:
/// scannedAt:)` to a real, visible renderer update.
private final class FakePowerAssertionBackend: PowerAssertionBackend, @unchecked Sendable {
    private var nextID: UInt32 = 1

    func createAssertion(mode: KeepAwakeMode, reason: String) throws -> UInt32 {
        defer { nextID += 1 }
        return nextID
    }

    func releaseAssertion(id: UInt32) throws {}
}

/// The typed, closed `BridgeCommandHandling` fake this suite's bridge-path
/// test routes `BridgeMessageHandler` through — recording the *exact*
/// commands/arguments it receives, rather than standing up a real
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

    /// One full, real Swift-side stack: a real `PanelController` (and
    /// therefore real `SeerWebViewFactory`/`SeerSchemeHandler`/
    /// `SeerWebViewNavigationDelegate` wiring) serving `RendererFixture`
    /// from a fresh temporary directory, a real `RendererEventSink`, and a
    /// real `BridgeMessageHandler` registered via the real
    /// `BridgeMessageHandlerRegistration.register(_:on:)` — i.e. exactly
    /// production's own `AppDelegate.bootstrapServices(...)` wiring, minus
    /// the status item/agent-monitor-loop/update-scheduler pieces this
    /// suite does not need. `router` is the only seam a test controls
    /// directly.
    @MainActor
    private struct Harness {
        let tempRoot: URL
        let panel: PanelController
        let bridgeMessageHandler: BridgeMessageHandler

        var webView: WKWebView { panel.webView }

        func tearDown() async {
            // Stops accepting/cancels in-flight bridge work, then removes
            // the exact registration `BridgeMessageHandlerRegistration
            // .register` installed — the isolated-world script message
            // handler and the relay user script — before releasing the
            // temporary renderer root this test served resources from.
            bridgeMessageHandler.stopAccepting()
            bridgeMessageHandler.cancelAll()
            panel.userContentController.removeScriptMessageHandler(
                forName: BridgeMessageHandler.messageHandlerName,
                contentWorld: BridgeContentWorld.bridge
            )
            panel.userContentController.removeAllUserScripts()
            panel.webView.stopLoading()
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func makeHarness(router: any BridgeCommandHandling) throws -> Harness {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RendererIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try RendererFixture.write(into: tempRoot)

        let panel = PanelController(rendererRoot: SeerRendererRoot(url: tempRoot))
        let rendererSink = RendererEventSink(javaScriptCaller: panel.webView)
        let bridgeMessageHandler = BridgeMessageHandler(router: router, responder: rendererSink)
        BridgeMessageHandlerRegistration.register(bridgeMessageHandler, on: panel.userContentController)
        panel.loadInitialDocument()

        return Harness(tempRoot: tempRoot, panel: panel, bridgeMessageHandler: bridgeMessageHandler)
    }

    /// Builds the same harness, but with a *real* `AppSnapshotCoordinator`
    /// (backed by in-memory settings/history storage, a fake power
    /// backend, and a fake update service — the "fake detector, storage,
    /// history, power, and update services" this task's requirements
    /// name) routed through `StandaloneBridgeCommandRouter.forCoordinator`
    /// — exactly the router production wiring builds.
    private func makeRealCoordinatorHarness(
        clock: MutableClock = MutableClock(now: 1_700_000_000_000)
    ) async throws -> (harness: Harness, coordinator: AppSnapshotCoordinator, detector: FakeAgentDetecting, agentMonitor: AgentMonitor) {
        let settingsStore = SettingsStore(
            store: AtomicJSONStore<SettingsDocument>(fileURL: settingsURL, fileSystem: InMemorySettingsFileSystem(), clock: clock)
        )
        let historyStore = HistoryStore(
            store: AtomicJSONStore<HistoryDocument>(fileURL: historyURL, fileSystem: InMemorySettingsFileSystem(), clock: clock),
            clock: clock
        )
        let power = PowerAssertionService(backend: FakePowerAssertionBackend())
        let updateService = FakeUpdateChecking()
        let detector = FakeAgentDetecting()
        let agentMonitor = AgentMonitor(detector: detector, clock: clock)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RendererIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try RendererFixture.write(into: tempRoot)
        let panel = PanelController(rendererRoot: SeerRendererRoot(url: tempRoot))
        let rendererSink = RendererEventSink(javaScriptCaller: panel.webView)

        let coordinator = await AppSnapshotCoordinator.makeAtStartup(
            settingsStore: settingsStore,
            historyStore: historyStore,
            power: power,
            renderer: rendererSink,
            clock: clock,
            appVersion: "1.0.0-integration-test",
            updateService: updateService,
            updateScheduler: FakeUpdateSchedulerControlling()
        )

        let router = StandaloneBridgeCommandRouter.forCoordinator(coordinator)
        let bridgeMessageHandler = BridgeMessageHandler(router: router, responder: rendererSink)
        BridgeMessageHandlerRegistration.register(bridgeMessageHandler, on: panel.userContentController)
        panel.loadInitialDocument()

        let harness = Harness(tempRoot: tempRoot, panel: panel, bridgeMessageHandler: bridgeMessageHandler)
        return (harness, coordinator, detector, agentMonitor)
    }

    // MARK: - JS helpers

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func evaluateString(_ webView: WKWebView, _ expression: String) async -> String? {
        (try? await webView.evaluateJavaScript(expression)) as? String
    }

    private func evaluateInt(_ webView: WKWebView, _ expression: String) async -> Int? {
        if let number = (try? await webView.evaluateJavaScript(expression)) as? NSNumber {
            return number.intValue
        }
        return nil
    }

    // MARK: 1. Bundled document loads, exposes the exact bridge version

    /// Full, real stack (real `PanelController`, real `SeerSchemeHandler`
    /// serving the fixture document from disk, real navigation policy)
    /// with fake detector/storage/history/power/update services backing a
    /// real `AppSnapshotCoordinator`. Waits for the bundled document to
    /// actually finish loading through `seer://app/standalone-window.html`
    /// before asserting `document.title`/`window.seerNative.version`.
    func testBundledDocumentLoadsAndExposesBridgeVersion() async throws {
        let (harness, _, _, _) = try await makeRealCoordinatorHarness()

        await waitUntil { await self.evaluateString(harness.webView, "document.title") == "Seer" }

        let title = await evaluateString(harness.webView, "document.title")
        XCTAssertEqual(title, "Seer")

        let version = await evaluateString(harness.webView, "window.seerNative && window.seerNative.version")
        XCTAssertEqual(version, bridgeVersion)

        await harness.tearDown()
    }

    // MARK: 2. A synthetic AppSnapshot visibly updates Status

    /// Drives a real scan through a fake `AgentDetecting`/`AgentMonitor`
    /// pair, exactly mirroring `AppDelegate.performScanTick(agentMonitor:
    /// coordinator:)`'s own two-step handoff (`agentMonitor.scan()` then
    /// `coordinator.applyScan(state.agents, scannedAt:)`), then confirms
    /// the resulting `snapshot.changed` event — delivered through the
    /// real `RendererEventSink` → `window.seerNative.receive` path — is
    /// visibly reflected in the fixture's "Status" DOM element.
    func testSyntheticSnapshotUpdatesVisibleStatusText() async throws {
        let (harness, coordinator, detector, agentMonitor) = try await makeRealCoordinatorHarness()

        await waitUntil { await self.evaluateString(harness.webView, "document.title") == "Seer" }

        let initialStatus = await evaluateString(harness.webView, "document.getElementById('status').textContent")
        XCTAssertEqual(initialStatus, "Idle")

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

        await waitUntil {
            await self.evaluateString(harness.webView, "document.getElementById('status').textContent") == "Active"
        }
        let updatedStatus = await evaluateString(harness.webView, "document.getElementById('status').textContent")
        XCTAssertEqual(updatedStatus, "Active", "a real snapshot.changed event must visibly update the Status element")
        XCTAssertTrue(coordinator.snapshot.monitor.active)

        await harness.tearDown()
    }

    // MARK: 3. keepAwakeMode.set / history.clear reach the typed fake coordinator

    /// Sends both commands from real page-world script, through the
    /// production DOM-relay contract (`BridgeRelayUserScript`'s isolated
    /// content-world listener, never `BridgeMessageHandler.handle(body:)`
    /// called directly), and asserts the typed `RecordingBridgeCommandRouter`
    /// fake received the exact commands/arguments, plus that the real
    /// response round-trip (through `RendererEventSink` back into
    /// `window.seerNative.receive`) actually completed successfully.
    func testKeepAwakeModeSetAndHistoryClearReachTypedFakeCoordinatorThroughRealBridgePath() async throws {
        let router = RecordingBridgeCommandRouter(snapshot: .empty(version: "1.0.0-integration-test"))
        let harness = try makeHarness(router: router)

        await waitUntil { await self.evaluateString(harness.webView, "document.title") == "Seer" }

        _ = try? await harness.webView.evaluateJavaScript(
            "window.__seerSendBridgeRequest('kam-1', 'keepAwakeMode.set', {mode: 'display'})"
        )
        _ = try? await harness.webView.evaluateJavaScript(
            "window.__seerSendBridgeRequest('hc-1', 'history.clear', {})"
        )

        await waitUntil { await self.evaluateInt(harness.webView, "window.__seerTestReceived.length") == 2 }

        let received = try await harness.webView.evaluateJavaScript("window.__seerTestReceived") as? [[String: Any]]
        let responsesByID = Dictionary(uniqueKeysWithValues: (received ?? []).compactMap { entry -> (String, [String: Any])? in
            guard let id = entry["id"] as? String else { return nil }
            return (id, entry)
        })

        XCTAssertEqual(responsesByID["kam-1"]?["ok"] as? Bool, true)
        XCTAssertEqual(responsesByID["hc-1"]?["ok"] as? Bool, true)

        XCTAssertEqual(router.keepAwakeModeSetCalls, [.display], "the exact requested mode must reach the typed fake coordinator")
        XCTAssertEqual(router.historyClearCallCount, 1, "history.clear must reach the typed fake coordinator exactly once")

        await harness.tearDown()
    }
}
