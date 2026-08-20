import XCTest
import WebKit
@testable import Seer

/// A fake `WKURLSchemeTask` — `WKURLSchemeTask` is an Objective-C protocol
/// (not a concrete, hard-to-instantiate class), so it can be conformed to
/// directly here, letting `SeerSchemeHandlerTests` drive
/// `SeerSchemeHandler.webView(_:start:)`/`webView(_:stop:)` without ever
/// needing a real WebKit navigation.
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

    /// Total terminal callbacks received — must be exactly 1 across the
    /// task's lifetime (either one `didFinish` or one `didFailWithError`,
    /// never both, never neither, never more than one of either).
    var terminalCallbackCount: Int {
        finishedCallCount + failedErrors.count
    }
}

@MainActor
final class SeerSchemeHandlerTests: XCTestCase {
    /// A fresh, UUID-named temporary directory per test — never
    /// `Bundle.main`'s real renderer. Removed in `tearDown`.
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeerSchemeHandlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func write(_ contents: String, at relativePath: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func write(bytes: Data, at relativePath: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    private func seerURL(_ path: String) -> URL {
        URL(string: "seer://app\(path)")!
    }

    // MARK: - SeerSchemeResourceLoader: happy path + exact MIME allowlist

    func testLoadsTheInitialDocumentAsTextHTMLUtf8() throws {
        try write("<!doctype html><title>Seer</title>", at: "standalone-window.html")
        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/standalone-window.html"), rendererRoot: SeerRendererRoot(url: tempRoot))
        guard case .success(let resource) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(resource.mimeType, "text/html; charset=utf-8")
        XCTAssertEqual(String(data: resource.data, encoding: .utf8), "<!doctype html><title>Seer</title>")
    }

    func testExactMimeTypeAllowlistPerExtension() throws {
        let cases: [(String, String, String)] = [
            ("assets/app.js", "js", "text/javascript; charset=utf-8"),
            ("assets/app.mjs", "mjs", "text/javascript; charset=utf-8"),
            ("assets/app.css", "css", "text/css; charset=utf-8"),
            ("assets/data.json", "json", "application/json"),
            ("assets/icon.svg", "svg", "image/svg+xml"),
            ("assets/icon.png", "png", "image/png"),
            ("assets/photo.jpg", "jpg", "image/jpeg"),
            ("assets/photo.jpeg", "jpeg", "image/jpeg"),
            ("assets/anim.webp", "webp", "image/webp"),
            ("assets/anim.gif", "gif", "image/gif"),
            ("assets/favicon.ico", "ico", "image/x-icon"),
            ("assets/font.woff", "woff", "font/woff"),
            ("assets/font.woff2", "woff2", "font/woff2"),
            ("assets/font.ttf", "ttf", "font/ttf"),
            ("assets/font.otf", "otf", "font/otf"),
        ]
        for (path, _, expectedMime) in cases {
            try write(bytes: Data("content".utf8), at: path)
            let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/\(path)"), rendererRoot: SeerRendererRoot(url: tempRoot))
            guard case .success(let resource) = result else {
                return XCTFail("expected success for \(path), got \(result)")
            }
            XCTAssertEqual(resource.mimeType, expectedMime, "unexpected MIME for \(path)")
        }
    }

    func testUnknownExtensionIsRejectedNotSniffed() throws {
        try write(bytes: Data("#!/bin/sh\necho hi".utf8), at: "assets/script.sh")
        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/assets/script.sh"), rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.unsupportedExtension))
    }

    func testExtensionlessFileIsRejected() throws {
        try write(bytes: Data("content".utf8), at: "assets/noext")
        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/assets/noext"), rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.unsupportedExtension))
    }

    // MARK: - scheme/host/query/fragment

    func testWrongSchemeIsRejected() {
        let result = SeerSchemeResourceLoader.load(requestURL: URL(string: "https://app/standalone-window.html")!, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.unsupportedScheme))
    }

    func testWrongHostIsRejected() throws {
        try write("hi", at: "standalone-window.html")
        let result = SeerSchemeResourceLoader.load(requestURL: URL(string: "seer://evil/standalone-window.html")!, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.unsupportedHost))
    }

