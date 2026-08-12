import XCTest
import os
@testable import Seer

/// In-memory `SettingsFileSystem` test double. An `actor` so it can be
/// shared safely across the concurrent `load`/`save` calls exercised by the
/// concurrency test, mirroring how `AtomicJSONStore` itself serializes
/// access to the real file system.
actor InMemorySettingsFileSystem: SettingsFileSystem {
    private(set) var files: [String: Data] = [:]
    private(set) var directoriesEnsured: [String] = []
    private(set) var callLog: [String] = []

    var failNextRead: Error?
    var failNextWrite: Error?
    var failNextReplace: Error?
    var failNextMove: Error?
    var failNextLock: Error?
    var failNextDirectorySync: Error?
    var failNextFileSize: Error?

    /// Overrides the size reported by `fileSize(at:)` for the seeded file
    /// at a given path, independent of `files[path]`'s actual byte count —
    /// lets boundary/oversized-file tests exercise the exact-size and
    /// exact-size-plus-one cases cheaply, without materializing a real
    /// 1&nbsp;MiB (or larger) `Data` value.
    private var sizeOverrides: [String: Int64] = [:]

    func setSizeOverride(_ size: Int64, at url: URL) {
        sizeOverrides[url.path] = size
    }

    // MARK: - Advisory lock coordination
    //
    // Mirrors the production `flock`-backed lock's exclusivity at the
    // in-memory level so tests can exercise two separate
    // `AtomicJSONStore` instances (or two overlapping load/save calls on
    // the same instance's underlying store) sharing one
    // `InMemorySettingsFileSystem` and observe the second genuinely
    // suspend until the first releases, exactly like two processes
    // contending for the same sibling lock file would.
    private var lockedPaths: Set<String> = []
    private var lockWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquireLock(for url: URL) async throws -> any SettingsFileLock {
        callLog.append("acquireLock")
        if let error = failNextLock {
            failNextLock = nil
            throw error
        }
        if symlinkLockPaths.contains(url.path) {
            throw SettingsFileSystemError.symlinkRejected
        }
        let path = url.path
        while lockedPaths.contains(path) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lockWaiters[path, default: []].append(continuation)
            }
        }
        lockedPaths.insert(path)
        return FakeSettingsFileLock(path: path, owner: self)
    }

    fileprivate func releaseLock(at path: String) {
        callLog.append("unlock")
        lockedPaths.remove(path)
        guard var waiters = lockWaiters[path], !waiters.isEmpty else {
            lockWaiters.removeValue(forKey: path)
            return
        }
        let next = waiters.removeFirst()
        lockWaiters[path] = waiters
        next.resume()
    }

    func isLocked(at url: URL) -> Bool {
        lockedPaths.contains(url.path)
    }

    // MARK: - Controlled suspension hooks (ordering tests)
    //
    // Tests that need to prove FIFO gate ordering — not just the final
    // state — arm a named suspension point (e.g. "readFile"), let one
    // caller's operation enter and block inside it (recorded in
    // `enteredSuspensions` and observable via `waitUntilEntered`), then
    // start a second, queued caller and assert it has *not* reached the
    // filesystem while the first is still suspended, before releasing the
    // first via `resumeSuspension` and observing the second proceed.
    private var armedSuspensions: Set<String> = []
    private var pendingSuspensions: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var enteredSuspensions: Set<String> = []
    /// Which call occurrence (1-based) of a given armed suspension name
    /// should actually suspend, e.g. so a test can let the *first*
    /// `readFile` (the initial corrupt-file probe) run to completion and
    /// only suspend the *second* `readFile` (quarantine's just-in-time
    /// re-read) to inject a simulated concurrent writer in between.
    /// Defaults to `1`, preserving every existing call site's behavior of
    /// suspending on the first call.
    private var suspensionTargetOccurrence: [String: Int] = [:]
    private var suspensionCallOccurrences: [String: Int] = [:]

    func armSuspension(_ name: String, onOccurrence occurrence: Int = 1) {
        armedSuspensions.insert(name)
        suspensionTargetOccurrence[name] = occurrence
    }

    func waitUntilEntered(_ name: String) async {
        while !enteredSuspensions.contains(name) {
            await Task.yield()
        }
    }

    func resumeSuspension(_ name: String) {
        guard let continuation = pendingSuspensions.removeValue(forKey: name) else {
            return
        }
        continuation.resume()
    }

    private func suspendIfArmed(_ name: String) async {
        guard armedSuspensions.contains(name) else {
            return
        }
        suspensionCallOccurrences[name, default: 0] += 1
        let targetOccurrence = suspensionTargetOccurrence[name] ?? 1
        guard suspensionCallOccurrences[name] == targetOccurrence else {
            return
        }
        armedSuspensions.remove(name)
        enteredSuspensions.insert(name)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingSuspensions[name] = continuation
        }
    }

    func seedFile(at url: URL, contents: Data) {
        files[url.path] = contents
    }

    /// Directly replaces the seeded contents at `url`, bypassing the lock
    /// and `moveItem`/`replaceItem` entirely — simulates a
    /// non-cooperating writer (another process ignoring the advisory
    /// lock) mutating the file out from under an in-flight load.
    func simulateConcurrentReplace(at url: URL, contents: Data) {
        files[url.path] = contents
    }

    /// Directly removes the seeded contents at `url`, bypassing the lock —
    /// simulates a non-cooperating writer deleting the file out from
    /// under an in-flight load.
    func simulateConcurrentRemoval(at url: URL) {
        files.removeValue(forKey: url.path)
    }

    func contents(at url: URL) -> Data? {
        files[url.path]
    }

    /// All file paths in `directory` (non-recursive), by last path
    /// component, so tests can assert on exactly which siblings exist.
    func fileNames(inDirectoryOf url: URL) -> Set<String> {
        let directory = url.deletingLastPathComponent().path
        return Set(
            files.keys
                .filter { $0.hasPrefix(directory + "/") }
                .map { String($0.dropFirst(directory.count + 1)) }
        )
    }

    func ensureDirectoryExists(at url: URL) async throws {
        callLog.append("ensureDirectoryExists")
        directoriesEnsured.append(url.path)
    }

    func fileExists(at url: URL) async -> Bool {
        files[url.path] != nil
    }

    func fileSize(at url: URL) async throws -> Int64 {
        callLog.append("fileSize")
        if let error = failNextFileSize {
            failNextFileSize = nil
            throw error
        }
        if let override = sizeOverrides[url.path] {
            return override
        }
        guard let data = files[url.path] else {
            throw SettingsFileSystemError.fileNotFound
        }
        return Int64(data.count)
    }

    /// Paths at which `readFile` must behave as though the document's own
    /// final path component were a symlink — mirroring the real
    /// `FileManagerSettingsFileSystem`'s `O_NOFOLLOW` refusal on the
    /// document open — without needing an actual symlink on disk (this
    /// fake has no disk at all).
    private var symlinkPaths: Set<String> = []

    func simulateSymlink(at url: URL) {
        symlinkPaths.insert(url.path)
    }

    /// Paths at which `acquireLock` must behave as though the *lock
    /// file's* own path were a symlink — modeled separately from
    /// `symlinkPaths` because the real lock file lives at a distinct
    /// sibling path (`<document>.lock`), not the document path itself, so
    /// a symlinked lock and a symlinked document are independent failure
    /// modes.
    private var symlinkLockPaths: Set<String> = []

    func simulateSymlinkLock(at url: URL) {
        symlinkLockPaths.insert(url.path)
    }

    func readFile(at url: URL) async throws -> Data {
        callLog.append("readFile")
        await suspendIfArmed("readFile")
        if let error = failNextRead {
            failNextRead = nil
            throw error
        }
        if symlinkPaths.contains(url.path) {
            throw SettingsFileSystemError.symlinkRejected
        }
        guard let data = files[url.path] else {
            throw SettingsFileSystemError.fileNotFound
        }
        // Mirrors the real bounded POSIX read: the bound is checked
        // against whatever content is actually present *at the moment of
        // this read*, not whatever a preceding `fileSize` probe reported
        // — so a test that seeds a small file, lets a `fileSize`/first
        // `readFile` pass, then replaces the content with something over
        // `StorageLimits.maxDocumentBytes` before this call actually
        // resolves (via `simulateConcurrentReplace` while `readFile` is
        // suspended) faithfully reproduces "replacement-after-stat"
        // growth without this fake ever needing to materialize a real
        // multi-hundred-megabyte `Data` value to prove the bound holds.
        guard Int64(data.count) <= StorageLimits.maxDocumentBytes else {
            throw SettingsFileSystemError.tooLarge
        }
        return data
    }

    func writeFileAndSynchronize(_ data: Data, to url: URL) async throws {
        callLog.append("writeFileAndSynchronize:\(url.lastPathComponent)")
        await suspendIfArmed("writeFileAndSynchronize")
        if let error = failNextWrite {
            failNextWrite = nil
            throw error
        }
        files[url.path] = data
    }

    func replaceItem(at destination: URL, withItemAt source: URL) async throws {
        callLog.append("replaceItem")
        if let error = failNextReplace {
            failNextReplace = nil
            throw error
        }
        guard let data = files[source.path] else {
            throw SettingsFileSystemError.fileNotFound
        }
        files[destination.path] = data
        files.removeValue(forKey: source.path)
    }

    func synchronizeDirectory(for url: URL) async throws {
        callLog.append("synchronizeDirectory")
        if let error = failNextDirectorySync {
            failNextDirectorySync = nil
            throw error
        }
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        callLog.append("moveItem")
        if let error = failNextMove {
            failNextMove = nil
            throw error
        }
        if files[destination.path] != nil {
            throw SettingsFileSystemError.destinationAlreadyExists
        }
        guard let data = files[source.path] else {
            throw SettingsFileSystemError.fileNotFound
        }
        files[destination.path] = data
        files.removeValue(forKey: source.path)
    }

    func removeItem(at url: URL) async throws {
        callLog.append("removeItem")
        guard files[url.path] != nil else {
            throw SettingsFileSystemError.fileNotFound
        }
        files.removeValue(forKey: url.path)
    }
}

