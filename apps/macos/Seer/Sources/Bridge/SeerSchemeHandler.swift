import Foundation
import WebKit
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Navigation policy

/// A pure description of the fields `SeerNavigationPolicy.decide` needs
/// from a real navigation-decision callback (e.g. `WKNavigationDelegate
/// .webView(_:decidePolicyFor:decisionHandler:)`). Kept independent of
/// `WKNavigationAction` itself — whose designated initializer is not
/// public — so this policy is directly unit-testable.
///
/// `targetFrameIsMain` is `nil` when the action has no target frame at all
/// (i.e. it would open a new window), which this app never permits.
public struct SeerNavigationRequest: Equatable, Sendable {
    public let url: URL
    public let targetFrameIsMain: Bool?
    public let isServerRedirect: Bool

    public init(url: URL, targetFrameIsMain: Bool?, isServerRedirect: Bool = false) {
        self.url = url
        self.targetFrameIsMain = targetFrameIsMain
        self.isServerRedirect = isServerRedirect
    }
}

public enum SeerNavigationDecision: Equatable, Sendable {
    case allow
    case cancel
}

/// A single, pure decision point over whether a *main-frame navigation* is
/// allowed. The only navigation this app ever permits is to the exact
/// initial `seer://app/standalone-window.html` document — every subresource
/// for that page (scripts, styles, images) loads through
/// `SeerSchemeHandler`'s `WKURLSchemeHandler` conformance instead, which
/// does not go through navigation-policy decisions at all. This rejects
/// every redirect, every attempt to open a new window, and every other
/// scheme/host/path (`http`, `file`, `data`, `javascript`, `about`, and any
/// other `seer://` path) as a main-frame navigation target. External update
/// pages are opened via a typed bridge command (`updates.open`), never web
/// navigation, so they never need to satisfy this policy at all.
public enum SeerNavigationPolicy {
    public static let allowedInitialDocumentURL = URL(string: "seer://app/standalone-window.html")!

    public static func decide(_ request: SeerNavigationRequest) -> SeerNavigationDecision {
        guard !request.isServerRedirect else { return .cancel }
        guard request.targetFrameIsMain == true else { return .cancel }
        guard request.url == allowedInitialDocumentURL else { return .cancel }
        return .allow
    }
}

// MARK: - Resource loading

/// Directory on disk `SeerSchemeResourceLoader` is allowed to serve files
/// from. Production wiring points this at the bundled renderer resources
/// (`Bundle.main.resourceURL!.appendingPathComponent("Renderer")`); tests
/// always point it at a synthetic, UUID-named temporary directory —
/// `Bundle.main`'s real renderer is never used in a test.
public struct SeerRendererRoot: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}

/// Every way `SeerSchemeResourceLoader.load` can refuse to serve a
/// requested `seer://` resource. Deliberately closed and free of any
/// interpolated file path — nothing here embeds the actual on-disk path
/// that was rejected.
public enum SeerResourceError: Error, Equatable, Sendable {
    case unsupportedScheme
    case unsupportedHost
    case unsupportedQueryOrFragment
    case emptyPath
    case invalidPathEncoding
    case pathEscapesRoot
    case unsupportedExtension
    case notFound
    case notARegularFile
    case tooLarge
    case ioFailure
}

public struct SeerLoadedResource: Equatable, Sendable {
    public let data: Data
    public let mimeType: String
}

/// Pure `seer://` resource resolver/reader, extracted from
/// `SeerSchemeHandler` so it is directly unit-testable without ever
/// instantiating a real `WKURLSchemeTask`/`WKWebView` navigation.
public enum SeerSchemeResourceLoader {
    /// `seer://` only ever serves this app's own bundled renderer bundle —
    /// nothing it serves is expected to approach this size. Bounds the
    /// maximum single resource this loader will ever read into memory, so
    /// a corrupted or maliciously large file on disk cannot force an
    /// unbounded read.
    public static let maxResourceBytes = 10 * 1024 * 1024

    private static let readChunkSize = 64 * 1024

