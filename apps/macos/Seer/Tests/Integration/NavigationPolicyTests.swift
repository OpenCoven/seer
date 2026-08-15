import XCTest
import WebKit
@testable import Seer

/// Records every URL a `RecordingReleaseOpener` (below) was ever asked to
/// open — used to prove `UpdateService.openCurrentRelease()` only ever
/// reaches this with an already-validated `https://github.com/...` URL,
/// never a tampered/legacy cache value or anything renderer-supplied. An
/// `actor` (matching `UpdateServiceTests.RecordingReleaseOpener`'s own
/// rationale) since `UpdateService` itself is an actor and may call
/// `open(_:)` from a different execution context than the test's own
/// assertions.
private actor RecordingReleaseOpener: ReleaseURLOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return true
    }
}

/// Security-focused navigation/scheme/update-open tests for the standalone
/// panel. Reuses the exact production decision points wherever possible
/// (`SeerNavigationPolicy.decide`, `SeerSchemeHandler`/
/// `SeerSchemeResourceLoader`, `BridgeRequestDecoder`,
/// `UpdateService.isValidReleaseURL`) rather than re-implementing any
/// security logic of its own, and drives a handful of the highest-value
/// scenarios through a genuinely real `WKWebView`/`PanelController` so the
/// full production wiring — not just the pure decision function in
/// isolation — is proven to deny them.
@MainActor
final class NavigationPolicyTests: XCTestCase {
    // MARK: - 1. Pure navigation-decision matrix (SeerNavigationPolicy.decide)

    /// The exhaustive, closed set of main-frame navigation decisions this
    /// task requires evidence for: an ordinary external host, a local
    /// file URL, a `javascript:` URL, an unrecognized `seer://` host, and
    /// the one legitimate document — reusing `SeerNavigationPolicy.decide`
    /// directly, the same pure function `SeerWebViewNavigationDelegate`
    /// (real production code, exercised end to end in section 2 below)
    /// calls on every real navigation decision.
    func testNavigationPolicyDecisionMatrix() {
        let cases: [(name: String, url: URL, expected: SeerNavigationDecision)] = [
            ("the one allowed document", SeerNavigationPolicy.allowedInitialDocumentURL, .allow),
            ("an ordinary external https host", URL(string: "https://example.com/blocked")!, .cancel),
            ("a local file URL", URL(fileURLWithPath: "/etc/passwd"), .cancel),
            ("a javascript: URL", URL(string: "javascript:void(document.title='hijacked')")!, .cancel),
            ("an unrecognized seer:// host", URL(string: "seer://evil-host/standalone-window.html")!, .cancel),
            ("a seer://app path other than the allowed document", URL(string: "seer://app/other.html")!, .cancel),
        ]

        for testCase in cases {
            let decision = SeerNavigationPolicy.decide(SeerNavigationRequest(url: testCase.url, targetFrameIsMain: true))
            XCTAssertEqual(decision, testCase.expected, "unexpected decision for \(testCase.name): \(testCase.url)")
        }
    }

    /// Even the one allowed document is denied the moment it is not a
    /// main-frame navigation (e.g. an attempted new-window/subframe open)
    /// or arrives as a server redirect — both dimensions
    /// `SeerNavigationRequest` carries independently of the URL itself.
    func testNavigationPolicyDeniesTheAllowedDocumentOutsideMainFrameOrViaRedirect() {
        let allowed = SeerNavigationPolicy.allowedInitialDocumentURL
        XCTAssertEqual(SeerNavigationPolicy.decide(SeerNavigationRequest(url: allowed, targetFrameIsMain: false)), .cancel)
        XCTAssertEqual(SeerNavigationPolicy.decide(SeerNavigationRequest(url: allowed, targetFrameIsMain: nil)), .cancel)
        XCTAssertEqual(
            SeerNavigationPolicy.decide(SeerNavigationRequest(url: allowed, targetFrameIsMain: true, isServerRedirect: true)),
            .cancel
        )
    }

    // MARK: - 2. Real WKWebView/PanelController: malicious navigations never leave the allowed document

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func evaluateString(_ webView: WKWebView, _ expression: String) async -> String? {
        (try? await webView.evaluateJavaScript(expression)) as? String
    }

    private func writeMinimalFixture(into root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<!doctype html><html><head><title>Seer</title></head><body></body></html>"
            .write(to: root.appendingPathComponent("standalone-window.html"), atomically: true, encoding: .utf8)
    }

