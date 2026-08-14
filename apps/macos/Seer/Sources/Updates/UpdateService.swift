import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Typed failures `UpdateService.check(force:)` can throw. A network
/// failure (offline, DNS, TLS, timeout, ...) or an unexpected HTTP status
/// or an undecodable response body are all reported through one of these
/// cases — never as an untyped `Error`/silently swallowed — and, per this
/// task's requirement, never mutate `SettingsStore`'s cached update state:
/// `UpdateService.currentState()` after a thrown `check(force:)` reports
/// exactly the same value it did before the call.
public enum UpdateCheckError: Error, Equatable, Sendable {
    /// The underlying `URLSession` request itself failed (offline, DNS,
    /// TLS, timeout, cancellation, ...). `message` is diagnostic-only.
    case network(String)
    /// The response was not an `HTTPURLResponse` at all.
    case invalidResponse
    /// The response's HTTP status was neither `200` (fresh result) nor
    /// `304` (not modified).
    case unexpectedStatus(Int)
    /// A `200` response's body could not be decoded as the expected
    /// GitHub release (or release-list) JSON shape.
    case malformedReleasePayload
}

/// The exact GitHub release fields `UpdateService` needs. `tagName` is the
/// raw tag (e.g. `v1.3.0`) parsed via `SemanticVersion.parse(_:)`;
/// `htmlURL` is the human-facing release page, validated by
/// `UpdateService.isValidReleaseURL(_:)` before ever being persisted or
/// opened.
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
    }
}

public protocol ReleaseURLOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

public struct WorkspaceReleaseURLOpener: ReleaseURLOpening {
    public init() {}

    public func open(_ url: URL) async -> Bool {
        #if canImport(AppKit)
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #else
        return false
        #endif
    }
}

/// `UpdateService`'s two possible GitHub endpoints, chosen by
/// `SettingsDocument.includePrereleaseUpdates`.
enum UpdateCheckMode: Equatable, Sendable {
    /// `GET /repos/{owner}/{repo}/releases/latest` — GitHub itself already
    /// excludes drafts and pre-releases from this endpoint's result.
    case stable
    /// `GET /repos/{owner}/{repo}/releases?per_page=20` — a bounded window
    /// over every release (including drafts and pre-releases), from which
    /// `UpdateService` picks the highest valid, non-draft SemVer tag.
    case prerelease
}

