import XCTest
@testable import Seer

/// Exercises `StorageBootstrap.resolveLocations(applicationSupportDirectory:
/// now:makeTemporaryFallbackDirectory:settingsFileURL:historyFileURL:)`
/// directly against a *real* (never mocked) filesystem failure: a plain
/// file is placed exactly where `SettingsFileLocation`/`HistoryFileLocation`
/// would need to create their shared `ai.opencoven.seer` directory, so
/// `FileManager.createDirectory(at:withIntermediateDirectories:)` genuinely
/// throws — reproducing Task 12's finding (a storage-setup directory-
/// creation failure) without any protocol/mock indirection standing in for
/// the real failure mode.
final class StorageBootstrapTests: XCTestCase {
    private var scratchDirectories: [URL] = []

    override func tearDown() {
        for directory in scratchDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories = []
        super.tearDown()
    }

    /// Creates a fresh, empty scratch directory under the real temporary
    /// directory, tracked for cleanup in `tearDown()`.
    private func makeScratchDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        return directory
    }

    /// Blocks `SettingsFileLocation`/`HistoryFileLocation`'s shared
    /// `ai.opencoven.seer` directory from ever being created under
    /// `applicationSupportDirectory`, by placing a plain *file* at that
    /// exact path — `FileManager.createDirectory(at:withIntermediateDirectories:)`
    /// genuinely throws when a non-directory already occupies the target
    /// path, so `SettingsFileLocation.settingsFileURL`/
    /// `HistoryFileLocation.historyFileURL` both fail for real, with no
    /// mocking involved at all.
    private func blockStorageDirectory(under applicationSupportDirectory: URL) {
        let blockingFilePath = applicationSupportDirectory
            .appendingPathComponent(SettingsFileLocation.directoryName, isDirectory: false)
        FileManager.default.createFile(atPath: blockingFilePath.path, contents: Data())
    }

    // MARK: - Primary directory succeeds

    func testPrimaryDirectorySucceedsWithNoDiagnostics() {
        let applicationSupportDirectory = makeScratchDirectory()

        let result = StorageBootstrap.resolveLocations(applicationSupportDirectory: applicationSupportDirectory, now: 1_700_000_000_000)

        switch result {
        case .success(let locations):
            XCTAssertEqual(locations.settingsURL.deletingLastPathComponent(), locations.historyURL.deletingLastPathComponent())
            XCTAssertTrue(locations.settingsURL.path.hasPrefix(applicationSupportDirectory.path))
            XCTAssertEqual(locations.diagnostics, [], "no fallback was needed, so no diagnostic should be recorded")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    // MARK: - Primary directory fails, temporary fallback recovers (the actual failure branch)

    /// Reproduces the actual failure branch this fix closes: the real,
    /// already-resolved Application Support directory cannot yield a
    /// usable settings/history location at all (directory creation
    /// genuinely fails), so `resolveLocations` must retry once against a
    /// dedicated temporary fallback directory and still succeed — folding
    /// the retry into a visible diagnostic rather than returning nothing
    /// and leaving bootstrap to silently abandon the launch.
    func testPrimaryDirectoryFailureFallsBackToTemporaryDirectoryAndSucceeds() {
        let applicationSupportDirectory = makeScratchDirectory()
        blockStorageDirectory(under: applicationSupportDirectory)

        let fallbackDirectory = makeScratchDirectory()
            .appendingPathComponent("fallback", isDirectory: true)

        let result = StorageBootstrap.resolveLocations(
            applicationSupportDirectory: applicationSupportDirectory,
            now: 1_700_000_000_000,
            makeTemporaryFallbackDirectory: { fallbackDirectory }
        )

        switch result {
        case .success(let locations):
            XCTAssertTrue(
                locations.settingsURL.path.hasPrefix(fallbackDirectory.path),
                "settings must be relocated under the dedicated temporary fallback directory"
            )
            XCTAssertTrue(
                locations.historyURL.path.hasPrefix(fallbackDirectory.path),
                "history must be relocated under the dedicated temporary fallback directory"
            )
            XCTAssertEqual(locations.diagnostics.count, 1)
            XCTAssertEqual(locations.diagnostics.first?.id, AppBootstrapDiagnosticID.storageLocationUnresolved)
            XCTAssertEqual(locations.diagnostics.first?.occurredAt, 1_700_000_000_000)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackDirectory.appendingPathComponent(SettingsFileLocation.directoryName).path))
        case .failure(let error):
            XCTFail("expected the temporary fallback to recover, got \(error)")
        }
    }

    // MARK: - Both the primary and the fallback fail

    /// The truly-unrecoverable case: even the dedicated temporary fallback
    /// directory cannot yield a usable settings/history location (also
    /// blocked by a real file at that path). `resolveLocations` must
    /// return `.failure` rather than ever synthesizing a location that
    /// doesn't actually work — this is what `bootstrapProduction()` uses
    /// to decide it must terminate cleanly instead of continuing silently.
    func testBothPrimaryAndTemporaryFallbackFailingReturnsFailure() {
        let applicationSupportDirectory = makeScratchDirectory()
        blockStorageDirectory(under: applicationSupportDirectory)

        let fallbackParent = makeScratchDirectory()
        let fallbackDirectory = fallbackParent.appendingPathComponent("fallback", isDirectory: true)
        try! FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
        blockStorageDirectory(under: fallbackDirectory)

        let result = StorageBootstrap.resolveLocations(
            applicationSupportDirectory: applicationSupportDirectory,
            now: 1_700_000_000_000,
            makeTemporaryFallbackDirectory: { fallbackDirectory }
        )

        switch result {
        case .success:
            XCTFail("expected failure when both the primary and the fallback directory cannot be prepared")
        case .failure:
            break
        }
    }

    // MARK: - Fallback directory naming

    func testDefaultTemporaryFallbackDirectoryIsUniquelyNamedUnderTheRealTemporaryDirectory() {
        let applicationSupportDirectory = makeScratchDirectory()
        blockStorageDirectory(under: applicationSupportDirectory)

        let resultA = StorageBootstrap.resolveLocations(applicationSupportDirectory: applicationSupportDirectory, now: 1)
        let resultB = StorageBootstrap.resolveLocations(applicationSupportDirectory: applicationSupportDirectory, now: 2)

        guard case .success(let locationsA) = resultA, case .success(let locationsB) = resultB else {
            XCTFail("expected both default-fallback resolutions to succeed")
            return
        }

        XCTAssertTrue(locationsA.settingsURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertNotEqual(
            locationsA.settingsURL.deletingLastPathComponent(),
            locationsB.settingsURL.deletingLastPathComponent(),
            "each default fallback directory must be uniquely named, never reused across bootstrap attempts"
        )

        scratchDirectories.append(locationsA.settingsURL.deletingLastPathComponent().deletingLastPathComponent())
        scratchDirectories.append(locationsB.settingsURL.deletingLastPathComponent().deletingLastPathComponent())
    }
}
