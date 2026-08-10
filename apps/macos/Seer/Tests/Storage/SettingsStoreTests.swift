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
}