    /// Exact MIME allowlist. An extension not in this table is rejected
    /// outright (`unsupportedExtension`) rather than sniffed.
    private static let mimeTypesByExtension: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
    ]

    public static func load(requestURL: URL, rendererRoot: SeerRendererRoot) -> Result<SeerLoadedResource, SeerResourceError> {
        do {
            let components = try validatedComponents(of: requestURL)
            let resolvedURL = try resolve(components: components, root: rendererRoot.url)
            let mimeType = try mimeType(forFinalComponent: components[components.count - 1])
            let data = try readBoundedRegularFile(at: resolvedURL)
            return .success(SeerLoadedResource(data: data, mimeType: mimeType))
        } catch let error as SeerResourceError {
            return .failure(error)
        } catch {
            return .failure(.ioFailure)
        }
    }

    // MARK: Path validation

    /// Validates `requestURL`'s scheme/host/absence-of-query-or-fragment,
    /// then splits its *raw* (still percent-encoded) path on literal `/`
    /// characters only — never on a value produced by decoding first, which
    /// is what would let an encoded separator (`%2F`) merge or fabricate
    /// path segments that were not present in the original URL. Each raw
    /// segment is then percent-decoded and validated individually.
    private static func validatedComponents(of requestURL: URL) throws -> [String] {
        guard requestURL.scheme?.lowercased() == "seer" else {
            throw SeerResourceError.unsupportedScheme
        }
        guard let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            throw SeerResourceError.invalidPathEncoding
        }
        guard components.host?.lowercased() == "app" else {
            throw SeerResourceError.unsupportedHost
        }
        guard components.query == nil, components.fragment == nil else {
            throw SeerResourceError.unsupportedQueryOrFragment
        }

        let rawPath = components.percentEncodedPath
        guard !rawPath.isEmpty else {
            // `seer://app` with no path at all (no trailing slash either).
            throw SeerResourceError.emptyPath
        }
        guard rawPath.hasPrefix("/") else {
            throw SeerResourceError.invalidPathEncoding
        }
        guard rawPath != "/" else {
            throw SeerResourceError.emptyPath
        }

        let rawSegments = rawPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !rawSegments.isEmpty else {
            throw SeerResourceError.emptyPath
        }

        var decodedSegments: [String] = []
        decodedSegments.reserveCapacity(rawSegments.count)
        for rawSegment in rawSegments {
            let segment = String(rawSegment)
            // An empty segment means either "//" or a trailing "/" in the
            // request path — both rejected rather than treated as
            // referring to the renderer root/a directory.
            guard !segment.isEmpty else {
                throw SeerResourceError.invalidPathEncoding
            }
            // A raw (not-yet-decoded) backslash should never appear in a
            // legitimate percent-encoded path segment.
            guard !segment.contains("\\") else {
                throw SeerResourceError.invalidPathEncoding
            }
            guard let decoded = segment.removingPercentEncoding else {
                throw SeerResourceError.invalidPathEncoding
            }
            try validateDecodedSegment(decoded)
            decodedSegments.append(decoded)
        }

        return decodedSegments
    }

    /// Applies a strict allowlist to a single, already percent-decoded path
    /// segment: only ASCII letters/digits/`-`/`_`/`.`, and never exactly
    /// `.`/`..`. This blocks every encoded-separator, encoded-backslash,
    /// encoded-NUL, double-encoding, and Unicode-normalization/look-alike
    /// traversal trick in a single pass — none of the rejected characters
    /// can ever legitimately appear in one of this bundle's real asset
    /// file names.
    private static func validateDecodedSegment(_ segment: String) throws {
        guard segment != ".", segment != ".." else {
            throw SeerResourceError.pathEscapesRoot
        }
        // A literal `%` surviving one decode pass means the original
        // segment was double- (or invalidly-) percent-encoded.
        guard !segment.contains("%") else {
            throw SeerResourceError.invalidPathEncoding
        }
        for scalar in segment.unicodeScalars {
            guard isAllowedResourceCharacter(scalar) else {
                throw SeerResourceError.invalidPathEncoding
            }
        }
    }

    private static func isAllowedResourceCharacter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".":
            return true
        default:
            return false
        }
    }

    /// Resolves `components` against `root` one path component at a time
    /// (never by string-concatenating a raw relative path onto the root),
    /// then verifies the final resolved URL is still contained within
    /// `root` as a final, belt-and-suspenders defense-in-depth check —
    /// component-by-component appending with the allowlisted charset above
    /// already makes escaping structurally impossible, since no component
    /// can ever contain a `/`.
    private static func resolve(components: [String], root: URL) throws -> URL {
        let standardizedRoot = root.standardizedFileURL
        var resolved = standardizedRoot
        for component in components {
            resolved = resolved.appendingPathComponent(component, isDirectory: false)
        }
        resolved = resolved.standardizedFileURL

        let rootPath = standardizedRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw SeerResourceError.pathEscapesRoot
        }
        return resolved
    }

    private static func mimeType(forFinalComponent component: String) throws -> String {
        let ext = (component as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let mime = mimeTypesByExtension[ext] else {
            throw SeerResourceError.unsupportedExtension
        }
        return mime
    }

    // MARK: File reading

    /// Reads `url` as a bounded, chunked read from a file descriptor opened
    /// with `O_NOFOLLOW | O_CLOEXEC` — never `Data(contentsOf:)`, which
    /// offers no control over symlink-following or maximum size. An
    /// `lstat` runs first purely to reject a symlink at the final path
    /// component with a dedicated error before even attempting to open it;
    /// `O_NOFOLLOW` on the `open` call itself is the authoritative guard
    /// against a symlink swapped in between the two calls (TOCTOU).
    private static func readBoundedRegularFile(at url: URL) throws -> Data {
        let path = url.path

        var linkStat = stat()
        guard lstat(path, &linkStat) == 0 else {
            throw SeerResourceError.notFound
        }
        guard (linkStat.st_mode & S_IFMT) != S_IFLNK else {
            throw SeerResourceError.pathEscapesRoot
        }

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw SeerResourceError.notFound
        }
        defer { close(fd) }

        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            throw SeerResourceError.ioFailure
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw SeerResourceError.notARegularFile
        }

        let size = Int(fileStat.st_size)
        guard size >= 0, size <= maxResourceBytes else {
            throw SeerResourceError.tooLarge
        }
        guard size > 0 else {
            return Data()
        }

        var data = Data(capacity: size)
        var remaining = size
        var buffer = [UInt8](repeating: 0, count: min(readChunkSize, size))
        while remaining > 0 {
            let toRead = min(remaining, buffer.count)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                read(fd, rawBuffer.baseAddress, toRead)
            }
            guard bytesRead > 0 else {
                throw SeerResourceError.ioFailure
            }
            data.append(contentsOf: buffer[0..<bytesRead])
            remaining -= bytesRead
        }
        return data
    }
}

