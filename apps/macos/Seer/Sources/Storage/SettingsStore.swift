import Foundation

/// A minimal, durable cache of the most recent valid GitHub release
/// `UpdateService` has observed for the running app — never a draft, never
/// an unparseable tag, and never a URL that failed the https/`github.com`
/// validation `UpdateService` applies before persisting anything. `version`
/// is the tag exactly as GitHub returned it (e.g. `v1.3.0`); `url` is the
/// release's `html_url`.
public struct PersistedRelease: Codable, Equatable, Sendable {
    public var version: String
    public var url: String

    public init(version: String, url: String) {
        self.version = version
        self.url = url
    }
}

/// Persisted Seer application settings. Standalone from day one — this
/// document, its storage location, and its bundle identifier
/// (`ai.opencoven.seer`) have never been, and must never become, tied to any
/// legacy host application's path or identifier.
///
/// `updateETag`/`lastUpdateCheckAt`/`lastRelease` are all optional so a
/// version-1 file written before this task (or any file with these keys
/// simply absent) still decodes successfully with every one of them `nil` —
/// Swift's synthesized `Decodable` treats a missing key on an `Optional`
/// stored property as `nil` rather than a decode failure.
public struct SettingsDocument: VersionedDocument {
    public static let currentVersion = 1

    public static let defaultValue = SettingsDocument(
        version: SettingsDocument.currentVersion,
        keepAwakeMode: .system,
        includePrereleaseUpdates: false
    )

    public var version: Int
    public var keepAwakeMode: KeepAwakeMode
    public var includePrereleaseUpdates: Bool
    /// The `ETag` response header from the most recent successful (200)
    /// update check, forwarded as `If-None-Match` on the next request so an
    /// unchanged release can short-circuit to a cheap `304`.
    public var updateETag: String?
    /// Unix milliseconds of the most recently *completed* update check
    /// (whether it returned `200` or `304`) — the 24-hour gate's basis.
    public var lastUpdateCheckAt: Int64?
    /// The most recent valid release `UpdateService` has observed, or `nil`
    /// if none has ever been found (or the app is already caught up).
    public var lastRelease: PersistedRelease?

    public init(
        version: Int,
        keepAwakeMode: KeepAwakeMode,
        includePrereleaseUpdates: Bool,
        updateETag: String? = nil,
        lastUpdateCheckAt: Int64? = nil,
        lastRelease: PersistedRelease? = nil
    ) {
        self.version = version
        self.keepAwakeMode = keepAwakeMode
        self.includePrereleaseUpdates = includePrereleaseUpdates
        self.updateETag = updateETag
        self.lastUpdateCheckAt = lastUpdateCheckAt
        self.lastRelease = lastRelease
    }
}

/// Resolves the on-disk location of Seer's standalone settings file. Always
/// `<Application Support>/ai.opencoven.seer/settings.json` — never any other
/// application's identifier or path.
public enum SettingsFileLocation {
    /// The Seer-specific directory name under Application Support. Kept as
    /// a named constant so it appears exactly once and every callers/tests
    /// reference the same literal.
    public static let directoryName = "ai.opencoven.seer"

    /// The settings file's name within `directoryName`.
    public static let fileName = "settings.json"

