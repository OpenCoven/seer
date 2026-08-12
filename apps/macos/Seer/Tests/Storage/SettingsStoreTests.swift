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

    // MARK: 16. Multi-instance lost update: two independently loaded
    // `SettingsStore`s, each with their own stale in-memory `current`
    // cache, must not clobber each other's on-disk changes when they
    // mutate different fields — the transactional `AtomicJSONStore.update`
    // fix for the classic load-mutate-save race.

    func testTwoInstancesMutatingDifferentFieldsPreserveBothChanges() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let storeA = makeSettingsStore(fileSystem: fileSystem)
        let storeB = makeSettingsStore(fileSystem: fileSystem)
        _ = await storeA.load()
        _ = await storeB.load()

        // Both instances loaded before either wrote anything, so each
        // instance's own `current` cache is the stale default document —
        // exactly the setup that would silently lose one instance's
        // change under a naive load-then-mutate-then-save
        // implementation.
        try await storeA.setKeepAwakeMode(.display)
        try await storeB.setIncludePrereleaseUpdates(true)

        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .display, "instance A's change must survive instance B's independent mutation")
        XCTAssertTrue(decoded.includePrereleaseUpdates, "instance B's change must also be reflected")

        // Instance B ran its update after A's had already committed, so
        // B's transform read A's committed change from disk and B's own
        // published cache reflects both fields — the merged final state.
        // Instance A's own cache reflects exactly what *it* committed at
        // the time it wrote (before B's later, independent mutation);
        // requiring it to omnisciently reflect a write that hadn't
        // happened yet would be the wrong bar. Confirming B's cache here
        // is the meaningful assertion: it's the one whose transform ran
        // second, so it's the one that could have clobbered A's change if
        // this fix weren't in place.
        let currentB = await storeB.current
        XCTAssertEqual(currentB, decoded, "instance B's cache must match the merged on-disk document it actually wrote")
    }

    func testTwoInstancesMutatingSameFieldControlledLockOrderLastAcceptedWins() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let storeA = makeSettingsStore(fileSystem: fileSystem)
        let storeB = makeSettingsStore(fileSystem: fileSystem)
        _ = await storeA.load()
        _ = await storeB.load()

        await fileSystem.armSuspension("writeFileAndSynchronize")

        let taskA = Task {
            try await storeA.setKeepAwakeMode(.display)
        }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        // storeA is suspended mid-write, holding the cross-instance lock.
        // Queue storeB's conflicting mutation of the very same field
        // behind it.
        let taskB = Task {
            try await storeB.setKeepAwakeMode(.system)
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
        try await taskA.value
        try await taskB.value

        // storeB's write actually ran last under the lock, so its value —
        // not storeA's — must be the final on-disk and published state.
        let decoder = JSONDecoder()
        let savedBytes = await fileSystem.contents(at: settingsURL)
        let decoded = try decoder.decode(SettingsDocument.self, from: savedBytes!)
        XCTAssertEqual(decoded.keepAwakeMode, .system)

        let currentB = await storeB.current
        XCTAssertEqual(currentB.keepAwakeMode, .system)
    }

    // MARK: 17. `durabilityUncertain` cache semantics: when the directory
    // sync following a successful rename fails, the new document is
    // already durably on disk. `current`/disk must reflect that committed
    // value even though `durabilityUncertain` is thrown — never silently
    // reverted — and the next mutation must build on top of it.

    func testDurabilityUncertainPublishesCommittedValueThenNextMutationPreservesIt() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeSettingsStore(fileSystem: fileSystem)
        _ = await store.load()

        await fileSystem.setFailNextDirectorySync(SettingsFileSystemError.other("directory fsync failed"))

        do {
            try await store.setKeepAwakeMode(.display)
            XCTFail("expected StorageError.durabilityUncertain")
        } catch StorageError.durabilityUncertain {
            // expected
        }

        // Even though the first mutation threw, its change was already
        // durably committed to disk (the rename succeeded) — the cache
        // must reflect that, not silently revert to the pre-mutation
        // default.
        let afterFirstMutation = await store.current
        XCTAssertEqual(afterFirstMutation.keepAwakeMode, .display, "the cache must publish the value already committed to disk, not revert it")

        let decoder = JSONDecoder()
        let bytesAfterFirst = await fileSystem.contents(at: settingsURL)
        let decodedAfterFirst = try decoder.decode(SettingsDocument.self, from: bytesAfterFirst!)
        XCTAssertEqual(decodedAfterFirst.keepAwakeMode, .display, "disk must already contain the committed change")

        // A second, ordinary mutation must build on top of the committed
        // value — preserving the first field's change while applying the
        // second — never reverting field one back to its pre-mutation
        // default.
        try await store.setIncludePrereleaseUpdates(true)

        let afterSecondMutation = await store.current
        XCTAssertEqual(afterSecondMutation.keepAwakeMode, .display, "the first mutation's committed field must survive the second mutation")
        XCTAssertTrue(afterSecondMutation.includePrereleaseUpdates, "the second mutation's own field must also apply")

        let bytesAfterSecond = await fileSystem.contents(at: settingsURL)
        let decodedAfterSecond = try decoder.decode(SettingsDocument.self, from: bytesAfterSecond!)
        XCTAssertEqual(decodedAfterSecond, afterSecondMutation, "disk must match the published cache after the second mutation")
    }
}
