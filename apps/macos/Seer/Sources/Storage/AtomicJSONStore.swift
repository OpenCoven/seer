import Foundation
import os

/// The maximum on-disk/encoded document size any `AtomicJSONStore` or
/// `SettingsFileSystem` will read or write, in bytes. Hoisted out of
/// `AtomicJSONStore<Document>` (a generic type, whose `static let`s cannot
/// be referenced without specializing a concrete `Document`) so the
/// non-generic `FileManagerSettingsFileSystem`'s bounded POSIX read can
/// enforce the exact same ceiling without allocating based on any
/// attacker-controlled size it reads from `stat`/`fstat`. 1 MiB is
/// enormously generous for a flat settings schema while keeping every
/// byte-scanning operation in this file bounded and safe.
public enum StorageLimits {
    public static let maxDocumentBytes: Int64 = 1_048_576
}

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
    /// `save` was called before `load` ever completed once for this
    /// instance. Distinct from `writesDisabled` (a completed load that
    /// determined the file is read-only): this is "no load has ever run",
    /// so there is no basis to know whether writing is safe, and no I/O
    /// is performed.
    case notLoaded
    /// The document to encode-and-save, once encoded, would exceed
    /// `AtomicJSONStore.maxDocumentBytes`. Thrown before any temp file is
    /// created.
    case payloadTooLarge
    /// The atomic rename/replace into the destination succeeded, but
    /// synchronizing the containing directory afterward failed. The new
    /// file's *contents* were durably written and the rename call
    /// returned success, but whether the directory entry pointing at it
    /// will survive a crash is unconfirmed — this is deliberately not
    /// reported as `writeFailed` (which would wrongly imply nothing
    /// happened) nor as ordinary success (which would wrongly imply full
    /// durability was confirmed).
    case durabilityUncertain
}

/// Thrown by `AtomicJSONStore.update(_:)`, which — unlike plain `save` —
/// can reach a state where the new document is already durably committed
/// to disk (the rename succeeded) yet the operation still cannot report
/// ordinary success (the following directory-sync failed). Wrapping
/// `StorageError.durabilityUncertain` alone would lose the committed
/// document; a caller (`SettingsStore`) needs that value to publish as its
/// new `current` cache *before* surfacing the uncertain-durability error,
/// so a later mutation starts from the value known to be on disk rather
/// than silently reverting to a stale in-memory cache.
public enum StorageUpdateError<Document: Sendable>: Error, Sendable {
    /// The transform's result was durably written and the rename/replace
    /// into place succeeded, but the following directory-sync could not be
    /// confirmed. `committed` is the exact document now on disk.
    case durabilityUncertain(committed: Document)
    /// Every other failure `update(_:)` can surface, wrapping the same
    /// `StorageError` cases `save` uses (`notLoaded`, `writesDisabled`,
    /// `unsupportedVersion`, `encodeFailed`, `payloadTooLarge`,
    /// `writeFailed`). No disk mutation occurred.
    case failure(StorageError)
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
    /// `readFile(at:)` (or the lock/document open it shares its
    /// canonical-parent-resolution logic with) found the final path
    /// component was a symlink. Rejected outright rather than followed,
    /// so a symlink swapped in at the document (or lock) path can never
    /// silently redirect a read, a lock, or a write to a different file
    /// than the one this store was constructed to guard.
    case symlinkRejected
    /// `readFile(at:)`'s bounded POSIX read found the file's contents
    /// exceed `StorageLimits.maxDocumentBytes` — either an initial
    /// `fstat` on the already-open descriptor reported an oversized
    /// count, or the content grew past the ceiling mid-stream (e.g. a
    /// non-cooperating writer appending to the same inode after this
    /// read's own preceding size probe already reported a small size).
    /// Thrown before any allocation proportional to the attacker-supplied
    /// size occurs.
    case tooLarge
    /// Any other I/O failure. `message` is diagnostic-only, not compared.
    case other(String)

    public static func == (lhs: SettingsFileSystemError, rhs: SettingsFileSystemError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotFound, .fileNotFound),
             (.destinationAlreadyExists, .destinationAlreadyExists),
             (.symlinkRejected, .symlinkRejected),
             (.tooLarge, .tooLarge):
            return true
        case let (.other(a), .other(b)):
            return a == b
        default:
            return false
        }
    }
}

/// An exclusive, advisory, per-canonical-document lock held by
/// `AtomicJSONStore` across an entire load (read/probe/quarantine) or save
/// (temp-write/sync/replace/directory-sync) operation, guarding against
/// concurrent access from another `AtomicJSONStore` instance in this
/// process or another process entirely.
///
/// `unlock()` must be safe to call more than once (idempotent) and from
/// any isolation context: `AtomicJSONStore` calls it exactly once on every
/// exit path of the operation that acquired it, but implementations may
/// additionally release as a safety net (e.g. in `deinit`) if a caller
/// ever fails to.
public protocol SettingsFileLock: Sendable {
    func unlock() async
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

    /// Acquires the exclusive lock guarding `url`'s canonical document,
    /// suspending until it is available. Held by the caller across an
    /// entire load or save operation; must be released via
    /// `SettingsFileLock.unlock()` on every exit path (including thrown
    /// errors). Implementations must exclude both other instances in this
    /// process and other processes entirely (e.g. via a sibling lock file
    /// and `flock`).
    func acquireLock(for url: URL) async throws -> any SettingsFileLock

    /// Returns the byte size of the file at `url` without reading its
    /// contents, so an oversized file can be rejected before any
    /// allocation.
    /// - Throws: `SettingsFileSystemError.fileNotFound` if no file exists
    ///   at `url`; some other error for any other stat failure.
    func fileSize(at url: URL) async throws -> Int64

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

    /// Synchronizes `url`'s containing directory to durable storage, so a
    /// preceding `replaceItem`/rename's directory-entry change is confirmed
    /// durable, not just the renamed file's own bytes.
    func synchronizeDirectory(for url: URL) async throws

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

/// Production `SettingsFileSystem` backed by `FileManager` for directory/
/// move/replace/remove operations and direct POSIX syscalls for the
/// operations this task hardens (locking, durable temp-file writes,
/// directory fsync, file-size probing) where `FileManager`/`FileHandle`
/// don't expose the required guarantees (`O_EXCL`/`O_NOFOLLOW` temp-file
/// creation, `F_FULLFSYNC`, `flock`, directory `fsync`).
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

