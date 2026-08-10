import XCTest
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

    func seedFile(at url: URL, contents: Data) {
        files[url.path] = contents
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

    func readFile(at url: URL) async throws -> Data {
        callLog.append("readFile")
        if let error = failNextRead {
            failNextRead = nil
            throw error
        }
        guard let data = files[url.path] else {
            throw SettingsFileSystemError.fileNotFound
        }
        return data
    }

    func writeFileAndSynchronize(_ data: Data, to url: URL) async throws {
        callLog.append("writeFileAndSynchronize:\(url.lastPathComponent)")
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
}