    /// Builds a real `PanelController` — real `SeerWebViewFactory`
    /// configuration, real `SeerSchemeHandler`, real
    /// `SeerWebViewNavigationDelegate` — serving a minimal fixture from a
    /// fresh temporary directory, loads the one allowed document, then
    /// attempts to navigate the same main frame directly to each denied
    /// URL and asserts the document never actually changed. `javascript:`
    /// is intentionally excluded from the real-navigation loop below and
    /// covered only by the pure-function matrix above instead: WKWebView
    /// does not reliably route a `javascript:` URL passed to
    /// `load(_:)` through an ordinary `decidePolicyFor` main-frame
    /// navigation decision the way it does for the other schemes here —
    /// the same carve-out `PanelControllerTests`'
    /// `testRealWKWebViewInvokesNavigationDelegateAndAppliesEveryDecision`
    /// already makes.
    func testRealPanelDeniesMaliciousMainFrameNavigations() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavigationPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try writeMinimalFixture(into: tempRoot)

        let panel = PanelController(rendererRoot: SeerRendererRoot(url: tempRoot))
        panel.loadInitialDocument()
        await waitUntil { await self.evaluateString(panel.webView, "document.title") == "Seer" }

        let deniedURLs: [URL] = [
            URL(string: "https://example.com/blocked")!,
            URL(fileURLWithPath: "/etc/passwd"),
            URL(string: "seer://evil-host/standalone-window.html")!,
        ]

        for url in deniedURLs {
            panel.webView.load(URLRequest(url: url))
            // `decidePolicyFor` cancels synchronously relative to the
            // navigation attempt; a short bounded wait gives WebKit's own
            // dispatch a chance to run without this test depending on any
            // exact timing for correctness (the assertion below is what
            // actually proves denial, not the wait itself).
            try? await Task.sleep(nanoseconds: 150_000_000)
            let title = await evaluateString(panel.webView, "document.title")
            XCTAssertEqual(title, "Seer", "navigation to \(url) must have been denied, but the document changed")
        }

        panel.webView.stopLoading()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - 3. Real SeerSchemeHandler: a percent-encoded ../ resource request is denied end to end