    /// Opens `documentURL`'s canonical (symlink-free) parent directory and
    /// returns an open, directory-verified, `O_CLOEXEC` file descriptor for
    /// it. Every other syscall-backed operation below that needs to open
    /// something "underneath" this directory (the lock file, the document
    /// itself) does so via `openat(dirFD, basename, ..., O_NOFOLLOW, ...)`
    /// relative to this one resolved descriptor, rather than re-resolving
    /// (and re-racing) a full path string per call. This removes the
    /// classic lstat-then-open TOCTOU gap: nothing between resolving the
    /// parent and opening a child by name can substitute a symlink into
    /// the child's own final path component, because `openat` never
    /// re-walks the parent portion of the path at all, and `O_NOFOLLOW` on
    /// the child open refuses to follow a symlink there either.
    ///
    /// Rejects a symlinked parent directory outright (`lstat` before
    /// `realpath`), and re-verifies with `fstat` after opening that the
    /// resolved path is still actually a directory (defends against a
    /// last-instant swap between `realpath` and `open`).
    static func openCanonicalParentDirectory(of documentURL: URL) throws -> Int32 {
        let parentPath = documentURL.deletingLastPathComponent().path

        var parentStat = stat()
        guard lstat(parentPath, &parentStat) == 0 else {
            throw SettingsFileSystemError.other("lstat failed for parent directory \(parentPath): \(posixErrorDescription())")
        }
        guard (parentStat.st_mode & S_IFMT) != S_IFLNK else {
            throw SettingsFileSystemError.other("parent directory is a symlink: \(parentPath)")
        }
        guard let resolvedParent = realpath(parentPath, nil) else {
            throw SettingsFileSystemError.other("realpath failed for parent directory \(parentPath): \(posixErrorDescription())")
        }
        let canonicalParentPath = String(cString: resolvedParent)
        free(resolvedParent)

        let fd = canonicalParentPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            throw SettingsFileSystemError.other("open failed for canonical parent directory \(canonicalParentPath): \(posixErrorDescription())")
        }
        var openedStat = stat()
        guard fstat(fd, &openedStat) == 0, (openedStat.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw SettingsFileSystemError.other("opened parent path is not a directory: \(canonicalParentPath)")
        }
        return fd
    }

    /// Acquires the sibling `.lock` file's advisory lock relative to
    /// `url`'s canonical parent directory. Creates the lock file (if
    /// missing) and opens it via `openat(dirFD, lockBasename, O_CREAT |
    /// O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600)` — a single atomic syscall,
    /// not the removed lstat-then-open pattern, so a symlink substituted
    /// at the lock path between any check and the open can never be
    /// followed. After opening, `fstat`s the resulting descriptor and
    /// refuses to lock a path that isn't a regular, single-hard-link file
    /// owned by the current effective user with no group/world write bit
    /// — every one of those would indicate the lock file isn't the
    /// private, cooperative artifact this store expects, before ever
    /// calling `flock`.
    public func acquireLock(for url: URL) async throws -> any SettingsFileLock {
        let dirFD = try Self.openCanonicalParentDirectory(of: url)
        let lockBasename = url.lastPathComponent + ".lock"

        let fd = lockBasename.withCString { openat(dirFD, $0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else {
            let description = Self.posixErrorDescription()
            close(dirFD)
            if errno == ELOOP {
                throw SettingsFileSystemError.symlinkRejected
            }
            throw SettingsFileSystemError.other("openat failed for lock file \(lockBasename): \(description)")
        }
        // The lock file descriptor is now independent of `dirFD`; the
        // directory descriptor itself is not held across the lock's
        // lifetime (unlike the document/lock inode, the directory isn't
        // what `flock` guards).
        close(dirFD)

        var lockStat = stat()
        guard fstat(fd, &lockStat) == 0 else {
            let description = Self.posixErrorDescription()
            close(fd)
            throw SettingsFileSystemError.other("fstat failed for lock file \(lockBasename): \(description)")
        }
        guard (lockStat.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw SettingsFileSystemError.other("lock file is not a regular file: \(lockBasename)")
        }
        guard lockStat.st_nlink <= 1 else {
            close(fd)
            throw SettingsFileSystemError.other("lock file has unexpected extra hard links: \(lockBasename)")
        }
        guard lockStat.st_uid == geteuid() else {
            close(fd)
            throw SettingsFileSystemError.other("lock file has an unexpected owner: \(lockBasename)")
        }
        guard (lockStat.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            close(fd)
            throw SettingsFileSystemError.other("lock file has an unexpectedly permissive mode: \(lockBasename)")
        }

        // Blocking exclusive advisory lock, held across an entire load or
        // save operation. This call is synchronous (like every other
        // syscall-backed method here) and may suspend the calling thread
        // for as long as another process/instance holds the lock —
        // consistent with the rest of this type's existing synchronous
        // `FileManager`/`FileHandle` I/O, which offers no weaker guarantee.
        while true {
            if flock(fd, LOCK_EX) == 0 {
                break
            }
            if errno != EINTR {
                let description = Self.posixErrorDescription()
                close(fd)
                throw SettingsFileSystemError.other("flock failed for lock file \(lockBasename): \(description)")
            }
        }
        return DarwinFileLock(fileDescriptor: fd)
    }

    public func fileSize(at url: URL) async throws -> Int64 {
        var statBuffer = stat()
        guard stat(url.path, &statBuffer) == 0 else {
            if errno == ENOENT {
                throw SettingsFileSystemError.fileNotFound
            }
            throw SettingsFileSystemError.other("stat failed for \(url.path): \(Self.posixErrorDescription())")
        }
        return Int64(statBuffer.st_size)
    }

    /// Reads `url`'s contents via a bounded, symlink-refusing POSIX
    /// descriptor read — used both for the original document load and for
    /// quarantine's just-in-time identity re-read, so both paths share
    /// identical protection against a huge or growing file.
    ///
    /// Opens the canonical parent directory, then `openat`s the document's
    /// basename with `O_RDONLY | O_NOFOLLOW | O_CLOEXEC` (refusing to
    /// follow a symlink substituted at the document's own path). `fstat`s
    /// the opened descriptor first: if the reported size already exceeds
    /// `StorageLimits.maxDocumentBytes`, returns `tooLarge` immediately
    /// without allocating a buffer anywhere near that size. Otherwise
    /// reads in fixed-size chunks (handling partial reads and `EINTR`)
    /// into a buffer capped at `maxDocumentBytes + 1` bytes total: if the
    /// accumulated content ever exceeds the ceiling — including because a
    /// non-cooperating writer *grew* the file after this method's own
    /// `fstat` already saw a small size — the read aborts as `tooLarge`
    /// having never allocated more than one chunk past the ceiling. This
    /// makes the read resistant to "replacement-after-stat": no caller of
    /// `readFile` can be misled into allocating proportional to an
    /// attacker-controlled size, whether that size was reported by a
    /// preceding `fileSize` probe or by this very `fstat` call.
    public func readFile(at url: URL) async throws -> Data {
        let dirFD = try Self.openCanonicalParentDirectory(of: url)
        defer { close(dirFD) }

        let basename = url.lastPathComponent
        let fd = basename.withCString { openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT {
                throw SettingsFileSystemError.fileNotFound
            }
            if code == ELOOP {
                throw SettingsFileSystemError.symlinkRejected
            }
            throw SettingsFileSystemError.other("openat failed for \(url.path): \(Self.posixErrorDescription(code))")
        }
        defer { close(fd) }

        var statBuffer = stat()
        guard fstat(fd, &statBuffer) == 0 else {
            throw SettingsFileSystemError.other("fstat failed for \(url.path): \(Self.posixErrorDescription())")
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            throw SettingsFileSystemError.other("document path is not a regular file: \(url.path)")
        }
        guard statBuffer.st_size <= StorageLimits.maxDocumentBytes else {
            throw SettingsFileSystemError.tooLarge
        }

        let maxBytes = Int(StorageLimits.maxDocumentBytes)
        let chunkSize = 65_536
        var buffer = [UInt8]()
        buffer.reserveCapacity(min(maxBytes, chunkSize) + 1)
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { rawBuffer -> Int in
                read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw SettingsFileSystemError.other("read failed for \(url.path): \(Self.posixErrorDescription())")
            }
            if bytesRead == 0 {
                break
            }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            if buffer.count > maxBytes {
                throw SettingsFileSystemError.tooLarge
            }
        }
        return Data(buffer)
    }

    /// Writes `data` to a brand-new file at `url` using `open` with
    /// `O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW` (refusing to create
    /// through a symlink or clobber an existing file — `url` is always a
    /// freshly chosen unique sibling path, so an existing file there would
    /// itself indicate something unexpected), writes every byte handling
    /// partial writes and `EINTR`, then synchronizes to durable storage
    /// with `F_FULLFSYNC` (macOS's stronger-than-`fsync` durability
    /// barrier), falling back to plain `fsync` only if the volume doesn't
    /// support `F_FULLFSYNC`.
    public func writeFileAndSynchronize(_ data: Data, to url: URL) async throws {
        let fd = url.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else {
            throw SettingsFileSystemError.other("open failed for temp file \(url.path): \(Self.posixErrorDescription())")
        }
        do {
            try Self.writeAllBytes(data, toFileDescriptor: fd)
            try Self.fullySynchronize(fd)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else {
            throw SettingsFileSystemError.other("close failed for temp file \(url.path): \(Self.posixErrorDescription())")
        }
    }

    private static func writeAllBytes(_ data: Data, toFileDescriptor fd: Int32) throws {
        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let base = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(fd, base + offset, rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SettingsFileSystemError.other("write failed: \(posixErrorDescription())")
                }
                if written == 0 {
                    throw SettingsFileSystemError.other("write returned zero bytes before completion")
                }
                offset += written
            }
        }
    }

    private static func fullySynchronize(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == -1 {
            // Some volumes (notably non-APFS/HFS+ or certain network
            // filesystems) don't support `F_FULLFSYNC` and report
            // `ENOTSUP`; fall back to the weaker but universally supported
            // `fsync` rather than failing outright.
            if errno == ENOTSUP {
                guard fsync(fd) == 0 else {
                    throw SettingsFileSystemError.other("fsync fallback failed: \(posixErrorDescription())")
                }
            } else {
                throw SettingsFileSystemError.other("F_FULLFSYNC failed: \(posixErrorDescription())")
            }
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

    /// Opens and `fsync`s `url`'s containing directory via the same
    /// canonical-parent resolution `readFile`/`acquireLock` use, so a
    /// preceding rename/replace's directory-entry change is confirmed
    /// durable, not just the renamed file's own bytes (which the temp
    /// file's own `F_FULLFSYNC` already covered before the rename), and so
    /// the directory actually fsync'd is provably the same one the
    /// document/lock opens resolved to, not a substituted symlink.
    public func synchronizeDirectory(for url: URL) async throws {
        let fd = try Self.openCanonicalParentDirectory(of: url)
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw SettingsFileSystemError.other("directory fsync failed for \(url.deletingLastPathComponent().path): \(Self.posixErrorDescription())")
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

    fileprivate static func posixErrorDescription(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }
}

/// Wraps the POSIX advisory lock (`flock`) file descriptor held for the
/// lifetime of one load or save operation against the settings lock-file
/// sibling. Deliberately never deletes/unlinks the lock file itself:
/// removing it while another process still holds (or is about to
/// acquire) a lock on the same inode would let a third process create a
/// *new* inode at the same path and take an independent, non-conflicting
/// lock — silently splitting the one advisory lock into two that no
/// longer exclude each other.
///
/// `final class` (not `struct`) so `unlock()` can be called from multiple
/// exit paths and still only release once, and so `deinit` can act as a
/// safety net. Marked `@unchecked Sendable` because the only mutable state
/// (`isReleased`) is guarded by `stateLock`, an `NSLock`, making concurrent
/// `unlock()` calls from different isolation contexts race-free even
/// though the compiler cannot verify that itself; `fileDescriptor` is an
/// immutable `Int32` value, trivially safe to share.
final class DarwinFileLock: SettingsFileLock, @unchecked Sendable {
    private let fileDescriptor: Int32
    // `OSAllocatedUnfairLock` (not `NSLock`) because `NSLock.lock()`/
    // `unlock()` are unavailable from `async` contexts under Swift 6's
    // strict concurrency checking — this type's own `unlock()` is `async`.
    // `OSAllocatedUnfairLock` is explicitly designed to be safe to use
    // (briefly, non-blocking-ly) from async code.
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func unlock() async {
        let alreadyReleased = state.withLock { isReleased in
            let was = isReleased
            isReleased = true
            return was
        }
        guard !alreadyReleased else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    deinit {
        let alreadyReleased = state.withLock { isReleased in
            let was = isReleased
            isReleased = true
            return was
        }
        guard !alreadyReleased else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

/// Diagnostic ids emitted by `AtomicJSONStore`. Kept as named constants so
/// production code and tests reference the exact same strings.
public enum StorageDiagnosticID {
    public static let unsupportedVersion = "storage.settings.unsupported-version"
    public static let readFailed = "storage.settings.read-failed"
    public static let corrupt = "storage.settings.corrupt"
    public static let quarantineFailed = "storage.settings.quarantine-failed"
    /// The on-disk file exceeds `AtomicJSONStore.maxDocumentBytes`. Left
    /// untouched, read-only: never read, quarantined, or written.
    public static let tooLarge = "storage.settings.too-large"
    /// A quarantine's just-in-time re-read found the file's bytes (or its
    /// existence) had changed since it was originally probed — most likely
    /// a non-cooperating writer that bypassed the advisory lock. The
    /// quarantine move is aborted and the file is left untouched,
    /// read-only, rather than risk moving/overwriting newer content.
    public static let concurrentChange = "storage.settings.concurrent-change"
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
/// A minimal, linear, non-backtracking JSON lexer plus decimal-string
/// classifier used to answer "what is the top-level `version` field, and
/// is it something this build supports, something newer, or invalid?"
/// without ever materializing the version value as `Double` or `Int`
/// (both of which can trap or misreport on the arbitrarily large numbers a
/// hand-edited or foreign-tool-written settings file might contain, e.g.
/// `1e309` or a 500-digit integer literal). Kept free of any generic
/// parameter (unlike `AtomicJSONStore<Document>` itself) so its
/// `static let`/`static func` members are ordinary ones, not subject to
/// Swift's "static stored properties not supported in generic types"
/// restriction.
fileprivate enum VersionProbing {
    /// The result of probing the top-level `version` field.
    enum Result {
        case supported
        /// A version this build cannot decode, described as text for
        /// diagnostics. Kept as `String` (not `Int`) because a well-formed
        /// integral JSON number (e.g. `1e100`, or a 500-digit literal) can
        /// vastly exceed `Int`'s range; a future version is always
        /// reported this way regardless of whether it happens to fit in
        /// an `Int`.
        case future(String)
        case invalid
    }

    /// Validates that `bytes` contains exactly one complete, well-formed
    /// top-level JSON value — consuming any trailing whitespace and
    /// rejecting anything else left over — using the same bounded,
    /// non-materializing scanner (`skipJSONValue`) that locates the
    /// top-level `version` token.
    ///
    /// Deliberately does not hand `bytes` to `JSONSerialization`:
    /// `JSONSerialization` itself throws when *any* JSON number in the
    /// document (not just the version field) overflows `Double` (e.g.
    /// `1e309`, or a several-hundred-digit integer), which would otherwise
    /// misreport a perfectly well-formed "future version" document — one
    /// that may legitimately contain other arbitrarily large numbers this
    /// build has no reason to decode — as corrupt. `skipJSONValue` and
    /// `scanNumberToken` accept a strict JSON number of any digit/exponent
    /// size anywhere in the document without ever materializing it as
    /// `Double`/`Int`.
    static func isStructurallyValidDocument(bytes: [UInt8]) -> Bool {
        let start = skipWhitespace(bytes, from: 0)
        // Start at depth `-1`, not `0`: `scanTopLevelVersionToken` never
        // calls `skipJSONValue` on the top-level object itself (it walks
        // the object's members with its own inline loop), only on each
        // member's *value*, and always with a fresh `depth: 0` budget for
        // that value regardless of how many sibling fields precede it.
        // Feeding the whole document — starting at its outermost `{` —
        // through `skipJSONValue` at `depth: 0` would count that outer
        // brace as one level of nesting, shrinking every top-level field's
        // own nesting budget by one and silently lowering the effective
        // depth limit for documents this whole-document check validates
        // versus documents `scanTopLevelVersionToken` merely skips through.
        // `-1` keeps the two paths' depth accounting identical: the
        // top-level object costs nothing, and each field's value still
        // gets the full `maxNestingDepth` budget.
        guard let end = skipJSONValue(bytes, from: start, depth: -1) else { return false }
        return skipWhitespace(bytes, from: end) == bytes.count
    }

    // MARK: - Lexical top-level `version` scan
    //
    // A minimal, linear, non-backtracking JSON lexer: it does exactly one
    // pass over the already-in-memory bytes (bounded by the file size
    // already read), tracking string/escape state and object/array
    // nesting just precisely enough to find the *top-level* `version`
    // member's number token by byte offset — without ever decoding the
    // number itself or the rest of the document.

    enum VersionKeyScan {
        /// The top-level `version` key was found and its value is a JSON
        /// number token spanning `range` (byte offsets into the scanned
        /// bytes).
        case numberToken(range: Range<Int>)
        /// The top-level `version` key was found, but its value is not a
        /// JSON number (string/object/array/`true`/`false`/`null`) — never
        /// a valid version.
        case nonNumericValue
        /// The root isn't a JSON object, the object has no top-level
        /// `version` key, or the bytes are malformed in a way that
        /// prevents determining an answer (e.g. an unterminated string or
        /// mismatched brackets encountered before reaching an answer).
        case notFound
    }

    static func scanTopLevelVersionToken(in bytes: [UInt8]) -> VersionKeyScan {
        var i = skipWhitespace(bytes, from: 0)
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else {
            return .notFound
        }
        i += 1

        while true {
            i = skipWhitespace(bytes, from: i)
            guard i < bytes.count else { return .notFound }
            if bytes[i] == UInt8(ascii: "}") {
                return .notFound
            }
            guard bytes[i] == UInt8(ascii: "\""), let (keyBytes, afterKey) = scanStringLiteral(bytes, from: i) else {
                return .notFound
            }
            i = skipWhitespace(bytes, from: afterKey)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return .notFound }
            i = skipWhitespace(bytes, from: i + 1)
            guard i < bytes.count else { return .notFound }

            let isVersionKey = keyBytes.elementsEqual(Array("version".utf8))
            let b = bytes[i]
            let looksNumeric = b == UInt8(ascii: "-") || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))

            if isVersionKey, looksNumeric {
                guard let end = scanNumberToken(bytes, from: i) else { return .notFound }
                return .numberToken(range: i..<end)
            }
            guard let afterValue = skipJSONValue(bytes, from: i) else { return .notFound }
            i = afterValue
            if isVersionKey {
                return .nonNumericValue
            }

            i = skipWhitespace(bytes, from: i)
            guard i < bytes.count else { return .notFound }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                return .notFound
            }
            return .notFound
        }
    }

    static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            default:
                return i
            }
        }
        return i
    }

    /// The maximum object/array nesting depth `skipJSONValue` will descend
    /// into before giving up and reporting the value as malformed.
    /// `SettingsDocument` is a flat schema, so any real settings file needs
    /// only a handful of nesting levels; 128 leaves generous headroom for
    /// nested/unknown-to-us fields in a future schema while keeping the
    /// recursion depth — and therefore the native call stack used by this
    /// scan — a small, fixed bound regardless of how deeply nested a
    /// pathological or adversarial file is. Without this cap, a file
    /// containing tens of thousands of nested arrays/objects would recurse
    /// once per nesting level and overflow the stack before ever reaching
    /// a return value.
    static let maxNestingDepth = 128

    /// Recursively skips exactly one JSON value (string, number, object,
    /// array, or `true`/`false`/`null`) starting at `start`, returning the
    /// index just past it, or `nil` if the bytes are not a well-formed
    /// value there, or if it is nested deeper than `maxNestingDepth`
    /// (treated the same as malformed: this scanner exists to answer a
    /// yes/no/future question about a flat schema, so pathologically deep
    /// nesting is rejected as corrupt rather than crashing).
    static func skipJSONValue(_ bytes: [UInt8], from start: Int, depth: Int = 0) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            guard let (_, end) = scanStringLiteral(bytes, from: start) else { return nil }
            return end

        case UInt8(ascii: "{"):
            guard depth < maxNestingDepth else { return nil }
            var i = skipWhitespace(bytes, from: start + 1)
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: "}") { return i + 1 }
            while true {
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\""),
                      let (_, afterKey) = scanStringLiteral(bytes, from: i)
                else {
                    return nil
                }
                i = skipWhitespace(bytes, from: afterKey)
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i = skipWhitespace(bytes, from: i + 1)
                guard let afterValue = skipJSONValue(bytes, from: i, depth: depth + 1) else { return nil }
                i = skipWhitespace(bytes, from: afterValue)
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") {
                    i = skipWhitespace(bytes, from: i + 1)
                    continue
                }
                if bytes[i] == UInt8(ascii: "}") { return i + 1 }
                return nil
            }

        case UInt8(ascii: "["):
            guard depth < maxNestingDepth else { return nil }
            var i = skipWhitespace(bytes, from: start + 1)
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: "]") { return i + 1 }
            while true {
                guard let afterValue = skipJSONValue(bytes, from: i, depth: depth + 1) else { return nil }
                i = skipWhitespace(bytes, from: afterValue)
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") {
                    i = skipWhitespace(bytes, from: i + 1)
                    continue
                }
                if bytes[i] == UInt8(ascii: "]") { return i + 1 }
                return nil
            }

        case UInt8(ascii: "t"):
            return matchLiteral(bytes, from: start, literal: "true")
        case UInt8(ascii: "f"):
            return matchLiteral(bytes, from: start, literal: "false")
        case UInt8(ascii: "n"):
            return matchLiteral(bytes, from: start, literal: "null")

        default:
            return scanNumberToken(bytes, from: start)
        }
    }

    static func matchLiteral(_ bytes: [UInt8], from start: Int, literal: String) -> Int? {
        let literalBytes = Array(literal.utf8)
        let end = start + literalBytes.count
        guard end <= bytes.count, Array(bytes[start..<end]) == literalBytes else { return nil }
        return end
    }

    /// Scans a JSON string literal starting at the opening `"` at `start`,
    /// decoding standard JSON escapes (including `\uXXXX` and surrogate
    /// pairs), so escaped keys/values are compared and skipped correctly.
    /// Returns the decoded UTF-8 bytes and the index just past the closing
    /// `"`, or `nil` if the string is unterminated or contains an invalid
    /// escape.
    static func scanStringLiteral(_ bytes: [UInt8], from start: Int) -> ([UInt8], Int)? {
        var i = start + 1
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                return (out, i + 1)
            }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { return nil }
                switch bytes[i] {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); i += 1
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); i += 1
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); i += 1
                case UInt8(ascii: "b"): out.append(0x08); i += 1
                case UInt8(ascii: "f"): out.append(0x0C); i += 1
                case UInt8(ascii: "n"): out.append(0x0A); i += 1
                case UInt8(ascii: "r"): out.append(0x0D); i += 1
                case UInt8(ascii: "t"): out.append(0x09); i += 1
                case UInt8(ascii: "u"):
                    guard let (unit, afterUnit) = readHex4(bytes, from: i + 1) else { return nil }
                    i = afterUnit
                    var scalarValue = UInt32(unit)
                    if unit >= 0xD800, unit <= 0xDBFF {
                        guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u"),
                              let (low, afterLow) = readHex4(bytes, from: i + 2), low >= 0xDC00, low <= 0xDFFF
                        else {
                            return nil
                        }
                        scalarValue = 0x10000 + (UInt32(unit) - 0xD800) * 0x400 + (UInt32(low) - 0xDC00)
                        i = afterLow
                    } else if unit >= 0xDC00, unit <= 0xDFFF {
                        return nil
                    }
                    guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
                    out.append(contentsOf: Array(String(scalar).utf8))
                default:
                    return nil
                }
            } else if b < 0x20 {
                return nil
            } else {
                out.append(b)
                i += 1
            }
        }
    }

    static func readHex4(_ bytes: [UInt8], from start: Int) -> (UInt16, Int)? {
        guard start + 4 <= bytes.count else { return nil }
        var value: UInt16 = 0
        for offset in 0..<4 {
            guard let digit = hexDigitValue(bytes[start + offset]) else { return nil }
            value = value << 4 | UInt16(digit)
        }
        return (value, start + 4)
    }

    static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Matches the strict JSON number grammar (RFC 8259 §6):
    /// `-? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?`, returning the
    /// index just past the token, or `nil` if the bytes at `start` don't
    /// form a valid JSON number.
    static func scanNumberToken(_ bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        guard i < bytes.count else { return nil }
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { return nil }

        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else if bytes[i] >= UInt8(ascii: "1"), bytes[i] <= UInt8(ascii: "9") {
            i += 1
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
        } else {
            return nil
        }

        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            var j = i + 1
            guard j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") else { return nil }
            while j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") { j += 1 }
            i = j
        }

        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            var j = i + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") { j += 1 }
            guard j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") else { return nil }
            while j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") { j += 1 }
            i = j
        }

        return i
    }

    // MARK: - Decimal classification of the version number token
    //
    // Classifies an already-grammar-validated JSON number token's exact
    // decimal magnitude using only string/character arithmetic — never
    // `Double` (which can't represent `1e309` or a 500-digit integer) and
    // never `Int` (which traps or overflows on the same inputs).

    /// The number of exponent digits above which the exponent's magnitude
    /// is guaranteed to dwarf any realistic fractional-digit count derived
    /// from bytes actually read from disk, letting classification avoid
    /// parsing the exponent into an `Int` at all for such tokens. 18 digits
    /// safely fits in `Int64` (max ~9.22e18) with headroom to spare.
    static let maxParsableExponentDigitCount = 18

    static func classifyVersionNumberToken(_ token: String, currentVersion: Int) -> Result {
        let remainder = Substring(token)
        guard remainder.first != "-" else {
            // A negative version has no meaning and no migration path.
            return .invalid
        }

        var mantissaPart = remainder
        var exponentDigits: Substring = ""
        var exponentIsNegative = false
        if let eIndex = remainder.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissaPart = remainder[remainder.startIndex..<eIndex]
            var expToken = remainder[remainder.index(after: eIndex)...]
            if expToken.first == "+" {
                expToken = expToken.dropFirst()
            } else if expToken.first == "-" {
                exponentIsNegative = true
                expToken = expToken.dropFirst()
            }
            exponentDigits = expToken
        }

        var integerPart = mantissaPart
        var fractionPart: Substring = ""
        if let dotIndex = mantissaPart.firstIndex(of: ".") {
            integerPart = mantissaPart[mantissaPart.startIndex..<dotIndex]
            fractionPart = mantissaPart[mantissaPart.index(after: dotIndex)...]
        }

        let mantissaDigits = Array(integerPart) + Array(fractionPart)
        let mantissaIsZero = mantissaDigits.allSatisfy { $0 == "0" }
        let fractionDigitCount = fractionPart.count
        let currentVersionDigits = Array(String(currentVersion))

        // Trim the exponent's own leading zeros before doing anything with
        // its digit count or magnitude. Grammar allows arbitrarily many
        // leading zeros in an exponent (e.g. `1e000000000000000000`), and
        // without this normalization a zero-padded-but-otherwise-tiny
        // exponent digit count alone (not magnitude) would exceed
        // `maxParsableExponentDigitCount` and be misclassified as an
        // astronomically large/huge exponent by the branch below, when the
        // exponent is actually zero (or, with thousands of leading zeros
        // followed by a single `1`, exactly ±1). `trimLeadingZeros` returns
        // `[]` for an all-zero run, correctly representing exponent zero.
        let normalizedExponentDigits = trimLeadingZeros(Array(exponentDigits))

        let integerDigits: [Character]
        if normalizedExponentDigits.count > maxParsableExponentDigitCount {
            if exponentIsNegative {
                // The exponent's magnitude vastly exceeds any realistic
                // fractional-digit count read from disk, so the value
                // collapses toward (or exactly to) zero: never a valid
                // positive integral version.
                return .invalid
            }
            if mantissaIsZero {
                // 0 * 10^(huge) is exactly zero, not a valid version.
                return .invalid
            }
            // The exponent's magnitude vastly exceeds the fractional
            // digit count, so the value is unambiguously integral and
            // astronomically larger than anything this build supports.
            return .future(token)
        }

        // `normalizedExponentDigits.count <= maxParsableExponentDigitCount`
        // guarantees this parses without overflow (18 digits maxes out
        // well under `Int64.max`'s 19 digits), but the resulting `Int` can
        // still be as large as ~10^18 — nowhere near enough to safely
        // drive an allocation below.
        let exponentValue = normalizedExponentDigits.isEmpty ? 0 : (Int(String(normalizedExponentDigits)) ?? 0)
        let signedExponent = exponentIsNegative ? -exponentValue : exponentValue
        let shift = signedExponent - fractionDigitCount

        if shift >= 0 {
            if mantissaIsZero {
                // 0 * 10^shift is exactly zero; versions start at 1.
                return .invalid
            }
            // Never materialize `shift` trailing zeros here: `shift` can
            // still be ~10^18 even though it fits in `Int`, so appending
            // that many characters would itself be an allocation
            // proportional to the exponent's magnitude — exactly the bug
            // this guards against. Instead, decide symbolically: trimming
            // `mantissaDigits`'s leading zeros is bounded only by the
            // digit bytes actually read from disk (not by `shift`), and
            // every digit `shift` appends is a trailing zero, so the
            // final integer's digit count is exactly
            // `significantDigits.count + shift` — no materialization
            // needed to compare that count against `currentVersion`'s.
            let significantDigits = trimLeadingZeros(mantissaDigits)
            let finalDigitCount = significantDigits.count + shift
            if finalDigitCount > currentVersionDigits.count {
                return .future(token)
            }
            if finalDigitCount < currentVersionDigits.count {
                return .invalid
            }
            // Digit counts tie exactly, so `shift` must be small (bounded
            // by `currentVersionDigits.count`, a tiny fixed constant) —
            // materializing to compare digit-for-digit is safe here.
            integerDigits = significantDigits + Array(repeating: Character("0"), count: shift)
        } else {
            let shiftMagnitude = -shift
            guard shiftMagnitude < mantissaDigits.count else {
                // The decimal point falls at or before the start of the
                // mantissa: even when the whole value collapses exactly to
                // zero, that's still not a valid version (versions start
                // at 1); otherwise it's a non-zero fraction, also invalid.
                return .invalid
            }
            let splitIndex = mantissaDigits.count - shiftMagnitude
            let tail = mantissaDigits[splitIndex...]
            guard tail.allSatisfy({ $0 == "0" }) else {
                // Non-zero digits after the decimal point: not integral.
                return .invalid
            }
            integerDigits = Array(mantissaDigits[..<splitIndex])
        }

        let normalized = trimLeadingZeros(integerDigits)
        guard !normalized.isEmpty else {
            // Value is exactly zero; versions start at 1.
            return .invalid
        }

        if normalized.count != currentVersionDigits.count {
            return normalized.count > currentVersionDigits.count ? .future(token) : .invalid
        }
        if normalized.elementsEqual(currentVersionDigits) {
            return .supported
        }
        return normalized.lexicographicallyPrecedes(currentVersionDigits) ? .invalid : .future(token)
    }

    static func trimLeadingZeros(_ digits: [Character]) -> [Character] {
        var start = digits.startIndex
        while start < digits.index(before: digits.endIndex), digits[start] == "0" {
            start += 1
        }
        let trimmed = digits[start...]
        return trimmed == ["0"] ? [] : Array(trimmed)
    }
}