    func testQueryStringIsRejected() throws {
        try write("hi", at: "standalone-window.html")
        let result = SeerSchemeResourceLoader.load(requestURL: URL(string: "seer://app/standalone-window.html?x=1")!, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.unsupportedQueryOrFragment))
    }

    func testFragmentIsRejected() throws {
        try write("hi", at: "standalone-window.html")
        let result = SeerSchemeResourceLoader.load(requestURL: URL(string: "seer://app/standalone-window.html#top")!, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.unsupportedQueryOrFragment))
    }

    func testEmptyPathIsRejected() {
        let result = SeerSchemeResourceLoader.load(requestURL: URL(string: "seer://app/")!, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.emptyPath))
    }

    func testEmptyPathWithNoTrailingSlashIsRejected() {
        let result = SeerSchemeResourceLoader.load(requestURL: URL(string: "seer://app")!, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.emptyPath))
    }

    // MARK: - traversal / encoding attacks

    func testRawDotDotTraversalIsRejected() {
        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/../etc/passwd"), rendererRoot: SeerRendererRoot(url: tempRoot))
        // A raw ".." segment normalizes away via URL/URLComponents parsing
        // in some cases; whichever error results, it must never succeed
        // in escaping the root.
        XCTAssertNotEqual(result.isSuccess, true)
    }

    func testPercentEncodedDotDotTraversalIsRejected() {
        let url = URL(string: "seer://app/assets/%2e%2e/%2e%2e/etc/passwd")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.pathEscapesRoot))
    }

    func testDoubleEncodedDotDotTraversalIsRejected() {
        // `%252e` decodes once to the literal three characters `%2e`,
        // which must be rejected as still-encoded rather than decoded a
        // second time into `.`.
        let url = URL(string: "seer://app/assets/%252e%252e/passwd")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.invalidPathEncoding))
    }

    func testEncodedSlashSeparatorIsRejected() {
        // `%2F` must never be treated as a path separator that could
        // fabricate additional segments.
        let url = URL(string: "seer://app/assets%2F..%2F..%2Fetc%2Fpasswd")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertNotEqual(result.isSuccess, true)
    }

    func testEncodedBackslashIsRejected() {
        let url = URL(string: "seer://app/assets/%5C..%5C..%5Cetc")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertNotEqual(result.isSuccess, true)
    }

    func testEncodedNulByteIsRejected() {
        let url = URL(string: "seer://app/assets/app.html%00.js")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertNotEqual(result.isSuccess, true)
    }

    func testUnicodeLookalikeCharactersAreRejectedByTheAllowlist() throws {
        // U+FF0E FULLWIDTH FULL STOP look-alike for `.`, and other
        // non-ASCII path segments, must never be treated as equivalent to
        // an allowed character or as traversal — the strict ASCII
        // allowlist rejects them outright.
        let url = URL(string: "seer://app/assets/app\u{FF0E}js")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertNotEqual(result.isSuccess, true)
    }

    func testBareDotSegmentIsRejected() {
        let url = URL(string: "seer://app/assets/./app.js")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertNotEqual(result.isSuccess, true)
    }

    func testDoubleSlashIsRejected() {
        let url = URL(string: "seer://app/assets//app.js")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertNotEqual(result.isSuccess, true)
    }

    func testAbsolutePathEscapeAttemptIsContained() throws {
        // Even a request that (if naively string-concatenated) would
        // resolve outside the root must fail, never silently serve
        // something from outside `rendererRoot`.
        let outsideDir = tempRoot.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try "secret".write(to: outsideDir.appendingPathComponent("secret.html"), atomically: true, encoding: .utf8)

        let url = URL(string: "seer://app/../\(outsideDir.lastPathComponent)/secret.html")!
        let result = SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertNotEqual(result.isSuccess, true)
    }

    // MARK: - symlinks

    func testSymlinkPointingOutsideRootIsRejected() throws {
        let outsideDir = tempRoot.deletingLastPathComponent().appendingPathComponent("symlink-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let secretFile = outsideDir.appendingPathComponent("secret.html")
        try "top secret".write(to: secretFile, atomically: true, encoding: .utf8)

        let linkPath = tempRoot.appendingPathComponent("standalone-window.html")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: secretFile)

        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/standalone-window.html"), rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.pathEscapesRoot))
    }

    func testSymlinkWithinRootIsStillRejected() throws {
        // Even a symlink whose target happens to also be inside the root
        // must never be followed — `O_NOFOLLOW` rejects any symlink at
        // the final path component unconditionally.
        try write("real content", at: "real.html")
        let linkPath = tempRoot.appendingPathComponent("link.html")
        try FileManager.default.createSymbolicLink(
            at: linkPath,
            withDestinationURL: tempRoot.appendingPathComponent("real.html")
        )

        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/link.html"), rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.pathEscapesRoot))
    }

    // MARK: - directories / missing files

    func testDirectoryRequestIsRejected() throws {
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/assets"), rendererRoot: SeerRendererRoot(url: tempRoot))
        // A bare directory name has no recognized extension, so it is
        // rejected before ever attempting to open it as a file.
        XCTAssertEqual(result, .failure(.unsupportedExtension))
    }

    func testMissingFileIsRejected() {
        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/assets/missing.js"), rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.notFound))
    }

    // MARK: - size limit

    func testOversizedResourceIsRejectedWithoutReadingItFully() throws {
        let url = tempRoot.appendingPathComponent("assets/huge.js")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Sparse-ish large file: seek and write one byte at the target
        // offset rather than actually allocating megabytes of content.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(SeerSchemeResourceLoader.maxResourceBytes + 1))
        handle.write(Data([0x00]))
        try handle.close()

        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/assets/huge.js"), rendererRoot: SeerRendererRoot(url: tempRoot))
        XCTAssertEqual(result, .failure(.tooLarge))
    }

    func testExactlyMaxSizedResourceIsAccepted() throws {
        let data = Data(repeating: 0x61, count: SeerSchemeResourceLoader.maxResourceBytes)
        try write(bytes: data, at: "assets/max.js")
        let result = SeerSchemeResourceLoader.load(requestURL: seerURL("/assets/max.js"), rendererRoot: SeerRendererRoot(url: tempRoot))
        guard case .success(let resource) = result else {
            return XCTFail("expected success at exactly the size limit")
        }
        XCTAssertEqual(resource.data.count, SeerSchemeResourceLoader.maxResourceBytes)
    }

    // MARK: - WKURLSchemeHandler task lifecycle (via the fake protocol conformance)

    func testHandlerDeliversResponseDataAndFinishExactlyOnceOnSuccess() throws {
        try write("<!doctype html>", at: "standalone-window.html")
        let handler = SeerSchemeHandler(rendererRoot: SeerRendererRoot(url: tempRoot))
        let webView = WKWebView(frame: .zero)
        let task = FakeSchemeTask(url: seerURL("/standalone-window.html"))

        handler.webView(webView, start: task)

        XCTAssertEqual(task.receivedResponses.count, 1)
        XCTAssertEqual(task.receivedData.count, 1)
        XCTAssertEqual(task.finishedCallCount, 1)
        XCTAssertEqual(task.failedErrors.count, 0)
        XCTAssertEqual(task.terminalCallbackCount, 1)
        XCTAssertEqual(task.receivedResponses.first?.mimeType, "text/html")
    }

    func testHandlerDeliversExactlyOneFailureCallbackForARejectedResource() {
        let handler = SeerSchemeHandler(rendererRoot: SeerRendererRoot(url: tempRoot))
        let webView = WKWebView(frame: .zero)
        let task = FakeSchemeTask(url: seerURL("/missing.js"))

        handler.webView(webView, start: task)

        XCTAssertEqual(task.receivedResponses.count, 0)
        XCTAssertEqual(task.receivedData.count, 0)
        XCTAssertEqual(task.finishedCallCount, 0)
        XCTAssertEqual(task.failedErrors.count, 1)
        XCTAssertEqual(task.terminalCallbackCount, 1)
    }

    func testStoppedTaskNeverReceivesAnyCallback() throws {
        try write("<!doctype html>", at: "standalone-window.html")
        let handler = SeerSchemeHandler(rendererRoot: SeerRendererRoot(url: tempRoot))
        let webView = WKWebView(frame: .zero)
        let task = FakeSchemeTask(url: seerURL("/standalone-window.html"))

        // Stop the task before it is ever started — simulating
        // cancellation racing ahead of (a hypothetically async) load.
        handler.webView(webView, stop: task)
        handler.webView(webView, start: task)

        XCTAssertEqual(task.terminalCallbackCount, 0, "a stopped task must never receive any callback")
    }

    func testStopBeforeStartPrunesTheCancelledTaskEntryInsteadOfLeakingIt() throws {
        try write("<!doctype html>", at: "standalone-window.html")
        let handler = SeerSchemeHandler(rendererRoot: SeerRendererRoot(url: tempRoot))
        let webView = WKWebView(frame: .zero)

        for _ in 0..<25 {
            let task = FakeSchemeTask(url: seerURL("/standalone-window.html"))
            handler.webView(webView, stop: task)
            handler.webView(webView, start: task)
            XCTAssertEqual(task.terminalCallbackCount, 0)
        }

        XCTAssertEqual(
            handler.cancelledTaskCountForTesting,
            0,
            "every stop-before-start task must be pruned from the cancelled set, not accumulate unboundedly"
        )
    }

    // MARK: - navigation policy

    func testNavigationPolicyAllowsOnlyTheExactInitialDocumentAsMainFrame() {
        let allowed = SeerNavigationRequest(url: SeerNavigationPolicy.allowedInitialDocumentURL, targetFrameIsMain: true)
        XCTAssertEqual(SeerNavigationPolicy.decide(allowed), .allow)
    }

    func testNavigationPolicyRejectsNonMainFrameNavigation() {
        let request = SeerNavigationRequest(url: SeerNavigationPolicy.allowedInitialDocumentURL, targetFrameIsMain: false)
        XCTAssertEqual(SeerNavigationPolicy.decide(request), .cancel)
    }

    func testNavigationPolicyRejectsNewWindowNavigation() {
        // `targetFrameIsMain == nil` models a `WKNavigationAction` with no
        // target frame at all, i.e. a request to open a new window.
        let request = SeerNavigationRequest(url: SeerNavigationPolicy.allowedInitialDocumentURL, targetFrameIsMain: nil)
        XCTAssertEqual(SeerNavigationPolicy.decide(request), .cancel)
    }

    func testNavigationPolicyRejectsServerRedirects() {
        let request = SeerNavigationRequest(
            url: SeerNavigationPolicy.allowedInitialDocumentURL,
            targetFrameIsMain: true,
            isServerRedirect: true
        )
        XCTAssertEqual(SeerNavigationPolicy.decide(request), .cancel)
    }

    func testNavigationPolicyRejectsOtherSchemes() {
        for urlString in ["http://app/standalone-window.html", "file:///etc/passwd", "data:text/html,hi", "javascript:alert(1)", "about:blank"] {
            let request = SeerNavigationRequest(url: URL(string: urlString)!, targetFrameIsMain: true)
            XCTAssertEqual(SeerNavigationPolicy.decide(request), .cancel, "expected \(urlString) to be rejected")
        }
    }

    func testNavigationPolicyRejectsOtherSeerPaths() {
        for path in ["seer://app/other.html", "seer://app/", "seer://evil/standalone-window.html", "seer://app/standalone-window.html?x=1"] {
            let request = SeerNavigationRequest(url: URL(string: path)!, targetFrameIsMain: true)
            XCTAssertEqual(SeerNavigationPolicy.decide(request), .cancel, "expected \(path) to be rejected")
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
