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

/// A fake `WKURLSchemeTask` — `WKURLSchemeTask` is an Objective-C protocol
/// (not a concrete, hard-to-instantiate class), so it can be conformed to
/// directly here, letting this suite drive `SeerSchemeHandler.webView(_:
/// start:)` directly and record its *exact* terminal callback
/// (`didReceive(response:)` + `didReceive(data:)` + `didFinish()`, or
/// `didFailWithError(_:)`) for an exact request URL — unambiguous proof of
/// allow/deny that does not depend on `WKWebView`'s own image-decoding
/// behavior the way an `<img>`-based real-navigation assertion would (a
/// served-but-undecodable resource and a denied resource both fire an
/// `<img>` `error` event, so that alone cannot distinguish "the scheme
/// handler denied this" from "the scheme handler served bytes an `<img>`
/// simply couldn't decode").
private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest

    private(set) var receivedResponses: [URLResponse] = []
    private(set) var receivedData: [Data] = []
    private(set) var finishedCallCount = 0
    private(set) var failedErrors: [Error] = []

    init(url: URL) {
        request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) {
        receivedResponses.append(response)
    }

    func didReceive(_ data: Data) {
        receivedData.append(data)
    }

    func didFinish() {
        finishedCallCount += 1
    }

    func didFailWithError(_ error: Error) {
        failedErrors.append(error)
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

    /// Writes the minimal fixture document into `root`, which the caller
    /// must have already created (and already registered for cleanup) —
    /// this function performs no directory creation of its own, precisely
    /// so a caller can register `addTeardownBlock` cleanup immediately
    /// after `FileManager.default.createDirectory` succeeds, before this
    /// (or any other fallible write) ever runs.
    private func writeMinimalFixture(into root: URL) throws {
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
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        // Registered immediately after the resource this test owns is
        // actually created — before the fixture write below (or anything
        // else) can throw — so `XCTestCase.addTeardownBlock`'s guarantee
        // (runs after the test method returns whether it passed, failed
        // an assertion, or threw) means this can never be skipped and
        // leak the temp directory.
        addTeardownBlock { try? FileManager.default.removeItem(at: tempRoot) }
        try writeMinimalFixture(into: tempRoot)

        let panel = PanelController(rendererRoot: SeerRendererRoot(url: tempRoot))
        addTeardownBlock { @MainActor in
            panel.webView.stopLoading()
            panel.panel.close()
        }
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
    }

    // MARK: - 3. Real SeerSchemeHandler: a percent-encoded ../ resource request is denied end to end

    /// A minimal, valid 1×1 transparent PNG — needed so both the
    /// legitimate in-root asset *and* the outside-root decoy below are
    /// genuinely decodable images. If the decoy were plain text (as it
    /// used to be), an `<img>` fetching it would fire `error` regardless
    /// of whether the scheme handler actually denied the request or
    /// mistakenly served it — a decode failure and a denial are
    /// indistinguishable from the DOM's `error` event alone. Using a real
    /// PNG for both makes `load` vs. `error` an unambiguous signal of
    /// allow vs. deny.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    /// A once-percent-encoded (`%2e%2e`) traversal path segment.
    /// Empirically (verified against this project's real `WKWebView`),
    /// WebKit's own WHATWG URL parser recognizes `%2e`/`%2E` as an alias
    /// for a literal `.` *during its own URL normalization* — so any
    /// request built from this shape, relative or absolute, is already
    /// collapsed to a flat, non-traversing `seer://app/<name>` path before
    /// `SeerSchemeHandler.webView(_:start:)` ever sees it: a real `<img
    /// src="assets/%2e%2e/%2e%2e/secret.png">` never actually reaches the
    /// scheme handler with `assets`/`%2e%2e` segments intact at all. This
    /// shape therefore only reaches `SeerSchemeResourceLoader`'s own
    /// character-level defense (`SeerResourceError.pathEscapesRoot`) when
    /// something constructs the request directly — see
    /// `testSeerSchemeHandlerDirectlyRecordsFinishForLegitimateResourceAndFailureForTraversal`
    /// below, and `SeerSchemeHandlerTests
    /// .testPercentEncodedDotDotTraversalIsRejected` at the pure-loader
    /// level — never via genuine browser-driven navigation.
    private static let directlyConstructedTraversalRequestSuffix = "assets/%2e%2e/%2e%2e"

    /// A *twice*-percent-encoded (`%252e%252e`) traversal path segment —
    /// after WebKit's own single decode-and-normalize pass, this becomes
    /// the three literal characters `%2e`, which is *not* itself a
    /// recognized dot-segment alias, so it survives WebKit's URL
    /// normalization completely intact. Confirmed empirically: a real
    /// `<img src="assets/%252e%252e/%252e%252e/secret.png">` reaches
    /// `SeerSchemeHandler.webView(_:start:)` as exactly
    /// `seer://app/assets/%252e%252e/%252e%252e/secret.png`, with every
    /// segment untouched — this is the one traversal shape that is both
    /// genuinely reachable through a real browser-driven request *and*
    /// still depends on `SeerSchemeResourceLoader`'s own defense (a
    /// literal `%` surviving one decode pass is rejected as
    /// `SeerResourceError.invalidPathEncoding`, precisely so a future
    /// change cannot "helpfully" decode it a second time into `..`) to be
    /// denied — exactly the "exercise the actual scheme handler path via
    /// real webview navigation" requirement.
    private static let browserSurvivableTraversalRequestSuffix = "assets/%252e%252e/%252e%252e"

    /// Both traversal shapes above resolve — per ordinary RFC 3986
    /// relative-reference merging, and (for the twice-encoded shape) per
    /// `SeerSchemeResourceLoader.resolve`'s own component-by-component
    /// path join — to exactly `<root>`'s parent directory, were their two
    /// `..`-equivalent segments ever actually honored: `assets` cancels
    /// with the first, and the second walks one level above `<root>`
    /// itself. Every traversal test below places its decoy at precisely
    /// that location — one directory above the served root, never an
    /// arbitrarily-deeper sibling — so a hypothetical regression that
    /// weakened either defense would still be caught here, rather than
    /// this test passing vacuously because the decoy never existed at the
    /// path traversal would actually reach.
    private static let traversalDecoyFileName = "secret.png"

    /// Drives a real percent-encoded path-traversal resource request
    /// through the actual `WKURLSchemeHandler` pipeline — a real `<img>`
    /// element's `src`, resolved and fetched by WebKit itself, never a
    /// directly-constructed `URL(string:)`. Uses
    /// `browserSurvivableTraversalRequestSuffix` (see its own
    /// documentation for why the more obvious single-encoded `%2e%2e`
    /// shape cannot actually prove anything about the scheme handler here
    /// — WebKit's own URL parser already neutralizes it before the
    /// handler is ever invoked). Both the legitimate sibling asset and the
    /// outside-root decoy are real, valid PNGs (see `onePixelPNG`'s
    /// documentation for why), and the decoy sits at the exact location
    /// the traversal's segments resolve to, so `load` vs. `error` here is
    /// unambiguous proof of "the scheme handler actually denied this",
    /// never an artifact of an undecodable file or a decoy planted
    /// somewhere the traversal could never have reached anyway.
    func testRealSchemeHandlerDeniesPercentEncodedTraversalForARealResourceRequest() async throws {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavigationPolicyTests-\(UUID().uuidString)", isDirectory: true)
        // `stagingRoot` itself is created — and its cleanup registered —
        // first and alone, before any nested directory/file write that
        // could throw, so a failure partway through fixture setup below
        // can never leak it.
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: stagingRoot) }

        let tempRoot = stagingRoot.appendingPathComponent("renderer-root", isDirectory: true)
        let assetsDir = tempRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: assetsDir.appendingPathComponent("pixel.png"))

        // The decoy: a real, decodable PNG exactly one directory above
        // `tempRoot` — precisely where the traversal resolves to (see
        // `traversalDecoyFileName`'s documentation). `stagingRoot` (not
        // the shared system temp directory itself) stands in as
        // `tempRoot`'s parent so this decoy, and its cleanup, both stay
        // scoped to this test.
        try Self.onePixelPNG.write(to: stagingRoot.appendingPathComponent(Self.traversalDecoyFileName))

        let html = """
        <!doctype html>
        <html>
          <head><title>Seer</title></head>
          <body>
            <img id="good" src="assets/pixel.png"
                 onload="window.__imgResults = window.__imgResults || {}; window.__imgResults.good = 'load';"
                 onerror="window.__imgResults = window.__imgResults || {}; window.__imgResults.good = 'error';">
            <img id="evil" src="\(Self.browserSurvivableTraversalRequestSuffix)/\(Self.traversalDecoyFileName)"
                 onload="window.__imgResults = window.__imgResults || {}; window.__imgResults.evil = 'load';"
                 onerror="window.__imgResults = window.__imgResults || {}; window.__imgResults.evil = 'error';">
          </body>
        </html>
        """
        try html.write(to: tempRoot.appendingPathComponent("standalone-window.html"), atomically: true, encoding: .utf8)

        let panel = PanelController(rendererRoot: SeerRendererRoot(url: tempRoot))
        addTeardownBlock { @MainActor in
            panel.webView.stopLoading()
            panel.panel.close()
        }
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
        XCTAssertEqual(
            evilResult, "error",
            "a percent-encoded ../ traversal request must be denied, never served, even though the decoy at its " +
            "resolved target is a genuinely valid, decodable image"
        )
    }

    /// Exercises the production `SeerSchemeHandler` directly — bypassing
    /// `WKWebView`/`<img>` entirely — via a real `FakeSchemeTask`,
    /// recording its *exact* terminal callback for the legitimate in-root
    /// resource and for both traversal shapes
    /// (`directlyConstructedTraversalRequestSuffix`,
    /// `browserSurvivableTraversalRequestSuffix`). This is the unambiguous
    /// "scheme task response recorder" version of the real-navigation test
    /// above: `didFinish()` with the exact PNG bytes for the legitimate
    /// request, and `didFailWithError(_:)` — never any data, never
    /// `didFinish()` — for each traversal, proven independent of any
    /// `WKWebView`/image-decoding behavior at all. The
    /// once-encoded shape is only reachable this way (see its own
    /// documentation for why a real `WKWebView` never actually delivers it
    /// intact), so this is its sole piece of coverage against a real
    /// `SeerSchemeHandler` instance.
    func testSeerSchemeHandlerDirectlyRecordsFinishForLegitimateResourceAndFailureForTraversal() throws {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavigationPolicyTests-\(UUID().uuidString)", isDirectory: true)
        // `stagingRoot` itself is created — and its cleanup registered —
        // first and alone, before any nested directory/file write that
        // could throw, so a failure partway through fixture setup below
        // can never leak it.
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: stagingRoot) }

        let tempRoot = stagingRoot.appendingPathComponent("renderer-root", isDirectory: true)
        let assetsDir = tempRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: assetsDir.appendingPathComponent("pixel.png"))
        try Self.onePixelPNG.write(to: stagingRoot.appendingPathComponent(Self.traversalDecoyFileName))

        let handler = SeerSchemeHandler(rendererRoot: SeerRendererRoot(url: tempRoot))
        // `SeerSchemeHandler.webView(_:start:)` never reads its `webView`
        // parameter (see `SeerSchemeHandler.swift`) — a disposable,
        // never-navigated `WKWebView` only satisfies the protocol's
        // required argument type.
        let unusedWebView = WKWebView(frame: .zero)

        let legitimateTask = FakeSchemeTask(url: URL(string: "seer://app/assets/pixel.png")!)
        handler.webView(unusedWebView, start: legitimateTask)

        XCTAssertEqual(legitimateTask.finishedCallCount, 1, "the legitimate in-root resource must finish exactly once")
        XCTAssertTrue(legitimateTask.failedErrors.isEmpty, "the legitimate in-root resource must never fail")
        XCTAssertEqual(legitimateTask.receivedData, [Self.onePixelPNG], "the exact bytes on disk must be delivered")
        XCTAssertEqual(legitimateTask.receivedResponses.first?.mimeType, "image/png")

        let onceEncodedTask = FakeSchemeTask(
            url: URL(string: "seer://app/\(Self.directlyConstructedTraversalRequestSuffix)/\(Self.traversalDecoyFileName)")!
        )
        handler.webView(unusedWebView, start: onceEncodedTask)

        XCTAssertEqual(onceEncodedTask.finishedCallCount, 0, "a once-encoded ../ traversal request must never finish")
        XCTAssertTrue(onceEncodedTask.receivedData.isEmpty, "a once-encoded ../ traversal request must never deliver data")
        XCTAssertEqual(
            onceEncodedTask.failedErrors.count, 1,
            "a once-encoded ../ traversal request must fail exactly once, never finish"
        )
        XCTAssertEqual(
            onceEncodedTask.failedErrors.first as? SeerSchemeHandlerError, SeerSchemeHandlerError(resourceError: .pathEscapesRoot),
            "a once-encoded ../ traversal request must fail with exactly .pathEscapesRoot"
        )

        let twiceEncodedTask = FakeSchemeTask(
            url: URL(string: "seer://app/\(Self.browserSurvivableTraversalRequestSuffix)/\(Self.traversalDecoyFileName)")!
        )
        handler.webView(unusedWebView, start: twiceEncodedTask)

        XCTAssertEqual(twiceEncodedTask.finishedCallCount, 0, "a twice-encoded ../ traversal request must never finish")
        XCTAssertTrue(twiceEncodedTask.receivedData.isEmpty, "a twice-encoded ../ traversal request must never deliver data")
        XCTAssertEqual(
            twiceEncodedTask.failedErrors.count, 1,
            "a twice-encoded ../ traversal request must fail exactly once, never finish"
        )
        XCTAssertEqual(
            twiceEncodedTask.failedErrors.first as? SeerSchemeHandlerError, SeerSchemeHandlerError(resourceError: .invalidPathEncoding),
            "a twice-encoded ../ traversal request must fail with exactly .invalidPathEncoding — the exact defense " +
            "the real-webview traversal test above depends on"
        )
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