public actor AtomicJSONStore<Document: VersionedDocument> {
    /// The maximum on-disk/encoded document size this store will read or
    /// write, in bytes. Checked via `fileSystem.fileSize(at:)` before any
    /// read allocation, and against the encoded save payload before any
    /// temp file is created. 1 MiB is enormously generous for a flat
    /// settings schema while keeping every byte-scanning operation in this
    /// file (`VersionProbing`'s lexer included) bounded and safe.
    public static var maxDocumentBytes: Int64 { StorageLimits.maxDocumentBytes }

    private let fileURL: URL
    private let fileSystem: SettingsFileSystem
    private let clock: Clock
    private var writesEnabled = true

    /// Whether `load()` has completed at least once for this instance.
    /// `save` before this is `true` throws `StorageError.notLoaded` and
    /// performs no I/O — distinct from `writesEnabled == false`, which
    /// means a completed load determined the file is read-only.
    private var isLoaded = false

    /// Serializes every public `load()`/`save(_:)` call through its full
    /// awaited I/O and `writesEnabled` publication, in FIFO invocation
    /// order. Without this, actor reentrancy across the `await`s inside
    /// `load`/`save` would let a later call observe or mutate state (disk
    /// bytes, `writesEnabled`) mid-operation of an earlier call. This is
    /// purely an intra-process ordering guarantee; cross-instance and
    /// cross-process exclusivity is provided separately by
    /// `fileSystem.acquireLock(for:)`.
    private let gate = AsyncGate()

    public init(fileURL: URL, fileSystem: SettingsFileSystem, clock: Clock) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        self.clock = clock
    }

    // MARK: - Load

    public func load() async -> LoadResult<Document> {
        await gate.acquire()
        let result = await performLoad()
        await gate.release()
        return result
    }

    private func performLoad() async -> LoadResult<Document> {
        isLoaded = true

        let lock: any SettingsFileLock
        do {
            lock = try await fileSystem.acquireLock(for: fileURL)
        } catch {
            writesEnabled = false
            let diagnostic = Diagnostic(
                id: StorageDiagnosticID.readFailed,
                message: "Could not acquire the settings file lock at \(fileURL.path): \(error); using defaults without writing to disk.",
                occurredAt: clock.nowMilliseconds()
            )
            return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)
        }

        let result = await performLoadLocked()
        await lock.unlock()
        return result
    }

    private func performLoadLocked() async -> LoadResult<Document> {
        switch await checkSourceFileSize() {
        case .missing:
            writesEnabled = true
            return LoadResult(value: Document.defaultValue, diagnostic: nil, writesEnabled: true)
        case .tooLarge:
            return tooLargeLoadResult()
        case .ok, .indeterminate:
            break
        }

        let data: Data
        switch await readSourceFile() {
        case .missing:
            writesEnabled = true
            return LoadResult(value: Document.defaultValue, diagnostic: nil, writesEnabled: true)
        case .tooLarge:
            return tooLargeLoadResult()
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
        case .future(let description):
            writesEnabled = false
            let diagnostic = Diagnostic(
                id: StorageDiagnosticID.unsupportedVersion,
                message: "Settings file version \(description) is newer than the version \(Document.currentVersion) this build supports; using defaults without writing to disk.",
                occurredAt: clock.nowMilliseconds()
            )
            return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)

        case .invalid:
            return await quarantine(reason: .invalidVersion, originalBytes: data)

        case .supported:
            do {
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard document.version == Document.currentVersion else {
                    return await quarantine(reason: .decodedVersionMismatch, originalBytes: data)
                }
                writesEnabled = true
                return LoadResult(value: document, diagnostic: nil, writesEnabled: true)
            } catch {
                return await quarantine(reason: .decodeFailed, originalBytes: data)
            }
        }
    }

    /// Shared "too large" `LoadResult`, reached identically whether a
    /// preceding `fileSize` stat probe or the bounded `readFile` itself
    /// (having detected the content grow past the ceiling mid-read)
    /// reported the oversized condition — both disable writes and leave
    /// the file untouched without ever finishing an unbounded read.
    private func tooLargeLoadResult() -> LoadResult<Document> {
        writesEnabled = false
        let diagnostic = Diagnostic(
            id: StorageDiagnosticID.tooLarge,
            message: "Settings file at \(fileURL.path) exceeds the \(Self.maxDocumentBytes)-byte limit; using defaults without reading, quarantining, or writing to disk.",
            occurredAt: clock.nowMilliseconds()
        )
        return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)
    }

    private enum SizeCheckOutcome {
        case ok
        case missing
        case tooLarge
        /// `fileSize` failed for a reason other than "missing" (e.g. a
        /// permissions error). Falls through to the ordinary read path,
        /// whose own error handling classifies the failure the same way
        /// it always has.
        case indeterminate
    }

    private func checkSourceFileSize() async -> SizeCheckOutcome {
        do {
            let size = try await fileSystem.fileSize(at: fileURL)
            return size > Self.maxDocumentBytes ? .tooLarge : .ok
        } catch SettingsFileSystemError.fileNotFound {
            return .missing
        } catch {
            return .indeterminate
        }
    }

    private enum ReadOutcome {
        case missing
        case failed
        /// `fileSystem.readFile(at:)` itself detected the content exceeds
        /// `maxDocumentBytes` — either at its own initial size probe or
        /// mid-stream growth — distinct from a generic `.failed` so
        /// callers can surface the same `tooLarge` diagnostic/read-only
        /// outcome as the pre-flight `checkSourceFileSize()` check,
        /// rather than a misleading `readFailed`.
        case tooLarge
        case success(Data)
    }

    private func readSourceFile() async -> ReadOutcome {
        do {
            return .success(try await fileSystem.readFile(at: fileURL))
        } catch SettingsFileSystemError.fileNotFound {
            return .missing
        } catch SettingsFileSystemError.tooLarge {
            return .tooLarge
        } catch {
            return .failed
        }
    }

    /// Inspects the top-level `version` field of `data` as raw JSON,
    /// without decoding the full document, so a future schema (which may
    /// have fields this build doesn't understand, including other
    /// arbitrarily large numbers) can be safely detected and preserved
    /// untouched rather than misread as corrupt.
    ///
    /// Deliberately does not hand `data` to `JSONSerialization` at all:
    /// `JSONSerialization` itself throws when *any* JSON number in the
    /// document overflows `Double` (e.g. `1e309`), not just the version
    /// field, which would otherwise misreport a perfectly well-formed
    /// "future version" document — one that may legitimately contain other
    /// huge numbers this build has no reason to decode — as corrupt.
    /// Instead this lexically locates the top-level `version` number token
    /// by byte offset, classifies its magnitude using decimal-string
    /// arithmetic (never materializing it as `Double`/`Int`), and
    /// separately structurally validates the *entire* document with the
    /// same bounded, non-materializing scanner (`isStructurallyValidDocument`).
    /// The single `Data` → `[UInt8]` copy here is the one unavoidable copy
    /// this scan needs to index by byte offset; it is safe to make
    /// unconditionally because `checkSourceFileSize()` above has already
    /// bounded `data` to at most `maxDocumentBytes` (1 MiB).
    private func probeVersion(in data: Data) -> VersionProbing.Result {
        let bytes = [UInt8](data)
        switch VersionProbing.scanTopLevelVersionToken(in: bytes) {
        case .notFound, .nonNumericValue:
            return .invalid

        case .numberToken(let range):
            guard VersionProbing.isStructurallyValidDocument(bytes: bytes) else {
                return .invalid
            }
            let token = String(decoding: bytes[range], as: UTF8.self)
            return VersionProbing.classifyVersionNumberToken(token, currentVersion: Document.currentVersion)
        }
    }


    private enum QuarantineReason {
        case invalidVersion
        case decodedVersionMismatch
        case decodeFailed
    }

    /// Moves the corrupt file at `fileURL` aside to a timestamped
    /// `.corrupt-<millis>` sibling (adding a deterministic numeric suffix on
    /// name collision) so it is never silently discarded.
    ///
    /// Before moving, re-reads `fileURL` and compares it against
    /// `originalBytes` (the exact bytes this load already probed as
    /// corrupt). Even though the lock is held across the whole load, this
    /// guards against a non-cooperating writer that bypassed the lock
    /// entirely and replaced the file between the original read and this
    /// quarantine attempt: quarantining/moving in that case could discard
    /// or clobber that writer's newer content based on a stale read. If
    /// the bytes differ (or the file is now missing/unreadable), the
    /// quarantine is aborted and a read-only `concurrentChange` diagnostic
    /// is returned instead of touching the file.
    private func quarantine(reason: QuarantineReason, originalBytes: Data) async -> LoadResult<Document> {
        switch await readSourceFile() {
        case .success(let currentBytes) where currentBytes == originalBytes:
            break
        default:
            return concurrentChangeResult()
        }

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

    private func concurrentChangeResult() -> LoadResult<Document> {
        writesEnabled = false
        let diagnostic = Diagnostic(
            id: StorageDiagnosticID.concurrentChange,
            message: "Settings file at \(fileURL.path) changed since it was read; leaving it untouched without writing to disk.",
            occurredAt: clock.nowMilliseconds()
        )
        return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)
    }

    // MARK: - Save

    /// Encodes `document` and atomically replaces the on-disk file with it:
    /// writes to a freshly named, unique sibling temp file, synchronizes it
    /// to durable storage, then atomically replaces (or moves into) the
    /// destination, then synchronizes the containing directory. The temp
    /// file is removed on any pre-replace failure so no orphaned sibling is
    /// left behind.
    public func save(_ document: Document) async throws {
        await gate.acquire()
        do {
            try await performSave(document)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performSave(_ document: Document) async throws {
        guard isLoaded else {
            throw StorageError.notLoaded
        }
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

        guard Int64(data.count) <= Self.maxDocumentBytes else {
            throw StorageError.payloadTooLarge
        }

        // The lock lives as a sibling file next to `fileURL`; ensure the
        // containing directory exists before trying to create it,
        // otherwise the very first save (no directory yet) would fail to
        // acquire the lock at all.
        let directory = fileURL.deletingLastPathComponent()
        do {
            try await fileSystem.ensureDirectoryExists(at: directory)
        } catch {
            throw StorageError.writeFailed
        }

        let lock: any SettingsFileLock
        do {
            lock = try await fileSystem.acquireLock(for: fileURL)
        } catch {
            throw StorageError.writeFailed
        }

        do {
            try await performSaveLocked(data: data)
            await lock.unlock()
        } catch {
            await lock.unlock()
            throw error
        }
    }

    private func performSaveLocked(data: Data) async throws {
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

        do {
            try await fileSystem.synchronizeDirectory(for: fileURL)
        } catch {
            // The rename/replace already succeeded — the file at `fileURL`
            // is the new content — but the directory entry pointing at it
            // is not confirmed durable. Surfacing this as `writeFailed`
            // would wrongly suggest nothing happened; surfacing plain
            // success would wrongly suggest full durability was confirmed.
            throw StorageError.durabilityUncertain
        }
    }

    // MARK: - Transactional update

    /// Atomically reads the freshest on-disk document, applies `transform`
    /// to it, and durably writes the result back — all under one single,
    /// continuously-held instance FIFO gate turn plus cross-instance/
    /// cross-process advisory lock, so the read this transform sees can
    /// never go stale between being read and being replaced.
    ///
    /// This is the fix for the "lost update" hazard plain `load()` +
    /// mutate-in-memory + `save()` has across two independently loaded
    /// `AtomicJSONStore` instances (e.g. two `SettingsStore`s in the same
    /// process, or a future second process): each instance's own `current`
    /// cache reflects whatever the file looked like at *that instance's
    /// last load*, not necessarily what's on disk right now. If instance A
    /// changes field `x` and saves, then instance B — still holding a
    /// stale in-memory copy from before A's change — changes field `y` and
    /// saves *its* stale copy (with `x` reverted to its pre-A value), A's
    /// change is silently lost even though the two changes touched
    /// unrelated fields. `update(_:)` closes this gap structurally: the
    /// value `transform` receives is read from disk *after* this call has
    /// already acquired both the instance gate and the file lock, and the
    /// transformed result is written back before either is released — no
    /// other `AtomicJSONStore` call (in this process or, via the
    /// cross-process file lock, another process) can observe or mutate the
    /// document in between. Two instances changing different fields, no
    /// matter which acquires the lock first, both end up reflected on
    /// disk; two instances changing the *same* field converge on whichever
    /// one's transform actually ran last under the lock, matching normal
    /// last-writer-wins semantics rather than silently reverting either.
    ///
    /// - Never calls this instance's own `load()`/`save(_:)` (which would
    ///   each try to acquire `gate` and the file lock a second time from
    ///   within a turn that already holds them, deadlocking against
    ///   itself); it inlines the equivalent probe/write steps under the
    ///   single lock acquisition this method itself performs.
    /// - Refuses to run `transform` at all — throwing
    ///   `StorageUpdateError.failure` instead — if the current on-disk
    ///   state is a future/unsupported schema version, unreadable,
    ///   oversized, or fails to decode as the current schema: exactly the
    ///   states `load()` itself would decline to silently paper over. This
    ///   store's normal quarantine behavior for a *corrupt* file only
    ///   triggers from `load()`, deliberately never from `update(_:)`:
    ///   moving a file aside is a repair action appropriate when a human
    ///   or the app is explicitly (re)initializing settings, not a side
    ///   effect a routine field mutation should ever trigger.
    /// - `transform` is a synchronous, `Sendable` closure — it cannot
    ///   itself perform I/O or await anything, so it cannot yield the
    ///   actor mid-transform and reintroduce the very race this API
    ///   exists to close.
    public func update(_ transform: @Sendable (Document) throws -> Document) async throws -> Document {
        await gate.acquire()
        do {
            let committed = try await performUpdate(transform)
            await gate.release()
            return committed
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performUpdate(_ transform: @Sendable (Document) throws -> Document) async throws -> Document {
        guard isLoaded else {
            throw StorageUpdateError<Document>.failure(.notLoaded)
        }
        guard writesEnabled else {
            throw StorageUpdateError<Document>.failure(.writesDisabled)
        }

        let lock: any SettingsFileLock
        do {
            lock = try await fileSystem.acquireLock(for: fileURL)
        } catch {
            throw StorageUpdateError<Document>.failure(.writeFailed)
        }

        do {
            let committed = try await performUpdateLocked(transform)
            await lock.unlock()
            return committed
        } catch {
            await lock.unlock()
            throw error
        }
    }

    /// Runs entirely under the single lock `performUpdate` already
    /// acquired: probes the freshest on-disk state, refuses to proceed if
    /// it isn't safely known to be a decodable current-version document
    /// (or simply missing), applies `transform`, validates and encodes the
    /// result, and writes it back via the same `performSaveLocked` plain
    /// `save` uses — all without acquiring the lock or the instance gate a
    /// second time.
    private func performUpdateLocked(_ transform: @Sendable (Document) throws -> Document) async throws -> Document {
        let currentValue: Document

        switch await checkSourceFileSize() {
        case .missing:
            currentValue = Document.defaultValue
        case .tooLarge:
            writesEnabled = false
            throw StorageUpdateError<Document>.failure(.writesDisabled)
        case .ok, .indeterminate:
            switch await readSourceFile() {
            case .missing:
                currentValue = Document.defaultValue
            case .tooLarge:
                writesEnabled = false
                throw StorageUpdateError<Document>.failure(.writesDisabled)
            case .failed:
                writesEnabled = false
                throw StorageUpdateError<Document>.failure(.writesDisabled)
            case .success(let bytes):
                switch probeVersion(in: bytes) {
                case .future:
                    writesEnabled = false
                    throw StorageUpdateError<Document>.failure(.writesDisabled)
                case .invalid:
                    writesEnabled = false
                    throw StorageUpdateError<Document>.failure(.writesDisabled)
                case .supported:
                    do {
                        let document = try JSONDecoder().decode(Document.self, from: bytes)
                        guard document.version == Document.currentVersion else {
                            writesEnabled = false
                            throw StorageUpdateError<Document>.failure(.writesDisabled)
                        }
                        currentValue = document
                    } catch let error as StorageUpdateError<Document> {
                        throw error
                    } catch {
                        writesEnabled = false
                        throw StorageUpdateError<Document>.failure(.writesDisabled)
                    }
                }
            }
        }

        // `transform` is synchronous and `Sendable`: it cannot itself
        // await, so nothing can interleave between reading `currentValue`
        // above and writing the transformed result below — the entire
        // read-modify-write is one uninterrupted critical section under
        // the lock this method's caller already holds.
        let transformed = try transform(currentValue)

        guard transformed.version == Document.currentVersion else {
            throw StorageUpdateError<Document>.failure(.unsupportedVersion(transformed.version))
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(transformed)
        } catch {
            throw StorageUpdateError<Document>.failure(.encodeFailed)
        }

        guard Int64(data.count) <= Self.maxDocumentBytes else {
            throw StorageUpdateError<Document>.failure(.payloadTooLarge)
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try await fileSystem.ensureDirectoryExists(at: directory)
        } catch {
            throw StorageUpdateError<Document>.failure(.writeFailed)
        }

        do {
            try await performSaveLocked(data: data)
        } catch StorageError.durabilityUncertain {
            writesEnabled = true
            throw StorageUpdateError<Document>.durabilityUncertain(committed: transformed)
        } catch let storageError as StorageError {
            throw StorageUpdateError<Document>.failure(storageError)
        } catch {
            throw StorageUpdateError<Document>.failure(.writeFailed)
        }

        writesEnabled = true
        return transformed
    }
}
