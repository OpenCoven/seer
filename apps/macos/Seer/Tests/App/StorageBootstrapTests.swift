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
    /// Also asserts this task's fix: whatever was already created under
    /// the dedicated fallback directory before the second failure must be
    /// recursively removed rather than left behind as a permanently
    /// orphaned, incomplete directory tree.
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

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fallbackDirectory.path),
            "a fallback directory that could not be fully prepared must be recursively cleaned up, never left behind as a permanently orphaned partial directory"
        )
    }

    /// A more targeted reproduction of the partial-failure cleanup than
    /// the double-blocked case above: the *settings* half of the
    /// fallback succeeds (genuinely creating `fallbackDirectory/
    /// ai.opencoven.seer/` on disk) but the *history* half then fails,
    /// leaving a real, partially-created directory tree behind before
    /// `resolveLocations` returns `.failure` — which must still remove
    /// that entire tree.
    func testPartialFallbackFailureCleansUpWhateverWasAlreadyCreated() {
        let applicationSupportDirectory = makeScratchDirectory()
        blockStorageDirectory(under: applicationSupportDirectory)

        let fallbackDirectory = makeScratchDirectory().appendingPathComponent("fallback", isDirectory: true)

        let result = StorageBootstrap.resolveLocations(
            applicationSupportDirectory: applicationSupportDirectory,
            now: 1_700_000_000_000,
            makeTemporaryFallbackDirectory: { fallbackDirectory },
            settingsFileURL: { try SettingsFileLocation.settingsFileURL(applicationSupportDirectory: $0) },
            historyFileURL: { _ in throw SettingsFileSystemError.other("simulated history location failure") }
        )

        switch result {
        case .success:
            XCTFail("expected failure when the history half of the fallback cannot be prepared")
        case .failure:
            break
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fallbackDirectory.deletingLastPathComponent().path),
            "cleanup must only remove the fallback directory itself, never its parent"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fallbackDirectory.path),
            "the partially-created fallback directory (whose settings half genuinely succeeded before history failed) must be recursively removed"
        )
    }

    // MARK: - Fallback root tracking

    /// When the primary directory succeeds outright, `Locations
    /// .fallbackRoot` must be `nil` — there is no dedicated temporary
    /// directory in play at all, so nothing should ever be scheduled for
    /// cleanup at shutdown.
    func testFallbackRootIsNilWhenThePrimaryDirectorySucceeds() {
        let applicationSupportDirectory = makeScratchDirectory()

        let result = StorageBootstrap.resolveLocations(applicationSupportDirectory: applicationSupportDirectory, now: 1_700_000_000_000)

        guard case .success(let locations) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertNil(locations.fallbackRoot)
    }

    /// When the fallback directory is actually used, `Locations
    /// .fallbackRoot` must be exactly that directory — this is what
    /// `AppDelegate` retains as its own `fallbackStorageRoot` to
    /// recursively remove once orderly shutdown completes.
    func testFallbackRootIsSetToTheDedicatedFallbackDirectoryWhenItIsUsed() {
        let applicationSupportDirectory = makeScratchDirectory()
        blockStorageDirectory(under: applicationSupportDirectory)
        let fallbackDirectory = makeScratchDirectory().appendingPathComponent("fallback", isDirectory: true)

        let result = StorageBootstrap.resolveLocations(
            applicationSupportDirectory: applicationSupportDirectory,
            now: 1_700_000_000_000,
            makeTemporaryFallbackDirectory: { fallbackDirectory }
        )

        guard case .success(let locations) = result else {
            XCTFail("expected the fallback to recover")
            return
        }
        XCTAssertEqual(locations.fallbackRoot, fallbackDirectory)
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
        XCTAssertTrue(
            locationsA.fallbackRoot?.lastPathComponent.hasPrefix(StorageBootstrap.fallbackDirectoryPrefix) == true,
            "the default fallback directory name must begin with the fixed, safe naming prefix pruning relies on"
        )

        scratchDirectories.append(locationsA.settingsURL.deletingLastPathComponent().deletingLastPathComponent())
        scratchDirectories.append(locationsB.settingsURL.deletingLastPathComponent().deletingLastPathComponent())
    }

    // MARK: - Bounded startup pruning of stale fallback directories

    /// Creates `name` directly under a fresh scratch "temporary
    /// directory" (never the real system temp dir, so these tests never
    /// touch unrelated real files), tracked for cleanup in `tearDown()`.
    private func makeDirectory(named name: String, under parent: URL) -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Only directories whose name begins with `StorageBootstrap
    /// .fallbackDirectoryPrefix` are ever even considered for pruning —
    /// an unrelated directory (any other app's, or the user's own) is
    /// never touched, no matter how "old" it looks from `now`'s vantage
    /// point.
    func testPruneStaleFallbackDirectoriesNeverTouchesUnrelatedDirectories() {
        let scratchTemp = makeScratchDirectory()
        let staleFallback = makeDirectory(named: "\(StorageBootstrap.fallbackDirectoryPrefix)AAAA", under: scratchTemp)
        let unrelated = makeDirectory(named: "SomeOtherApp-cache", under: scratchTemp)

        // `now` is far enough in the future that every directory just
        // created above is unambiguously "old" relative to it — this
        // test can't backdate real filesystem creation timestamps, so it
        // instead moves `now` forward instead of the files themselves.
        let farFuture = Date().addingTimeInterval(100_000)
        let result = StorageBootstrap.pruneStaleFallbackDirectories(
            in: scratchTemp,
            excluding: nil,
            now: farFuture,
            maxAge: 60
        )

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFallback.path), "a stale, this-app-owned fallback directory must be pruned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "a directory with any other name must never be touched, regardless of age")
    }

    /// The session's own currently-active fallback root must never be
    /// pruned, even if (implausibly) it looks old from `now`'s vantage
    /// point — it is always excluded explicitly, never relying on age
    /// alone.
    func testPruneStaleFallbackDirectoriesNeverRemovesTheActiveFallbackRoot() {
        let scratchTemp = makeScratchDirectory()
        let activeFallback = makeDirectory(named: "\(StorageBootstrap.fallbackDirectoryPrefix)ACTIVE", under: scratchTemp)
        let staleFallback = makeDirectory(named: "\(StorageBootstrap.fallbackDirectoryPrefix)STALE", under: scratchTemp)

        let farFuture = Date().addingTimeInterval(100_000)
        let result = StorageBootstrap.pruneStaleFallbackDirectories(
            in: scratchTemp,
            excluding: activeFallback,
            now: farFuture,
            maxAge: 60
        )

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeFallback.path), "the currently-active fallback root must never be pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFallback.path))
    }

    /// A fallback directory younger than `maxAge` must be left alone —
    /// pruning only ever targets genuinely stale, orphaned directories
    /// from a previous run, never one that might still be in active use
    /// by a process that is merely slow to reach its own orderly
    /// shutdown.
    func testPruneStaleFallbackDirectoriesLeavesRecentDirectoriesAlone() {
        let scratchTemp = makeScratchDirectory()
        let freshFallback = makeDirectory(named: "\(StorageBootstrap.fallbackDirectoryPrefix)FRESH", under: scratchTemp)

        let result = StorageBootstrap.pruneStaleFallbackDirectories(
            in: scratchTemp,
            excluding: nil,
            now: Date(),
            maxAge: 3600
        )

        XCTAssertEqual(result.removedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFallback.path))
    }

    /// Pruning is bounded: at most `maxDirectoriesToPrune` matching
    /// directories are ever removed in a single call, even when more
    /// stale, matching directories exist — closing off an unbounded
    /// single-launch pruning pass.
    func testPruneStaleFallbackDirectoriesIsBoundedByMaxDirectoriesToPrune() {
        let scratchTemp = makeScratchDirectory()
        for index in 0..<5 {
            _ = makeDirectory(named: "\(StorageBootstrap.fallbackDirectoryPrefix)\(index)", under: scratchTemp)
        }

        let farFuture = Date().addingTimeInterval(100_000)
        let result = StorageBootstrap.pruneStaleFallbackDirectories(
            in: scratchTemp,
            excluding: nil,
            now: farFuture,
            maxAge: 60,
            maxDirectoriesToPrune: 2
        )

        XCTAssertEqual(result.removedCount, 2, "pruning must never remove more than maxDirectoriesToPrune matching directories in a single call")
        let remaining = try! FileManager.default.contentsOfDirectory(atPath: scratchTemp.path)
        XCTAssertEqual(remaining.count, 3, "the remaining stale directories beyond the bound must be left for a future prune pass")
    }

    /// A file (not a directory) that happens to share the fallback
    /// prefix must never be removed — pruning only ever targets actual
    /// directories.
    func testPruneStaleFallbackDirectoriesNeverRemovesAFileEvenIfItMatchesThePrefix() {
        let scratchTemp = makeScratchDirectory()
        let matchingFilePath = scratchTemp.appendingPathComponent("\(StorageBootstrap.fallbackDirectoryPrefix)file", isDirectory: false)
        FileManager.default.createFile(atPath: matchingFilePath.path, contents: Data())

        let farFuture = Date().addingTimeInterval(100_000)
        let result = StorageBootstrap.pruneStaleFallbackDirectories(
            in: scratchTemp,
            excluding: nil,
            now: farFuture,
            maxAge: 60
        )

        XCTAssertEqual(result.removedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: matchingFilePath.path))
    }
}

