import Foundation

/// Persisted Seer application settings. Standalone from day one — this
/// document, its storage location, and its bundle identifier
/// (`ai.opencoven.seer`) have never been, and must never become, tied to any
/// legacy host application's path or identifier.
///
/// Update-cache fields (last-checked timestamp, cached release info, etc.)
/// belong to a later task and are intentionally omitted here.
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

    public init(version: Int, keepAwakeMode: KeepAwakeMode, includePrereleaseUpdates: Bool) {
        self.version = version
        self.keepAwakeMode = keepAwakeMode
        self.includePrereleaseUpdates = includePrereleaseUpdates
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
