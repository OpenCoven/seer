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

    func testCollectCandidatesBoundsAllInspectedEntriesInAHugeSingleDirectory() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        for index in 0..<600 {
            let active = base.appendingPathComponent(String(format: "active-%05d.jsonl", index))
            write("{}", to: active)
            setModificationDate(Date(timeIntervalSince1970: Double(fixedNow) / 1000), at: active)
        }
        for index in 0..<(sessionMaximumInspectedEntriesPerRoot - 100) {
            write("ignored", to: base.appendingPathComponent(String(format: "unrelated-%05d.txt", index)))
        }

        let result = SessionSnapshotSource.collectCandidatesWithStats(
            root: base.path,
            extensions: [".jsonl"],
            fileNames: nil,
            now: fixedNow
        )

        XCTAssertEqual(result.inspectedEntries, sessionMaximumInspectedEntriesPerRoot)
        XCTAssertEqual(result.inspectedDirectories, 1)
        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertLessThanOrEqual(result.candidates.count, sessionMaximumFilesPerRoot)
    }

    func testCollectCandidatesBoundsInspectedDirectoriesIndependently() throws {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        for index in 0..<(sessionMaximumInspectedDirectoriesPerRoot + 50) {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(String(format: "directory-%05d", index)),
                withIntermediateDirectories: false
            )
        }

        let result = SessionSnapshotSource.collectCandidatesWithStats(
            root: base.path,
            extensions: [".jsonl"],
            fileNames: nil,
            now: fixedNow
        )

        XCTAssertEqual(result.inspectedDirectories, sessionMaximumInspectedDirectoriesPerRoot)
        XCTAssertLessThanOrEqual(result.inspectedEntries, sessionMaximumInspectedEntriesPerRoot)
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

    private func insertCursorFixtureRecord(at url: URL, key: String, value: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    /// Simulates Cursor's real UPSERT-in-place behavior: same `rowid`, new
    /// value. Used to prove validated JSON recency (not insertion-order
    /// `rowid`) drives ordering.
    private func updateCursorFixtureRecord(at url: URL, key: String, value: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE cursorDiskKV SET value = ? WHERE key = ?", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        XCTAssertEqual(sqlite3_changes(db), 1)
    }

    /// Inserts many rows through a single connection/prepared statement/
    /// transaction — the adversarial tests below need hundreds to thousands
    /// of rows, and `insertCursorFixtureRecord`'s per-call open/close would
    /// make those needlessly slow.
    private func insertManyCursorFixtureRecords(at url: URL, records: [(key: String, value: String)]) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, record.key, -1, transient)
            sqlite3_bind_text(statement, 2, record.value, -1, transient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
    }

    /// Inserts `count` rows with keys that never match
    /// `key LIKE 'composerData:%'`, without building an in-memory
    /// `[(key, value)]` array first — the adversarial responsiveness test
    /// below needs a row count large enough to make a regression to a full
    /// (non-index-driven) table scan obvious, while staying fast under the
    /// real, index-driven `WHERE key LIKE 'composerData:%'` prefix filter.
    private func insertManyNonMatchingCursorFixtureRecords(at url: URL, count: Int) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for index in 0..<count {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, "otherKey:\(index)", -1, transient)
            sqlite3_bind_text(statement, 2, "x", -1, transient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
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
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:abc123",
            valueJSON: #"{"status":"generating","lastUpdatedAt":1700000000000}"#
        )

        let source = NativeSessionSnapshotSource(homeDirectory: home)
        let evidence = try await source.snapshot(now: fixedNow)

        let cursorEvidence = evidence.filter { $0.family == .cursor }
        XCTAssertEqual(cursorEvidence.count, 1)
        XCTAssertEqual(cursorEvidence.first?.identity, "abc123")
    }

    func testCursorMalformedRowsAreSkippedWithoutHidingAValidActiveComposer() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)
        insertCursorFixtureRecord(at: dbURL, key: "composerData:00-invalid", value: #"{"status":"#)
        insertCursorFixtureRecord(at: dbURL, key: "composerData:01-array", value: #"["generating"]"#)
        insertCursorFixtureRecord(
            at: dbURL,
            key: "composerData:02-valid",
            value: #"{"status":"generating","lastUpdatedAt":1700000000000}"#
        )

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        XCTAssertEqual(evidence.filter { $0.family == .cursor }.map(\.identity), ["02-valid"])
    }

    func testCursorAllMalformedRowsProduceNoCandidatesInsteadOfFailingTheScan() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)
        insertCursorFixtureRecord(at: dbURL, key: "composerData:invalid", value: "{")
        insertCursorFixtureRecord(at: dbURL, key: "composerData:array", value: #"[]"#)
        insertCursorFixtureRecord(at: dbURL, key: "composerData:scalar", value: #""generating""#)

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        XCTAssertTrue(evidence.filter { $0.family == .cursor }.isEmpty)
    }

    func testCursorMalformedPrimitivesAndMissingTimestampsStayInactiveAcrossRepeatedScans() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)
        let records = [
            #"{"status":7,"lastUpdatedAt":1700000000000}"#,
            #"{"status":null,"lastUpdatedAt":1700000000000}"#,
            #"{"status":"generating"}"#,
            #"{"status":"generating","lastUpdatedAt":null}"#,
            #"{"status":"generating","lastUpdatedAt":true}"#,
            #"{"status":"completed","isContinuationInProgress":1}"#,
            #"{"status":"completed","fullConversationHeadersOnly":[null,true,42,"header",[],{"type":1}]}"#,
        ]
        for (index, record) in records.enumerated() {
            insertCursorFixtureRecord(
                at: dbURL,
                key: String(format: "composerData:malformed-%02d", index),
                value: record
            )
        }

        let source = NativeSessionSnapshotSource(homeDirectory: home)
        for scanNow in [fixedNow, fixedNow + 1_000, fixedNow + 60_000] {
            let evidence = try await source.snapshot(now: scanNow)
            XCTAssertTrue(evidence.filter { $0.family == .cursor }.isEmpty)
        }
    }

    func testCursorMixedHeadersUseValidTimestampWithoutRefreshingOnLaterScans() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:mixed",
            valueJSON: """
            {
              "status": "completed",
              "lastUpdatedAt": \(fixedNow - 60_000),
              "fullConversationHeadersOnly": [
                null,
                true,
                42,
                "header",
                [],
                {"type": "1", "createdAt": \(fixedNow)},
                {"type": 1, "createdAt": null},
                {"type": 1, "createdAt": \(fixedNow - 1_000)}
              ]
            }
            """
        )
        let source = NativeSessionSnapshotSource(homeDirectory: home)

        let fresh = try await source.snapshot(now: fixedNow)
        XCTAssertEqual(fresh.filter { $0.family == .cursor }.map(\.identity), ["mixed"])
        XCTAssertEqual(
            fresh.first { $0.family == .cursor }?.lastActivityAt,
            fixedNow - 1_000
        )

        let stale = try await source.snapshot(now: fixedNow + turnActiveGraceMs + 1)
        XCTAssertTrue(stale.filter { $0.family == .cursor }.isEmpty)
    }

    func testCursorMalformedAndStalePrefixesBeyondFormerRawCapDoNotHideActiveComposer() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        for index in 0..<205 {
            let value = index.isMultiple(of: 2)
                ? #"{"status":"#
                : #"{"status":"completed","lastUpdatedAt":0}"#
            insertCursorFixtureRecord(
                at: dbURL,
                key: String(format: "composerData:a-%03d", index),
                value: value
            )
        }
        insertCursorFixtureRecord(
            at: dbURL,
            key: "composerData:z-active",
            value: #"{"status":"generating","lastUpdatedAt":1700000000000}"#
        )

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        XCTAssertEqual(evidence.filter { $0.family == .cursor }.map(\.identity), ["z-active"])
    }

    func testCursorOversizedRowsAreSkippedAndSQLLikeStringsRemainPlainData() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)
        let oversized = #"{"status":"generating","padding":""#
            + String(repeating: "x", count: 4_000_000)
            + #""}"#
        insertCursorFixtureRecord(at: dbURL, key: "composerData:00-oversized", value: oversized)
        let injectionLikeIdentity = #"x' UNION SELECT key, value FROM cursorDiskKV --"#
        insertCursorFixtureRecord(
            at: dbURL,
            key: "composerData:\(injectionLikeIdentity)",
            value: #"{"status":"generating","lastUpdatedAt":1700000000000,"name":"'); DROP TABLE cursorDiskKV; --"}"#
        )

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        XCTAssertEqual(evidence.filter { $0.family == .cursor }.map(\.identity), [injectionLikeIdentity])
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
            #"INSERT INTO cursorDiskKV (key, value) VALUES ('composerData:wal-active', '{"status":"generating","lastUpdatedAt":1700000000000}')"#,
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
            #"INSERT INTO cursorDiskKV (key, value) VALUES ('composerData:snapshot', '{"status":"generating","lastUpdatedAt":1700000000000}')"#,
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

    // MARK: - Cursor: realistic bubble tool status (issue B)

    /// Real Cursor data: the composer header only references a bubble id;
    /// the actual tool status lives in a separate
    /// `bubbleId:<composerId>:<bubbleId>` row's `toolFormerData.status`.
    /// End-to-end proof (real SQLite, real bounded scan path — not just the
    /// pure assessor) that this realistic shape is detected as an active
    /// running tool call, which the unrealistic embedded-status fixture this
    /// replaces could never exercise.
    func testCursorRealisticBubbleRowIsDetectedAsActiveToolCall() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:realistic-active",
            valueJSON: """
            {
              "status": "completed",
              "lastUpdatedAt": \(fixedNow - 65_000),
              "fullConversationHeadersOnly": [
                {"type": 1, "createdAt": \(fixedNow - 65_000)},
                {"type": 2, "createdAt": \(fixedNow - 60_000), "bubbleId": "bubble-tool-1"}
              ]
            }
            """
        )
        insertCursorFixtureRecord(
            at: dbURL,
            key: "bubbleId:realistic-active:bubble-tool-1",
            value: #"{"toolFormerData":{"status":"inProgress"}}"#
        )

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        let cursorEvidence = evidence.filter { $0.family == .cursor }
        XCTAssertEqual(cursorEvidence.map(\.identity), ["realistic-active"])
        XCTAssertEqual(cursorEvidence.first?.reason, "tool_call in progress")
    }

    /// Without the bubble lookup, this exact composer (60s-old header, no
    /// embedded legacy status) would be judged stale under the narrower
    /// 45s `turnActiveGraceMs` window — proving the bubble content is what
    /// flips the verdict, not some other coincidental signal.
    func testCursorComposerWithoutResolvableBubbleStaysInactive() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:dangling-bubble",
            valueJSON: """
            {
              "status": "completed",
              "lastUpdatedAt": \(fixedNow - 65_000),
              "fullConversationHeadersOnly": [
                {"type": 1, "createdAt": \(fixedNow - 65_000)},
                {"type": 2, "createdAt": \(fixedNow - 60_000), "bubbleId": "bubble-never-written"}
              ]
            }
            """
        )
        // Deliberately no `bubbleId:dangling-bubble:bubble-never-written` row.

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        XCTAssertTrue(evidence.filter { $0.family == .cursor }.isEmpty)
    }

    /// Requirement 7: the legacy embedded `grouping.toolFormerStatus` shape
    /// this code already, intentionally supports (proven at the pure
    /// assessor level by `testCursorToolStatusInProgressMixedCaseIsActive`)
    /// must keep working through the full real SQLite scan path too, not
    /// just in isolation.
    func testCursorLegacyEmbeddedToolStatusStillActiveThroughSQLitePath() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:legacy-active",
            valueJSON: """
            {
              "status": "completed",
              "lastUpdatedAt": \(fixedNow - 5_000),
              "fullConversationHeadersOnly": [
                {"type": 2, "createdAt": \(fixedNow - 5_000), "grouping": {"toolFormerStatus": "inProgress"}}
              ]
            }
            """
        )

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        let cursorEvidence = evidence.filter { $0.family == .cursor }
        XCTAssertEqual(cursorEvidence.map(\.identity), ["legacy-active"])
        XCTAssertEqual(cursorEvidence.first?.reason, "tool_call in progress")
    }

    /// Duplicate bubble references within one composer must cost exactly
    /// one real SQL lookup — proves the scan batches/dedupes rather than
    /// paying a round trip per (redundant) reference.
    func testCursorDuplicateBubbleReferencesAreLookedUpOnlyOnce() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:duplicate-refs",
            valueJSON: """
            {
              "status": "completed",
              "lastUpdatedAt": \(fixedNow - 65_000),
              "fullConversationHeadersOnly": [
                {"type": 1, "createdAt": \(fixedNow - 65_000)},
                {"type": 2, "createdAt": \(fixedNow - 64_000), "bubbleId": "bubble-dup"},
                {"type": 2, "createdAt": \(fixedNow - 63_000), "bubbleId": "bubble-dup"},
                {"type": 2, "createdAt": \(fixedNow - 60_000), "bubbleId": "bubble-dup"}
              ]
            }
            """
        )
        insertCursorFixtureRecord(
            at: dbURL,
            key: "bubbleId:duplicate-refs:bubble-dup",
            value: #"{"toolFormerData":{"status":"inProgress"}}"#
        )

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }

        var bubbleLookups = 0
        let evidence = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow,
            onBubbleLookup: { bubbleLookups += 1 }
        )

        XCTAssertEqual(evidence.map(\.identity), ["duplicate-refs"])
        XCTAssertEqual(bubbleLookups, 1, "three references to the same bubble id must cost exactly one lookup")
    }

    /// Confirmed defect: the bubble lookup previously treated every
    /// non-`SQLITE_ROW` step result as "this bubble is missing", hiding
    /// genuine operational failures (BUSY/INTERRUPT/IOERR/CORRUPT/...)
    /// behind the same silent "absent" outcome. Reproducing each of these
    /// against a real SQLite connection is impractical (BUSY needs real
    /// lock contention, INTERRUPT needs a concurrent `sqlite3_interrupt`
    /// call, IOERR/CORRUPT need real disk-level faults) —
    /// `simulatedBubbleStepResultCode` is a narrow, test-only seam that
    /// substitutes exactly one C API return value, exercising the real
    /// error-propagation code path (`SQLITE_DONE` is the ONLY step result
    /// that may mean "missing" — see `testCursorComposerWithoutResolvableBubbleStaysInactive`
    /// for that legitimate case) without needing to fabricate the
    /// underlying condition.
    func testCursorBubbleLookupOperationalErrorsPropagateInsteadOfBeingTreatedAsMissing() throws {
        let simulatedFailures: [(code: Int32, expected: CursorSessionScanError)] = [
            (SQLITE_BUSY, .databaseBusy(code: SQLITE_BUSY)),
            (SQLITE_INTERRUPT, .databaseFailure(operation: "read bubble lookup", code: SQLITE_INTERRUPT)),
            (SQLITE_IOERR, .databaseFailure(operation: "read bubble lookup", code: SQLITE_IOERR)),
            (SQLITE_CORRUPT, .databaseFailure(operation: "read bubble lookup", code: SQLITE_CORRUPT)),
        ]

        for (code, expectedError) in simulatedFailures {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let dbURL = home
                .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            makeCursorFixtureDatabase(
                at: dbURL,
                key: "composerData:needs-bubble",
                valueJSON: """
                {
                  "status": "completed",
                  "lastUpdatedAt": \(fixedNow - 65_000),
                  "fullConversationHeadersOnly": [
                    {"type": 1, "createdAt": \(fixedNow - 65_000)},
                    {"type": 2, "createdAt": \(fixedNow - 60_000), "bubbleId": "bubble-error"}
                  ]
                }
                """
            )
            insertCursorFixtureRecord(
                at: dbURL,
                key: "bubbleId:needs-bubble:bubble-error",
                value: #"{"toolFormerData":{"status":"inProgress"}}"#
            )

            let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
            defer { close(fd) }

            do {
                _ = try SessionSnapshotSource.queryCursorComposers(
                    fd: fd,
                    validatedPath: dbURL.path,
                    now: fixedNow,
                    simulatedBubbleStepResultCode: code
                )
                XCTFail("simulated SQLite code \(code) from the bubble lookup must propagate, not be treated as a missing bubble")
            } catch let error as CursorSessionScanError {
                XCTAssertEqual(error, expectedError, "unexpected error shape for simulated code \(code)")
            } catch {
                XCTFail("expected typed CursorSessionScanError for simulated code \(code), got \(error)")
            }
        }
    }

    /// The bubble lookup's bounded `CASE WHEN octet_length(value) <= ?1 ...`
    /// projection must reject an oversized bubble *value* (unlike the
    /// dangling-bubble case above, this row genuinely exists — `sqlite3_step`
    /// returns `SQLITE_ROW`, never `SQLITE_DONE`) purely from the always-safe
    /// `valueByteCount` INTEGER column, without the SQL-level projection or
    /// the Swift accessor ever needing to materialize the oversized text
    /// itself. Confirms the "reject oversize without touching
    /// `sqlite3_column_text`/`_blob`" requirement holds for bubble lookups
    /// exactly as it already does for the composer row scan (see
    /// `testCursorOversizedRowsAreSkippedAndSQLLikeStringsRemainPlainData`),
    /// and that this rejection is a distinct code path from "SQLITE_DONE
    /// means absent" — an existing, oversized row is still correctly treated
    /// as an unusable/absent bubble, never a crash or a truncated read.
    func testCursorOversizedBubbleValueIsTreatedAsAbsentViaBoundedProjection() async throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:oversized-bubble",
            valueJSON: """
            {
              "status": "completed",
              "lastUpdatedAt": \(fixedNow - 65_000),
              "fullConversationHeadersOnly": [
                {"type": 1, "createdAt": \(fixedNow - 65_000)},
                {"type": 2, "createdAt": \(fixedNow - 60_000), "bubbleId": "bubble-oversized"}
              ]
            }
            """
        )
        let oversizedBubbleValue = #"{"toolFormerData":{"status":"inProgress","padding":""#
            + String(repeating: "x", count: cursorMaximumValueBytes)
            + #""}}"#
        insertCursorFixtureRecord(
            at: dbURL,
            key: "bubbleId:oversized-bubble:bubble-oversized",
            value: oversizedBubbleValue
        )

        let evidence = try await NativeSessionSnapshotSource(homeDirectory: home).snapshot(now: fixedNow)

        // Without a resolvable (in-bounds) bubble, this exact 60s-old header
        // falls back to the same "no tool signal" verdict as
        // `testCursorComposerWithoutResolvableBubbleStaysInactive` — proving
        // the oversized bubble was actually rejected, not silently truncated
        // or crashed past, into some other unintended state.
        XCTAssertTrue(evidence.filter { $0.family == .cursor }.isEmpty)
    }

    // MARK: - Cursor: bounded scan adversarial tests (issue A)

    /// Comfortably more than `cursorMaximumInspectedRows`, all sharing the
    /// same old (epoch-zero) recency, plus one genuinely active composer.
    /// Every "old" row is provably no newer than the row-limit sentinel, so
    /// hitting the row cap here must not permanently fail the scan (the
    /// confirmed defect: "throwing whenever >2000 composers permanently
    /// freezes retained state in persistent large DBs").
    func testCursorRowLimitRecoversWhenThousandsOfOldRowsExistBeyondNewestCandidates() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        let totalRows = cursorMaximumInspectedRows + 50
        var records: [(key: String, value: String)] = []
        for index in 0..<totalRows {
            records.append((
                key: String(format: "composerData:row-%05d", index),
                value: #"{"status":"completed","lastUpdatedAt":0}"#
            ))
        }
        records.append((
            key: "composerData:z-active",
            value: #"{"status":"generating","lastUpdatedAt":\#(fixedNow)}"#
        ))
        insertManyCursorFixtureRecords(at: dbURL, records: records)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }
        let evidence = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow
        )

        XCTAssertEqual(evidence.map(\.identity), ["z-active"])
    }

    /// `cursorMaximumInspectedRows + 50` rows, each with its OWN recent (but
    /// non-active — "completed") timestamp a few seconds apart. Ordered
    /// newest-first, the `(cap + 1)`-th row (the sentinel) is still only a
    /// couple of seconds older than `fixedNow` — comfortably inside
    /// `sessionCandidateWindowMs` — so the scan cannot prove every omitted
    /// row is too old to matter, and must still reject rather than risk
    /// silently dropping a real active composer.
    func testCursorRowLimitStillThrowsWhenCutOffCandidateCouldPlausiblyStillBeActive() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        // The (cap + 1)-th row (0-indexed: cursorMaximumInspectedRows) is the
        // sentinel; confirm it really is inside the candidate window so the
        // scan's rejection below is a genuine truncation risk, not a fixture bug.
        XCTAssertLessThan(Int64(cursorMaximumInspectedRows), sessionCandidateWindowMs)

        let totalRows = cursorMaximumInspectedRows + 50
        var records: [(key: String, value: String)] = []
        for index in 0..<totalRows {
            records.append((
                key: String(format: "composerData:recent-%05d", index),
                value: #"{"status":"completed","lastUpdatedAt":\#(fixedNow - Int64(index))}"#
            ))
        }
        insertManyCursorFixtureRecords(at: dbURL, records: records)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }

        var inspectedRows = 0
        do {
            _ = try SessionSnapshotSource.queryCursorComposers(
                fd: fd,
                validatedPath: dbURL.path,
                now: fixedNow,
                onRowInspected: { inspectedRows += 1 }
            )
            XCTFail("a plausibly-active cut-off candidate must fail the scan instead of silently reporting partial results")
        } catch let error as CursorSessionScanError {
            XCTAssertEqual(error, .scanIncomplete(reason: .rowLimit))
        } catch {
            XCTFail("expected typed CursorSessionScanError, got \(error)")
        }

        XCTAssertGreaterThan(inspectedRows, 0)
        XCTAssertLessThanOrEqual(inspectedRows, cursorMaximumInspectedRows)
        XCTAssertLessThan(inspectedRows, totalRows, "must never step through the entire table once bounded")
    }

    /// Regression for the "far-future sentinel treated as safe" defect:
    /// `isRecentTimestamp` reports a far-future timestamp as "not recent"
    /// (its future-skew tolerance rejects it), so the old sentinel check —
    /// which called `isRecentTimestamp` and only flagged `rowLimit` when it
    /// returned `true` — would wrongly treat a corrupted/adversarial
    /// far-future `(cap + 1)`-th row as "safe to truncate", silently
    /// dropping a genuinely active composer ranked behind it. Every filler
    /// row here carries its own unique far-future `lastUpdatedAt`
    /// (~1 year ahead of `fixedNow`), so under `ORDER BY recencyMs DESC`
    /// they all sort ahead of the one hidden, genuinely active composer
    /// (whose recency is the real `fixedNow`), pushing it beyond the row
    /// cap. `isDefinitelyOlderThanWindowLowerBound` must still recognize
    /// the far-future sentinel as inconclusive (not "definitely old") and
    /// the scan must fail closed with `.rowLimit` rather than silently
    /// reporting an empty/partial result.
    func testCursorRowLimitStillThrowsWhenThousandsOfRowsCarryAFarFutureRecency() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        let farFutureBase = fixedNow + 365 * 24 * 60 * 60 * 1000
        let totalRows = cursorMaximumInspectedRows + 50
        var records: [(key: String, value: String)] = []
        for index in 0..<totalRows {
            records.append((
                key: String(format: "composerData:future-%05d", index),
                value: #"{"status":"completed","lastUpdatedAt":\#(farFutureBase + Int64(index))}"#
            ))
        }
        // Hidden, genuinely active composer: ranks behind every far-future
        // filler row above and so falls beyond the row cap.
        records.append((
            key: "composerData:hidden-active",
            value: #"{"status":"generating","lastUpdatedAt":\#(fixedNow)}"#
        ))
        insertManyCursorFixtureRecords(at: dbURL, records: records)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }

        var inspectedRows = 0
        do {
            _ = try SessionSnapshotSource.queryCursorComposers(
                fd: fd,
                validatedPath: dbURL.path,
                now: fixedNow,
                onRowInspected: { inspectedRows += 1 }
            )
            XCTFail("a far-future sentinel must fail the scan instead of being wrongly treated as provably old/safe")
        } catch let error as CursorSessionScanError {
            XCTAssertEqual(error, .scanIncomplete(reason: .rowLimit))
        } catch {
            XCTFail("expected typed CursorSessionScanError, got \(error)")
        }

        XCTAssertGreaterThan(inspectedRows, 0)
        XCTAssertLessThanOrEqual(inspectedRows, cursorMaximumInspectedRows)
        XCTAssertLessThan(inspectedRows, totalRows, "must never step through the entire table once bounded")
    }

    /// "target" gets the lowest `rowid` (inserted first) with an old value,
    /// then `cursorMaximumInspectedRows` filler rows are inserted after it
    /// (all higher `rowid`s, equally old/non-active), then "target" is
    /// UPDATEd in place — mirroring Cursor's real UPSERT behavior — to a
    /// recent/active value while its `rowid` never changes. Under
    /// `ORDER BY rowid DESC` alone, "target" (the lowest rowid) would sort
    /// dead last, behind every filler row, and would never be reached within
    /// the row cap. Validated JSON recency must rank it first instead, since
    /// it is now the newest activity by actual timestamp.
    func testCursorRecencyOrderingRanksUpdatedOldRowidComposerAboveStaleHighRowidComposers() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:target",
            valueJSON: #"{"status":"completed","lastUpdatedAt":0}"#
        )

        var filler: [(key: String, value: String)] = []
        for index in 0..<cursorMaximumInspectedRows {
            filler.append((
                key: String(format: "composerData:filler-%05d", index),
                value: #"{"status":"completed","lastUpdatedAt":0}"#
            ))
        }
        insertManyCursorFixtureRecords(at: dbURL, records: filler)

        updateCursorFixtureRecord(
            at: dbURL,
            key: "composerData:target",
            value: #"{"status":"generating","lastUpdatedAt":\#(fixedNow)}"#
        )

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }
        let evidence = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow
        )

        XCTAssertEqual(evidence.map(\.identity), ["target"])
        XCTAssertEqual(evidence.first?.reason, "generating")
    }

    // MARK: - Cursor row limit + extended recency shapes (header-only /
    // string timestamps): proves `cursorRecencySqlExpression` covering every
    // assessor-active timestamp shape (not just numeric root fields) is load
    // bearing for the row-limit sentinel's safety, not merely cosmetic.
    // Mirrors the analogous section in `main/services/agent-detector.test.ts`.

    /// No root-level `lastUpdatedAt`/`createdAt`/
    /// `conversationCheckpointLastUpdatedAt` at all — this composer's ONLY
    /// recency signal is a `fullConversationHeadersOnly[*].createdAt`.
    /// Before `cursorRecencySqlExpression` covered headers, this row's SQL
    /// recency was `NULL` (unrankable): it sorted dead last under
    /// `ORDER BY recencyMs DESC` no matter how recent its header actually
    /// was, so thousands of "old but numerically rankable" rows could push
    /// it beyond `cursorMaximumInspectedRows` and silently drop it. Inserted
    /// first so it also has the lowest `rowid`, ruling out the `rowid`
    /// tiebreaker from accidentally saving it.
    func testCursorRowLimitRecoversAndDetectsHeaderOnlyActiveComposerDespiteThousandsOfOlderRows() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:header-only-active",
            valueJSON: #"{"fullConversationHeadersOnly":[{"type":1,"createdAt":\#(fixedNow)}]}"#
        )

        // Comfortably more than cursorMaximumInspectedRows, every one an old
        // (epoch-zero), purely-numeric, inactive composer with a strictly
        // higher rowid than the header-only composer above.
        var filler: [(key: String, value: String)] = []
        for index in 0..<(cursorMaximumInspectedRows + 50) {
            filler.append((
                key: String(format: "composerData:old-%05d", index),
                value: #"{"status":"completed","lastUpdatedAt":0}"#
            ))
        }
        insertManyCursorFixtureRecords(at: dbURL, records: filler)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }
        let evidence = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow
        )

        XCTAssertEqual(evidence.map(\.identity), ["header-only-active"])
        XCTAssertEqual(evidence.first?.reason, "user prompt")
    }

    /// The only recency signal is `lastUpdatedAt` as an ISO-8601 string
    /// (`Date.prototype.toISOString()`'s own canonical shape on the TS side;
    /// the exact same string shape `Date.ISO8601FormatStyle` parses here)
    /// instead of a JSON number — before `cursorRecencySqlExpression`
    /// accepted string timestamps, `json_type(...) IN ('integer', 'real')`
    /// excluded it entirely, so this row's SQL recency was also `NULL`.
    func testCursorRowLimitRecoversAndDetectsStringTimestampActiveComposerDespiteThousandsOfOlderRows() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeCursorFixtureDatabase(
            at: dbURL,
            key: "composerData:string-timestamp-active",
            valueJSON: #"{"status":"generating","lastUpdatedAt":"2023-11-14T22:13:20.000Z"}"#
        )
        // Confirms the fixture ISO string really is this suite's `fixedNow`
        // under Swift's own parser, so a match below is a genuine parity
        // proof rather than a coincidence of two independently-chosen values.
        XCTAssertEqual(parseISO8601ToMs("2023-11-14T22:13:20.000Z"), fixedNow)

        var filler: [(key: String, value: String)] = []
        for index in 0..<(cursorMaximumInspectedRows + 50) {
            filler.append((
                key: String(format: "composerData:old-%05d", index),
                value: #"{"status":"completed","lastUpdatedAt":0}"#
            ))
        }
        insertManyCursorFixtureRecords(at: dbURL, records: filler)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }
        let evidence = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow
        )

        XCTAssertEqual(evidence.map(\.identity), ["string-timestamp-active"])
        XCTAssertEqual(evidence.first?.reason, "generating")
    }

    /// Mirrors `testCursorRowLimitStillThrowsWhenCutOffCandidateCouldPlausiblyStillBeActive`
    /// above, but every row's ONLY recency signal is a conversation header's
    /// `createdAt` rather than a root field — proving the new
    /// header-recency contribution participates in the exact same fail-safe
    /// "ambiguous sentinel" check instead of quietly bypassing it (e.g. by
    /// mis-ranking a genuinely recent header-only row as unrankable/old).
    func testCursorRowLimitStillThrowsWhenCutOffCandidateHeaderDerivedTimestampCouldPlausiblyStillBeActive() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        XCTAssertLessThan(Int64(cursorMaximumInspectedRows), sessionCandidateWindowMs)

        let totalRows = cursorMaximumInspectedRows + 50
        var records: [(key: String, value: String)] = []
        for index in 0..<totalRows {
            records.append((
                key: String(format: "composerData:recent-header-%05d", index),
                value: #"{"status":"completed","fullConversationHeadersOnly":[{"type":2,"createdAt":\#(fixedNow - Int64(index))}]}"#
            ))
        }
        insertManyCursorFixtureRecords(at: dbURL, records: records)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }

        var inspectedRows = 0
        do {
            _ = try SessionSnapshotSource.queryCursorComposers(
                fd: fd,
                validatedPath: dbURL.path,
                now: fixedNow,
                onRowInspected: { inspectedRows += 1 }
            )
            XCTFail("a plausibly-active cut-off candidate must fail the scan instead of silently reporting partial results")
        } catch let error as CursorSessionScanError {
            XCTAssertEqual(error, .scanIncomplete(reason: .rowLimit))
        } catch {
            XCTFail("expected typed CursorSessionScanError, got \(error)")
        }

        XCTAssertGreaterThan(inspectedRows, 0)
        XCTAssertLessThanOrEqual(inspectedRows, cursorMaximumInspectedRows)
        XCTAssertLessThan(inspectedRows, totalRows, "must never step through the entire table once bounded")
    }

    /// Same shape as `testCursorRowLimitRecoversWhenThousandsOfOldRowsExistBeyondNewestCandidates`
    /// above, but exercising the new header/string recency paths for the
    /// *old* history itself: every filler row's own recency is unambiguously
    /// old (epoch-zero) via a header `createdAt` or a string `createdAt`,
    /// not a numeric root field — proving old header/string-derived rows
    /// are correctly recognized as old (not accidentally left
    /// unrankable-`NULL`, which would still be "safe" but would defeat the
    /// point of ranking them at all) and so hitting the row cap here must
    /// not permanently fail the scan.
    func testCursorRowLimitRecoversWhenThousandsOfOldRowsCarryOnlyHeaderOrStringDerivedRecency() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        let totalRows = cursorMaximumInspectedRows + 50
        var records: [(key: String, value: String)] = []
        for index in 0..<totalRows {
            if index % 2 == 0 {
                records.append((
                    key: String(format: "composerData:old-header-%05d", index),
                    value: #"{"status":"completed","fullConversationHeadersOnly":[{"type":2,"createdAt":0}]}"#
                ))
            } else {
                records.append((
                    key: String(format: "composerData:old-string-%05d", index),
                    value: #"{"status":"completed","lastUpdatedAt":"1970-01-01T00:00:00.000Z"}"#
                ))
            }
        }
        records.append((
            key: "composerData:z-active",
            value: #"{"status":"generating","lastUpdatedAt":\#(fixedNow)}"#
        ))
        insertManyCursorFixtureRecords(at: dbURL, records: records)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }
        let evidence = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow
        )

        XCTAssertEqual(evidence.map(\.identity), ["z-active"])
    }

    /// Source-level companion to
    /// `testCursorScanLimitConstantsMatchSharedParityFixture` below (and to
    /// `agent-detector.test.ts`'s "byte-count thresholds are bound named
    /// parameters" assertion): the composer and bubble queries must select
    /// a byte-count column plus a bounded `CASE` projection of the value —
    /// never a raw, unbounded `value` column — and must bind the byte
    /// threshold as a real SQLite parameter (`sqlite3_bind_int64`), never
    /// interpolate it into the SQL text. Reads this file's own sibling
    /// production source directly from disk (mirroring how
    /// `TurnAssessorsTests.swift` locates its shared fixture oracle via
    /// `#filePath`) since, unlike the TS worker source, Swift's SQL text
    /// lives as literals inside `queryCursorComposers`/`lookUpBubble`, not
    /// as an exported string constant a purely behavioral test could
    /// introspect directly.
    func testCursorComposerAndBubbleQueriesUseBoundedProjectionAndBoundByteThreshold() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/Detection
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Seer (apps/macos/Seer project root)
            .appendingPathComponent("Sources/Detection/SessionSnapshotSource.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let boundedProjection = "CASE WHEN octet_length(value) <= ?1 THEN value ELSE NULL END AS boundedValue"
        XCTAssertEqual(
            source.components(separatedBy: boundedProjection).count - 1,
            2,
            "both the composer and bubble queries must use the identical bounded CASE projection, never raw `value`"
        )
        XCTAssertEqual(
            source.components(separatedBy: "octet_length(value) AS valueByteCount").count - 1,
            2,
            "both queries must also select the always-safe-to-read byte-count column"
        )
        XCTAssertTrue(source.contains("sqlite3_bind_int64(statement, 1, Int64(cursorMaximumValueBytes))"))
        XCTAssertTrue(source.contains("sqlite3_bind_int64(bubbleStatement, 1, Int64(cursorMaximumValueBytes))"))

        // Never a bare, unbounded raw-`value` selection (the pre-fix shape)
        // reintroduced by accident.
        XCTAssertFalse(source.contains("SELECT key, value,"))
        XCTAssertFalse(source.contains("SELECT value FROM cursorDiskKV"))
    }

    /// Many rows that never match `key LIKE 'composerData:%'` must stay
    /// cheap: `key` is the table's primary key, so the `WHERE` clause seeks
    /// directly to the matching key range instead of forcing SQLite to
    /// evaluate `cursorRecencySqlExpression`/`ORDER BY` against every
    /// unrelated row in a much larger table. Guards against a regression
    /// that would silently turn this into an O(table size) scan and
    /// jeopardize the deadline's ability to keep the scan bounded.
    func testCursorScanRemainsFastAndSucceedsWithManyNonMatchingRows() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        insertManyNonMatchingCursorFixtureRecords(at: dbURL, count: 300_000)
        insertCursorFixtureRecord(
            at: dbURL,
            key: "composerData:needle",
            value: #"{"status":"generating","lastUpdatedAt":\#(fixedNow)}"#
        )

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }

        let started = Date()
        let evidence = try SessionSnapshotSource.queryCursorComposers(
            fd: fd,
            validatedPath: dbURL.path,
            now: fixedNow,
            // Comfortably shorter than the real 4s production deadline, but
            // generous enough to rule out flakes: an index-driven prefix
            // scan over 300K unrelated rows must finish in well under a
            // second, not merely "eventually" inside the full deadline.
            deadlineMillisecondsOverride: 2_000
        )
        let elapsedSeconds = Date().timeIntervalSince(started)

        XCTAssertEqual(evidence.map(\.identity), ["needle"])
        XCTAssertLessThan(elapsedSeconds, 2, "300K non-matching rows must never approach the deadline")
    }

    /// Many medium composer rows whose sum exceeds
    /// `cursorMaximumTotalDecodedValueBytes`, even though each is
    /// individually within the per-row `cursorMaximumValueBytes` cap, must
    /// still fail the scan conservatively — the aggregate cap is
    /// independent of the per-row cap.
    func testCursorCumulativeDecodedByteLimitExceededThrowsScanIncomplete() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        let padding = String(repeating: "x", count: 3_500_000)
        var records: [(key: String, value: String)] = []
        for index in 0..<20 {
            records.append((
                key: String(format: "composerData:big-%02d", index),
                value: #"{"status":"completed","lastUpdatedAt":0,"padding":""# + padding + #""}"#
            ))
        }
        insertManyCursorFixtureRecords(at: dbURL, records: records)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }

        do {
            _ = try SessionSnapshotSource.queryCursorComposers(fd: fd, validatedPath: dbURL.path, now: fixedNow)
            XCTFail("exceeding the cumulative decoded-byte cap must fail the scan instead of silently reporting partial results")
        } catch let error as CursorSessionScanError {
            XCTAssertEqual(error, .scanIncomplete(reason: .decodedByteLimit))
        } catch {
            XCTFail("expected typed CursorSessionScanError, got \(error)")
        }
    }

    /// Many distinct, plausibly-recent composers each referencing
    /// `cursorMaximumRecentHeadersPerComposer` distinct bubble ids
    /// collectively exceed the global `cursorMaximumBubbleLookups` budget —
    /// the scan must fail conservatively rather than silently stop looking
    /// up bubbles (which could hide a genuinely running tool call).
    func testCursorBubbleLookupLimitExceededThrowsScanIncomplete() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        // 55 * 8 = 440 distinct bubble references > cursorMaximumBubbleLookups (400).
        let composerCount = 55
        var records: [(key: String, value: String)] = []
        for composerIndex in 0..<composerCount {
            var headers: [String] = []
            for bubbleIndex in 0..<cursorMaximumRecentHeadersPerComposer {
                headers.append(
                    #"{"type":2,"createdAt":\#(fixedNow - 60_000 + Int64(bubbleIndex)),"bubbleId":"tool-\#(composerIndex)-\#(bubbleIndex)"}"#
                )
            }
            let value = """
            {"status":"completed","lastUpdatedAt":\(fixedNow - 61_000),"fullConversationHeadersOnly":[\(headers.joined(separator: ","))]}
            """
            records.append((key: "composerData:many-bubbles-\(composerIndex)", value: value))
        }
        insertManyCursorFixtureRecords(at: dbURL, records: records)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }

        var bubbleLookups = 0
        do {
            _ = try SessionSnapshotSource.queryCursorComposers(
                fd: fd,
                validatedPath: dbURL.path,
                now: fixedNow,
                onBubbleLookup: { bubbleLookups += 1 }
            )
            XCTFail("exceeding the bubble-lookup cap must fail the scan instead of silently reporting partial results")
        } catch let error as CursorSessionScanError {
            XCTAssertEqual(error, .scanIncomplete(reason: .bubbleLookupLimit))
        } catch {
            XCTFail("expected typed CursorSessionScanError, got \(error)")
        }

        XCTAssertGreaterThan(bubbleLookups, 0)
        XCTAssertLessThanOrEqual(bubbleLookups, cursorMaximumBubbleLookups)
    }

    /// A slow-processing scan (simulated via `onRowInspected`) that exceeds
    /// its deadline before naturally exhausting the result set must fail the
    /// scan rather than report only what it managed to inspect in time.
    func testCursorDeadlineExhaustionThrowsScanIncompleteBeforeInspectingAllRows() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        makeEmptyCursorFixtureDatabase(at: dbURL)

        let totalRows = 40
        var records: [(key: String, value: String)] = []
        for index in 0..<totalRows {
            records.append((
                key: String(format: "composerData:slow-%02d", index),
                value: #"{"status":"completed","lastUpdatedAt":0}"#
            ))
        }
        insertManyCursorFixtureRecords(at: dbURL, records: records)

        let fd = try XCTUnwrap(SessionSnapshotSource.openVerifiedRegularFile(at: dbURL.path, root: canonicalRoot(home)))
        defer { close(fd) }

        var inspectedRows = 0
        do {
            _ = try SessionSnapshotSource.queryCursorComposers(
                fd: fd,
                validatedPath: dbURL.path,
                now: fixedNow,
                onRowInspected: {
                    inspectedRows += 1
                    usleep(5_000) // 5ms per row: a handful of rows blows a 20ms deadline.
                },
                deadlineMillisecondsOverride: 20
            )
            XCTFail("a scan that exceeds its deadline must fail instead of silently reporting partial results")
        } catch let error as CursorSessionScanError {
            XCTAssertEqual(error, .scanIncomplete(reason: .deadline))
        } catch {
            XCTFail("expected typed CursorSessionScanError, got \(error)")
        }

        XCTAssertGreaterThan(inspectedRows, 0)
        XCTAssertLessThan(inspectedRows, totalRows, "must stop before exhausting all rows once the deadline passes")
    }

    /// Cross-language parity: both Swift and TypeScript load the same shared
    /// fixture (`tests/fixtures/agent-detection/cursor-scan-limits.json`) and
    /// assert their own bound constants against it, so the two
    /// implementations can never silently drift apart on these numbers.
    func testCursorScanLimitConstantsMatchSharedParityFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/Detection
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Seer (apps/macos/Seer project root)
            .deletingLastPathComponent() // apps/macos
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("tests/fixtures/agent-detection/cursor-scan-limits.json")
        let data = try Data(contentsOf: url)
        let limits = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual((limits["cursorMaximumValidCandidates"] as? NSNumber)?.intValue, cursorMaximumValidCandidates)
        XCTAssertEqual((limits["cursorMaximumKeyBytes"] as? NSNumber)?.intValue, cursorMaximumKeyBytes)
        XCTAssertEqual((limits["cursorMaximumValueBytes"] as? NSNumber)?.intValue, cursorMaximumValueBytes)
        XCTAssertEqual(
            (limits["cursorSQLiteBusyTimeoutMilliseconds"] as? NSNumber)?.int32Value,
            cursorSQLiteBusyTimeoutMilliseconds
        )
        XCTAssertEqual(
            (limits["cursorSQLiteQueryDeadlineMilliseconds"] as? NSNumber)?.intValue,
            cursorSQLiteQueryDeadlineMilliseconds
        )
        XCTAssertEqual((limits["cursorMaximumInspectedRows"] as? NSNumber)?.intValue, cursorMaximumInspectedRows)
        XCTAssertEqual(
            (limits["cursorMaximumTotalDecodedValueBytes"] as? NSNumber)?.intValue,
            cursorMaximumTotalDecodedValueBytes
        )
        XCTAssertEqual((limits["cursorMaximumBubbleLookups"] as? NSNumber)?.intValue, cursorMaximumBubbleLookups)
        XCTAssertEqual(
            (limits["cursorMaximumRecentHeadersPerComposer"] as? NSNumber)?.intValue,
            cursorMaximumRecentHeadersPerComposer
        )
    }

}
