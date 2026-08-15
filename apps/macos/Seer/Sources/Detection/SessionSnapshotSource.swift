import Darwin
import Foundation
import SQLite3

/// One agent family's assessed-active session/transcript turn, ready to be
/// merged with process evidence by `AgentDetector`. Produced only for turns
/// a format-specific assessor (`TurnAssessors.swift`) judged `active` —
/// idle/stale candidates never reach this type.
public struct SessionTurnEvidence: Equatable, Sendable {
    public let family: AgentFamily
    /// A stable identity within the family: the transcript's absolute path
    /// for file-backed formats, or the Cursor composer key for `.cursor`.
    public let identity: String
    public let label: String?
    public let reason: String
    public let lastActivityAt: Int64

    public init(family: AgentFamily, identity: String, label: String?, reason: String, lastActivityAt: Int64) {
        self.family = family
        self.identity = identity
        self.label = label
        self.reason = reason
        self.lastActivityAt = lastActivityAt
    }
}

/// Injectable source of session/transcript evidence. Production code is
/// `NativeSessionSnapshotSource`; tests substitute a stub that never reads
/// real session data or a real home directory.
public protocol SessionSnapshotProviding: Sendable {
    func snapshot(now: Int64) async throws -> [SessionTurnEvidence]
}

// MARK: - Bounds (exact values from the approved plan)

/// Maximum recursion depth walked beneath each configured session root.
public let sessionMaximumWalkDepth = 5
/// Maximum number of candidate files collected per configured root before
/// traversal of that root stops early.
public let sessionMaximumFilesPerRoot = 400
/// Maximum number of freshest candidates actually assessed (opened/read) per
/// family, across all of that family's configured roots combined.
public let sessionMaximumAssessedCandidates = 24
/// Maximum number of trailing bytes read from a transcript file when
/// looking for recent turn events.
public let sessionTailReadBytes = 120_000
/// Maximum number of leading bytes read from a Codex rollout file when
/// falling back to a raw `"cwd"` scan for a project label.
public let codexHeadReadBytes = 32_000

private let sessionSkippedDirectoryNames: Set<String> = [".git", "node_modules", "cache", "subagents"]
/// Bounds how many Cursor composer rows are inspected per scan — composer
/// blobs are individually small, but the table can accumulate a very large
/// history over time.
private let cursorMaximumRows = 200
/// Bounds how large a single composer JSON blob this reader will parse,
/// defending against a pathological/corrupted row forcing an unbounded
/// `JSONSerialization` allocation.
private let cursorMaximumValueBytes = 4_000_000

/// One session/transcript candidate discovered during a bounded directory
/// walk, prior to being opened or assessed.
struct SessionCandidate: Equatable {
    let path: String
    let mtimeMs: Int64
    let label: String
}

/// Native, bounded session/transcript source. Canonicalizes every
/// configured root beneath `homeDirectory` (never a hardcoded real home —
/// production passes the real home, tests pass a synthetic temporary
/// directory), rejects any root or traversed path that resolves outside it,
/// and opens every transcript file through an `O_NOFOLLOW` + root-containment
/// checked descriptor sequence (see `SessionSnapshotSource.openVerifiedRegularFile`).
/// Reuses Task 7's pure turn assessors (`TurnAssessors.swift`) for every
/// format-specific active/idle judgement — no classification logic is
/// duplicated here.
public struct NativeSessionSnapshotSource: SessionSnapshotProviding {
    public let homeDirectory: URL

    public init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    public func snapshot(now: Int64) async throws -> [SessionTurnEvidence] {
        guard let homeCanonical = SessionSnapshotSource.canonicalPath(of: homeDirectory.path) else {
            // Home directory doesn't exist / isn't resolvable: no evidence
            // is possible, but this is not itself a scan failure.
            return []
        }

        var evidence: [SessionTurnEvidence] = []
        for kind in AGENT_KINDS {
            // Defense-in-depth only, checked once per family: this alone
            // does not guarantee a prompt `AgentMonitor.stop()` return
            // (`stop()` never awaits this task's cooperation), but it lets
            // a cancelled traversal unwind between families rather than
            // always walking every configured root to completion.
            try Task.checkCancellation()
            switch kind.sessionFormat {
            case .none:
                continue
            case .cursor:
                evidence.append(contentsOf: SessionSnapshotSource.cursorEvidence(homeDirectory: homeDirectory, homeCanonical: homeCanonical, now: now))
            case .claude, .codex, .grok, .genericMtime:
                evidence.append(contentsOf: SessionSnapshotSource.familyEvidence(kind: kind, homeDirectory: homeDirectory, homeCanonical: homeCanonical, now: now))
            }
        }
        return evidence
    }
}

