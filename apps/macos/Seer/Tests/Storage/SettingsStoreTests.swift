import XCTest
@testable import Seer

final class SettingsStoreTests: XCTestCase {
    private let settingsURL = URL(fileURLWithPath: "/Seer-Test-Root/ai.opencoven.seer/settings.json")

    private func makeSettingsStore(
        fileSystem: InMemorySettingsFileSystem,
        clock: Clock = FixedClock(fixedMilliseconds: 1_700_000_000_000)
    ) -> SettingsStore {
        let atomicStore = AtomicJSONStore<SettingsDocument>(fileURL: settingsURL, fileSystem: fileSystem, clock: clock)
        return SettingsStore(store: atomicStore)
    }

    func testLoadPublishesDefaultsWhenNoFileExists() async {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)

        let result = await store.load()

        XCTAssertEqual(result.value, SettingsDocument.defaultValue)
        let current = await store.current
        XCTAssertEqual(current, SettingsDocument.defaultValue)
        let diagnostic = await store.lastDiagnostic
        XCTAssertNil(diagnostic)
    }

    func testSetKeepAwakeModePersistsBeforePublishing() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)
        _ = await store.load()

        try await store.setKeepAwakeMode(.display)

        let current = await store.current
        XCTAssertEqual(current.keepAwakeMode, .display)

        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .display)
    }

    func testSetIncludePrereleaseUpdatesPersistsBeforePublishing() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)
        _ = await store.load()

        try await store.setIncludePrereleaseUpdates(true)

        let current = await store.current
        XCTAssertTrue(current.includePrereleaseUpdates)

        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertTrue(decoded.includePrereleaseUpdates)
    }

    // MARK: 12. Failed mutation does not change cache

    func testFailedMutationDoesNotChangeCache() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)
        _ = await store.load()

        let before = await store.current
        XCTAssertEqual(before, SettingsDocument.defaultValue)

        await fileSystem.setFailNextWrite(SettingsFileSystemError.other("disk full"))

        do {
            try await store.setKeepAwakeMode(.display)
            XCTFail("expected save to throw")
        } catch StorageError.writeFailed {
            // expected
        }

        let after = await store.current
        XCTAssertEqual(after, before, "cache must remain unchanged when the underlying save fails")
        XCTAssertEqual(after.keepAwakeMode, .system)
    }

    func testFailedMutationWhenWritesDisabledDoesNotChangeCache() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let futureBytes = Data("""
        {"version":999}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: futureBytes)
        let store = makeSettingsStore(fileSystem: fileSystem)
        _ = await store.load()

        let before = await store.current
        do {
            try await store.setIncludePrereleaseUpdates(true)
            XCTFail("expected StorageError.writesDisabled")
        } catch StorageError.writesDisabled {
            // expected
        }

        let after = await store.current
        XCTAssertEqual(after, before)

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, futureBytes)
    }

    // MARK: 11. Concurrent/rapid mutations serialize; final cache matches last accepted mutation

    func testConcurrentMutationsSerializeAndFinalCacheMatchesLastAcceptedMutation() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)
        _ = await store.load()

        // The actor serializes these calls to its own in-order queue, so the
        // last task to actually run wins. We assert on internal consistency
        // (cache matches disk, decodable, current version) rather than a
        // specific interleaving, since task-group scheduling order isn't
        // guaranteed even though the actor applies them one at a time.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for iteration in 0..<20 {
                group.addTask {
                    try await store.setIncludePrereleaseUpdates(iteration % 2 == 0)
                }
            }
            try await group.waitForAll()
        }

        let current = await store.current
        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)

        XCTAssertEqual(decoded, current, "on-disk file must match the actor's published cache after all mutations settle")
        XCTAssertEqual(decoded.version, SettingsDocument.currentVersion)

        let names = await fileSystem.fileNames(inDirectoryOf: settingsURL)
        XCTAssertEqual(names, ["settings.json"], "no leftover temp files after concurrent mutations")
    }

    // MARK: 13. FIFO gate ordering at the SettingsStore layer itself — a
    // queued mutation must not enter the filesystem (or publish `current`)
    // until a prior in-flight mutation's write completes and releases.

    func testQueuedMutationDoesNotEnterFilesystemUntilPriorMutationReleases() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)
        _ = await store.load()

        await fileSystem.armSuspension("writeFileAndSynchronize")

        let taskA = Task {
            try await store.setKeepAwakeMode(.display)
        }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        // A is suspended inside its write, holding SettingsStore's gate.
        // Queue B behind it.
        let taskB = Task {
            try await store.setIncludePrereleaseUpdates(true)
        }

        for _ in 0..<50 {
            await Task.yield()
        }
        let logWhileABlocked = await fileSystem.callLog
        XCTAssertEqual(
            logWhileABlocked.filter { $0.hasPrefix("writeFileAndSynchronize") }.count, 1,
            "queued mutation B must not enter the filesystem while mutation A still holds the gate"
        )
        let currentWhileABlocked = await store.current
        XCTAssertEqual(
            currentWhileABlocked, SettingsDocument.defaultValue,
            "cache must not reflect either mutation until each is actually applied in order"
        )

        await fileSystem.resumeSuspension("writeFileAndSynchronize")
        try await taskA.value
        try await taskB.value

        let finalLog = await fileSystem.callLog
        XCTAssertEqual(finalLog.filter { $0.hasPrefix("writeFileAndSynchronize") }.count, 2)

        let current = await store.current
        XCTAssertEqual(current.keepAwakeMode, .display, "A's mutation must still be reflected")
        XCTAssertTrue(current.includePrereleaseUpdates, "B's mutation must be reflected")

        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded, current, "disk must match the published cache")
    }

    // MARK: 14. A failed first queued mutation still releases the gate for
    // the next queued mutation, and does not corrupt the cache.

    func testFailedFirstQueuedMutationReleasesNextQueuedMutation() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)
        _ = await store.load()

        await fileSystem.armSuspension("writeFileAndSynchronize")

        let taskA = Task {
            try await store.setKeepAwakeMode(.display)
        }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        let taskB = Task {
            try await store.setIncludePrereleaseUpdates(true)
        }

        await fileSystem.setFailNextWrite(SettingsFileSystemError.other("boom"))
        await fileSystem.resumeSuspension("writeFileAndSynchronize")

        do {
            try await taskA.value
            XCTFail("expected mutation A to throw")
        } catch StorageError.writeFailed {
            // expected
        }

        // B must still be released and able to proceed even though A failed.
        try await taskB.value

        let current = await store.current
        XCTAssertEqual(current.keepAwakeMode, .system, "A's failed mutation must not be reflected")
        XCTAssertTrue(current.includePrereleaseUpdates, "B's mutation must still apply")
    }

    // MARK: 15. A mutator called with no prior explicit `load()` performs its
    // own internal load first (inside the same FIFO gate), so a missing file
    // is loaded as defaults and saved, while an existing future-version file
    // is correctly honored as read-only rather than silently overwritten.

    func testMutationWithoutPriorExplicitLoadLoadsDefaultsThenSavesWhenFileIsMissing() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)

        try await store.setKeepAwakeMode(.display)

        let current = await store.current
        XCTAssertEqual(current.keepAwakeMode, .display)

        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .display)
    }

    func testMutationWithoutPriorExplicitLoadHonorsExistingFutureVersionFileAsReadOnly() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let futureBytes = Data("""
        {"version":999}
        """.utf8)
        await fileSystem.seedFile(at: settingsURL, contents: futureBytes)
        let store = makeSettingsStore(fileSystem: fileSystem)

        do {
            try await store.setKeepAwakeMode(.display)
            XCTFail("expected StorageError.writesDisabled")
        } catch StorageError.writesDisabled {
            // expected
        }

        let preserved = await fileSystem.contents(at: settingsURL)
        XCTAssertEqual(preserved, futureBytes, "a future-version file must never be overwritten by a mutation with no prior explicit load()")

        let current = await store.current
        XCTAssertEqual(current, SettingsDocument.defaultValue, "the in-memory cache must reflect the internal load's defaults, not silently claim the mutation applied")
    }
}
