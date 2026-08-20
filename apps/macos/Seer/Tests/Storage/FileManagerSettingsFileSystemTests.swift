import XCTest
@testable import Seer

/// Integration tests against the real, production `FileManagerSettingsFileSystem`
/// — every other test in this target exercises `AtomicJSONStore` against the
/// in-memory `InMemorySettingsFileSystem` fake, which models the *documented*
/// contract but never actually calls into `openat`/`fstat`/`flock`. These
/// tests instead run the genuine POSIX syscalls against a real, explicitly
/// created temporary directory (never Application Support or any other
/// home-library path) so a regression in the canonical-parent-directory +
/// `O_NOFOLLOW` hardening itself — not just in `AtomicJSONStore`'s handling
/// of the fake's simulated errors — would be caught.
///
/// Deliberately avoids any assumption about the host filesystem being APFS
/// (e.g. `F_FULLFSYNC` support, hard-link/clonefile behavior): CI runners may
/// back `FileManager.default.temporaryDirectory` with a different filesystem,
/// and `FileManagerSettingsFileSystem.writeFileAndSynchronize` already falls
/// back from `F_FULLFSYNC` to `fsync` on volumes that don't support it.
final class FileManagerSettingsFileSystemTests: XCTestCase {
    private var tempDirectory: URL!
    private let fileSystem = FileManagerSettingsFileSystem()

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A unique child of the real temporary directory, created fresh for
        // every test and removed in `tearDown` — never touches Application
        // Support or any other home-library path.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeerFileManagerSettingsFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
    }

    override func tearDownWithError() throws {
        // Only ever removes the exact unique child directory created above,
        // never any ancestor of it.
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    private func documentURL(_ name: String = "settings.json") -> URL {
        tempDirectory.appendingPathComponent(name, isDirectory: false)
    }

    /// Writes `data` to `url` via the real `writeFileAndSynchronize` +
    /// `replaceItem` sequence `AtomicJSONStore.save` itself uses, so this
    /// helper exercises production code paths rather than reaching around
    /// them with `FileManager`/`Data.write` directly.
    private func writeRegularFile(_ data: Data, to url: URL) async throws {
        let tempURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try await fileSystem.writeFileAndSynchronize(data, to: tempURL)
        try await fileSystem.replaceItem(at: url, withItemAt: tempURL)
    }

    // MARK: - Regular file write/read/size round trip

    func testRegularFileWriteReadAndFileSizeRoundTripSucceeds() async throws {
        let url = documentURL()
        let payload = Data(#"{"version":1,"keepAwakeMode":"system","includePrereleaseUpdates":false}"#.utf8)

        try await writeRegularFile(payload, to: url)

        let size = try await fileSystem.fileSize(at: url)
        XCTAssertEqual(size, Int64(payload.count))

        let readBack = try await fileSystem.readFile(at: url)
        XCTAssertEqual(readBack, payload)
    }

    // MARK: - Missing-file semantics preserved

    func testFileSizeThrowsFileNotFoundForMissingFile() async {
        let url = documentURL("does-not-exist.json")

        do {
            _ = try await fileSystem.fileSize(at: url)
            XCTFail("expected fileSize to throw fileNotFound for a missing file")
        } catch SettingsFileSystemError.fileNotFound {
            // expected
        } catch {
            XCTFail("expected fileNotFound, got \(error)")
        }
    }

    func testReadFileThrowsFileNotFoundForMissingFile() async {
        let url = documentURL("does-not-exist.json")

        do {
            _ = try await fileSystem.readFile(at: url)
            XCTFail("expected readFile to throw fileNotFound for a missing file")
        } catch SettingsFileSystemError.fileNotFound {
            // expected
        } catch {
            XCTFail("expected fileNotFound, got \(error)")
        }
    }

    // MARK: - Symlinked document path rejected by fileSize/readFile

    func testFileSizeRejectsSymlinkedDocumentPath() async throws {
        let url = documentURL()
        let target = documentURL("elsewhere.json")
        try Data(#"{"elsewhere":true}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        do {
            _ = try await fileSystem.fileSize(at: url)
            XCTFail("expected fileSize to reject a symlinked document path")
        } catch SettingsFileSystemError.symlinkRejected {
            // expected
        } catch {
            XCTFail("expected symlinkRejected, got \(error)")
        }
    }

    func testReadFileRejectsSymlinkedDocumentPath() async throws {
        let url = documentURL()
        let target = documentURL("elsewhere.json")
        try Data(#"{"elsewhere":true}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        do {
            _ = try await fileSystem.readFile(at: url)
            XCTFail("expected readFile to reject a symlinked document path")
        } catch SettingsFileSystemError.symlinkRejected {
            // expected
        } catch {
            XCTFail("expected symlinkRejected, got \(error)")
        }
    }

    // MARK: - Symlinked lock path rejected by acquireLock

    func testAcquireLockRejectsSymlinkedLockPath() async throws {
        let url = documentURL()
        let target = documentURL("elsewhere-lock-target")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let lockPath = url.path + ".lock"
        try FileManager.default.createSymbolicLink(atPath: lockPath, withDestinationPath: target.path)

        do {
            _ = try await fileSystem.acquireLock(for: url)
            XCTFail("expected acquireLock to reject a symlinked lock path")
        } catch SettingsFileSystemError.symlinkRejected {
            // expected
        } catch {
            XCTFail("expected symlinkRejected, got \(error)")
        }
    }

    // MARK: - Acquired lock blocks a second acquisition and releases

    func testAcquiredLockBlocksSecondAcquisitionUntilReleased() async throws {
        let url = documentURL()

        let firstLock = try await fileSystem.acquireLock(for: url)

        let secondLockBox = LockBox()
        let fileSystem = self.fileSystem
        let secondAcquisitionTask = Task {
            let lock = try await fileSystem.acquireLock(for: url)
            await secondLockBox.set(lock)
        }

        // The second acquisition must still be blocked shortly after being
        // issued, while the first lock is held: `flock`'s exclusivity is
        // per open-file-description, not per-process, so two independent
        // `acquireLock` calls in this same test process genuinely contend
        // for the same advisory lock exactly like two separate processes
        // would.
        try await Task.sleep(nanoseconds: 300_000_000)
        let stillBlockedLock = await secondLockBox.get()
        XCTAssertNil(stillBlockedLock, "a second acquireLock call must block while the first lock is held")

        await firstLock.unlock()

        // Poll (bounded) for the second acquisition to complete now that
        // the first lock has released, rather than re-waiting an
        // `XCTestExpectation` a second time (which XCTest forbids).
        var secondLock: (any SettingsFileLock)?
        for _ in 0..<50 {
            if let lock = await secondLockBox.get() {
                secondLock = lock
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(secondLock, "the second acquireLock call must complete after the first lock releases")
        await secondLock?.unlock()
        secondAcquisitionTask.cancel()
    }

    // MARK: - Bounded real-file oversized behavior

    func testReadFileRejectsRealOversizedFileWithoutUnboundedAllocation() async throws {
        let url = documentURL()
        // One byte past `StorageLimits.maxDocumentBytes` (1 MiB) — large
        // enough to exercise the real `fstat`-based ceiling check without
        // being an unreasonably slow test to write to disk.
        let oversizedPayload = Data(repeating: 0x41, count: Int(StorageLimits.maxDocumentBytes) + 1)
        try oversizedPayload.write(to: url)

        do {
            _ = try await fileSystem.readFile(at: url)
            XCTFail("expected readFile to reject a real file past the size ceiling")
        } catch SettingsFileSystemError.tooLarge {
            // expected
        } catch {
            XCTFail("expected tooLarge, got \(error)")
        }
    }
}

/// A tiny actor box used only to hand a `SettingsFileLock` acquired inside a
/// detached `Task` back out to the awaiting test body, since `SettingsFileLock`
/// existentials aren't safe to capture across the task boundary as a plain
/// `var` without isolation.
private actor LockBox {
    private var lock: (any SettingsFileLock)?

    func set(_ lock: any SettingsFileLock) {
        self.lock = lock
    }

    func get() -> (any SettingsFileLock)? {
        lock
    }
}