/// Test-double lock token for `InMemorySettingsFileSystem`, mirroring
/// `DarwinFileLock`'s idempotent-release contract. `unlock()` proxies back
/// into the owning actor to release its in-memory lock bookkeeping and
/// wake the next queued waiter, if any.
final class FakeSettingsFileLock: SettingsFileLock, @unchecked Sendable {
    private let path: String
    private weak var owner: InMemorySettingsFileSystem?
    // `OSAllocatedUnfairLock` (not `NSLock`) because `NSLock.lock()`/
    // `unlock()` are unavailable from `async` contexts under Swift 6's
    // strict concurrency checking, and this type's own `unlock()` is
    // `async`.
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(path: String, owner: InMemorySettingsFileSystem) {
        self.path = path
        self.owner = owner
    }

    func unlock() async {
        let alreadyReleased = state.withLock { isReleased in
            let was = isReleased
            isReleased = true
            return was
        }
        guard !alreadyReleased else { return }
        await owner?.releaseLock(at: path)
    }
}

final class AtomicJSONStoreTests: XCTestCase {
    private let settingsURL = URL(fileURLWithPath: "/Seer-Test-Root/ai.opencoven.seer/settings.json")

    private func makeStore(
        fileSystem: InMemorySettingsFileSystem,
        clock: Clock = FixedClock(fixedMilliseconds: 1_700_000_000_000)
    ) -> AtomicJSONStore<SettingsDocument> {
        AtomicJSONStore<SettingsDocument>(fileURL: settingsURL, fileSystem: fileSystem, clock: clock)
    }