/// Namespace for the bounded, symlink-hardened traversal/read primitives
/// backing `NativeSessionSnapshotSource`. Kept as free functions on an
/// internal enum (rather than private members of the public struct) so
/// `SessionSnapshotSourceTests` can exercise each bound and each hardening
/// check directly and quickly, without standing up a full synthetic home
/// directory tree for every assertion.
enum SessionSnapshotSource {
    // MARK: - Path canonicalization

    static func canonicalPath(of path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `candidate` is exactly `root` or a path beneath it.
    /// Comparing against `root + "/"` (not a bare prefix) avoids a
    /// same-prefix sibling (e.g. `/home/user2`) being misclassified as
    /// contained within `/home/user`.
    static func isPath(_ candidate: String, containedIn root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Canonicalizes a configured session root (a fixed relative path from
    /// `AgentKind.sessionRoots`) beneath the canonical home directory, and
    /// rejects it outright if it resolves outside that home — e.g. a
    /// symlinked ancestor directory pointing elsewhere.
    static func canonicalConfiguredRoot(homeDirectory: URL, homeCanonical: String, relativePath: String) -> String? {
        let configuredURL = homeDirectory.appendingPathComponent(relativePath, isDirectory: true)
        guard let canonical = canonicalPath(of: configuredURL.path) else { return nil }
        guard isPath(canonical, containedIn: homeCanonical) else { return nil }
        return canonical
    }

    // MARK: - Bounded directory walk

    /// Collects every session-file candidate beneath `root` (already
    /// canonicalized and verified contained within home), bounded by
    /// `sessionMaximumWalkDepth` and `sessionMaximumFilesPerRoot`, and
    /// filtered to the recent-activity candidate window. Every directory
    /// entry is inspected with `lstat` (never `stat`) so symlinked
    /// directories are never descended into and symlinked files are never
    /// collected as candidates — both are silently skipped, not opened.
    static func collectCandidates(
        root: String,
        extensions: [String],
        fileNames: [String]?,
        now: Int64
    ) -> [SessionCandidate] {
        var hits: [SessionCandidate] = []
        walk(directory: root, depth: 0, root: root, extensions: extensions, fileNames: fileNames, now: now, hits: &hits)
        hits.sort { $0.mtimeMs > $1.mtimeMs }
        return hits
    }

    private static func walk(
        directory: String,
        depth: Int,
        root: String,
        extensions: [String],
        fileNames: [String]?,
        now: Int64,
        hits: inout [SessionCandidate]
    ) {
        guard hits.count < sessionMaximumFilesPerRoot else { return }
        guard depth <= sessionMaximumWalkDepth else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }

        // Deterministic traversal order regardless of the filesystem's own
        // (unspecified) directory-entry ordering.
        for name in entries.sorted() {
            guard hits.count < sessionMaximumFilesPerRoot else { return }
            let fullPath = directory + "/" + name

            var entryStat = stat()
            guard lstat(fullPath, &entryStat) == 0 else { continue }
            let mode = entryStat.st_mode & S_IFMT

            if mode == S_IFDIR {
                guard !sessionSkippedDirectoryNames.contains(name) else { continue }
                walk(directory: fullPath, depth: depth + 1, root: root, extensions: extensions, fileNames: fileNames, now: now, hits: &hits)
                continue
            }

            // Anything that isn't a plain regular file — most importantly
            // a symlink, but also devices/FIFOs/sockets — is never
            // considered a candidate.
            guard mode == S_IFREG else { continue }

            if let fileNames, !fileNames.contains(name) { continue }
            guard extensions.contains(where: { name.hasSuffix($0) }) else { continue }
            guard isPath(fullPath, containedIn: root) else { continue }

            let mtimeMs = mtimeMilliseconds(from: entryStat)
            guard isRecentTimestamp(mtimeMs, now: now, within: sessionCandidateWindowMs) else { continue }

            hits.append(SessionCandidate(path: fullPath, mtimeMs: mtimeMs, label: friendlySessionLabel(fullPath)))
        }
    }

    static func mtimeMilliseconds(from st: stat) -> Int64 {
        let seconds = Int64(st.st_mtimespec.tv_sec)
        let nanoseconds = Int64(st.st_mtimespec.tv_nsec)
        let millisFromSeconds = saturatingInt64Multiply(seconds, 1000)
        let (total, overflow) = millisFromSeconds.addingReportingOverflow(nanoseconds / 1_000_000)
        return overflow ? (millisFromSeconds < 0 ? Int64.min : Int64.max) : total
    }

    private static func saturatingInt64Multiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? (a < 0 ? Int64.min : Int64.max) : result
    }

    // MARK: - Symlink-hardened, bounded file open + read

    /// Opens `path` for reading only after: (1) rejecting a symlinked
    /// parent directory outright via `lstat`, (2) canonicalizing the
    /// parent directory and verifying it is still contained within `root`
    /// — the "root-contained standardized prefix check immediately before
    /// open" — and (3) opening the canonical parent with `O_NOFOLLOW`, then
    /// `openat`-ing the basename with `O_NOFOLLOW | O_CLOEXEC`, refusing to
    /// ever follow a symlink substituted at either the parent or the leaf.
    /// A final `fstat` on the resulting descriptor rejects anything that
    /// isn't a plain regular file. Returns `nil` (not a thrown error) for
    /// any rejection — callers treat that identically to "no readable
    /// session here," per the requirement that one bad entry must not
    /// abort the whole family scan.
    static func openVerifiedRegularFile(at path: String, root: String) -> Int32? {
        let parentPath = (path as NSString).deletingLastPathComponent
        var parentStat = stat()
        guard lstat(parentPath, &parentStat) == 0 else { return nil }
        guard (parentStat.st_mode & S_IFMT) != S_IFLNK else { return nil }

        guard let canonicalParent = canonicalPath(of: parentPath) else { return nil }
        guard isPath(canonicalParent, containedIn: root) else { return nil }

        let dirFD = canonicalParent.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dirFD >= 0 else { return nil }

        var openedDirStat = stat()
        guard fstat(dirFD, &openedDirStat) == 0, (openedDirStat.st_mode & S_IFMT) == S_IFDIR else {
            close(dirFD)
            return nil
        }

        let basename = (path as NSString).lastPathComponent
        let fd = basename.withCString { openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        close(dirFD)
        guard fd >= 0 else { return nil }

        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }

        return fd
    }

    /// Reads up to `length` bytes starting at `offset` from an already
    /// symlink-verified descriptor, retrying on `EINTR` and looping over
    /// short reads. Stops cleanly at end-of-file (returning whatever was
    /// actually read) rather than assuming `length` bytes are always
    /// available — this is what keeps short, growing, or concurrently
    /// truncated files safe to read: a file that shrank between `fstat`
    /// and this read simply yields fewer bytes than requested instead of
    /// reading garbage or crashing.
    static func boundedPRead(fd: Int32, offset: off_t, length: Int) -> Data? {
        guard length > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: length)
        var totalRead = 0
        while totalRead < length {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return pread(fd, base.advanced(by: totalRead), length - totalRead, offset + off_t(totalRead))
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return totalRead > 0 ? Data(buffer.prefix(totalRead)) : nil
            }
            if bytesRead == 0 { break } // EOF: short/truncated file, stop cleanly.
            totalRead += bytesRead
        }
        return Data(buffer.prefix(totalRead))
    }

    static func fileSize(fd: Int32) -> Int? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return Int(st.st_size)
    }

    /// Reads at most `sessionTailReadBytes` from the end of the file at
    /// `fd`, tolerating a mid-line start by reporting whether the first
    /// returned line is partial (so the caller can drop it).
    static func readTail(fd: Int32, maxBytes: Int) -> (data: Data, droppedPartialFirstLine: Bool)? {
        guard let size = fileSize(fd: fd) else { return nil }
        guard size > 0 else { return (Data(), false) }
        let start = max(0, size - maxBytes)
        let length = size - start
        guard let data = boundedPRead(fd: fd, offset: off_t(start), length: length) else { return nil }
        return (data, start > 0)
    }

    static func readHead(fd: Int32, maxBytes: Int) -> Data? {
        guard let size = fileSize(fd: fd) else { return nil }
        guard size > 0 else { return Data() }
        return boundedPRead(fd: fd, offset: 0, length: min(size, maxBytes))
    }

    /// Parses newline-delimited JSON tolerating corrupt/partial lines,
    /// mirroring the production TypeScript tail reader's leniency exactly.
    static func parseTailLines(_ data: Data, droppedPartialFirstLine: Bool) -> [JSONObject] {
        var completeLines = data
        if droppedPartialFirstLine {
            guard let newline = completeLines.firstIndex(of: 0x0A) else { return [] }
            completeLines = completeLines.subdata(in: completeLines.index(after: newline)..<completeLines.endIndex)
        }
        guard let text = String(data: completeLines, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")

        var events: [JSONObject] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: lineData)) as? JSONObject else { continue }
            events.append(object)
        }
        return events
    }

    /// Raw regex scan for a top-level `"cwd"` field in a Codex rollout's
    /// bounded head bytes, used only as a fallback when the tail-derived
    /// events didn't carry a `cwd` (see `assessCodexTurn`/`codexProjectLabel`).
    static func extractCodexHeadCwd(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #""cwd"\s*:\s*"((?:[^"\\]|\\.)*)""#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        guard let cwdRange = Range(match.range(at: 1), in: text) else { return nil }
        let escaped = String(text[cwdRange])
        let unescaped = escaped.replacingOccurrences(of: "\\/", with: "/")
        return codexProjectLabelFromPath(unescaped)
    }

    // MARK: - Per-family evidence assembly

    static func familyEvidence(kind: AgentKind, homeDirectory: URL, homeCanonical: String, now: Int64) -> [SessionTurnEvidence] {
        var candidates: [SessionCandidate] = []
        for relativeRoot in kind.sessionRoots {
            guard let canonicalRoot = canonicalConfiguredRoot(homeDirectory: homeDirectory, homeCanonical: homeCanonical, relativePath: relativeRoot) else {
                continue
            }
            candidates.append(contentsOf: collectCandidates(
                root: canonicalRoot,
                extensions: kind.sessionExtensions,
                fileNames: kind.sessionFileNames,
                now: now
            ))
        }

        candidates.sort { $0.mtimeMs > $1.mtimeMs }
        let assessed = candidates.prefix(sessionMaximumAssessedCandidates)

        var evidence: [SessionTurnEvidence] = []
        for candidate in assessed {
            guard let root = kind.sessionRoots.compactMap({ canonicalConfiguredRoot(homeDirectory: homeDirectory, homeCanonical: homeCanonical, relativePath: $0) })
                .first(where: { isPath(candidate.path, containedIn: $0) }) else { continue }

            let assessment = assessCandidate(kind: kind, candidate: candidate, root: root, now: now)
            guard assessment.active else { continue }

            let label = assessment.label ?? (candidate.label.isEmpty ? nil : candidate.label)
            evidence.append(SessionTurnEvidence(
                family: kind.id,
                identity: candidate.path,
                label: label,
                reason: assessment.reason,
                lastActivityAt: assessment.lastActivityAt
            ))
        }
        return evidence
    }

    private static func assessCandidate(kind: AgentKind, candidate: SessionCandidate, root: String, now: Int64) -> TurnAssessment {
        if kind.sessionFormat == .genericMtime {
            return assessGenericMtime(mtimeMs: candidate.mtimeMs, now: now)
        }

        guard let fd = openVerifiedRegularFile(at: candidate.path, root: root) else {
            return TurnAssessment(active: false, lastActivityAt: candidate.mtimeMs, reason: "unreadable session")
        }
        defer { close(fd) }

        guard let (tailData, droppedPartial) = readTail(fd: fd, maxBytes: sessionTailReadBytes) else {
            return TurnAssessment(active: false, lastActivityAt: candidate.mtimeMs, reason: "unreadable session")
        }
        let events = parseTailLines(tailData, droppedPartialFirstLine: droppedPartial)

        switch kind.sessionFormat {
        case .claude:
            return assessClaudeTurn(events, mtimeMs: candidate.mtimeMs, now: now)
        case .grok:
            return assessGrokTurn(events, mtimeMs: candidate.mtimeMs, now: now)
        case .codex:
            let assessment = assessCodexTurn(events, mtimeMs: candidate.mtimeMs, now: now)
            guard assessment.active, assessment.label == nil else { return assessment }
            guard let headData = readHead(fd: fd, maxBytes: codexHeadReadBytes),
                  let label = extractCodexHeadCwd(headData) else { return assessment }
            return TurnAssessment(active: assessment.active, lastActivityAt: assessment.lastActivityAt, reason: assessment.reason, label: label)
        case .genericMtime, .none, .cursor:
            return TurnAssessment(active: false, lastActivityAt: candidate.mtimeMs, reason: "no session format")
        }
    }

    // MARK: - Cursor (SQLite)

    /// Cursor's IDE composer/agent state lives in a fixed, known path
    /// beneath home: `Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
    /// Applies the exact same lstat/no-symlink/root-containment sequence as
    /// every other transcript before ever touching SQLite, then opens the
    /// database read-only via the SQLite C API through the already
    /// symlink-verified descriptor (`/dev/fd/<fd>`), so SQLite's own
    /// internal `open()` can never be tricked into following a symlink
    /// substituted after the verification above. Never shells out to
    /// `sqlite3`.
    static func cursorEvidence(homeDirectory: URL, homeCanonical: String, now: Int64) -> [SessionTurnEvidence] {
        let dbURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb", isDirectory: false)

        guard let fd = openVerifiedRegularFile(at: dbURL.path, root: homeCanonical) else { return [] }
        defer { close(fd) }

        return queryCursorComposers(fd: fd, now: now)
    }

    private static func queryCursorComposers(fd: Int32, now: Int64) -> [SessionTurnEvidence] {
        // Read-only, immutable URI over the already-verified descriptor —
        // SQLite is never given the original path string, so it cannot
        // reopen (and potentially follow a symlink at) a different inode
        // than the one already checked above.
        let uri = "file:/dev/fd/\(fd)?immutable=1"
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer {
            if let db { sqlite3_close(db) }
        }
        guard openRC == SQLITE_OK, let db else { return [] }

        let sinceMs = now - sessionCandidateWindowMs
        let sql = """
        SELECT key, value FROM cursorDiskKV
        WHERE key LIKE 'composerData:%'
          AND value IS NOT NULL
          AND (
            json_extract(value, '$.status') = 'generating'
            OR json_extract(value, '$.isContinuationInProgress') = 1
            OR json_array_length(COALESCE(json_extract(value, '$.generatingBubbleIds'), '[]')) > 0
            OR COALESCE(json_extract(value, '$.conversationCheckpointLastUpdatedAt'), 0) >= ?
            OR COALESCE(json_extract(value, '$.lastUpdatedAt'), 0) >= ?
            OR COALESCE(json_extract(value, '$.createdAt'), 0) >= ?
          )
        LIMIT \(cursorMaximumRows)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sinceMs)
        sqlite3_bind_int64(statement, 2, sinceMs)
        sqlite3_bind_int64(statement, 3, sinceMs)

        var evidence: [SessionTurnEvidence] = []
        var rowCount = 0
        while rowCount < cursorMaximumRows, sqlite3_step(statement) == SQLITE_ROW {
            rowCount += 1

            guard let keyCString = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyCString)

            guard let valueCString = sqlite3_column_text(statement, 1) else { continue }
            let valueByteCount = Int(sqlite3_column_bytes(statement, 1))
            // Bounded blob processing: skip (never log) anything
            // implausibly large for a composer record.
            guard valueByteCount > 0, valueByteCount <= cursorMaximumValueBytes else { continue }
            let valueString = String(cString: valueCString)

            guard let valueData = valueString.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: valueData)) as? JSONObject else { continue }

            let assessment = assessCursorComposerRecord(record, now: now)
            guard assessment.active else { continue }

            let identity = key.hasPrefix("composerData:") ? String(key.dropFirst("composerData:".count)) : key
            evidence.append(SessionTurnEvidence(
                family: .cursor,
                identity: identity,
                label: assessment.label,
                reason: assessment.reason,
                lastActivityAt: assessment.lastActivityAt
            ))
        }

        evidence.sort { $0.lastActivityAt > $1.lastActivityAt }
        return evidence
    }
}