/// A GitHub-backed, notify-only update checker for the standalone macOS
/// app. Persists only `lastUpdateCheckAt`/`updateETag`/`lastRelease`
/// (via `SettingsStore`) — never downloads, installs, or auto-applies
/// anything. An actor so every `check(force:)`/`currentState()`/
/// `setIncludePrerelease(_:)` call serializes against the same in-flight
/// request state.
public actor UpdateService {
    /// The stable, always-owner/repo GitHub coordinates this app's release
    /// feed lives at. Not configurable — Seer only ever checks the
    /// dedicated public releases repository (`OpenCoven/seer-releases`),
    /// never the main `OpenCoven/seer` source repository, which never has
    /// its own GitHub releases published against it.
    static let owner = "OpenCoven"
    static let repoName = "seer-releases"
    static let userAgent = "Seer/1.0.0"
    /// The 24-hour gate `check(force:)` (when not forced) and
    /// `UpdateScheduler` both key off of.
    static let checkIntervalMs: Int64 = 24 * 60 * 60 * 1000

    private let settingsStore: SettingsStore
    private let session: URLSession
    private let clock: Clock
    private let currentVersion: SemanticVersion
    private let releaseOpener: any ReleaseURLOpening
    private var isChecking = false

    public init(
        settingsStore: SettingsStore,
        session: URLSession,
        clock: Clock,
        currentVersion: String,
        releaseOpener: any ReleaseURLOpening = WorkspaceReleaseURLOpener()
    ) {
        self.settingsStore = settingsStore
        self.session = session
        self.clock = clock
        self.releaseOpener = releaseOpener
        // An unparseable running-app version (should never happen in
        // production, where it comes from `CFBundleShortVersionString`)
        // falls back to `0.0.0` — the smallest possible version — so this
        // service still degrades to "any valid release looks newer"
        // rather than crashing or silently disabling update checks.
        self.currentVersion = SemanticVersion.parse(currentVersion) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    /// A production `URLSession`: ephemeral (no on-disk cache), no cookies,
    /// no credential storage, and a 10-second timeout for both the request
    /// and the overall resource load — this service never needs to persist
    /// any session-level state of its own between requests, and every
    /// piece of state it *does* need to persist goes through
    /// `SettingsStore` instead.
    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// The current, non-network-touching update state, derived from
    /// `SettingsStore`'s persisted cache — the same value `check(force:)`
    /// leaves in place on a thrown `UpdateCheckError`.
    public func currentState() async -> UpdateState {
        stateFrom(settings: await settingsStore.current)
    }

    /// Persists the include-prerelease toggle (which also clears the
    /// cached `ETag`/`lastRelease` — see `SettingsStore
    /// .setIncludePrereleaseUpdates(_:)`) and then immediately forces a
    /// fresh check against the newly selected stream. If the forced check
    /// itself fails, the persisted toggle is *not* rolled back — the
    /// setting change always succeeds independently of network
    /// reachability — but the thrown `UpdateCheckError` still propagates
    /// to the caller so it can surface the failure.
    public func setIncludePrerelease(_ value: Bool) async throws -> UpdateState {
        try await settingsStore.setIncludePrereleaseUpdates(value)
        return try await check(force: true)
    }

    /// Opens the most recently cached, already-validated release URL via
    /// `NSWorkspace` — never a URL supplied by any caller, and never one
    /// that has not already passed `isValidReleaseURL(_:)` at persist time.
    /// Returns `false` (without throwing) if there is no cached release or
    /// `NSWorkspace` itself declines to open it.
    @discardableResult
    public func openCurrentRelease() async -> Bool {
        guard let release = await settingsStore.current.lastRelease,
              let url = URL(string: release.url),
              Self.isValidReleaseURL(url)
        else {
            return false
        }
        return await releaseOpener.open(url)
    }

    /// Runs one update check. When `force` is `false` and the last
    /// completed check was less than `checkIntervalMs` ago, this returns
    /// the cached state immediately with no network request at all — the
    /// 24-hour gate. Otherwise it queries the GitHub endpoint matching the
    /// currently persisted `includePrereleaseUpdates` mode, forwarding the
    /// cached `ETag` as `If-None-Match`.
    ///
    /// - A `304 Not Modified` response retains the previously cached
    ///   `ETag`/`lastRelease` and only advances `lastUpdateCheckAt`.
    /// - A `200` response selects the highest valid (non-draft, parseable,
    ///   HTTPS/`github.com`) SemVer release from the response, and
    ///   persists it (or `nil`, if none qualified) alongside the response's
    ///   `ETag` and the current time.
    /// - Any other status, a non-HTTP response, an undecodable body, or a
    ///   transport-level failure throws a typed `UpdateCheckError` and
    ///   leaves every persisted field exactly as it was before the call.
    public func check(force: Bool) async throws -> UpdateState {
        let now = clock.nowMilliseconds()
        let settings = await settingsStore.current

        if !force,
           let lastCheckedAt = settings.lastUpdateCheckAt,
           now - lastCheckedAt < Self.checkIntervalMs
        {
            return stateFrom(settings: settings)
        }

        let includePrerelease = settings.includePrereleaseUpdates
        let request = Self.makeRequest(
            mode: includePrerelease ? .prerelease : .stable,
            etag: settings.updateETag
        )

        isChecking = true
        defer { isChecking = false }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        if httpResponse.statusCode == 304 {
            let completedAt = clock.nowMilliseconds()
            try await settingsStore.recordUpdateCheck(
                etag: settings.updateETag,
                lastCheckedAt: completedAt,
                release: settings.lastRelease
            )
            isChecking = false
            return await currentState()
        }

        guard httpResponse.statusCode == 200 else {
            throw UpdateCheckError.unexpectedStatus(httpResponse.statusCode)
        }

        let releases: [GitHubRelease]
        do {
            let decoder = JSONDecoder()
            if includePrerelease {
                releases = try decoder.decode([GitHubRelease].self, from: data)
            } else {
                releases = [try decoder.decode(GitHubRelease.self, from: data)]
            }
        } catch {
            throw UpdateCheckError.malformedReleasePayload
        }

        let selected = Self.selectBestRelease(from: releases)
        let newEtag = httpResponse.value(forHTTPHeaderField: "Etag")

        // `selectBestRelease` already filtered out every release with an
        // invalid URL before ranking by version, so `selected` (if any) is
        // always safe to persist as-is here.
        let persistedRelease: PersistedRelease? = selected.map {
            PersistedRelease(version: $0.tagName, url: $0.htmlURL)
        }

        let completedAt = clock.nowMilliseconds()
        try await settingsStore.recordUpdateCheck(etag: newEtag, lastCheckedAt: completedAt, release: persistedRelease)
        isChecking = false
        return await currentState()
    }

    // MARK: - Pure helpers

    private func stateFrom(settings: SettingsDocument) -> UpdateState {
        var availableVersion: String?
        var releaseURL: String?
        if let release = settings.lastRelease,
           let releaseVersion = SemanticVersion.parse(release.version),
           currentVersion < releaseVersion
        {
            availableVersion = release.version
            releaseURL = release.url
        }
        return UpdateState(
            checking: isChecking,
            availableVersion: availableVersion,
            releaseURL: releaseURL,
            lastCheckedAt: settings.lastUpdateCheckAt
        )
    }

    /// Every non-draft release in `releases` whose `tagName` parses as a
    /// valid `SemanticVersion` *and* whose `htmlURL` passes
    /// `isValidReleaseURL(_:)`, keeping the single highest one by SemVer
    /// precedence (ties broken by keeping the first encountered). Drafts
    /// are unconditionally excluded regardless of endpoint/mode; the
    /// stable `/releases/latest` endpoint itself already excludes drafts
    /// and pre-releases before this ever runs, so this filter chiefly
    /// matters for the bounded `/releases` list used in pre-release mode.
    ///
    /// URL validity is filtered *before* ranking by version — not after
    /// picking the nominally-highest candidate — so a higher-versioned
    /// release with an untrustworthy URL can never suppress a lower,
    /// otherwise-valid release from being selected: e.g. releases
    /// `[9.9.9 (bad URL), 1.2.0 (good URL)]` must still select `1.2.0`,
    /// not silently report "no update available" just because the
    /// highest-numbered entry happened to fail URL validation.
    static func selectBestRelease(from releases: [GitHubRelease]) -> GitHubRelease? {
        var best: (release: GitHubRelease, version: SemanticVersion)?
        for release in releases where !release.draft {
            guard let version = SemanticVersion.parse(release.tagName) else { continue }
            guard let url = URL(string: release.htmlURL), isValidReleaseURL(url) else { continue }
            if best == nil || version > best!.version {
                best = (release, version)
            }
        }
        return best?.release
    }

    /// Defense-in-depth: a release URL is only ever trusted (persisted,
    /// exposed to the renderer, or opened via `NSWorkspace`) if it is
    /// exactly `https://github.com/...` — never any other scheme or host,
    /// even one a compromised or unexpected API response might supply.
    static func isValidReleaseURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
    }

    private static func endpointURL(for mode: UpdateCheckMode) -> URL {
        switch mode {
        case .stable:
            return URL(string: "https://api.github.com/repos/\(owner)/\(repoName)/releases/latest")!
        case .prerelease:
            return URL(string: "https://api.github.com/repos/\(owner)/\(repoName)/releases?per_page=20")!
        }
    }

    /// Builds the exact `URLRequest` this service sends: `GET`, no body,
    /// a 10-second per-request timeout, only the three headers a GitHub
    /// release check needs (`User-Agent`, `Accept`, and — when a cached
    /// `ETag` exists — `If-None-Match`), and nothing that could reveal any
    /// other local state to the server.
    static func makeRequest(mode: UpdateCheckMode, etag: String?) -> URLRequest {
        var request = URLRequest(
            url: endpointURL(for: mode),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }
}

// MARK: - Scheduler

/// Abstraction over suspending for a duration, injected into
/// `UpdateScheduler` so tests can deterministically control exactly when
/// its background loop wakes up, instead of depending on real wall-clock
/// delays. Production uses `TaskSleeper` (backed by `Task.sleep`).
public protocol Sleeper: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

/// The production `Sleeper`, backed by `Task.sleep(nanoseconds:)` — which
/// already responds to task cancellation by throwing `CancellationError`.
public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// The `UpdateService` operations `AppSnapshotCoordinator` depends on to
/// integrate update checks into its own atomic snapshot transitions.
/// Abstracted behind a protocol (rather than the coordinator depending on
/// the concrete actor directly) purely for testability: coordinator-level
/// tests can substitute a scripted fake here instead of standing up a real
/// `UpdateService` with a live/mocked `URLSession` for every test, even
/// ones that have nothing to do with updates. `UpdateService` conforms via
/// the extension immediately below; production code always uses that real
/// conformance.

public protocol UpdateChecking: Sendable {
    func check(force: Bool) async throws -> UpdateState
    func currentState() async -> UpdateState
    func setIncludePrerelease(_ value: Bool) async throws -> UpdateState
    @discardableResult
    func openCurrentRelease() async -> Bool
}

extension UpdateService: UpdateChecking {}

/// Runs `UpdateScheduler`'s own non-forced scheduled check once its 24-hour
/// interval elapses. `UpdateScheduler` itself has no notion of *how* that
/// check's resulting `UpdateState` should be surfaced — it only knows how
/// to wait for the right moment and invoke this callback. Production
/// wiring that has an `AppSnapshotCoordinator` (or equivalent) available
/// should route this at `checkForUpdates(force: false)` so a scheduled
/// check publishes its result and surfaces any failure as
/// `CoordinatorDiagnosticID.updatesCheckFailed`, exactly like an explicit,
/// renderer-initiated check would; the bare `UpdateChecking`-based
/// convenience initializer below instead calls `check(force:)` directly
/// and silently discards its result/failure, for callers (or tests) with
/// no such coordinator to route through.
public typealias UpdateSchedulerCheckAction = @Sendable () async -> Void

/// Reports the timestamp (in milliseconds) of the most recently completed
/// scheduled check, if any — used only to compute `UpdateScheduler`'s
/// initial due time. Mirrors whichever store backs
/// `UpdateSchedulerCheckAction` (e.g. a coordinator's own
/// `snapshot.update.lastCheckedAt`, or a bare `UpdateService`'s
/// `currentState().lastCheckedAt`).
public typealias UpdateSchedulerLastCheckedAtProvider = @Sendable () async -> Int64?

/// Runs one non-forced update check every 24 hours (from the most
/// recently completed check, not wall-clock ticks) for as long as the app
/// is running, entirely in the background. `start()` computes how long to
/// sleep until the last completed check's time plus 24h (or checks
/// immediately if no check has ever completed), sleeps via the injected
/// `Sleeper`, invokes `performScheduledCheck`, and reschedules from
/// `lastCompletedCheckAt`'s own latest value after every wake/check
/// attempt — never from the wake's own wall-clock time — so a slow/failed
/// check never causes back-to-back immediate retries, and a wake the 24h
/// gate suppresses (e.g. because a manual/prerelease-forced check already
/// ran elsewhere while this loop slept) reschedules 24h after *that*
/// check instead of deferring another full 24h from this stale wake.
/// `stop()` cancels the background `Task` at shutdown; an in-progress
/// sleep is abandoned rather than waited out.
public actor UpdateScheduler {
    private let performScheduledCheck: UpdateSchedulerCheckAction
    private let lastCompletedCheckAt: UpdateSchedulerLastCheckedAtProvider
    private let clock: Clock
    private let sleeper: Sleeper
    private var task: Task<Void, Never>?

    /// The primary initializer: every scheduled, non-forced check is
    /// routed entirely through `performScheduledCheck` (and its due time
    /// computed from `lastCompletedCheckAt`) rather than this scheduler
    /// owning an `UpdateService`/`UpdateChecking` directly — so production
    /// wiring can point both at an `AppSnapshotCoordinator`'s own
    /// `checkForUpdates(force: false)`/`snapshot.update.lastCheckedAt`
    /// instead of silently discarding every scheduled check's result the
    /// way a bare service call would.
    ///
    /// If `performScheduledCheck`/`lastCompletedCheckAt` capture a
    /// class/actor that itself owns this scheduler (e.g. an
    /// `AppSnapshotCoordinator` that stores the resulting
    /// `UpdateScheduler` for its own `start()`/`stop()` lifecycle), that
    /// reference **must** be captured weakly to avoid a retain cycle —
    /// this initializer has no way to enforce that at the type level,
    /// since `@Sendable () async -> Void` erases any captured reference's
    /// identity.
    public init(
        clock: Clock,
        sleeper: Sleeper = TaskSleeper(),
        lastCompletedCheckAt: @escaping UpdateSchedulerLastCheckedAtProvider,
        performScheduledCheck: @escaping UpdateSchedulerCheckAction
    ) {
        self.lastCompletedCheckAt = lastCompletedCheckAt
        self.performScheduledCheck = performScheduledCheck
        self.clock = clock
        self.sleeper = sleeper
    }

    /// A convenience initializer wiring the scheduler directly to a bare
    /// `UpdateChecking` conformance (typically `UpdateService` itself)
    /// with no further publish/diagnostic behavior: a scheduled check's
    /// result is discarded and any failure is silently retried at the
    /// next interval, mirroring `check(force:)`'s own "leave cached state
    /// untouched" contract. Used by callers/tests that only need to
    /// exercise the scheduler's own timing behavior in isolation, with no
    /// `AppSnapshotCoordinator` (or equivalent) to route scheduled checks
    /// through — see the primary initializer above for the wiring real
    /// production code should use instead, whenever such a coordinator is
    /// available.
    public init(service: any UpdateChecking, clock: Clock, sleeper: Sleeper = TaskSleeper()) {
        self.init(
            clock: clock,
            sleeper: sleeper,
            lastCompletedCheckAt: { await service.currentState().lastCheckedAt },
            performScheduledCheck: { _ = try? await service.check(force: false) }
        )
    }

    /// Starts the background loop, if not already running. Safe to call
    /// more than once — a second call while already started is a no-op.
    public func start() {
        guard task == nil else { return }
        task = Task { [performScheduledCheck, lastCompletedCheckAt, clock, sleeper] in
            await Self.runLoop(
                performScheduledCheck: performScheduledCheck,
                lastCompletedCheckAt: lastCompletedCheckAt,
                clock: clock,
                sleeper: sleeper
            )
        }
    }

    /// Cancels the background loop. If it is currently sleeping, the sleep
    /// is abandoned (via `Task` cancellation) rather than run to
    /// completion — no further check is performed after this returns
    /// (once the cancelled task actually finishes unwinding).
    public func stop() {
        task?.cancel()
        task = nil
    }

    private static func runLoop(
        performScheduledCheck: UpdateSchedulerCheckAction,
        lastCompletedCheckAt: UpdateSchedulerLastCheckedAtProvider,
        clock: Clock,
        sleeper: Sleeper
    ) async {
        var dueAt = await nextDueAt(lastCompletedCheckAt: lastCompletedCheckAt, clock: clock)
        while !Task.isCancelled {
            let remainingMs = max(0, dueAt - clock.nowMilliseconds())
            do {
                try await sleeper.sleep(nanoseconds: UInt64(remainingMs) * 1_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await performScheduledCheck()
            // Recompute from the latest completed check's own timestamp
            // (not from `clock.nowMilliseconds()` right after this wake)
            // so a wake that the 24h gate suppressed — e.g. because a
            // manual/prerelease-forced check already ran elsewhere while
            // this loop slept — reschedules 24h after *that* check
            // instead of deferring another full 24h from this stale wake.
            dueAt = await nextDueAt(lastCompletedCheckAt: lastCompletedCheckAt, clock: clock)
        }
    }

    /// Computes the next due time as 24h after the most recently completed
    /// check (falling back to "now" if none has ever completed) — used
    /// both for the loop's initial sleep and to reschedule after every
    /// wake/check attempt, so both cases always derive from the same
    /// latest persisted/service `lastCheckedAt` source rather than from
    /// whenever the loop happened to wake up.
    private static func nextDueAt(
        lastCompletedCheckAt: UpdateSchedulerLastCheckedAtProvider,
        clock: Clock
    ) async -> Int64 {
        let lastCheckedAt = await lastCompletedCheckAt()
        let now = clock.nowMilliseconds()
        return (lastCheckedAt ?? now) + UpdateService.checkIntervalMs
    }
}

/// The `UpdateScheduler` lifecycle operations `AppSnapshotCoordinator`
/// depends on for scheduler ownership (`start()`/`stop()`), abstracted for
/// the same testability reason as `UpdateChecking` above — a coordinator
/// test can verify the scheduler was started/stopped at the right moments
/// without needing a real background loop or `Sleeper`.

public protocol UpdateSchedulerControlling: Sendable {
    func start() async
    func stop() async
}

extension UpdateScheduler: UpdateSchedulerControlling {}