// MARK: - WKURLSchemeHandler adapter

/// Wraps a rejected `SeerResourceError` as an `Error` suitable for
/// `WKURLSchemeTask.didFailWithError(_:)`. Carries only the closed error
/// case — never an interpolated file path or other internal detail.
public struct SeerSchemeHandlerError: Error, Equatable {
    public let resourceError: SeerResourceError
}

/// Loads `seer://` resources for the standalone renderer's `WKWebView`.
/// Delegates every actual file-resolution/read decision to the pure
/// `SeerSchemeResourceLoader` above — this type's only responsibility is
/// `WKURLSchemeTask` lifecycle: exactly one `didReceive(response:)` +
/// `didReceive(data:)` + `didFinish()`, or exactly one
/// `didFailWithError(_:)`, per task — and never any callback at all once
/// `webView(_:stop:)` has been called for that task.
@MainActor
public final class SeerSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "seer"

    private let rendererRoot: SeerRendererRoot

    /// Tasks `webView(_:stop:)` has cancelled. `SeerSchemeResourceLoader
    /// .load` runs synchronously to completion within `webView(_:start:)`
    /// on this same main-actor-isolated instance, so in practice a task
    /// can only ever land in this set *before* its matching `start` call
    /// begins — this check exists as the same defense-in-depth guarantee
    /// regardless of how that timing might change in the future (e.g. if
    /// loading ever became asynchronous). Every path that consults this
    /// set — the stop-before-start early return in `webView(_:start:)` and
    /// the terminal `defer` in `finish(_:taskID:requestURL:with:)` — also
    /// prunes its entry, so this can never grow without bound across the
    /// handler's lifetime no matter which ordering (`start`-then-`stop` or
    /// `stop`-then-`start`) a given task takes.
    private var cancelledTasks: Set<ObjectIdentifier> = []

    /// Test-only visibility into `cancelledTasks`' size, to prove it stays
    /// pruned rather than growing unboundedly.
    var cancelledTaskCountForTesting: Int {
        cancelledTasks.count
    }

    public init(rendererRoot: SeerRendererRoot) {
        self.rendererRoot = rendererRoot
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        guard !cancelledTasks.contains(taskID) else {
            // `stop` arrived before `start` — this is the terminal
            // handling for this task (no callback is ever delivered, and
            // `finish` will never run for it), so its entry must be
            // pruned here. Leaving it behind would let `cancelledTasks`
            // grow without bound over the process's lifetime for every
            // task that happens to be stopped before it starts.
            cancelledTasks.remove(taskID)
            return
        }

        guard let url = urlSchemeTask.request.url else {
            finish(urlSchemeTask, taskID: taskID, requestURL: nil, with: .failure(.invalidPathEncoding))
            return
        }

        finish(
            urlSchemeTask,
            taskID: taskID,
            requestURL: url,
            with: SeerSchemeResourceLoader.load(requestURL: url, rendererRoot: rendererRoot)
        )
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        cancelledTasks.insert(ObjectIdentifier(urlSchemeTask))
    }

    private func finish(
        _ task: WKURLSchemeTask,
        taskID: ObjectIdentifier,
        requestURL: URL?,
        with result: Result<SeerLoadedResource, SeerResourceError>
    ) {
        // Re-checked immediately before delivering any callback: `stop`
        // may have been called while a hypothetical future asynchronous
        // `load` was in flight.
        guard !cancelledTasks.contains(taskID) else { return }
        defer { cancelledTasks.remove(taskID) }

        switch result {
        case .success(let resource):
            let mimeTypeWithoutParameters = resource.mimeType.split(separator: ";").first.map(String.init)
            let response = URLResponse(
                url: requestURL ?? task.request.url ?? SeerNavigationPolicy.allowedInitialDocumentURL,
                mimeType: mimeTypeWithoutParameters,
                expectedContentLength: resource.data.count,
                textEncodingName: resource.mimeType.contains("utf-8") ? "utf-8" : nil
            )
            task.didReceive(response)
            task.didReceive(resource.data)
            task.didFinish()
        case .failure(let error):
            task.didFailWithError(SeerSchemeHandlerError(resourceError: error))
        }
    }
}
