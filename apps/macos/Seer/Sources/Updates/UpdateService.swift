import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Overflow-safe `Int64` millisecond arithmetic for the 24-hour gate in
/// `UpdateService.check(force:)` and `UpdateScheduler`'s due-time
/// computation. Both operate on a *persisted* `Int64` (`lastUpdateCheckAt`)
/// that could, through disk corruption or a bogus prior write, hold any
/// value at all — including `Int64.min`/`Int64.max` — and Swift's plain
/// `+`/`-` trap on overflow rather than wrapping, so naively subtracting an
/// arbitrary persisted timestamp from "now" (or adding the 24h interval to
/// one) can crash the whole app at startup or mid-schedule. Every use site
/// below routes through `SafeTime` instead of a raw operator.
enum SafeTime {
    /// `lhs + rhs`, saturating at `Int64.max`/`Int64.min` instead of
    /// trapping when the true sum would overflow.
    static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return result }
        return rhs >= 0 ? Int64.max : Int64.min
    }

    /// `lhs - rhs`, saturating at `Int64.max`/`Int64.min` instead of
    /// trapping when the true difference would overflow.
    static func saturatingSubtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard overflow else { return result }
        return rhs >= 0 ? Int64.min : Int64.max
    }

    /// Normalizes a persisted "last checked at" timestamp against `now`
    /// before it is used in any elapsed-time/due-time arithmetic. A value
    /// greater than `now` can only be corrupt (no completed check can have
    /// a timestamp from the future) and, left unclamped, would make the
    /// 24-hour gate believe a check "just happened" forever — permanently
    /// suppressing every future check. Clamping it down to `now` instead
    /// bounds the resulting next-due time to exactly one interval from now,
    /// rather than never. Values at or before `now` (including
    /// `Int64.min`) pass through unchanged; `saturatingSubtract`/
    /// `saturatingAdd` at the actual call sites make those safe to combine
    /// with `now`/the interval without overflowing.
    static func normalizedLastCheckedAt(_ lastCheckedAt: Int64, now: Int64) -> Int64 {
        min(lastCheckedAt, now)
    }
}

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
    /// `check(force:)` found a corrupt (future-dated) persisted
    /// `lastUpdateCheckAt` (see `SafeTime.normalizedLastCheckedAt(_:now:)`)
    /// and attempting to persist the repaired value through
    /// `SettingsStore.recordUpdateCheck(etag:lastCheckedAt:release:)`
    /// itself failed. `SettingsStore`/`AtomicJSONStore` retain their
    /// previous persisted value on any failed write, so treating this as
    /// a success would falsely report the gate as satisfied while the
    /// corrupt future timestamp remains on disk — silently delaying
    /// every subsequent real check by another full interval, and
    /// performing no network request at all this call. `message` is
    /// diagnostic-only.
    case timestampRepairFailed(String)
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
    /// How many `check(force:)` calls currently have a network round-trip
    /// in flight (i.e. have passed the 24h gate above and are somewhere
    /// between `session.data(for:)`'s call and return) — tracked as a
    /// count, not a bool, because an actor is reentrant across `await`:
    /// two overlapping `check(force:)` calls can each be mid-flight at
    /// once, and the first one to *return* must not report `isChecking =
    /// false` while the second is still outstanding.
    private var activeCheckCount = 0
    /// Monotonically increases every time a `check(force:)` call actually
    /// starts a network round-trip (i.e. every time `activeCheckCount`
    /// above is incremented), *and* synchronously — before ever awaiting
    /// anything — at the very start of `setIncludePrerelease(_:)`. Each
    /// `check(force:)` call captures its own value (`myGeneration`) before
    /// awaiting `session.data(for:)`, and only persists its result if
    /// `generation` is *still* exactly that value once the await returns —
    /// i.e. only if no other `check(force:)` call (or `setIncludePrerelease`
    /// stream switch) started in the meantime. Because actors are
    /// reentrant across `await`, two overlapping calls (e.g. a manual/
    /// scheduled stable-stream check racing a `setIncludePrerelease(true)`
    /// switch to the prerelease stream) can each have a request in flight
    /// at once, and whichever *returns* first is not necessarily the one
    /// whose ETag/release should end up persisted: persisting completion
    /// order instead of start order would let an older, slower request
    /// stomp a newer one's fresher result, or let one stream's ETag land
    /// after a switch to the other stream. This makes the call that
    /// *started* last always win — never the one that merely *finishes*
    /// last — and every stale/superseded call instead returns whatever the
    /// winning call (or, if it hasn't completed yet, whatever was already
    /// persisted) ends up leaving in `SettingsStore`.
    ///
    /// `setIncludePrerelease(_:)`'s own synchronous bump exists because,
    /// without it, an old-stream check already in flight when the switch
    /// begins would still hold a `myGeneration` ticket that remains valid
    /// (`generation` not yet advanced) throughout `setIncludePrerelease`'s
    /// own `await settingsStore.setIncludePrereleaseUpdates(value)` call —
    /// `generation` was previously only ever advanced later, inside the
    /// forced `check(force: true)` this function goes on to make. That
    /// old call could then complete *during* that await and persist its
    /// now-stale (old-stream) ETag/release right on top of the freshly
    /// cleared state, and that stale write would survive even if the
    /// subsequent forced check against the *new* stream then itself
    /// fails — silently resurrecting the previous stream's cached release
    /// after a switch. Bumping `generation` as the very first, synchronous
    /// statement here — actor code runs to completion up to its first
    /// suspension point, so no other task can interleave before this
    /// executes — invalidates any such in-flight call immediately, before
    /// settings are ever touched, regardless of how the forced check that
    /// follows resolves.
    private var generation: Int64 = 0

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
        // Synchronously invalidate any check already in flight *before*
        // ever awaiting anything — see `generation`'s documentation for
        // why this must happen here, ahead of the settings mutation
        // below, rather than only later inside the forced `check(force:
        // true)` call this function goes on to make.
        generation += 1

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
    /// - A corrupt (future-dated) persisted `lastUpdateCheckAt` whose
    ///   repair-persist itself fails throws
    ///   `UpdateCheckError.timestampRepairFailed` and performs no network
    ///   request, leaving every persisted field exactly as it was before
    ///   the call — see the repair block below.
    public func check(force: Bool) async throws -> UpdateState {
        let now = clock.nowMilliseconds()
        var settings = await settingsStore.current

        if !force,
           let lastCheckedAt = settings.lastUpdateCheckAt
        {
            // See `SafeTime`: a future-dated `lastCheckedAt` can only be
            // corrupt (no completed check can have a future timestamp).
            // Clamping it down to `now` bounds *this* call's elapsed time
            // to zero (i.e. still gated), but merely re-deriving that
            // clamp from a fresh `now` on every subsequent call would
            // suppress checks forever, since the persisted value never
            // itself changes. Persisting the corrected value here —
            // exactly once, even though this call performs no network
            // check — fixes that: every later gate check measures real
            // elapsed time from this point forward, bounding the very
            // next actual check to one ordinary interval from now.
            //
            // That repair-persist can itself fail (e.g. a transient disk
            // write error) — and `SettingsStore` deliberately retains its
            // previous (still corrupt/future) value on any failed write
            // (see `SettingsStore.applyUpdate(_:)`). Silently ignoring
            // that failure (as a bare `try?` once did) and proceeding to
            // treat `settings.lastUpdateCheckAt` as repaired anyway would
            // report this call as gated/successful — with no network
            // request — while the corrupt timestamp is still exactly
            // what's on disk, delaying every subsequent real check by
            // another full interval indefinitely, with no visible
            // failure anywhere. Instead, surface a typed error and adopt
            // the normalized value locally only once persistence has
            // actually confirmed it.
            let normalized = SafeTime.normalizedLastCheckedAt(lastCheckedAt, now: now)
            if normalized != lastCheckedAt {
                do {
                    try await settingsStore.recordUpdateCheck(
                        etag: settings.updateETag,
                        lastCheckedAt: normalized,
                        release: settings.lastRelease
                    )
                } catch {
                    throw UpdateCheckError.timestampRepairFailed(String(describing: error))
                }
                settings.lastUpdateCheckAt = normalized
            }
            // Saturating subtraction so an extreme-past value (e.g.
            // `Int64.min`) reports a huge-but-finite elapsed time —
            // always past the gate — instead of trapping.
            let elapsed = SafeTime.saturatingSubtract(now, normalized)
            if elapsed < Self.checkIntervalMs {
                return stateFrom(settings: settings)
            }
        }

        let includePrerelease = settings.includePrereleaseUpdates
        let request = Self.makeRequest(
            mode: includePrerelease ? .prerelease : .stable,
            etag: settings.updateETag
        )

        // See `generation`'s documentation: this call's own "ticket",
        // captured before the network round-trip begins. Only a call
        // whose ticket is still the most recently issued one, once its
        // round-trip completes, is allowed to persist.
        generation += 1
        let myGeneration = generation
        activeCheckCount += 1
        isChecking = true
        // Every normal-return exit below calls `finishActiveCheck()`
        // itself *before* computing its `currentState()` return value —
        // exactly like the explicit `isChecking = false` this replaced —
        // so that value reflects this call's own completion rather than
        // whatever was still true at the moment `await currentState()`
        // began evaluating. `didFinishActiveCheck` then makes this `defer`
        // a no-op on those paths, while still catching every thrown-error
        // exit (which never calls `finishActiveCheck()` itself).
        var didFinishActiveCheck = false
        func finishActiveCheck() {
            guard !didFinishActiveCheck else { return }
            didFinishActiveCheck = true
            activeCheckCount -= 1
            isChecking = activeCheckCount > 0
        }
        defer { finishActiveCheck() }

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
            // A newer `check(force:)` call has started since this one
            // began — its own result (whether already persisted or still
            // in flight) must win. This call's own (now-stale) 304 must
            // not touch `SettingsStore` at all, and its return value
            // reflects whatever is currently persisted instead of its own
            // discarded outcome.
            guard myGeneration == generation else {
                finishActiveCheck()
                return await currentState()
            }
            let completedAt = clock.nowMilliseconds()
            try await settingsStore.recordUpdateCheck(
                etag: settings.updateETag,
                lastCheckedAt: completedAt,
                release: settings.lastRelease
            )
            finishActiveCheck()
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

        // Same staleness check as the 304 branch above, for the same
        // reason: a newer call started while this one's request was still
        // in flight, so this (older) call's freshly-fetched 200 result
        // must not overwrite whatever that newer call has (or will)
        // persist.
        guard myGeneration == generation else {
            finishActiveCheck()
            return await currentState()
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
        finishActiveCheck()
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
/// interval elapses, returning whether the attempt succeeded (`true`) or
/// threw (`false`) — used only to decide how `UpdateScheduler` should
/// reschedule its *next* attempt (see `runLoop`'s handling of a `false`
/// result). `UpdateScheduler` itself has no other notion of *how* that
/// check's resulting `UpdateState` should be surfaced — it only knows how
/// to wait for the right moment, invoke this callback, and interpret its
/// returned success flag. Production wiring that has an
/// `AppSnapshotCoordinator` (or equivalent) available should route this at
/// `checkForUpdates(force: false)` so a scheduled check publishes its
/// result and surfaces any failure as
/// `CoordinatorDiagnosticID.updatesCheckFailed`, exactly like an explicit,
/// renderer-initiated check would, while still reporting that failure
/// back to the scheduler; the bare `UpdateChecking`-based convenience
/// initializer below instead calls `check(force:)` directly, silently
/// discards its result, and reports only whether it threw, for callers
/// (or tests) with no such coordinator to route through.
public typealias UpdateSchedulerCheckAction = @Sendable () async -> Bool

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
/// `Sleeper`, invokes `performScheduledCheck`, and reschedules its next
/// wake depending on that attempt's outcome:
///
/// - On success (or a wake the 24h gate suppresses — e.g. because a
///   manual/prerelease-forced check already ran elsewhere while this loop
///   slept), it reschedules from `lastCompletedCheckAt`'s own latest
///   value — never from the wake's own wall-clock time — so it
///   reschedules 24h after *that* check instead of deferring another
///   full 24h from this stale wake.
/// - On failure, `lastCompletedCheckAt` is guaranteed unchanged (a failed
///   check never persists a new `lastCheckedAt`) and — since that stale
///   value is exactly what made this attempt due in the first place — is
///   already in the past. Recomputing from it here would therefore
///   produce a due time still in the past, causing an immediate,
///   zero-delay retry loop. Instead the scheduler reschedules a full 24h
///   from *this* failed attempt's own completion time, bounding retries
///   to once daily like every other scheduled attempt.
///
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
            performScheduledCheck: { (try? await service.check(force: false)) != nil }
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
            // Bounded to `[0, checkIntervalMs]`: `dueAt`/`clock
            // .nowMilliseconds()` can each independently be any `Int64`
            // (a corrupt persisted timestamp, or — in tests — a
            // deliberately extreme injected clock value), so a plain
            // `dueAt - now` could trap, and even a saturating subtraction
            // alone could still hand `UInt64(remainingMs) * 1_000_000`
            // below a value large enough to overflow *that* multiplication.
            // Clamping to the interval keeps every sleep both crash-safe
            // and no longer than one ordinary scheduling period.
            let elapsed = SafeTime.saturatingSubtract(dueAt, clock.nowMilliseconds())
            let remainingMs = min(max(0, elapsed), UpdateService.checkIntervalMs)
            do {
                try await sleeper.sleep(nanoseconds: UInt64(remainingMs) * 1_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }
            let succeeded = await performScheduledCheck()
            if succeeded {
                // Recompute from the latest completed check's own timestamp
                // (not from `clock.nowMilliseconds()` right after this wake)
                // so a wake that the 24h gate suppressed — e.g. because a
                // manual/prerelease-forced check already ran elsewhere while
                // this loop slept — reschedules 24h after *that* check
                // instead of deferring another full 24h from this stale wake.
                dueAt = await nextDueAt(lastCompletedCheckAt: lastCompletedCheckAt, clock: clock)
            } else {
                // A failed attempt leaves `lastCompletedCheckAt` unchanged —
                // and that stale value is already in the past (it's exactly
                // what made this attempt due). Recomputing from it here
                // would produce a due time still in the past, causing an
                // immediate, zero-delay retry loop. Reschedule a full 24h
                // from this failed attempt's own completion time instead,
                // so a failing scheduled check still only retries once
                // daily, exactly like a successful one.
                dueAt = SafeTime.saturatingAdd(clock.nowMilliseconds(), UpdateService.checkIntervalMs)
            }
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
        // See `SafeTime`: a real persisted value gets clamped down to
        // `now` if it's future-dated (corrupt) so a bogus value (e.g.
        // `Int64.max`) can never push the next due time out to "never" —
        // it instead becomes due a bounded 24h from now, exactly as if
        // the check had just completed. An extreme-past value (e.g.
        // `Int64.min`) passes through unclamped and is made overflow-safe
        // by `saturatingAdd` below. `nil` (no check has ever completed)
        // is unaffected — it still schedules the first check 24h from now,
        // preserving ordinary startup semantics.
        let normalized = lastCheckedAt.map { SafeTime.normalizedLastCheckedAt($0, now: now) } ?? now
        return SafeTime.saturatingAdd(normalized, UpdateService.checkIntervalMs)
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
