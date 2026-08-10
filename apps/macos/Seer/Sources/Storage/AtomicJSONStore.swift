import Foundation

/// A JSON document whose on-disk schema is explicitly versioned.
///
/// `AtomicJSONStore` uses `currentVersion`/`defaultValue` to decide whether a
/// document on disk is decodable, from a future schema, or corrupt, without
/// depending on any single concrete document type.
public protocol VersionedDocument: Codable, Equatable, Sendable {
    /// The schema version this build of Seer knows how to read and write.
    static var currentVersion: Int { get }

    /// The value used whenever no valid on-disk document is available.
    static var defaultValue: Self { get }

    /// The schema version this particular instance was decoded as (or will
    /// be encoded as, for values constructed in memory).
    var version: Int { get }
}

/// Typed failures surfaced by `AtomicJSONStore`. Every failure path returns
/// or throws one of these cases rather than silently substituting a success
/// result — callers can distinguish "no file yet" from "something is
/// wrong" and react (e.g. surface a diagnostic) accordingly.
public enum StorageError: Error, Equatable, Sendable {
    /// The on-disk document declared a schema version newer than this build
    /// understands. The associated value is the version found on disk.
    case unsupportedVersion(Int)
    /// `save` was called after `load` determined the store is read-only.
    case writesDisabled
    /// The in-memory document could not be encoded to JSON.
    case encodeFailed
    /// The on-disk bytes could not be decoded into the expected document.
    case decodeFailed
    /// The on-disk file could not be read (permissions, I/O error, etc).
    case readFailed
    /// The temporary file could not be written/synchronized or the atomic
    /// replace into the destination failed.
    case writeFailed
    /// A corrupt file could not be moved aside into quarantine.
    case quarantineFailed
}

/// The result of `AtomicJSONStore.load()`. Load never throws: a missing,
/// corrupt, unreadable, or unsupported-version file all resolve to a usable
/// in-memory value (defaults) plus enough information for the caller to
/// decide whether persistence is currently safe and whether to surface a
/// diagnostic to the user.
public struct LoadResult<Document: Sendable>: Sendable {
    public let value: Document
    public let diagnostic: Diagnostic?
    /// Whether `save` may be called safely. `false` means the on-disk file
    /// is being deliberately left untouched (unsupported version or read
    /// failure) and any subsequent `save` call will throw
    /// `StorageError.writesDisabled`.
    public let writesEnabled: Bool

    public init(value: Document, diagnostic: Diagnostic?, writesEnabled: Bool) {
        self.value = value
        self.diagnostic = diagnostic
        self.writesEnabled = writesEnabled
    }
}

/// Errors thrown by a `SettingsFileSystem` implementation to let
/// `AtomicJSONStore` distinguish specific, meaningful failure modes from
/// generic I/O errors.
public enum SettingsFileSystemError: Error, Equatable, Sendable {
    /// `readFile(at:)` found no file at the given URL.
    case fileNotFound
    /// `moveItem(at:to:)` found an existing file already occupying the
    /// destination path (used by quarantine's collision-avoidance loop).
    case destinationAlreadyExists
    /// Any other I/O failure. `message` is diagnostic-only, not compared.
    case other(String)

    public static func == (lhs: SettingsFileSystemError, rhs: SettingsFileSystemError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotFound, .fileNotFound), (.destinationAlreadyExists, .destinationAlreadyExists):
            return true
        case let (.other(a), .other(b)):
            return a == b
        default:
            return false
        }
    }
}

/// The file-system boundary `AtomicJSONStore` depends on, injected so tests
/// can exercise every branch (missing file, corrupt bytes, read/write/move
/// failures, quarantine collisions) without touching real disk state or
/// relying on platform-specific permission quirks (`chmod`, etc). Production
/// code uses `FileManagerSettingsFileSystem`.
///
/// All operations are `async` so a purely in-memory `actor`-based test
/// double can safely be shared across concurrent calls, matching how the
/// real store (also an `actor`) serializes access.
public protocol SettingsFileSystem: Sendable {
    /// Creates `url` (and any missing intermediate directories) if it does
    /// not already exist. Must not fail if the directory already exists.
    func ensureDirectoryExists(at url: URL) async throws

    /// Reads the full contents of the file at `url`.
    /// - Throws: `SettingsFileSystemError.fileNotFound` if no file exists at
    ///   `url`; some other error for any other read failure.
    func readFile(at url: URL) async throws -> Data

