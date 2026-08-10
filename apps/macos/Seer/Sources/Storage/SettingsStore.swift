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
        let result = await store.load()
        current = result.value
        lastDiagnostic = result.diagnostic
        return result
    }

    public func setKeepAwakeMode(_ mode: KeepAwakeMode) async throws {
        var updated = current
        updated.keepAwakeMode = mode
        try await store.save(updated)
        current = updated
    }

    public func setIncludePrereleaseUpdates(_ value: Bool) async throws {
        var updated = current
        updated.includePrereleaseUpdates = value
        try await store.save(updated)
        current = updated
    }
}
