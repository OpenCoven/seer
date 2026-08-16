import XCTest
import SQLite3
@testable import Seer

/// Exercises `SessionSnapshotSource`'s bounded traversal, symlink/root-escape
/// hardening, bounded reads, and the Cursor SQLite path — both at the
/// internal-primitive level and via full `NativeSessionSnapshotSource`
/// integration against synthetic home directories. Every fixture lives
/// under an exact, per-test `UUID`-named child of
/// `FileManager.default.temporaryDirectory`, removed in a `defer` — this
/// suite never reads a real home directory, a real Cursor database, or any
/// other user data.
final class SessionSnapshotSourceTests: XCTestCase {
    private let fixedNow: Int64 = 1_700_000_000_000

    // MARK: - Temp fixture helpers

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeerSessionSnapshotSourceTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.data(using: .utf8)!.write(to: url)
        setModificationDate(Date(timeIntervalSince1970: Double(fixedNow) / 1000), at: url)
    }

    private func setModificationDate(_ date: Date, at url: URL) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func symlink(at linkURL: URL, to targetPath: String) {
        try! FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: targetPath)
    }

    /// `openVerifiedRegularFile(at:root:)` compares its `root` argument
    /// against a `realpath`-canonicalized parent directory, exactly like
    /// production callers always pass a pre-canonicalized configured root
    /// (see `canonicalConfiguredRoot`). `FileManager.default
    /// .temporaryDirectory` itself resolves through a symlink on macOS
    /// (`/var` → `/private/var`), so passing the raw, uncanonicalized
    /// `base.path` here would make every containment check fail — this
    /// helper mirrors what production code does, so these low-level tests
    /// exercise the same contract real callers rely on.
    private func canonicalRoot(_ url: URL) -> String {
        SessionSnapshotSource.canonicalPath(of: url.path)!
    }

    /// An active Claude transcript line: a fresh "user" turn with no
    /// `toolUseResult`, which `assessClaudeTurn` judges active as long as
    /// its embedded timestamp is within `turnActiveGraceMs` of `now`.
    private func activeClaudeLine(timestampMs: Int64) -> String {
        #"{"type":"user","timestamp":\#(timestampMs)}"#
    }

    private let claudeKind = AGENT_KINDS.first { $0.id == .claudeCode }!
    private let grokKind = AGENT_KINDS.first { $0.id == .grok }!

    // MARK: - isPath(_:containedIn:) component-boundary containment

    func testIsPathRejectsSamePrefixSiblingDirectory() {
        XCTAssertFalse(SessionSnapshotSource.isPath("/tmp/homeEvil/x", containedIn: "/tmp/home"))
        XCTAssertFalse(SessionSnapshotSource.isPath("/tmp/homeEvil", containedIn: "/tmp/home"))
    }

    func testIsPathAcceptsExactRootAndTrueDescendants() {
        XCTAssertTrue(SessionSnapshotSource.isPath("/tmp/home", containedIn: "/tmp/home"))
        XCTAssertTrue(SessionSnapshotSource.isPath("/tmp/home/a/b", containedIn: "/tmp/home"))
    }

    // MARK: - canonicalConfiguredRoot: symlinked-ancestor root escape

    func testCanonicalConfiguredRootRejectsRootEscapingViaSymlinkedAncestor() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let home = base.appendingPathComponent("home", isDirectory: true)
        let evil = base.appendingPathComponent("homeEvil", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evil.appendingPathComponent(".claude/projects/x"), withIntermediateDirectories: true)

        // A same-prefix sibling ("homeEvil") is exactly the case a naive
        // `hasPrefix` string check (without the trailing-slash boundary)
        // would wrongly treat as contained within "home".
        symlink(at: home.appendingPathComponent(".claude"), to: evil.appendingPathComponent(".claude").path)

        guard let homeCanonical = SessionSnapshotSource.canonicalPath(of: home.path) else {
            return XCTFail("expected home to canonicalize")
        }

        let root = SessionSnapshotSource.canonicalConfiguredRoot(
            homeDirectory: home,
            homeCanonical: homeCanonical,
            relativePath: ".claude/projects"
        )
        XCTAssertNil(root, "a configured root reached only through a symlinked ancestor pointing outside home must be rejected")
    }

    func testCanonicalConfiguredRootAcceptsAnOrdinaryRootBeneathHome() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)

        guard let homeCanonical = SessionSnapshotSource.canonicalPath(of: home.path) else {
            return XCTFail("expected home to canonicalize")
        }
        let root = SessionSnapshotSource.canonicalConfiguredRoot(homeDirectory: home, homeCanonical: homeCanonical, relativePath: ".claude/projects")
        XCTAssertNotNil(root)
    }

    // MARK: - collectCandidates: depth bound

    func testCollectCandidatesRespectsMaximumWalkDepth() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        // depth 5 (root/a1/a2/a3/a4/a5/allowed.jsonl) must be included;
        // depth 6 (one level deeper) must not be.
        let atDepth5 = base.appendingPathComponent("a1/a2/a3/a4/a5/allowed.jsonl")
        let atDepth6 = base.appendingPathComponent("a1/a2/a3/a4/a5/a6/toodeep.jsonl")
        write("{}", to: atDepth5)
        write("{}", to: atDepth6)

        let hits = SessionSnapshotSource.collectCandidates(root: base.path, extensions: [".jsonl"], fileNames: nil, now: fixedNow)

        XCTAssertTrue(hits.contains { $0.path == atDepth5.path })
        XCTAssertFalse(hits.contains { $0.path == atDepth6.path }, "a file beyond the maximum walk depth must never be collected")
    }

    // MARK: - collectCandidates: per-root file bound

    func testCollectCandidatesCapsFileCountPerRoot() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        for index in 1...450 {
            let name = String(format: "f%04d.jsonl", index)
            write("{}", to: base.appendingPathComponent(name))
        }

        let hits = SessionSnapshotSource.collectCandidates(root: base.path, extensions: [".jsonl"], fileNames: nil, now: fixedNow)

        XCTAssertEqual(hits.count, sessionMaximumFilesPerRoot)
        XCTAssertEqual(sessionMaximumFilesPerRoot, 400)
    }

    func testCollectCandidatesAllowsOnlyBoundedFutureMtimeSkew() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let tolerated = base.appendingPathComponent("tolerated.jsonl")
        let rejected = base.appendingPathComponent("rejected.jsonl")
        write("{}", to: tolerated)
        write("{}", to: rejected)
        setModificationDate(Date(timeIntervalSince1970: Double(fixedNow + timestampFutureSkewMs) / 1000), at: tolerated)
        setModificationDate(Date(timeIntervalSince1970: Double(fixedNow + timestampFutureSkewMs + 1_000) / 1000), at: rejected)

        let hits = SessionSnapshotSource.collectCandidates(
            root: base.path,
            extensions: [".jsonl"],
            fileNames: nil,
            now: fixedNow
        )

        XCTAssertEqual(hits.map(\.path), [tolerated.path])
    }

    // MARK: - collectCandidates: skipped directory names + symlinked dirs

    func testCollectCandidatesSkipsWellKnownDirectoryNames() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        for skipped in [".git", "node_modules", "cache", "subagents"] {
            write("{}", to: base.appendingPathComponent("\(skipped)/inside.jsonl"))
        }
        write("{}", to: base.appendingPathComponent("kept/inside.jsonl"))

        let hits = SessionSnapshotSource.collectCandidates(root: base.path, extensions: [".jsonl"], fileNames: nil, now: fixedNow)

        XCTAssertEqual(hits.map(\.path), [base.appendingPathComponent("kept/inside.jsonl").path])
    }

    func testCollectCandidatesNeverDescendsIntoASymlinkedDirectory() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }

        // `outside` is a sibling temp directory, never a descendant of
        // `base` — only a symlink *inside* `base` points at it, so any
        // collected hit here could only have come from following that link.
        write("{}", to: outside.appendingPathComponent("poison.jsonl"))
        symlink(at: base.appendingPathComponent("linked-dir"), to: outside.path)

        let hits = SessionSnapshotSource.collectCandidates(root: base.path, extensions: [".jsonl"], fileNames: nil, now: fixedNow)

        XCTAssertTrue(hits.isEmpty, "a symlinked directory entry must never be descended into")
    }

    func testCollectCandidatesNeverCollectsASymlinkedFile() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }

        let poisonTarget = outside.appendingPathComponent("poison.jsonl")
        write(activeClaudeLine(timestampMs: fixedNow), to: poisonTarget)
        symlink(at: base.appendingPathComponent("linked.jsonl"), to: poisonTarget.path)

        let hits = SessionSnapshotSource.collectCandidates(root: base.path, extensions: [".jsonl"], fileNames: nil, now: fixedNow)

        XCTAssertTrue(hits.isEmpty, "a symlinked file must never be collected as a candidate")
    }

    // MARK: - collectCandidates: extension / known-file-name filters

    func testCollectCandidatesFiltersByExtension() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        write("{}", to: base.appendingPathComponent("session.jsonl"))
        write("{}", to: base.appendingPathComponent("notes.txt"))

        let hits = SessionSnapshotSource.collectCandidates(root: base.path, extensions: [".jsonl"], fileNames: nil, now: fixedNow)

        XCTAssertEqual(hits.map(\.path), [base.appendingPathComponent("session.jsonl").path])
    }

    func testCollectCandidatesFiltersGrokToEventsJSONLOnly() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        write("{}", to: base.appendingPathComponent("events.jsonl"))
        write("{}", to: base.appendingPathComponent("chat_history.jsonl"))
        write("{}", to: base.appendingPathComponent("updates.jsonl"))

        let hits = SessionSnapshotSource.collectCandidates(
            root: base.path,
            extensions: grokKind.sessionExtensions,
            fileNames: grokKind.sessionFileNames,
            now: fixedNow
        )

        XCTAssertEqual(hits.map(\.path), [base.appendingPathComponent("events.jsonl").path])
    }

    // MARK: - collectCandidates: recent-activity candidate window

    func testCollectCandidatesExcludesFilesOlderThanTheCandidateWindow() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fresh = base.appendingPathComponent("fresh.jsonl")
        let stale = base.appendingPathComponent("stale.jsonl")
        write("{}", to: fresh)
        write("{}", to: stale)
        setModificationDate(Date(timeIntervalSince1970: Double(fixedNow) / 1000), at: fresh)
        setModificationDate(
            Date(timeIntervalSince1970: Double(fixedNow - sessionCandidateWindowMs - 60_000) / 1000),
            at: stale
        )

        let hits = SessionSnapshotSource.collectCandidates(root: base.path, extensions: [".jsonl"], fileNames: nil, now: fixedNow)

        XCTAssertEqual(hits.map(\.path), [fresh.path])
    }

    // MARK: - openVerifiedRegularFile: symlink + descriptor errors

    func testOpenVerifiedRegularFileRejectsASymlinkedFile() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("real.jsonl")
        write("{}", to: target)
        let link = base.appendingPathComponent("link.jsonl")
        symlink(at: link, to: target.path)

        let fd = SessionSnapshotSource.openVerifiedRegularFile(at: link.path, root: canonicalRoot(base))
        XCTAssertNil(fd)
    }

    func testOpenVerifiedRegularFileRejectsANonRegularFile() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let directoryMasqueradingAsFile = base.appendingPathComponent("looks-like-a-file.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryMasqueradingAsFile, withIntermediateDirectories: true)

        let fd = SessionSnapshotSource.openVerifiedRegularFile(at: directoryMasqueradingAsFile.path, root: canonicalRoot(base))
        XCTAssertNil(fd, "a directory must never be returned as an openable regular file descriptor")
    }

    func testOpenVerifiedRegularFileReturnsNilForAMissingParentDirectory() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let missing = base.appendingPathComponent("does/not/exist.jsonl")

        let fd = SessionSnapshotSource.openVerifiedRegularFile(at: missing.path, root: canonicalRoot(base))
        XCTAssertNil(fd, "a nonexistent parent directory must produce a nil descriptor, not a crash")
    }

    func testOpenVerifiedRegularFileSucceedsForAnOrdinaryFile() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("real.jsonl")
        write("hello", to: target)

        let fd = SessionSnapshotSource.openVerifiedRegularFile(at: target.path, root: canonicalRoot(base))
        XCTAssertNotNil(fd)
        if let fd { close(fd) }
    }

    // MARK: - Bounded reads: tail / head / partial lines / corrupt JSON

    func testReadTailReturnsEntireFileWhenSmallerThanBound() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("small.jsonl")
        write("line-one\nline-two", to: file)

        guard let fd = SessionSnapshotSource.openVerifiedRegularFile(at: file.path, root: canonicalRoot(base)) else {
            return XCTFail("expected an open descriptor")
        }
        defer { close(fd) }

        let result = SessionSnapshotSource.readTail(fd: fd, maxBytes: sessionTailReadBytes)
        XCTAssertEqual(result?.droppedPartialFirstLine, false)
        XCTAssertEqual(String(data: result?.data ?? Data(), encoding: .utf8), "line-one\nline-two")
    }

    func testReadTailDropsPartialFirstLineWhenTruncatedMidFile() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("big.jsonl")
        // Two complete lines, then a large filler so only a small tail read
        // starts mid-way through the filler line — the "first" line the
        // tail read sees is a partial fragment, not a genuine record.
        let filler = String(repeating: "x", count: 100)
        write("{\"a\":1}\n{\"b\":2}\n\(filler)\n{\"c\":3}\n", to: file)

        guard let fd = SessionSnapshotSource.openVerifiedRegularFile(at: file.path, root: canonicalRoot(base)) else {
            return XCTFail("expected an open descriptor")
        }
        defer { close(fd) }

        let result = SessionSnapshotSource.readTail(fd: fd, maxBytes: 20)
        XCTAssertEqual(result?.droppedPartialFirstLine, true)
    }

    func testParseTailLinesToleratesCorruptAndNonObjectLines() {
        let text = """
        not-json
        {"valid":1}
        {broken json
        {"alsoValid":2}

        """
        let events = SessionSnapshotSource.parseTailLines(text.data(using: .utf8)!, droppedPartialFirstLine: false)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["valid"] as? Int, 1)
        XCTAssertEqual(events[1]["alsoValid"] as? Int, 2)
    }

    func testParseTailLinesDropsFirstLineWhenMarkedPartial() {
        let text = "garbage-partial-tail\n{\"kept\":1}\n"
        let events = SessionSnapshotSource.parseTailLines(text.data(using: .utf8)!, droppedPartialFirstLine: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["kept"] as? Int, 1)
    }

    func testParseTailLinesDropsBisectedUTF8BeforeDecodingLaterEvents() {
        for scalar in ["é", "€", "🧙"] {
            let bytes = Array(scalar.utf8)
            XCTAssertTrue((2...4).contains(bytes.count))
            for split in 1..<bytes.count {
                var tail = Data(bytes.dropFirst(split))
                tail.append(Data(" partial line\n{\"kept\":\"\(scalar)\"}\n".utf8))

                let events = SessionSnapshotSource.parseTailLines(tail, droppedPartialFirstLine: true)

                XCTAssertEqual(events.count, 1, "failed for \(bytes.count)-byte scalar split at byte \(split)")
                XCTAssertEqual(events.first?["kept"] as? String, scalar)
            }
        }
    }

    func testParseTailLinesAtOffsetZeroDecodesWholeUnicodeData() {
        let data = Data("{\"kept\":\"🧙 café €\"}\n".utf8)

        let events = SessionSnapshotSource.parseTailLines(data, droppedPartialFirstLine: false)

        XCTAssertEqual(events.first?["kept"] as? String, "🧙 café €")
    }

    func testReadHeadIsBoundedAndExtractsCodexCwd() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("rollout.jsonl")
        let filler = String(repeating: "z", count: codexHeadReadBytes + 5_000)
        write("{\"cwd\":\"/Users/example/my-project\"}\n\(filler)", to: file)

        guard let fd = SessionSnapshotSource.openVerifiedRegularFile(at: file.path, root: canonicalRoot(base)) else {
            return XCTFail("expected an open descriptor")
        }
        defer { close(fd) }

        let head = SessionSnapshotSource.readHead(fd: fd, maxBytes: codexHeadReadBytes)
        XCTAssertNotNil(head)
        XCTAssertLessThanOrEqual(head?.count ?? .max, codexHeadReadBytes)

        let label = try XCTUnwrap(head.flatMap(SessionSnapshotSource.extractCodexHeadCwd))
        // "my" is a short (<=2 char), already-lowercase word, which
        // `titleCaseWords` intentionally leaves lowercase (matching the TS
        // reference's handling of short connecting words) — only
        // "Project" is capitalized.
        XCTAssertEqual(label, "my Project")
    }

    // MARK: - Integration: NativeSessionSnapshotSource end-to-end

    func testNativeSourceProducesEvidenceForAnActiveClaudeTranscript() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appendingPathComponent(".claude/projects/my-project/session.jsonl")
        write(activeClaudeLine(timestampMs: fixedNow), to: transcript)

        let source = NativeSessionSnapshotSource(homeDirectory: home)
        let evidence = try await source.snapshot(now: fixedNow)

        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.family, .claudeCode)
        guard let canonicalPath = SessionSnapshotSource.canonicalPath(of: transcript.path) else {
            return XCTFail("expected the transcript to canonicalize")
        }
        XCTAssertEqual(evidence.first?.identity, canonicalPath)
    }

    func testNativeSourceProducesNoDetectorEvidenceFromExtremeFutureTranscriptTimestamp() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appendingPathComponent(".claude/projects/my-project/session.jsonl")
        write(activeClaudeLine(timestampMs: Int64.max), to: transcript)

        let source = NativeSessionSnapshotSource(homeDirectory: home)
        let evidence = try await source.snapshot(now: fixedNow)

        XCTAssertTrue(
            evidence.isEmpty,
            "rejected future transcript evidence must never reach AgentDetector or activate its downstream power state"
        )
    }

    func testNativeSourceProducesZeroEvidenceForASymlinkedTranscriptOutsideRoot() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let outsidePoison = home.deletingLastPathComponent().appendingPathComponent("poison-\(UUID().uuidString).jsonl")
        write(activeClaudeLine(timestampMs: fixedNow), to: outsidePoison)
        defer { try? FileManager.default.removeItem(at: outsidePoison) }

        let link = home.appendingPathComponent(".claude/projects/my-project/session.jsonl")
        symlink(at: link, to: outsidePoison.path)

        let source = NativeSessionSnapshotSource(homeDirectory: home)
        let evidence = try await source.snapshot(now: fixedNow)

        XCTAssertTrue(evidence.isEmpty, "a symlinked transcript pointing outside the configured root must never produce evidence")
    }

    func testNativeSourceProducesZeroEvidenceWhenSessionRootEscapesHomeViaSymlink() async throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let evil = base.appendingPathComponent("homeEvil", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let evilTranscript = evil.appendingPathComponent("projects/x/session.jsonl")
        write(activeClaudeLine(timestampMs: fixedNow), to: evilTranscript)

        symlink(at: home.appendingPathComponent(".claude"), to: evil.path)

        let source = NativeSessionSnapshotSource(homeDirectory: home)
        let evidence = try await source.snapshot(now: fixedNow)

        XCTAssertTrue(evidence.isEmpty, "a configured root escaping home through a symlinked ancestor must never produce evidence")
    }

    func testNativeSourceCapsAssessedCandidatesAtTwentyFour() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        for index in 0..<30 {
            let transcript = home.appendingPathComponent(".claude/projects/proj\(index)/session.jsonl")
            write(activeClaudeLine(timestampMs: fixedNow), to: transcript)
            setModificationDate(Date(timeIntervalSince1970: Double(fixedNow - Int64(index) * 1_000) / 1000), at: transcript)
        }

        let evidence = SessionSnapshotSource.familyEvidence(
            kind: claudeKind,
            homeDirectory: home,
            homeCanonical: SessionSnapshotSource.canonicalPath(of: home.path)!,
            now: fixedNow
        )

        XCTAssertEqual(evidence.count, sessionMaximumAssessedCandidates)
        XCTAssertEqual(sessionMaximumAssessedCandidates, 24)
    }

    // MARK: - Cursor: synthetic SQLite fixture + symlink defense

    private func makeCursorFixtureDatabase(at url: URL, key: String, valueJSON: String) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, valueJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func makeEmptyCursorFixtureDatabase(at url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil), SQLITE_OK)
    }

    private func openCursorWriter(at url: URL, wal: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, flags, nil), SQLITE_OK)
        let writer = try XCTUnwrap(db)
        if wal {
            XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(writer, "PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
        }
        return writer
    }

    private func exec(_ sql: String, on db: OpaquePointer) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) } ?? ""
        sqlite3_free(errorMessage)
        XCTAssertEqual(result, SQLITE_OK, message)
    }

    func testNativeSourceProducesEvidenceFromASyntheticCursorDatabase() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(at: dbURL, key: "composerData:abc123", valueJSON: #"{"status":"generating"}"#)

        let source = NativeSessionSnapshotSource(homeDirectory: home)
        let evidence = try await source.snapshot(now: fixedNow)

        let cursorEvidence = evidence.filter { $0.family == .cursor }
        XCTAssertEqual(cursorEvidence.count, 1)
        XCTAssertEqual(cursorEvidence.first?.identity, "abc123")
    }

    func testNativeSourceReadsActiveComposerCommittedOnlyToLiveWAL() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        let writer = try openCursorWriter(at: dbURL, wal: true)
        defer { sqlite3_close(writer) }
        exec("PRAGMA wal_checkpoint(TRUNCATE)", on: writer)
        exec(
            #"INSERT INTO cursorDiskKV (key, value) VALUES ('composerData:wal-active', '{"status":"generating"}')"#,
            on: writer
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path + "-wal"))

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        XCTAssertTrue(evidence.contains { $0.family == .cursor && $0.identity == "wal-active" })
    }

    func testCursorReadUsesConsistentSnapshotWhileWALWriterCommits() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)
        let writer = try openCursorWriter(at: dbURL, wal: true)
        defer { sqlite3_close(writer) }
        exec(
            #"INSERT INTO cursorDiskKV (key, value) VALUES ('composerData:snapshot', '{"status":"generating"}')"#,
            on: writer
        )

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(
            at: dbURL.path,
            root: canonicalRoot(home)
        ))
        defer { close(fd) }

        let beforeCommit = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow
        )
        XCTAssertEqual(beforeCommit.map(\.identity), ["snapshot"])

        let evidence = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow,
            onSnapshotEstablished: {
                self.exec(
                    #"UPDATE cursorDiskKV SET value = '{"status":"completed","lastUpdatedAt":0}' WHERE key = 'composerData:snapshot'"#,
                    on: writer
                )
            }
        )

        XCTAssertEqual(evidence.map(\.identity), ["snapshot"])
        let afterCommit = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow
        )
        XCTAssertTrue(afterCommit.isEmpty)
    }

    func testCursorBusyDatabaseThrowsTypedBoundedScanFailure() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        let writer = try openCursorWriter(at: dbURL, wal: false)
        defer { sqlite3_close(writer) }
        exec("BEGIN EXCLUSIVE", on: writer)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        do {
            _ = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)
            XCTFail("a locked Cursor database must fail the scan instead of returning stale empty evidence")
        } catch let error as CursorSessionScanError {
            XCTAssertEqual(error, .databaseBusy(code: SQLITE_BUSY))
            XCTAssertEqual(cursorSQLiteBusyTimeoutMilliseconds, 100)
        } catch {
            XCTFail("expected typed CursorSessionScanError, got \(error)")
        }
    }

    func testNativeSourceProducesZeroEvidenceForASymlinkedCursorDatabaseOutsideRoot() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let poisonDB = home.deletingLastPathComponent().appendingPathComponent("poison-\(UUID().uuidString).vscdb")
        makeCursorFixtureDatabase(at: poisonDB, key: "composerData:POISON", valueJSON: #"{"status":"generating"}"#)
        defer { try? FileManager.default.removeItem(at: poisonDB) }

        let linkURL = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        symlink(at: linkURL, to: poisonDB.path)

        let source = NativeSessionSnapshotSource(homeDirectory: home)
        let evidence = try await source.snapshot(now: fixedNow)

        let cursorEvidence = evidence.filter { $0.family == .cursor }
        XCTAssertTrue(cursorEvidence.isEmpty, "a symlinked state.vscdb pointing outside home must never be consumed")
        XCTAssertFalse(evidence.contains { $0.identity == "POISON" }, "the sentinel poison composer id must never appear")
    }

}