    /// Writes `data` to a new file at `url` and ensures the bytes are
    /// flushed/synchronized to durable storage before returning. `url` is
    /// always a freshly chosen, unique sibling path — implementations do
    /// not need to handle overwriting an existing file here.
    func writeFileAndSynchronize(_ data: Data, to url: URL) async throws

    /// Atomically replaces `destination` with the contents at `source`. If
    /// `destination` does not yet exist, moves `source` into place instead.
    /// Either way, `source` no longer exists afterwards on success, and
    /// `destination`'s prior contents are preserved on failure.
    func replaceItem(at destination: URL, withItemAt source: URL) async throws

    /// Moves `source` to `destination`.
    /// - Throws: `SettingsFileSystemError.destinationAlreadyExists` if
    ///   `destination` already exists (`source` is left untouched in that
    ///   case); some other error for any other failure (`source` is left
    ///   untouched in that case too).
    func moveItem(at source: URL, to destination: URL) async throws

    /// Removes the file at `url`, used only to clean up an orphaned
    /// temporary file after a failed save.
    func removeItem(at url: URL) async throws
}

/// Production `SettingsFileSystem` backed by `FileManager`/`FileHandle`.
public struct FileManagerSettingsFileSystem: SettingsFileSystem {
    // `FileManager` is not `Sendable` in the SDK's annotations, but Apple's
    // documentation guarantees a single `FileManager` instance is safe to
    // use concurrently from multiple threads for the stateless, delegate-free
    // operations used here (no shared mutable state is exposed to callers).
    // `nonisolated(unsafe)` is scoped to this one field rather than
    // `@unchecked Sendable` on the whole type.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func ensureDirectoryExists(at url: URL) async throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func fileExists(at url: URL) async -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func readFile(at url: URL) async throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SettingsFileSystemError.fileNotFound
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }

    public func writeFileAndSynchronize(_ data: Data, to url: URL) async throws {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw SettingsFileSystemError.other("createFile failed at \(url.path)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }

    public func replaceItem(at destination: URL, withItemAt source: URL) async throws {
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        if fileManager.fileExists(atPath: destination.path) {
            throw SettingsFileSystemError.destinationAlreadyExists
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }

    public func removeItem(at url: URL) async throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }
}

/// Diagnostic ids emitted by `AtomicJSONStore`. Kept as named constants so
/// production code and tests reference the exact same strings.
public enum StorageDiagnosticID {
    public static let unsupportedVersion = "storage.settings.unsupported-version"
    public static let readFailed = "storage.settings.read-failed"
    public static let corrupt = "storage.settings.corrupt"
    public static let quarantineFailed = "storage.settings.quarantine-failed"
}

/// Loads and saves a single versioned JSON document at a fixed file URL,
/// serializing all access as an `actor` so concurrent `load`/`save` calls
/// (e.g. rapid-fire settings mutations) apply in invocation order with no
/// interleaved partial writes.
///
/// Failure handling never silently discards data:
/// - A future/unsupported schema version leaves the file byte-for-byte
///   untouched and disables further writes for this instance.
/// - A read failure (permissions, I/O) leaves the file untouched and
///   disables further writes.
/// - A corrupt file (malformed JSON or invalid current-version data) is
///   moved aside into a timestamped `.corrupt-<millis>` sibling so it is
///   never silently discarded, and writes remain enabled since the store
///   safely owns a fresh default document going forward.
/// - If quarantining itself fails, the corrupt source is left in place and
///   writes are disabled.
public actor AtomicJSONStore<Document: VersionedDocument> {
    private let fileURL: URL
    private let fileSystem: SettingsFileSystem
    private let clock: Clock
    private var writesEnabled = true

    public init(fileURL: URL, fileSystem: SettingsFileSystem, clock: Clock) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        self.clock = clock
    }

    // MARK: - Load

    public func load() async -> LoadResult<Document> {
        let data: Data
        switch await readSourceFile() {
        case .missing:
            writesEnabled = true
            return LoadResult(value: Document.defaultValue, diagnostic: nil, writesEnabled: true)
        case .failed:
            writesEnabled = false
            let diagnostic = Diagnostic(
                id: StorageDiagnosticID.readFailed,
                message: "Could not read settings file at \(fileURL.path) (\(StorageError.readFailed)); using defaults without writing to disk.",
                occurredAt: clock.nowMilliseconds()
            )
            return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)
        case .success(let bytes):
            data = bytes
        }

        switch probeVersion(in: data) {
        case .future(let version):
            writesEnabled = false
            let diagnostic = Diagnostic(
                id: StorageDiagnosticID.unsupportedVersion,
                message: "Settings file version \(version) is newer than the version \(Document.currentVersion) this build supports; using defaults without writing to disk (\(StorageError.unsupportedVersion(version))).",
                occurredAt: clock.nowMilliseconds()
            )
            return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)

        case .invalid:
            return await quarantine(reason: .invalidVersion)

        case .supported:
            do {
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard document.version == Document.currentVersion else {
                    return await quarantine(reason: .decodedVersionMismatch)
                }
                writesEnabled = true
                return LoadResult(value: document, diagnostic: nil, writesEnabled: true)
            } catch {
                return await quarantine(reason: .decodeFailed)
            }
        }
    }

    private enum ReadOutcome {
        case missing
        case failed
        case success(Data)
    }

    private func readSourceFile() async -> ReadOutcome {
        do {
            return .success(try await fileSystem.readFile(at: fileURL))
        } catch SettingsFileSystemError.fileNotFound {
            return .missing
        } catch {
            return .failed
        }
    }

    private enum VersionProbe {
        case supported
        case future(Int)
        case invalid
    }

    /// Inspects the top-level `version` field of `data` as raw JSON,
    /// without decoding the full document, so a future schema (which may
    /// have fields this build doesn't understand) can be safely detected
    /// and preserved untouched rather than misread as corrupt.
    private func probeVersion(in data: Data) -> VersionProbe {
        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let dictionary = json as? [String: Any],
            let versionValue = dictionary["version"]
        else {
            return .invalid
        }

        // JSON `true`/`false` bridge to `NSNumber` on Darwin; explicitly
        // reject them so a boolean "version" isn't misread as 0/1.
        guard let number = versionValue as? NSNumber, isBooleanNSNumber(number) == false else {
            return .invalid
        }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue == doubleValue.rounded(), doubleValue >= 1 else {
            return .invalid
        }

        let intValue = Int(doubleValue)
        if intValue > Document.currentVersion {
            return .future(intValue)
        }
        if intValue == Document.currentVersion {
            return .supported
        }
        // A lower, currently-unrecognized version: no migration path is
        // defined yet, so treat it the same as any other invalid schema.
        return .invalid
    }

    private func isBooleanNSNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private enum QuarantineReason {
        case invalidVersion
        case decodedVersionMismatch
        case decodeFailed
    }

    /// Moves the corrupt file at `fileURL` aside to a timestamped
    /// `.corrupt-<millis>` sibling (adding a deterministic numeric suffix on
    /// name collision) so it is never silently discarded.
    private func quarantine(reason: QuarantineReason) async -> LoadResult<Document> {
        let millis = clock.nowMilliseconds()
        let directory = fileURL.deletingLastPathComponent()
        let baseName = "\(fileURL.lastPathComponent).corrupt-\(millis)"

        var suffix = 0
        while true {
            let candidateName = suffix == 0 ? baseName : "\(baseName)-\(suffix)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            do {
                try await fileSystem.moveItem(at: fileURL, to: candidateURL)
                writesEnabled = true
                let diagnostic = Diagnostic(
                    id: StorageDiagnosticID.corrupt,
                    message: "Settings file was corrupt (\(reason)) and has been quarantined to \(candidateName); using defaults.",
                    occurredAt: millis
                )
                return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: true)
            } catch SettingsFileSystemError.destinationAlreadyExists {
                suffix += 1
                continue
            } catch {
                writesEnabled = false
                let diagnostic = Diagnostic(
                    id: StorageDiagnosticID.quarantineFailed,
                    message: "Settings file was corrupt but could not be quarantined (\(StorageError.quarantineFailed)); using defaults without writing to disk.",
                    occurredAt: millis
                )
                return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)
            }
        }
    }

    // MARK: - Save

    /// Encodes `document` and atomically replaces the on-disk file with it:
    /// writes to a freshly named, unique sibling temp file, synchronizes it
    /// to durable storage, then atomically replaces (or moves into) the
    /// destination. The temp file is removed on any failure so no orphaned
    /// sibling is left behind.
    public func save(_ document: Document) async throws {
        guard writesEnabled else {
            throw StorageError.writesDisabled
        }
        guard document.version == Document.currentVersion else {
            throw StorageError.unsupportedVersion(document.version)
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw StorageError.encodeFailed
        }

        let directory = fileURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent("\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            try await fileSystem.ensureDirectoryExists(at: directory)
            try await fileSystem.writeFileAndSynchronize(data, to: tempURL)
            try await fileSystem.replaceItem(at: fileURL, withItemAt: tempURL)
        } catch {
            try? await fileSystem.removeItem(at: tempURL)
            throw StorageError.writeFailed
        }
    }
}