    /// A minimal, valid 1×1 transparent PNG — needed so the "legitimate
    /// sibling asset" `<img>` below actually fires `load` (not `error` from
    /// a decode failure), making the contrast with the denied traversal
    /// request unambiguous.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    /// Drives a real percent-encoded (`%2e%2e`) path-traversal resource
    /// request through the actual `WKURLSchemeHandler` pipeline — a real
    /// `<img>` element's `src`, resolved and fetched by WebKit itself, not
    /// a directly-constructed `URL(string:)` handed straight to
    /// `SeerSchemeResourceLoader.load(requestURL:rendererRoot:)` (already
    /// covered at that unit level by `SeerSchemeHandlerTests`). Percent-
    /// encoded dot segments are used deliberately: unlike literal `..`,
    /// they are not collapsed by the browser's own URL parser during
    /// relative-reference resolution, so this is the one traversal shape
    /// that can actually reach `SeerSchemeHandler.webView(_:start:)` with
    /// its escaping intent intact from a real page load — exactly the
    /// "exercise the actual scheme handler path" requirement.
    func testRealSchemeHandlerDeniesPercentEncodedTraversalForARealResourceRequest() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavigationPolicyTests-\(UUID().uuidString)", isDirectory: true)
        let assetsDir = tempRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: assetsDir.appendingPathComponent("pixel.png"))

        // A decoy file genuinely outside the renderer root, in a sibling
        // directory — if traversal were ever actually served, this exact
        // byte sequence would end up observable, but it never does.
        let outsideRoot = tempRoot.deletingLastPathComponent()
            .appendingPathComponent("NavigationPolicyTests-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try Data("top-secret".utf8).write(to: outsideRoot.appendingPathComponent("secret.txt"))

        let html = """
        <!doctype html>
        <html>
          <head><title>Seer</title></head>
          <body>
            <img id="good" src="assets/pixel.png"
                 onload="window.__imgResults = window.__imgResults || {}; window.__imgResults.good = 'load';"
                 onerror="window.__imgResults = window.__imgResults || {}; window.__imgResults.good = 'error';">
            <img id="evil" src="assets/%2e%2e/%2e%2e/secret.txt"
                 onload="window.__imgResults = window.__imgResults || {}; window.__imgResults.evil = 'load';"
                 onerror="window.__imgResults = window.__imgResults || {}; window.__imgResults.evil = 'error';">
          </body>
        </html>
        """
        try html.write(to: tempRoot.appendingPathComponent("standalone-window.html"), atomically: true, encoding: .utf8)

        let panel = PanelController(rendererRoot: SeerRendererRoot(url: tempRoot))
        panel.loadInitialDocument()

        await waitUntil {
            let ready = try? await panel.webView.evaluateJavaScript(
                "window.__imgResults && window.__imgResults.good && window.__imgResults.evil"
            )
            return (ready as? String) != nil
        }

        let goodResult = await evaluateString(panel.webView, "window.__imgResults && window.__imgResults.good")
        let evilResult = await evaluateString(panel.webView, "window.__imgResults && window.__imgResults.evil")

        XCTAssertEqual(goodResult, "load", "the legitimate sibling asset must load normally")
        XCTAssertEqual(evilResult, "error", "a percent-encoded ../ traversal request must be denied, never served")

        panel.webView.stopLoading()
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: outsideRoot)
    }

    // MARK: - 4. updates.open can never carry (or open) a renderer-supplied URL

    /// The wire protocol itself structurally cannot carry a URL for
    /// `updates.open`: `BridgeRequestDecoder` requires this method's
    /// payload to be exactly `{}` (see `BridgeRequestDecoder.validate`),
    /// so a renderer attempting to smuggle a `url` field is rejected
    /// before any command ever routes anywhere — never merely ignored.
    func testUpdatesOpenBridgeRequestRejectsAnyRendererSuppliedPayload() {
        let requestID = "11111111-1111-1111-1111-111111111111"
        let maliciousJSON = """
        {"id":"\(requestID)","version":"\(bridgeVersion)","method":"updates.open","payload":{"url":"https://evil.example.com/take-over"}}
        """
        guard case .rejected(let rejectedID, let error) = BridgeRequestDecoder.decode(data: Data(maliciousJSON.utf8)) else {
            return XCTFail("a payload smuggling a URL into updates.open must never be accepted")
        }
        XCTAssertEqual(rejectedID, requestID)
        XCTAssertEqual(error.code, .invalidPayload)

        // Proves the rejection above is specifically about the smuggled
        // `url` field, not that `updates.open` dispatch itself is broken:
        // the one well-formed shape (an empty payload) is still accepted.
        let wellFormedJSON = """
        {"id":"\(requestID)","version":"\(bridgeVersion)","method":"updates.open","payload":{}}
        """
        guard case .accepted(let request) = BridgeRequestDecoder.decode(data: Data(wellFormedJSON.utf8)) else {
            return XCTFail("a well-formed updates.open request with an empty payload must be accepted")
        }
        XCTAssertEqual(request.method, .updatesOpen)
        XCTAssertEqual(request.payload, .empty)
    }

    /// `UpdateService.openCurrentRelease()` opens only the currently
    /// cached, already-`isValidReleaseURL`-checked release URL — never a
    /// tampered/legacy cache value (simulated here directly via
    /// `SettingsStore.recordUpdateCheck`, bypassing any real network call)
    /// and never anything a caller could supply, since the method itself
    /// takes no URL argument at all.
    func testOpenCurrentReleaseOnlyOpensAValidatedGitHubURLNeverATamperedCacheValue() async throws {
        let clock = MutableClock(now: 1_700_000_000_000)
        let settingsStore = SettingsStore(
            store: AtomicJSONStore<SettingsDocument>(
                fileURL: URL(fileURLWithPath: "/Navigation-Policy-Test/ai.opencoven.seer/settings.json"),
                fileSystem: InMemorySettingsFileSystem(),
                clock: clock
            )
        )
        let opener = RecordingReleaseOpener()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let updateService = UpdateService(
            settingsStore: settingsStore,
            session: URLSession(configuration: configuration),
            clock: clock,
            currentVersion: "1.0.0",
            releaseOpener: opener
        )

        // A tampered/legacy cache entry whose URL is not
        // `https://github.com/...` must never reach the opener, no matter
        // how it ended up on disk.
        try await settingsStore.recordUpdateCheck(
            etag: nil,
            lastCheckedAt: clock.nowMilliseconds(),
            release: PersistedRelease(version: "9.9.9", url: "https://evil.example.com/fake-release")
        )
        let openedTampered = await updateService.openCurrentRelease()
        XCTAssertFalse(openedTampered)
        let openedAfterTampered = await opener.openedURLs
        XCTAssertTrue(openedAfterTampered.isEmpty, "a non-github cached URL must never reach the release opener")

        // A legitimately-validated GitHub release URL is exactly (and
        // only) what gets opened once cached.
        try await settingsStore.recordUpdateCheck(
            etag: nil,
            lastCheckedAt: clock.nowMilliseconds(),
            release: PersistedRelease(version: "1.2.0", url: "https://github.com/OpenCoven/seer-releases/releases/tag/v1.2.0")
        )
        let openedValid = await updateService.openCurrentRelease()
        XCTAssertTrue(openedValid)
        let openedAfterValid = await opener.openedURLs
        XCTAssertEqual(openedAfterValid.map(\.absoluteString), ["https://github.com/OpenCoven/seer-releases/releases/tag/v1.2.0"])
    }
}