    /// Resolves the real, user-domain Application Support directory,
    /// creating it if necessary. Production entry point; tests inject their
    /// own base URL via `settingsFileURL(applicationSupportDirectory:)`
    /// instead of calling this.
    public static func resolveApplicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Appends `ai.opencoven.seer/settings.json` to `applicationSupportDirectory`,
    /// creating the intermediate `ai.opencoven.seer` directory if needed, and
    /// returns the settings file's URL. `applicationSupportDirectory` is
    /// injected so tests can point at an isolated scratch directory instead
    /// of the real Application Support folder.
    public static func settingsFileURL(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = applicationSupportDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

/// Owns the single in-memory `SettingsDocument` plus the underlying
/// `AtomicJSONStore`, serialized as an `actor` so concurrent mutation calls
/// (e.g. rapid toggles in the UI) apply in invocation order.
///
/// Every mutator persists to disk *before* updating `current`, so a failed
/// disk save never leaves the in-memory value looking like it succeeded.
public actor SettingsStore {
    private let store: AtomicJSONStore<SettingsDocument>
    public private(set) var current: SettingsDocument
    public private(set) var lastDiagnostic: Diagnostic?

    /// Whether `store.load()` has completed at least once for this
    /// instance. Mutators check this (via `ensureLoaded()`) so a caller
    /// can mutate `SettingsStore` directly without a separate `load()`
    /// call first.
    private var hasLoaded = false

    /// Serializes every public `load()`/mutator call through its full
    /// awaited underlying `AtomicJSONStore` round trip and `current`/
    /// `lastDiagnostic` publication, in FIFO invocation order. Without
    /// this, actor reentrancy across the `await store.load()`/`await
    /// store.save(...)` calls below would let a second mutator read
    /// `current` before the first one has published its result, or let
    /// two mutators race to publish out of invocation order.
    private let gate = AsyncGate()

    public init(
        store: AtomicJSONStore<SettingsDocument>,
        initialValue: SettingsDocument = SettingsDocument.defaultValue
    ) {
        self.store = store
        self.current = initialValue
    }

    /// Loads the persisted document (or defaults), publishing the result as
    /// `current` and `lastDiagnostic`. Safe to call repeatedly; each call
    /// re-reads from disk through the underlying `AtomicJSONStore`.
    @discardableResult
    public func load() async -> LoadResult<SettingsDocument> {
        await gate.acquire()
        let result = await performLoad()
        await gate.release()
        return result
    }

    private func performLoad() async -> LoadResult<SettingsDocument> {
        let result = await store.load()
        current = result.value
        lastDiagnostic = result.diagnostic
        hasLoaded = true
        return result
    }

    /// Performs `load()`'s underlying work exactly once, if it has never
    /// run, *without* acquiring `gate` again — every caller of this is
    /// already running inside a `gate`-guarded mutator, and `gate` is not
    /// reentrant, so acquiring it a second time here would deadlock. This
    /// lets a mutator be called directly with no prior explicit `load()`
    /// call, while still correctly treating an existing on-disk
    /// future/unreadable file as read-only — the subsequent
    /// `store.save(...)` throws `StorageError.writesDisabled` in that case
    /// — instead of silently overwriting it.
    private func ensureLoaded() async {
        guard !hasLoaded else { return }
        _ = await performLoad()
    }

    public func setKeepAwakeMode(_ mode: KeepAwakeMode) async throws {
        await gate.acquire()
        do {
            try await performSetKeepAwakeMode(mode)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performSetKeepAwakeMode(_ mode: KeepAwakeMode) async throws {
        await ensureLoaded()
        try await applyUpdate { document in
            var updated = document
            updated.keepAwakeMode = mode
            return updated
        }
    }

    /// Persists the include-prerelease toggle *and*, in the same atomic
    /// transform, clears every cached update-check field
    /// (`updateETag`/`lastUpdateCheckAt`/`lastRelease`). Switching streams
    /// (stable ⇄ prerelease) changes which GitHub endpoint the next check
    /// queries, so a cached `ETag`/release from the other stream must never
    /// be reused as a conditional-request precondition or shown as though
    /// it were the freshest answer for the newly selected stream; clearing
    /// `lastUpdateCheckAt` alongside them additionally means the very next
    /// check (whether the caller also explicitly forces one, or the
    /// background scheduler's next tick) is treated as due immediately
    /// rather than still gated behind a stale 24-hour window.
    public func setIncludePrereleaseUpdates(_ value: Bool) async throws {
        await gate.acquire()
        do {
            try await performSetIncludePrereleaseUpdates(value)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performSetIncludePrereleaseUpdates(_ value: Bool) async throws {
        await ensureLoaded()
        try await applyUpdate { document in
            var updated = document
            updated.includePrereleaseUpdates = value
            updated.updateETag = nil
            updated.lastUpdateCheckAt = nil
            updated.lastRelease = nil
            return updated
        }
    }

    /// Persists the outcome of one completed update check — the response's
    /// `ETag` (or `nil` if the response had none), the moment the check
    /// completed, and the most recent valid release observed (or `nil` if
    /// none is known/applicable) — as a single atomic transform. Called by
    /// `UpdateService` after both a fresh `200` result and a `304 Not
    /// Modified` result (the latter passing through its own prior
    /// `etag`/`release` unchanged, since only `lastUpdateCheckAt` actually
    /// changed): either way, this is the one place that update-check state
    /// is written to disk.
    public func recordUpdateCheck(etag: String?, lastCheckedAt: Int64, release: PersistedRelease?) async throws {
        await gate.acquire()
        do {
            try await performRecordUpdateCheck(etag: etag, lastCheckedAt: lastCheckedAt, release: release)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performRecordUpdateCheck(etag: String?, lastCheckedAt: Int64, release: PersistedRelease?) async throws {
        await ensureLoaded()
        try await applyUpdate { document in
            var updated = document
            updated.updateETag = etag
            updated.lastUpdateCheckAt = lastCheckedAt
            updated.lastRelease = release
            return updated
        }
    }

    /// Runs `transform` through `AtomicJSONStore.update(_:)` — a single
    /// lock-scoped read-modify-write against the *freshest on-disk*
    /// document, not this instance's own possibly-stale `current` cache —
    /// so two independently loaded `SettingsStore` instances mutating
    /// different fields can never lose one's change to the other's stale
    /// snapshot (see `AtomicJSONStore.update(_:)`'s documentation).
    ///
    /// If the underlying write's directory-sync durability is uncertain,
    /// the new document was still durably committed to disk (the rename
    /// itself succeeded): `current` is published to that committed value
    /// *before* rethrowing `StorageError.durabilityUncertain`, so the
    /// cache is never left stale relative to disk and a subsequent
    /// mutation always starts from the value actually on disk, never
    /// reverting it.
    private func applyUpdate(_ transform: @Sendable (SettingsDocument) -> SettingsDocument) async throws {
        do {
            current = try await store.update(transform)
        } catch let error as StorageUpdateError<SettingsDocument> {
            switch error {
            case .durabilityUncertain(let committed):
                current = committed
                throw StorageError.durabilityUncertain
            case .failure(let storageError):
                throw storageError
            }
        }
    }
}