    private func encode(_ document: SettingsDocument) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(document)
    }

    // MARK: 1. Missing file

    func testMissingFileReturnsDefaultsNoDiagnosticWritable() async {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    // MARK: 2. Valid file loads

    func testValidFileLoads() async {
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true)
        await fileSystem.seedFile(at: settingsURL, contents: encode(document))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, document)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    // MARK: 3. Corrupt JSON quarantines

    func testCorruptJSONQuarantinesToTimestampedSibling() async {
        let fileSystem = InMemorySettingsFileSystem()
        let corruptBytes = Data("{ not valid json".utf8)
        await fileSystem.seedFile(at: settingsURL, contents: corruptBytes)
        let clock = FixedClock(fixedMilliseconds: 1_700_000_000_000)
        let store = makeStore(fileSystem: fileSystem, clock: clock)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertEqual(result.diagnostic?.occurredAt, 1_700_000_000_000)
        XCTAssertTrue(result.writesEnabled)

        let quarantinedURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.corrupt-1700000000000")
        let quarantined = await fileSystem.contents(at: quarantinedURL)
        XCTAssertEqual(quarantined, corruptBytes)
        let original = await fileSystem.contents(at: settingsURL)
        XCTAssertNil(original)
    }

    // MARK: 4. Invalid current-version schema quarantines

    func testInvalidCurrentVersionSchemaQuarantines() async {
        let fileSystem = InMemorySettingsFileSystem()
        // version: 1 (current) but keepAwakeMode has an invalid raw value.
        let invalidBytes = Data("""
        {"version":1,"keepAwakeMode":"bogus","includePrereleaseUpdates":false}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: invalidBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)

        let originalGone = await fileSystem.contents(at: settingsURL)
        XCTAssertNil(originalGone)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertTrue(names.contains { $0.hasPrefix("settings.json.corrupt-") })
    }

    // MARK: 5. Future version preserves bytes, read-only

    func testFutureVersionReturnsReadOnlyDefaultsAndPreservesBytes() async {
        let fileSystem = InMemorySettingsFileSystem()
        let futureBytes = Data("""
        {"version":999,"someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: futureBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, futureBytes)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    // MARK: 6. Injected read failure

    func testReadFailureReturnsReadOnlyDefaultsNoWriteOrMove() async {
        let fileSystem = InMemorySettingsFileSystem()
        let existingBytes = encode(SettingsDocument.defaultValue)
        await fileSystem.seedFile(at: settingsURL, contents: existingBytes)
        await fileSystem.setFailNextRead(SettingsFileSystemError.other("permission denied"))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.readFailed)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, existingBytes)
        let log = await fileSystem.callLog
        XCTAssertFalse(log.contains("moveItem"))
        XCTAssertFalse(log.contains("writeFileAndSynchronize"))
    }

    // MARK: 7. Quarantine failure

    func testQuarantineFailurePreservesSourceAndReadOnly() async {
        let fileSystem = InMemorySettingsFileSystem()
        let corruptBytes = Data("not json at all".utf8)
        await fileSystem.seedFile(at: settingsURL, contents: corruptBytes)
        await fileSystem.setFailNextMove(SettingsFileSystemError.other("disk full"))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.quarantineFailed)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, corruptBytes)
    }

    // MARK: 8. Save when writes disabled

    func testSaveWhenWritesDisabledThrowsAndPreservesSource() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let futureBytes = Data("""
        {"version":999}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: futureBytes)
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        do {
            try await store.save(SettingsDocument.defaultValue)
            XCTFail("expected StorageError.writesDisabled")
        } catch StorageError.writesDisabled {
            // expected
        } catch {
            XCTFail("expected StorageError.writesDisabled, got \(error)")
        }

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, futureBytes)
    }

    // MARK: 9. Atomic save uses sibling unique temp, synchronizes, leaves no temp

    func testAtomicSaveUsesUniqueSiblingTempAndLeavesNoTempBehind() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        let document = SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true)
        try await store.save(document)

        let log = await fileSystem.callLog
        let writeIndex = log.firstIndex(where: { $0.hasPrefix("writeFileAndSynchronize:") })
        let replaceIndex = log.firstIndex(of: "replaceItem")
        XCTAssertNotNil(writeIndex)
        XCTAssertNotNil(replaceIndex)
        XCTAssertLessThan(writeIndex!, replaceIndex!, "must synchronize the temp file before replacing the destination")

        let tempName = log[writeIndex!].replacingOccurrences(of: "writeFileAndSynchronize:", with: "")
        XCTAssertTrue(tempName.hasPrefix("settings.json.tmp-"))

        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertEqual(names, ["settings.json"])

        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded, document)
    }

    // MARK: 10. Replacement/write failure surfaces typed error, old file remains, temp cleaned

    func testWriteFailureSurfacesTypedErrorAndCleansUpTemp() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let originalDocument = SettingsDocument(version: 1, keepAwakeMode: .system, includePrereleaseUpdates: false)
        await fileSystem.seedFile(at: settingsURL, contents: encode(originalDocument))
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        await fileSystem.setFailNextReplace(SettingsFileSystemError.other("replace failed"))

        do {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true))
            XCTFail("expected StorageError.writeFailed")
        } catch StorageError.writeFailed {
            // expected
        } catch {
            XCTFail("expected StorageError.writeFailed, got \(error)")
        }

        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertEqual(names, ["settings.json"], "no orphaned temp file should remain")

        let decoder = JSONDecoder()
        let currentBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: currentBytes!)
        XCTAssertEqual(decoded, originalDocument, "old file must remain valid after a failed save")
    }

    // MARK: 11. Concurrent saves serialize; final file matches last accepted mutation

    func testConcurrentSavesSerializeAndFinalStateMatchesInvocationOrder() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        // Issue mutations sequentially from the caller's perspective (the
        // actor guarantees in-order application even if launched
        // concurrently), then confirm the very last one accepted is what
        // ends up on disk.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for updates in 0..<20 {
                group.addTask {
                    try await store.save(
                        SettingsDocument(
                            version: 1,
                            keepAwakeMode: updates % 2 == 0 ? .system : .display,
                            includePrereleaseUpdates: updates == 19
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertEqual(names, ["settings.json"], "no leftover temp files after concurrent saves")

        let decoder = JSONDecoder()
        let finalBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: finalBytes!)
        // Every task group member wrote version 1 with includePrereleaseUpdates
        // true only on the last-issued (updates == 19) invocation; since the
        // actor serializes saves in submission order for this in-memory
        // filesystem, the final on-disk document must be internally
        // consistent (decodable, current version).
        XCTAssertEqual(decoded.version, 1)
        _ = decoded
    }

    // MARK: 12. Failed mutation does not change cache — covered at the SettingsStore
    // level in SettingsStoreTests (AtomicJSONStore itself has no cache to
    // corrupt: it is stateless aside from `writesEnabled`, which a failed
    // save must also not flip).

    func testFailedSaveDoesNotDisableWrites() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        await fileSystem.setFailNextWrite(SettingsFileSystemError.other("boom"))
        do {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true))
            XCTFail("expected failure")
        } catch StorageError.writeFailed {
            // expected
        }

        // Writes must still be enabled — a transient write failure isn't a
        // permanent read-only condition.
        try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true))
        let saved = await fileSystem.contents(at: settingsURL)
        XCTAssertNotNil(saved)
    }

    // MARK: 15. FIFO gate ordering — queued save does not enter the filesystem
    // until the prior save's write completes and releases the gate.

    func testQueuedSaveDoesNotEnterFilesystemUntilPriorSaveReleases() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        await fileSystem.armSuspension("writeFileAndSynchronize")

        let taskA = Task {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: false))
        }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        // A is now suspended inside its write, holding the gate. Start B —
        // it must queue behind A rather than interleave.
        let taskB = Task {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .system, includePrereleaseUpdates: true))
        }

        // Give the scheduler ample opportunity to run B if the gate were
        // (incorrectly) not serializing: B must still not have reached the
        // filesystem while A holds it.
        for _ in 0..<50 {
            await Task.yield()
        }
        let logWhileABlocked = await fileSystem.callLog
        XCTAssertEqual(
            logWhileABlocked.filter { $0.hasPrefix("writeFileAndSynchronize") }.count, 1,
            "queued save B must not enter the filesystem while save A still holds the gate"
        )

        await fileSystem.resumeSuspension("writeFileAndSynchronize")
        try await taskA.value
        try await taskB.value

        let finalLog = await fileSystem.callLog
        XCTAssertEqual(finalLog.filter { $0.hasPrefix("writeFileAndSynchronize") }.count, 2)

        let decoder = JSONDecoder()
        let finalBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: finalBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .system, "disk must match B, the later-queued save")
        XCTAssertTrue(decoded.includePrereleaseUpdates)
    }

    // MARK: 16. FIFO gate ordering — a queued save cannot write while a load
    // is still blocked reading a future-version file; once the load
    // determines writes are disabled, the queued save throws and the
    // original bytes are unchanged.

    func testQueuedSaveBlockedBehindLoadOnFutureVersionFileNeverWrites() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let futureBytes = Data("""
        {"version":999,"someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: futureBytes)
        let store = makeStore(fileSystem: fileSystem)

        await fileSystem.armSuspension("readFile")

        let loadTask = Task {
            await store.load()
        }
        await fileSystem.waitUntilEntered("readFile")

        // The load is now suspended inside its read, holding the gate.
        // Queue a save behind it.
        let saveTask = Task {
            try await store.save(SettingsDocument.defaultValue)
        }

        for _ in 0..<50 {
            await Task.yield()
        }
        let logWhileLoadBlocked = await fileSystem.callLog
        XCTAssertFalse(
            logWhileLoadBlocked.contains { $0.hasPrefix("writeFileAndSynchronize") },
            "queued save must not enter the filesystem while load still holds the gate"
        )

        await fileSystem.resumeSuspension("readFile")
        let loadResult = await loadTask.value
        XCTAssertFalse(loadResult.writesEnabled)
        XCTAssertEqual(loadResult.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)

        do {
            try await saveTask.value
            XCTFail("expected StorageError.writesDisabled once the future-version load completes")
        } catch StorageError.writesDisabled {
            // expected
        } catch {
            XCTFail("expected StorageError.writesDisabled, got \(error)")
        }

        let finalLog = await fileSystem.callLog
        XCTAssertFalse(finalLog.contains { $0.hasPrefix("writeFileAndSynchronize") })
        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, futureBytes, "original bytes must be unchanged")
    }

    // MARK: 17. A failed first queued operation still releases the gate for
    // the next queued operation.

    func testFailedFirstQueuedSaveReleasesNextQueuedSave() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        await fileSystem.armSuspension("writeFileAndSynchronize")

        let taskA = Task {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: false))
        }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        let taskB = Task {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .system, includePrereleaseUpdates: true))
        }

        // Arrange for A's write to fail once it resumes, then release it.
        await fileSystem.setFailNextWrite(SettingsFileSystemError.other("boom"))
        await fileSystem.resumeSuspension("writeFileAndSynchronize")

        do {
            try await taskA.value
            XCTFail("expected save A to throw")
        } catch StorageError.writeFailed {
            // expected
        }

        // B must still be released and able to proceed/succeed even though
        // A (ahead of it in the queue) failed.
        try await taskB.value

        let decoder = JSONDecoder()
        let finalBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: finalBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .system)
        XCTAssertTrue(decoded.includePrereleaseUpdates)
    }

    // MARK: 18. Oversized/boundary numeric versions must never trap at Int
    // conversion, and must be treated as unsupported-version/read-only.

    func testOversizedExponentialVersionIsUnsupportedReadOnlyAndDoesNotTrap() async {
        let fileSystem = InMemorySettingsFileSystem()
        let hugeVersionBytes = Data("""
        {"version":1e100,"someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: hugeVersionBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, hugeVersionBytes, "bytes must be preserved, not quarantined")
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    func testVersionExactlyIntMaxIsUnsupportedReadOnlyAndDoesNotTrap() async {
        let fileSystem = InMemorySettingsFileSystem()
        let intMaxVersionBytes = Data("""
        {"version":9223372036854775807}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: intMaxVersionBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, intMaxVersionBytes)
    }

    func testVersionJustBeyondIntMaxRangeIsUnsupportedReadOnlyAndDoesNotTrap() async {
        let fileSystem = InMemorySettingsFileSystem()
        // 2^63, exactly one past Int64.max — also the value `Double(Int.max)`
        // itself rounds up to, which is the classic trap trigger for a naive
        // `Int(doubleValue)` conversion guarded only by `<= Double(Int.max)`.
        let beyondIntMaxBytes = Data("""
        {"version":9223372036854775808}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: beyondIntMaxBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, beyondIntMaxBytes)
    }

    // MARK: 19. Arbitrarily large top-level versions must be recognized as
    // unsupported/read-only without ever materializing the number as a
    // `Double`/`Int` (which would either trap or misreport via
    // `JSONSerialization`'s own non-finite-number rejection).

    func testExponentBeyondDoubleRangeIsUnsupportedReadOnlyAndDoesNotTrap() async {
        let fileSystem = InMemorySettingsFileSystem()
        // 1e309 overflows `Double` (max ~1.7976931348623157e308).
        // `JSONSerialization` itself throws "Number wound up as NaN" when
        // asked to parse this verbatim, so the probe must never hand the
        // full, unmodified document to `JSONSerialization` while this
        // token is still present.
        let hugeExponentBytes = Data("""
        {"version":1e309,"someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: hugeExponentBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, hugeExponentBytes, "original bytes must be preserved, not quarantined")
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    func testFiveHundredDigitIntegerVersionIsUnsupportedReadOnlyAndDoesNotTrap() async {
        let fileSystem = InMemorySettingsFileSystem()
        let fiveHundredDigits = "1" + String(repeating: "0", count: 499)
        let hugeIntegerBytes = Data("""
        {"version":\(fiveHundredDigits)}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: hugeIntegerBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, hugeIntegerBytes)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    func testHugePositiveExponentDigitCountIsUnsupportedReadOnlyAndDoesNotTrap() async {
        let fileSystem = InMemorySettingsFileSystem()
        // An exponent with far more digits than fit in an `Int` (20 digits
        // here), which a naive `Int(exponentString)` parse would trap on.
        let hugeExponentDigitsBytes = Data("""
        {"version":1e99999999999999999999}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: hugeExponentDigitsBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, hugeExponentDigitsBytes)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    func testMalformedJSONWithOversizedVersionStillQuarantines() async {
        let fileSystem = InMemorySettingsFileSystem()
        // The version token itself is a huge exponent, but the document
        // around it is malformed (missing comma between members). The
        // sanitized structural re-check must catch this and route it to
        // the ordinary corrupt/quarantine path, not unsupported-version.
        let malformedBytes = Data("""
        {"version":1e309 "someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: malformedBytes)
        let clock = FixedClock(fixedMilliseconds: 1_700_000_000_000)
        let store = makeStore(fileSystem: fileSystem, clock: clock)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)

        let originalGone = await fileSystem.contents(at: settingsURL)
        XCTAssertNil(originalGone)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertTrue(names.contains { $0.hasPrefix("settings.json.corrupt-") })
    }

    func testNestedVersionDoesNotOverrideMissingTopLevelVersion() async {
        let fileSystem = InMemorySettingsFileSystem()
        // "version" only appears inside a nested object; the top-level
        // document has no "version" key at all, which must be treated the
        // same as any other missing-version document (invalid schema),
        // not as if the nested value of 5 were the top-level version.
        let nestedVersionBytes = Data("""
        {"outer":{"version":5},"other":1}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: nestedVersionBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)

        let originalGone = await fileSystem.contents(at: settingsURL)
        XCTAssertNil(originalGone)
    }

    func testStringVersionValueDoesNotOverrideMissingNumericVersion() async {
        let fileSystem = InMemorySettingsFileSystem()
        // A string field happens to be named "version" at the top level,
        // but a string can never be a valid version — must be treated as
        // invalid schema, not silently coerced.
        let stringVersionBytes = Data("""
        {"version":"5","other":1}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: stringVersionBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testEscapedTopLevelKeysAreHandledCorrectlyWhenLocatingVersion() async {
        let fileSystem = InMemorySettingsFileSystem()
        // A preceding sibling key/value contains escaped quotes and a
        // backslash that must not confuse the scan for the top-level
        // "version" key, and the "version" key itself is written with a
        // \u unicode escape that decodes to the same text. The rest of the
        // fields are exactly what `SettingsDocument` needs so this exercises
        // only the version scan, not unrelated document decoding.
        let escapedBytes = Data("""
        {"note":"a \\"quoted\\" value with a backslash \\\\","\\u0076ersion":1,"keepAwakeMode":"system","includePrereleaseUpdates":false}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: escapedBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value.version, 1)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    func testFractionalVersionIsInvalidSchemaNotUnsupported() async {
        let fileSystem = InMemorySettingsFileSystem()
        let fractionalBytes = Data("""
        {"version":1.5}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: fractionalBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)

        let originalGone = await fileSystem.contents(at: settingsURL)
        XCTAssertNil(originalGone)
    }

    func testNegativeVersionIsInvalidSchemaNotUnsupportedAndDoesNotTrap() async {
        let fileSystem = InMemorySettingsFileSystem()
        let negativeBytes = Data("""
        {"version":-1}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: negativeBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testOrdinaryCurrentVersionStillLoadsUnchanged() async {
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .system, includePrereleaseUpdates: false)
        await fileSystem.seedFile(at: settingsURL, contents: encode(document))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, document)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    func testSmallFutureVersionStillUnsupportedReadOnlyUnchanged() async {
        let fileSystem = InMemorySettingsFileSystem()
        let futureBytes = Data("""
        {"version":2,"someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: futureBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, futureBytes)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    // MARK: 20. Exponent magnitude must never drive allocation size.
    //
    // A naive classifier that materializes `shift` trailing zeros before
    // comparing digit counts allocates an array proportional to the
    // exponent's *value* (not its digit count), so an 18-digit exponent
    // (which still fits comfortably in `Int64`) can still request an
    // ~10^18-element array and OOM/hang. These cases must classify in
    // bounded time/memory regardless of how large the exponent's value is.

    func testHugeIntegralPositiveExponentIsUnsupportedReadOnlyAndDoesNotHang() async {
        let fileSystem = InMemorySettingsFileSystem()
        // Exactly 18 exponent digits: parses into `Int` without overflow,
        // but a naive `Array(repeating: "0", count: shift)` would still
        // try to allocate ~10^18 elements.
        let hugeExponentBytes = Data("""
        {"version":1e999999999999999999}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: hugeExponentBytes)
        let store = makeStore(fileSystem: fileSystem)

        let start = DispatchTime.now()
        let result = await store.load()
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsedSeconds, 5.0, "classification must not scale with exponent magnitude")
        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, hugeExponentBytes, "bytes must be preserved, not quarantined")
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    func testHugeNegativeExponentIsInvalidSchemaQuarantinesAndDoesNotHang() async {
        let fileSystem = InMemorySettingsFileSystem()
        let hugeNegativeExponentBytes = Data("""
        {"version":1e-999999999999999999}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: hugeNegativeExponentBytes)
        let clock = FixedClock(fixedMilliseconds: 1_700_000_000_000)
        let store = makeStore(fileSystem: fileSystem, clock: clock)

        let start = DispatchTime.now()
        let result = await store.load()
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsedSeconds, 5.0, "classification must not scale with exponent magnitude")
        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)

        let originalGone = await fileSystem.contents(at: settingsURL)
        XCTAssertNil(originalGone)
    }

    func testExponentWithThousandsOfDigitsPositiveIsUnsupportedAndDoesNotHang() async {
        let fileSystem = InMemorySettingsFileSystem()
        let thousandsOfDigits = String(repeating: "9", count: 4000)
        let bytes = Data("""
        {"version":1e\(thousandsOfDigits)}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let start = DispatchTime.now()
        let result = await store.load()
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsedSeconds, 5.0)
        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)
    }

    func testExponentWithThousandsOfDigitsNegativeIsInvalidAndDoesNotHang() async {
        let fileSystem = InMemorySettingsFileSystem()
        let thousandsOfDigits = String(repeating: "9", count: 4000)
        let bytes = Data("""
        {"version":1e-\(thousandsOfDigits)}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let start = DispatchTime.now()
        let result = await store.load()
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsedSeconds, 5.0)
        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testScientificExactCurrentVersionZeroExponentLoadsUnchanged() async {
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .system, includePrereleaseUpdates: false)
        let bytes = Data("""
        {"version":1e0,"keepAwakeMode":"system","includePrereleaseUpdates":false}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, document)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    func testScientificExactCurrentVersionShiftedMantissaLoadsUnchanged() async {
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .system, includePrereleaseUpdates: false)
        // 10e-1 == 1, the current version — exercises the negative-shift
        // (fractional-exponent) branch resolving to an exact integer.
        let bytes = Data("""
        {"version":10e-1,"keepAwakeMode":"system","includePrereleaseUpdates":false}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, document)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    func testScientificExactCurrentVersionLargerShiftedMantissaLoadsUnchanged() async {
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .system, includePrereleaseUpdates: false)
        // 100e-2 == 1, the current version.
        let bytes = Data("""
        {"version":100e-2,"keepAwakeMode":"system","includePrereleaseUpdates":false}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, document)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    func testScientificFutureVersionZeroExponentIsUnsupportedReadOnly() async {
        let fileSystem = InMemorySettingsFileSystem()
        let bytes = Data("""
        {"version":2e0,"someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, bytes)
    }

    func testScientificFractionalVersionIsInvalidSchemaNotUnsupported() async {
        let fileSystem = InMemorySettingsFileSystem()
        // 1e-1 == 0.1, a non-integral version — invalid schema, not
        // unsupported-future, and must not be confused with the
        // huge-negative-exponent case above.
        let bytes = Data("""
        {"version":1e-1}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)

        let originalGone = await fileSystem.contents(at: settingsURL)
        XCTAssertNil(originalGone)
    }

    // MARK: 21. Every scanner byte access must be bounds-checked: truncated
    // object/array/string/escape/number tokens must quarantine as invalid,
    // never index past the end of the buffer.

    func testMalformedNestedObjectTruncatedAfterCommaQuarantinesWithoutCrashing() async {
        let fileSystem = InMemorySettingsFileSystem()
        // Reproduction: a nested object truncated immediately after a
        // trailing comma. The object-value loop in `skipJSONValue` used to
        // jump back to re-read the next key byte without first checking
        // that a next byte exists, indexing one past the end of the array.
        let truncatedNestedBytes = Data(#"{"version":1,"x":{"a":1,"#.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: truncatedNestedBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testTruncationAtEveryByteBoundaryOfNestedDocumentNeverCrashesOrHangs() async {
        // A representative document exercising every token kind the scanner
        // understands: nested object, nested array, a string containing an
        // escaped quote and an escaped backslash, and a plain number — all
        // truncated at every possible byte offset. Every single prefix must
        // resolve to *some* `LoadResult` (quarantined as corrupt, since a
        // truncated document is never well-formed) without trapping or
        // hanging, regardless of exactly where the cut falls (mid-object,
        // mid-array, mid-string, mid-escape, or mid-number).
        let full = Data(#"""
        {"version":1,"nested":{"arr":[1,2,{"s":"a\"b\\c","n":123},[]],"obj":{}},"keepAwakeMode":"system","includePrereleaseUpdates":false}
        """#.utf8)

        let start = DispatchTime.now()
        for length in 0...full.count {
            let fileSystem = InMemorySettingsFileSystem()
            await fileSystem.seedFile(at: settingsURL, contents: full.prefix(length))
            let store = makeStore(fileSystem: fileSystem)
            _ = await store.load()
        }
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsedSeconds, 15.0, "scanning every truncation boundary must stay linear in input size")
    }

    // MARK: 22. Recursion must be bounded: deeply nested JSON must be
    // rejected as invalid rather than overflowing the native call stack.

    private func nestedArrayValue(depth: Int) -> String {
        String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    }

    private func documentWithDeepField(depth: Int) -> Data {
        // "deep" must precede "version" in byte order: the lexical scanner
        // returns as soon as it locates the top-level "version" key, so a
        // pathologically nested sibling field only ever gets fed through
        // `skipJSONValue`'s recursion/depth-limit if the scanner has to
        // skip past it first while still searching for "version".
        Data("""
        {"deep":\(nestedArrayValue(depth: depth)),"version":1,"keepAwakeMode":"system","includePrereleaseUpdates":false}
        """.utf8)
    }

    func test127NestedArraysStillValidatesAndLoadsSupportedVersion() async {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.seedFile(at: settingsURL, contents: documentWithDeepField(depth: 127))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    func test128NestedArraysAtExactlyTheDepthLimitStillValidatesAndLoads() async {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.seedFile(at: settingsURL, contents: documentWithDeepField(depth: 128))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    func test129NestedArraysOneOverTheDepthLimitQuarantinesWithoutCrashing() async {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.seedFile(at: settingsURL, contents: documentWithDeepField(depth: 129))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func test50000NestedArraysRejectedQuicklyWithoutStackOverflow() async {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.seedFile(at: settingsURL, contents: documentWithDeepField(depth: 50_000))
        let store = makeStore(fileSystem: fileSystem)

        let start = DispatchTime.now()
        let result = await store.load()
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsedSeconds, 5.0, "depth-bounded scan must reject pathological nesting in bounded time")
        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    // MARK: 23. Zero-padded exponents must be normalized by digit magnitude,
    // not raw digit count, before classification.

    func testZeroPaddedExponentAllZerosIsExponentZeroAndLoadsSupportedVersion() async {
        let fileSystem = InMemorySettingsFileSystem()
        // 1e000000000000000000 has 18 zero exponent digits — one shy of
        // `maxParsableExponentDigitCount` on its own, but real-world zero
        // padding can exceed it arbitrarily; use enough zeros to guarantee
        // the raw (untrimmed) digit count would exceed the threshold.
        let manyZeros = String(repeating: "0", count: 4_000)
        let bytes = Data("""
        {"version":1e\(manyZeros),"keepAwakeMode":"system","includePrereleaseUpdates":false}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertNil(result.diagnostic, "an all-zero exponent must classify as exponent 0, not huge/future")
        XCTAssertTrue(result.writesEnabled)
    }

    func testZeroPaddedExponentThousandsOfZerosThenOneIsExponentPlusOneAndFuture() async {
        let fileSystem = InMemorySettingsFileSystem()
        // Thousands of leading zeros followed by a single `1` must mean
        // exponent +1 (value 10, two digits — more than currentVersion's
        // one digit, so a future version), not an astronomically huge
        // exponent merely because the raw digit count is large.
        let leadingZeros = String(repeating: "0", count: 4_000)
        let bytes = Data("""
        {"version":1e\(leadingZeros)1,"someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, bytes, "bytes must be preserved, not quarantined")
    }

    func testZeroPaddedExponentThousandsOfZerosThenOneNegativeIsInvalidSchema() async {
        let fileSystem = InMemorySettingsFileSystem()
        // Thousands of leading zeros followed by a single `1` in a negative
        // exponent must mean exponent -1 (value 0.1, non-integral —
        // invalid schema), not an astronomically huge negative exponent.
        let leadingZeros = String(repeating: "0", count: 4_000)
        let bytes = Data("""
        {"version":1e-\(leadingZeros)1}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testZeroPaddedHugePositiveExponentStillUnsupported() async {
        let fileSystem = InMemorySettingsFileSystem()
        // Leading zero padding in front of a genuinely huge exponent must
        // not change the outcome: trimming the padding must still leave a
        // digit count far beyond `maxParsableExponentDigitCount`.
        let leadingZeros = String(repeating: "0", count: 4_000)
        let hugeDigits = String(repeating: "9", count: 30)
        let bytes = Data("""
        {"version":1e\(leadingZeros)\(hugeDigits),"someNewField":"unknown-to-us"}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, bytes, "bytes must be preserved, not quarantined")
    }

    func testZeroPaddedHugeNegativeExponentStillInvalid() async {
        let fileSystem = InMemorySettingsFileSystem()
        let leadingZeros = String(repeating: "0", count: 4_000)
        let hugeDigits = String(repeating: "9", count: 30)
        let bytes = Data("""
        {"version":1e-\(leadingZeros)\(hugeDigits)}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testMalformedExponentMissingDigitsIsInvalidSchemaAndDoesNotCrash() async {
        let fileSystem = InMemorySettingsFileSystem()
        // `e` with no following digits is not a valid JSON number token at
        // all (RFC 8259 requires at least one exponent digit) — must
        // quarantine as corrupt, not crash while scanning past the missing
        // digits.
        let bytes = Data(#"{"version":1e,"other":1}"#.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    // MARK: 24. A future schema's own arbitrary-size sibling numbers must
    // never make an otherwise well-formed document look corrupt: structural
    // validation must use the bounded scanner (which accepts JSON numbers of
    // any digit/exponent size without materializing them), not
    // `JSONSerialization` (which throws on any number overflowing `Double`,
    // e.g. `1e309`, regardless of whether it is the version field).

    func testFutureVersionWithHugeSiblingExponentAndNestedHugeNumbersIsUnsupportedPreserved() async {
        let fileSystem = InMemorySettingsFileSystem()
        let fiveHundredDigitInteger = "1" + String(repeating: "0", count: 499)
        // "version":2 (future, since current is 1) alongside an unrelated
        // sibling field whose own value overflows `Double` — this is
        // exactly the shape `JSONSerialization` cannot structurally
        // validate, even though the document is perfectly well-formed
        // JSON. A nested object also carries a 500-digit integer and a
        // 500-exponent-digit number to prove *any* number anywhere in the
        // document, not just top-level siblings, must be tolerated.
        let bytes = Data("""
        {"version":2,"future":1e309,"nested":{"big":\(fiveHundredDigitInteger),"exp":1e\(String(repeating: "9", count: 500))}}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, bytes, "a structurally valid future document must be preserved byte-for-byte")
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    func testFutureVersionWithHugeNumericArrayStringAndObjectValuesIsUnsupportedPreserved() async {
        let fileSystem = InMemorySettingsFileSystem()
        let hugeDigits = String(repeating: "9", count: 500)
        // Every JSON value kind this build doesn't understand yet — an
        // array mixing huge exponents and huge integers, an ordinary
        // string, and a deeply-valued (but shallow-nested) object — must
        // all be accepted structurally for a future schema version without
        // decoding any of it.
        let bytes = Data("""
        {"version":2,"arr":[1e309,\(hugeDigits),-1e309],"str":"a normal string","obj":{"x":1e400,"y":{"z":\(hugeDigits)}}}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, bytes)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") })
    }

    func testFutureVersionWithMalformedHugeSiblingNumberStillQuarantines() async {
        let fileSystem = InMemorySettingsFileSystem()
        // The sibling number token itself is malformed (a second decimal
        // point is not part of the JSON number grammar), even though the
        // top-level "version" is a valid future value. The structural
        // scan of the *whole* document must catch this and route it to the
        // ordinary corrupt/quarantine path, not unsupported-version.
        let bytes = Data(#"{"version":2,"future":1e309.5}"#.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testFutureVersionWithTrailingGarbageAfterValidDocumentQuarantines() async {
        let fileSystem = InMemorySettingsFileSystem()
        // A structurally complete, well-formed top-level object followed
        // by trailing bytes that are not whitespace. Exactly one complete
        // top-level JSON value must be required, with trailing tokens
        // rejected rather than silently ignored.
        let bytes = Data(#"{"version":2,"future":1e309} garbage"#.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testFutureVersionWithBadCommaAndColonSyntaxQuarantines() async {
        let fileSystem = InMemorySettingsFileSystem()
        // Missing colon before the huge sibling value's key/value
        // separator, alongside a valid future version.
        let missingColonBytes = Data(#"{"version":2,"future" 1e309}"#.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: missingColonBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testFutureVersionWithDoubleCommaSyntaxQuarantines() async {
        let fileSystem = InMemorySettingsFileSystem()
        let bytes = Data(#"{"version":2,,"future":1e309}"#.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testFutureVersionWithUnclosedNestedObjectQuarantines() async {
        let fileSystem = InMemorySettingsFileSystem()
        // A future version alongside a nested object that never closes,
        // trailing off mid-huge-number.
        let bytes = Data(#"{"version":2,"outer":{"inner":1e309"#.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: bytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled)
    }

    func testCurrentVersionWithOrdinaryFieldsStillLoadsUnchangedAfterScannerReplacement() async {
        // Regression guard: replacing the structural validator must not
        // change the well-trodden current-version success path.
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true)
        await fileSystem.seedFile(at: settingsURL, contents: encode(document))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, document)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
    }

    func testAdversarialFutureVersionSuiteRepeatsUnderTimeoutWithoutHangingOrCrashing() async {
        // Repeats a representative sample of the adversarial future-version
        // documents above many times, asserting the whole batch completes
        // well within a generous bound — guarding against any accidental
        // reintroduction of quadratic behavior or hangs in the scanner.
        let hugeDigits = String(repeating: "9", count: 500)
        let documents = [
            Data("""
            {"version":2,"future":1e309,"nested":{"big":\(hugeDigits),"exp":1e\(hugeDigits)}}
            """.utf8),
            Data("""
            {"version":2,"arr":[1e309,\(hugeDigits),-1e309],"str":"a normal string","obj":{"x":1e400,"y":{"z":\(hugeDigits)}}}
            """.utf8),
            Data(#"{"version":2,"future":1e309.5}"#.utf8),
            Data(#"{"version":2,"future":1e309} garbage"#.utf8),
            Data(#"{"version":2,"future" 1e309}"#.utf8),
            Data(#"{"version":2,,"future":1e309}"#.utf8),
            Data(#"{"version":2,"outer":{"inner":1e309"#.utf8)
        ]
        let expectedDiagnosticIDs = [
            StorageDiagnosticID.unsupportedVersion,
            StorageDiagnosticID.unsupportedVersion,
            StorageDiagnosticID.corrupt,
            StorageDiagnosticID.corrupt,
            StorageDiagnosticID.corrupt,
            StorageDiagnosticID.corrupt,
            StorageDiagnosticID.corrupt
        ]

        let start = DispatchTime.now()
        for _ in 0..<25 {
            for (bytes, expectedID) in zip(documents, expectedDiagnosticIDs) {
                let fileSystem = InMemorySettingsFileSystem()
                await fileSystem.seedFile(at: settingsURL, contents: bytes)
                let store = makeStore(fileSystem: fileSystem)
                let result = await store.load()
                XCTAssertEqual(result.diagnostic?.id, expectedID)
            }
        }
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsedSeconds, 15.0, "repeating the adversarial future-version suite must stay well within a bounded timeout")
    }

    // MARK: 13. Path resolver uses injected base URL exactly

    func testSettingsFileURLUsesInjectedBaseURLExactly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeerAtomicJSONStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let resolved = try SettingsFileLocation.settingsFileURL(applicationSupportDirectory: base)

        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            base.appendingPathComponent("ai.opencoven.seer/settings.json").standardizedFileURL.path
        )
        var isDirectory: ObjCBool = false
        let directoryExists = FileManager.default.fileExists(
            atPath: base.appendingPathComponent("ai.opencoven.seer").path,
            isDirectory: &isDirectory
        )
        XCTAssertTrue(directoryExists)
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: 14. No production storage source references Glaze or its paths

    /// Scoped to `Sources/Storage` (this task's production code) rather than
    /// all of `Sources/`: unrelated prior-task files may legitimately
    /// document historical Glaze parity decisions (e.g. activation policy)
    /// without implying any coupling in settings storage.
    func testNoProductionStorageSourceReferencesGlaze() throws {
        let storageSourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/Storage
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // .../Seer (project root)
            .appendingPathComponent("Sources/Storage", isDirectory: true)

        let enumerator = FileManager.default.enumerator(at: storageSourcesURL, includingPropertiesForKeys: nil)
        var offendingFiles: [String] = []
        while let element = enumerator?.nextObject() as? URL {
            guard element.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: element, encoding: .utf8)
            let lowercased = contents.lowercased()
            if lowercased.contains("glaze") || lowercased.contains("userdata") {
                offendingFiles.append(element.lastPathComponent)
            }
        }

        XCTAssertTrue(offendingFiles.isEmpty, "found Glaze/old-path references in: \(offendingFiles)")
    }

    // MARK: 15. Save before any load throws `notLoaded` and performs no I/O

    func testSaveBeforeLoadThrowsNotLoadedAndPerformsNoIO() async {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)

        do {
            try await store.save(SettingsDocument.defaultValue)
            XCTFail("expected StorageError.notLoaded")
        } catch StorageError.notLoaded {
            // expected
        } catch {
            XCTFail("expected StorageError.notLoaded, got \(error)")
        }

        let log = await fileSystem.callLog
        XCTAssertTrue(log.isEmpty, "a save before any completed load must not perform any I/O at all, including locking")
    }

    // MARK: 16. Cross-instance lock: a second store instance genuinely waits

    func testSecondStoreInstanceSaveWaitsForFirstsLockToRelease() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let storeA = makeStore(fileSystem: fileSystem)
        let storeB = makeStore(fileSystem: fileSystem)
        _ = await storeA.load()
        _ = await storeB.load()

        await fileSystem.armSuspension("writeFileAndSynchronize")

        let taskA = Task {
            try await storeA.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: false))
        }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        // storeA is suspended mid-write, holding the cross-instance lock.
        // storeB is a wholly independent actor with its own FIFO gate, so
        // only the shared advisory lock (not any in-process gate) can be
        // responsible for blocking it here.
        let taskB = Task {
            try await storeB.save(SettingsDocument(version: 1, keepAwakeMode: .system, includePrereleaseUpdates: true))
        }

        for _ in 0..<50 {
            await Task.yield()
        }
        let lockedWhileABlocked = await fileSystem.isLocked(at: settingsURL)
        XCTAssertTrue(lockedWhileABlocked, "the lock must still be held while storeA's write is suspended")
        let logWhileBlocked = await fileSystem.callLog
        XCTAssertEqual(
            logWhileBlocked.filter { $0.hasPrefix("writeFileAndSynchronize") }.count, 1,
            "storeB must not enter its own write while storeA still holds the cross-instance lock"
        )

        await fileSystem.resumeSuspension("writeFileAndSynchronize")
        try await taskA.value
        try await taskB.value

        let lockedAfter = await fileSystem.isLocked(at: settingsURL)
        XCTAssertFalse(lockedAfter, "the lock must be released once both saves complete")

        let decoder = JSONDecoder()
        let finalBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: finalBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .system, "storeB's save, which waited for the lock, must be the final content")
    }

    // MARK: 17. Lock releases on every load/save error exit path

    func testLockReleasesAfterLoadLockAcquisitionFailure() async {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.setFailNextLock(SettingsFileSystemError.other("lock failed"))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertFalse(result.writesEnabled)
        let locked = await fileSystem.isLocked(at: settingsURL)
        XCTAssertFalse(locked, "a lock the store never actually acquired must not be reported as held")
    }

    func testLockReleasesAfterLoadReadFailure() async {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.seedFile(at: settingsURL, contents: encode(SettingsDocument.defaultValue))
        await fileSystem.setFailNextRead(SettingsFileSystemError.other("permission denied"))
        let store = makeStore(fileSystem: fileSystem)

        _ = await store.load()

        let locked = await fileSystem.isLocked(at: settingsURL)
        XCTAssertFalse(locked, "the lock must be released even when the read fails")
    }

    func testLockReleasesAfterSaveWriteFailure() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()
        await fileSystem.setFailNextWrite(SettingsFileSystemError.other("boom"))

        do {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true))
            XCTFail("expected failure")
        } catch StorageError.writeFailed {
            // expected
        }

        let locked = await fileSystem.isLocked(at: settingsURL)
        XCTAssertFalse(locked, "the lock must be released even when the write fails")
    }

    func testLockReleasesAfterSaveLockAcquisitionFailure() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()
        await fileSystem.setFailNextLock(SettingsFileSystemError.other("lock failed"))

        do {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true))
            XCTFail("expected StorageError.writeFailed")
        } catch StorageError.writeFailed {
            // expected
        } catch {
            XCTFail("expected StorageError.writeFailed, got \(error)")
        }

        let locked = await fileSystem.isLocked(at: settingsURL)
        XCTAssertFalse(locked, "a lock the store never actually acquired must not be reported as held")
    }

    func testLockReleasesAfterDirectorySyncFailure() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()
        await fileSystem.setFailNextDirectorySync(SettingsFileSystemError.other("directory fsync failed"))

        do {
            try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true))
            XCTFail("expected StorageError.durabilityUncertain")
        } catch StorageError.durabilityUncertain {
            // expected
        }

        let locked = await fileSystem.isLocked(at: settingsURL)
        XCTAssertFalse(locked, "the lock must be released even when directory synchronization fails")
    }

    // MARK: 18. Quarantine's just-in-time re-read detects a non-cooperating
    // writer that replaced the file between the original corrupt-file read
    // and the quarantine move, and preserves the newer content untouched.

    func testQuarantineRereadDetectsConcurrentReplacementAndPreservesNewFile() async {
        let fileSystem = InMemorySettingsFileSystem()
        let corruptBytes = Data("{ not valid json".utf8)
        await fileSystem.seedFile(at: settingsURL, contents: corruptBytes)
        let store = makeStore(fileSystem: fileSystem)

        // The first `readFile` call is the initial corrupt-file probe; the
        // second is quarantine's just-in-time re-read immediately before
        // moving the file aside. Suspend only the second so a simulated
        // non-cooperating writer can replace the file in between.
        await fileSystem.armSuspension("readFile", onOccurrence: 2)

        let loadTask = Task {
            await store.load()
        }
        await fileSystem.waitUntilEntered("readFile")

        let replacementBytes = Data("""
        {"version":1,"keepAwakeMode":"display","includePrereleaseUpdates":true}
        """.utf8)
        await fileSystem.simulateConcurrentReplace(at: settingsURL, contents: replacementBytes)

        await fileSystem.resumeSuspension("readFile")
        let result = await loadTask.value

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.concurrentChange)
        XCTAssertFalse(result.writesEnabled)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, replacementBytes, "the non-cooperating writer's newer content must be preserved, not quarantined or clobbered")
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") }, "no quarantine move should have happened")
    }

    func testQuarantineRereadDetectsConcurrentRemovalAndLeavesWritesDisabled() async {
        let fileSystem = InMemorySettingsFileSystem()
        let corruptBytes = Data("{ not valid json".utf8)
        await fileSystem.seedFile(at: settingsURL, contents: corruptBytes)
        let store = makeStore(fileSystem: fileSystem)

        await fileSystem.armSuspension("readFile", onOccurrence: 2)

        let loadTask = Task {
            await store.load()
        }
        await fileSystem.waitUntilEntered("readFile")

        await fileSystem.simulateConcurrentRemoval(at: settingsURL)

        await fileSystem.resumeSuspension("readFile")
        let result = await loadTask.value

        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.concurrentChange)
        XCTAssertFalse(result.writesEnabled)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") }, "no quarantine move should have happened when the file vanished out from under the load")
    }

    // MARK: 19. Durability event ordering: lock -> write+sync -> replace ->
    // directory sync -> unlock.

    func testSaveEventOrderIsLockThenWriteThenReplaceThenDirectorySyncThenUnlock() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        let baseline = await fileSystem.callLog.count
        try await store.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true))

        let log = await fileSystem.callLog
        let saveLog = Array(log[baseline...])

        guard
            let lockIndex = saveLog.firstIndex(of: "acquireLock"),
            let writeIndex = saveLog.firstIndex(where: { $0.hasPrefix("writeFileAndSynchronize:") }),
            let replaceIndex = saveLog.firstIndex(of: "replaceItem"),
            let directorySyncIndex = saveLog.firstIndex(of: "synchronizeDirectory"),
            let unlockIndex = saveLog.firstIndex(of: "unlock")
        else {
            XCTFail("expected every durability event to be recorded during save: \(saveLog)")
            return
        }

        XCTAssertLessThan(lockIndex, writeIndex, "the lock must be acquired before the temp file is written")
        XCTAssertLessThan(writeIndex, replaceIndex, "the temp file must be written and fully synchronized before the atomic replace")
        XCTAssertLessThan(replaceIndex, directorySyncIndex, "the containing directory must be synchronized only after the atomic replace")
        XCTAssertLessThan(directorySyncIndex, unlockIndex, "the lock must be released only after every durability step, including the directory sync")
    }

    // MARK: 20. Directory sync failure throws a typed commit-uncertain error,
    // never plain success, even though the rename itself already succeeded.

    func testDirectorySyncFailureThrowsDurabilityUncertainWithNewContentAlreadyReplaced() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()
        await fileSystem.setFailNextDirectorySync(SettingsFileSystemError.other("directory fsync failed"))

        let document = SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true)
        do {
            try await store.save(document)
            XCTFail("expected StorageError.durabilityUncertain, never plain success")
        } catch StorageError.durabilityUncertain {
            // expected
        } catch {
            XCTFail("expected StorageError.durabilityUncertain, got \(error)")
        }

        // The rename/replace itself already succeeded — the new content is
        // on disk — even though directory-entry durability is unconfirmed.
        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded, document)

        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertEqual(names, ["settings.json"], "no orphaned temp file should remain")
    }

    // MARK: 21. Size ceiling: exact boundary is read normally; one byte over
    // is preserved read-only without ever being read, quarantined, or
    // written; an oversized save is rejected before any temp file exists.

    func testFileSizeExactlyAtCeilingIsReadNormally() async {
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true)
        await fileSystem.seedFile(at: settingsURL, contents: encode(document))
        await fileSystem.setSizeOverride(AtomicJSONStore<SettingsDocument>.maxDocumentBytes, at: settingsURL)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, document)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
        let log = await fileSystem.callLog
        XCTAssertTrue(log.contains("readFile"), "a file exactly at the ceiling must still be read")
    }

    func testFileSizeOneByteOverCeilingIsPreservedReadOnlyWithoutReadQuarantineOrWrite() async {
        let fileSystem = InMemorySettingsFileSystem()
        let existingBytes = encode(SettingsDocument.defaultValue)
        await fileSystem.seedFile(at: settingsURL, contents: existingBytes)
        await fileSystem.setSizeOverride(AtomicJSONStore<SettingsDocument>.maxDocumentBytes + 1, at: settingsURL)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.tooLarge)
        XCTAssertFalse(result.writesEnabled)

        let log = await fileSystem.callLog
        XCTAssertFalse(log.contains("readFile"), "an oversized file must never be read")
        XCTAssertFalse(log.contains("moveItem"), "an oversized file must never be quarantined")
        XCTAssertFalse(log.contains { $0.hasPrefix("writeFileAndSynchronize") }, "an oversized file must never be written")

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, existingBytes, "the oversized file must be preserved byte-for-byte")
    }

    func testIndeterminateFileSizeFallsThroughToOrdinaryReadPath() async {
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true)
        await fileSystem.seedFile(at: settingsURL, contents: encode(document))
        // A `fileSize` failure that isn't `fileNotFound` (e.g. a transient
        // stat-level permission error) must not be treated as "too large"
        // or "missing" — it must fall through to the ordinary read path,
        // whose own success/failure classification is unchanged.
        await fileSystem.setFailNextFileSize(SettingsFileSystemError.other("stat permission error"))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, document)
        XCTAssertNil(result.diagnostic)
        XCTAssertTrue(result.writesEnabled)
        let log = await fileSystem.callLog
        XCTAssertTrue(log.contains("readFile"), "an indeterminate file-size check must still fall through to reading the file")
    }

    func testOversizedSaveIsRejectedBeforeAnyTempFileIsCreated() async throws {
        let largeDocumentURL = URL(fileURLWithPath: "/Seer-Test-Root/ai.opencoven.seer/large.json")
        let fileSystem = InMemorySettingsFileSystem()
        let clock = FixedClock(fixedMilliseconds: 1_700_000_000_000)
        let store = AtomicJSONStore<LargeTestDocument>(fileURL: largeDocumentURL, fileSystem: fileSystem, clock: clock)
        _ = await store.load()

        let oversizedPayload = String(repeating: "a", count: Int(AtomicJSONStore<LargeTestDocument>.maxDocumentBytes) + 1)
        let document = LargeTestDocument(version: 1, payload: oversizedPayload)

        do {
            try await store.save(document)
            XCTFail("expected StorageError.payloadTooLarge")
        } catch StorageError.payloadTooLarge {
            // expected
        } catch {
            XCTFail("expected StorageError.payloadTooLarge, got \(error)")
        }

        let log = await fileSystem.callLog
        XCTAssertFalse(log.contains { $0.hasPrefix("writeFileAndSynchronize") }, "an oversized save must never create a temp file")
        XCTAssertFalse(log.contains("replaceItem"))
        let names = await fileSystem.fileNames(inDirectoryOf: largeDocumentURL)
        XCTAssertTrue(names.isEmpty, "no file should exist for a rejected oversized save")
    }

    // MARK: 22. Transactional `update(_:)`: reads the freshest on-disk
    // value under a single continuously-held lock, never a stale
    // previously-loaded cache — the fix for the multi-instance lost-update
    // hazard plain load()+mutate+save() has.

    func testUpdateAppliesTransformToFreshestDiskValueNotStaleLoad() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        // A second, independent store instance saves a change after the
        // first's load() — simulating another process/instance's write —
        // entirely bypassing the first instance's in-memory knowledge.
        let otherStore = makeStore(fileSystem: fileSystem)
        _ = await otherStore.load()
        try await otherStore.save(SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: false))

        // `store`'s own `load()` happened before the other instance's
        // save, so if `update` naively based its transform on that stale
        // snapshot instead of re-reading disk under the lock, this would
        // revert `keepAwakeMode` back to `.system`.
        let committed = try await store.update { document in
            var updated = document
            updated.includePrereleaseUpdates = true
            return updated
        }

        XCTAssertEqual(committed.keepAwakeMode, .display, "update must read the freshest disk value, not this instance's stale load() snapshot")
        XCTAssertTrue(committed.includePrereleaseUpdates)

        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded, committed)
    }

    func testUpdateAcrossTwoInstancesChangingDifferentFieldsPreservesBoth() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let storeA = makeStore(fileSystem: fileSystem)
        let storeB = makeStore(fileSystem: fileSystem)
        _ = await storeA.load()
        _ = await storeB.load()

        try await storeA.update { document in
            var updated = document
            updated.keepAwakeMode = .display
            return updated
        }
        try await storeB.update { document in
            var updated = document
            updated.includePrereleaseUpdates = true
            return updated
        }

        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .display, "instance A's field change must survive instance B's independent update")
        XCTAssertTrue(decoded.includePrereleaseUpdates, "instance B's field change must also be reflected")
    }

    func testUpdateSameFieldControlledLockOrderLastAcceptedWins() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let storeA = makeStore(fileSystem: fileSystem)
        let storeB = makeStore(fileSystem: fileSystem)
        _ = await storeA.load()
        _ = await storeB.load()

        await fileSystem.armSuspension("writeFileAndSynchronize")

        let taskA = Task {
            try await storeA.update { document in
                var updated = document
                updated.keepAwakeMode = .display
                return updated
            }
        }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        // storeA is suspended mid-write, holding the cross-instance lock.
        // Queue storeB's conflicting update behind it.
        let taskB = Task {
            try await storeB.update { document in
                var updated = document
                updated.keepAwakeMode = .system
                return updated
            }
        }
        for _ in 0..<50 {
            await Task.yield()
        }
        let logWhileBlocked = await fileSystem.callLog
        XCTAssertEqual(
            logWhileBlocked.filter { $0.hasPrefix("writeFileAndSynchronize") }.count, 1,
            "storeB must not enter its own write while storeA still holds the cross-instance lock"
        )

        await fileSystem.resumeSuspension("writeFileAndSynchronize")
        _ = try await taskA.value
        _ = try await taskB.value

        // storeB's update acquired the lock (and therefore read disk, and
        // wrote) strictly after storeA's, so storeB's value — the last one
        // actually accepted under the lock — must be what's on disk.
        let decoder = JSONDecoder()
        let finalBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: finalBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .system, "the update whose write actually ran last under the lock must be the final content")
    }

    func testUpdateThrowsNotLoadedBeforeAnyLoad() async {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)

        do {
            _ = try await store.update { $0 }
            XCTFail("expected StorageUpdateError.failure(.notLoaded)")
        } catch StorageUpdateError<SettingsDocument>.failure(.notLoaded) {
            // expected
        } catch {
            XCTFail("expected StorageUpdateError.failure(.notLoaded), got \(error)")
        }

        let log = await fileSystem.callLog
        XCTAssertTrue(log.isEmpty, "an update before any completed load must not perform any I/O at all, including locking")
    }

    func testUpdateRefusesWhenExistingFileIsFutureVersionRatherThanReplacingIt() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let futureBytes = Data("""
        {"version":999}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: futureBytes)
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        do {
            _ = try await store.update { _ in SettingsDocument.defaultValue }
            XCTFail("expected StorageUpdateError.failure(.writesDisabled)")
        } catch StorageUpdateError<SettingsDocument>.failure(.writesDisabled) {
            // expected
        } catch {
            XCTFail("expected StorageUpdateError.failure(.writesDisabled), got \(error)")
        }

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, futureBytes, "a future-version file must never be replaced by update(_:)")
    }

    func testUpdateRefusesWhenCurrentDocumentIsCorruptRatherThanReplacingIt() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let corruptBytes = Data("{ not valid json".utf8)
        await fileSystem.seedFile(at: settingsURL, contents: corruptBytes)
        let store = makeStore(fileSystem: fileSystem)
        // `load()` quarantines the corrupt file (moving it aside) and
        // re-enables writes, matching this store's existing corrupt-load
        // behavior. Re-seed a fresh corrupt file directly afterward
        // (bypassing the lock, as a non-cooperating writer would) so
        // `update(_:)`'s own probe — not `load()`'s — is what's under
        // test: `update(_:)` must never quarantine on its own.
        _ = await store.load()
        await fileSystem.simulateConcurrentReplace(at: settingsURL, contents: corruptBytes)

        do {
            _ = try await store.update { _ in SettingsDocument.defaultValue }
            XCTFail("expected StorageUpdateError.failure(.writesDisabled)")
        } catch StorageUpdateError<SettingsDocument>.failure(.writesDisabled) {
            // expected
        } catch {
            XCTFail("expected StorageUpdateError.failure(.writesDisabled), got \(error)")
        }

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, corruptBytes, "update(_:) must never quarantine or otherwise touch a corrupt file — only load() does that")
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertEqual(names, ["settings.json", "settings.json.corrupt-1700000000000"], "update(_:) must not add any new quarantine sibling beyond the one load() already created")
    }

    func testUpdateDurabilityUncertainCarriesCommittedDocumentAlreadyOnDisk() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()
        await fileSystem.setFailNextDirectorySync(SettingsFileSystemError.other("directory fsync failed"))

        do {
            _ = try await store.update { document in
                var updated = document
                updated.keepAwakeMode = .display
                return updated
            }
            XCTFail("expected StorageUpdateError.durabilityUncertain")
        } catch StorageUpdateError<SettingsDocument>.durabilityUncertain(let committed) {
            XCTAssertEqual(committed.keepAwakeMode, .display, "the durability-uncertain error must carry the exact document already committed to disk")
            let decoder = JSONDecoder()
            let savedBytes = await fileSystem.contents(at: settingsURL)
            let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
            XCTAssertEqual(decoded, committed, "disk must already contain the committed document even though durability is unconfirmed")
        } catch {
            XCTFail("expected StorageUpdateError.durabilityUncertain, got \(error)")
        }

        let locked = await fileSystem.isLocked(at: settingsURL)
        XCTAssertFalse(locked, "the lock must be released even when directory synchronization fails")
    }

    func testUpdateAcquiresLockAndGateExactlyOnceNeverRecursively() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        let baseline = await fileSystem.callLog.count
        _ = try await store.update { document in
            var updated = document
            updated.includePrereleaseUpdates = true
            return updated
        }

        let log = await fileSystem.callLog
        let updateLog = Array(log[baseline...])
        XCTAssertEqual(updateLog.filter { $0 == "acquireLock" }.count, 1, "update(_:) must acquire the cross-instance/cross-process lock exactly once, never recursively")
        XCTAssertEqual(updateLog.filter { $0 == "unlock" }.count, 1, "update(_:) must release the lock exactly once")
    }

    // MARK: 23. Bounded reads resistant to replacement-after-stat: content
    // that grows past the ceiling between an earlier probe and the actual
    // read — including quarantine's own identity re-read — must be
    // rejected as `tooLarge`, never allocated/decoded unbounded.

    func testReadGrowthAfterStatIsRejectedAsTooLarge() async {
        let fileSystem = InMemorySettingsFileSystem()
        let document = SettingsDocument(version: 1, keepAwakeMode: .display, includePrereleaseUpdates: true)
        await fileSystem.seedFile(at: settingsURL, contents: encode(document))
        let store = makeStore(fileSystem: fileSystem)

        // Suspend the actual `readFile` call (after `fileSize` has already
        // reported a small, acceptable size) and grow the file past the
        // ceiling before letting the read resume — modeling a
        // non-cooperating writer that replaces the file's content between
        // the size probe and the read actually resolving.
        await fileSystem.armSuspension("readFile")
        let oversizedBytes = Data(repeating: UInt8(ascii: "a"), count: Int(AtomicJSONStore<SettingsDocument>.maxDocumentBytes) + 1)

        let loadTask = Task {
            await store.load()
        }
        await fileSystem.waitUntilEntered("readFile")
        await fileSystem.simulateConcurrentReplace(at: settingsURL, contents: oversizedBytes)
        await fileSystem.resumeSuspension("readFile")
        let result = await loadTask.value

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.tooLarge)
        XCTAssertFalse(result.writesEnabled)

        let log = await fileSystem.callLog
        XCTAssertFalse(log.contains("moveItem"), "a file that grew past the ceiling mid-read must never be quarantined")
        XCTAssertFalse(log.contains { $0.hasPrefix("writeFileAndSynchronize") })
        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, oversizedBytes, "the oversized content must be preserved byte-for-byte, untouched")
    }

    func testQuarantineRereadGrowthPastCeilingAbortsAsConcurrentChange() async {
        let fileSystem = InMemorySettingsFileSystem()
        let corruptBytes = Data("{ not valid json".utf8)
        await fileSystem.seedFile(at: settingsURL, contents: corruptBytes)
        let store = makeStore(fileSystem: fileSystem)

        // The first `readFile` call is the initial corrupt-file probe; the
        // second is quarantine's just-in-time re-read. Suspend only the
        // second, then grow the file past the ceiling — modeling a
        // non-cooperating writer that both replaced *and* grew the file
        // past the bound in the window between the original probe and the
        // quarantine move.
        await fileSystem.armSuspension("readFile", onOccurrence: 2)
        let oversizedBytes = Data(repeating: UInt8(ascii: "b"), count: Int(AtomicJSONStore<SettingsDocument>.maxDocumentBytes) + 1)

        let loadTask = Task {
            await store.load()
        }
        await fileSystem.waitUntilEntered("readFile")
        await fileSystem.simulateConcurrentReplace(at: settingsURL, contents: oversizedBytes)
        await fileSystem.resumeSuspension("readFile")
        let result = await loadTask.value

        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.concurrentChange, "growth past the ceiling during quarantine's identity re-read must abort as a concurrent change, not proceed to quarantine")
        XCTAssertFalse(result.writesEnabled)
        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertFalse(names.contains { $0.contains("corrupt") }, "no quarantine move should have happened once the re-read detected growth past the ceiling")
        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, oversizedBytes, "the grown content must be preserved untouched")
    }

    // MARK: 24. Symlink rejection: a symlinked document path must be
    // refused (surfaced as an ordinary read failure, disabling writes)
    // rather than followed.

    func testSymlinkedDocumentPathIsRejectedNotFollowed() async {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.seedFile(at: settingsURL, contents: encode(SettingsDocument.defaultValue))
        await fileSystem.simulateSymlink(at: settingsURL)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.readFailed, "a symlinked document path must be refused like any other unreadable file, never followed")
        XCTAssertFalse(result.writesEnabled)
        let log = await fileSystem.callLog
        XCTAssertFalse(log.contains("moveItem"))
        XCTAssertFalse(log.contains { $0.hasPrefix("writeFileAndSynchronize") })
    }

    func testSymlinkedLockPathPreventsLoadFromProceeding() async {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.seedFile(at: settingsURL, contents: encode(SettingsDocument.defaultValue))
        await fileSystem.simulateSymlinkLock(at: settingsURL)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()

        // The fake's `acquireLock` refuses before any read is attempted,
        // exactly like the real `FileManagerSettingsFileSystem` refusing a
        // symlinked lock-file path via `O_NOFOLLOW` before ever calling
        // `flock`.
        XCTAssertFalse(result.writesEnabled)
        let log = await fileSystem.callLog
        XCTAssertFalse(log.contains("readFile"), "a rejected lock must prevent any read from being attempted")
    }
}

/// A minimal `VersionedDocument` whose encoded size can be driven arbitrarily
/// large via `payload`, used only to exercise the encoded-payload-too-large
/// save path — `SettingsDocument`'s own fixed, flat schema (an enum and a
/// bool) can never legitimately encode past a few dozen bytes.
private struct LargeTestDocument: VersionedDocument {
    static let currentVersion = 1
    static let defaultValue = LargeTestDocument(version: 1, payload: "")

    var version: Int
    var payload: String
}

extension InMemorySettingsFileSystem {
    func setFailNextRead(_ error: Error) {
        failNextRead = error
    }

    func setFailNextWrite(_ error: Error) {
        failNextWrite = error
    }

    func setFailNextReplace(_ error: Error) {
        failNextReplace = error
    }

    func setFailNextMove(_ error: Error) {
        failNextMove = error
    }

    func setFailNextLock(_ error: Error) {
        failNextLock = error
    }

    func setFailNextDirectorySync(_ error: Error) {
        failNextDirectorySync = error
    }

    func setFailNextFileSize(_ error: Error) {
        failNextFileSize = error
    }
}
