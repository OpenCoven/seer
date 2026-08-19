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
/// older candidates are discarded.
public let sessionMaximumFilesPerRoot = 400
/// Maximum directory entries inspected per root, including stale, unrelated,
/// malformed, and excluded entries.
public let sessionMaximumInspectedEntriesPerRoot = 2_048
/// Maximum directories opened per root, independently of the entry limit.
public let sessionMaximumInspectedDirectoriesPerRoot = 128
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
/// Bounds retained active Cursor composers after each row has independently
/// passed key/value, JSON-shape, and activity validation. Reaching this cap
/// is an intentional early exit (plenty of concurrent agents already found),
/// never treated as a truncated/incomplete scan.
let cursorMaximumValidCandidates = 200
/// Bounds composer identifiers before allocating Swift strings for untrusted keys.
let cursorMaximumKeyBytes = 4_096
/// Bounds how large a single composer or bubble JSON blob this reader will
/// parse, defending against a pathological/corrupted row forcing an
/// unbounded `JSONSerialization` allocation.
let cursorMaximumValueBytes = 4_000_000
/// Keeps a locked live Cursor database from stalling the three-second scan loop.
let cursorSQLiteBusyTimeoutMilliseconds: Int32 = 100
let cursorSQLiteQueryDeadlineMilliseconds = 4_000
/// Hard cap on TOTAL `composerData:*` rows stepped through in one scan,
/// counting inactive, malformed, duplicate, and active rows alike — unlike
/// `cursorMaximumValidCandidates`, this bounds work regardless of how many
/// rows turn out to be active. The composer query's SQL `LIMIT` is this
/// value **+ 1**: if the (cap + 1)-th row is actually delivered by SQLite,
/// more matching rows exist beyond what was inspected, so the scan must be
/// treated as truncated rather than silently reporting only what it saw.
let cursorMaximumInspectedRows = 2_000
/// Hard cap on the cumulative bytes handed to `JSONSerialization` in one
/// scan, summed across every composer AND bubble value decoded — bounds
/// aggregate CPU/memory cost independent of the per-row
/// `cursorMaximumValueBytes` cap (many medium rows can otherwise add up to
/// an unbounded total even though no single row is individually oversized).
let cursorMaximumTotalDecodedValueBytes = 64_000_000
/// Hard cap on total distinct `bubbleId:<composerId>:<bubbleId>` point
/// lookups performed in one scan, deduplicated globally so repeated or
/// duplicate references never cost more than a single lookup.
let cursorMaximumBubbleLookups = 400

/// Name under which `cursorRecencySqlExpression`'s generated SQL calls
/// `cursorCanonicalIsoStringToEpochMs` (`TurnAssessors.swift`) as a
/// registered SQLite scalar function, via `sqlite3_create_function_v2` in
/// `queryCursorComposers`. Matches
/// `CURSOR_TIMESTAMP_SQL_FUNCTION_NAME`/`cursor_canonical_iso_to_epoch_ms`
/// on the TS side (`agent-detection-policy.ts`) — the two are otherwise
/// independent string literals with no shared build-time constant across
/// languages, so this is asserted equal by the parity test suite rather
/// than statically enforced.
let cursorTimestampSqlFunctionName = "cursor_canonical_iso_to_epoch_ms"

/// C callback registered as the `cursorTimestampSqlFunctionName` SQLite
/// scalar function via `sqlite3_create_function_v2` in
/// `queryCursorComposers` below. A free (non-capturing) top-level function,
/// exactly like this file's existing `sqlite3_progress_handler` callback
/// closure (see below), so it converts implicitly to the `@convention(c)`
/// function pointer `sqlite3_create_function_v2` expects.
///
/// Mirrors TS's `cursorCanonicalIsoStringToEpochMs` SQL-function wrapper:
/// extracts `argv[0]` (the raw JSON value under test) as text and
/// `argv[1..3]` as the `minYear`/`maxYear`/`maxOffsetMinutes` bounds
/// `cursorRecencySqlExpression` bakes into the generated SQL as literal
/// integers, then defers to `cursorCanonicalIsoStringToEpochMs`
/// (`TurnAssessors.swift`) — the *exact* same Swift function
/// `parseCursorTimestamp`'s own string branch already calls, so there is
/// only ever one Swift implementation of this grammar/arithmetic to keep
/// correct; SQLite itself never re-derives the value on its own.
///
/// Defensive beyond what a same-Swift caller needs, because SQLite hands
/// this callback raw `sqlite3_value*` arguments whose runtime SQL type may
/// not match what `cursorRecencySqlExpression`'s own `json_type(...) =
/// 'text'` guard already checked before ever generating this call: this
/// callback still degrades safely (calling `sqlite3_result_null`, never
/// trapping) for any unexpected argument count or non-text first argument,
/// exactly like an unparseable string would resolve — a thrown/trapped
/// callback would abort the whole query, which is exactly the "one
/// malformed row poisons every other row's evidence" failure mode this
/// codebase's NULL-on-anything-invalid convention exists to avoid.
///
/// Deliberately internal (not `private`): `TurnAssessorsTests.swift`'s and
/// `SessionSnapshotSourceTests.swift`'s own throwaway `:memory:` SQLite
/// connections must register this exact same callback under
/// `cursorTimestampSqlFunctionName` before they can execute
/// `cursorRecencySqlExpression` themselves — mirroring how the TS parity
/// suite's `sqlRecencyForRawValue` registers `cursorCanonicalIsoStringToEpochMs`
/// on its own `node:sqlite` connection rather than only ever running the
/// SQL through the one production call site.
func cursorCanonicalIsoToEpochMsXFunc(
    _ context: OpaquePointer?,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard let context else { return }
    guard let argv, argc == 4, sqlite3_value_type(argv[0]) == SQLITE_TEXT,
          let textPointer = sqlite3_value_text(argv[0])
    else {
        sqlite3_result_null(context)
        return
    }
    let value = String(cString: textPointer)
    let minYear = Int(sqlite3_value_int64(argv[1]))
    let maxYear = Int(sqlite3_value_int64(argv[2]))
    let maxOffsetMinutes = Int(sqlite3_value_int64(argv[3]))
    guard let milliseconds = cursorCanonicalIsoStringToEpochMs(
        value, minYear: minYear, maxYear: maxYear, maxOffsetMinutes: maxOffsetMinutes
    ) else {
        sqlite3_result_null(context)
        return
    }
    sqlite3_result_int64(context, milliseconds)
}

/// Mirrors `cursorRecencySqlExpression("cursorDiskKV.value")` in
/// `main/services/agent-detection-policy.ts`: same field priority
/// (`conversationCheckpointLastUpdatedAt`, `lastUpdatedAt`, `createdAt` —
/// the same order `assessCursorComposerRecord` itself already reads for a
/// composer's own `lastActivityAt`), same `1e12` seconds/milliseconds
/// heuristic, same `maxSupportedTimestampMs` bound (`8_640_000_000_000_000`),
/// and the same `fullConversationHeadersOnly[*].createdAt` header-max
/// contribution — so both platforms rank composer recency identically and
/// can share numeric-bound test fixtures. `SessionSnapshotSourceTests.swift`
/// asserts this SQL, executed against real SQLite, agrees with
/// `assessCursorComposerRecord`'s own computed `lastActivityAt` for the
/// same numeric/ISO-string/header-only/malformed/future-skew fixtures the
/// TS parity suite uses.
///
/// Computes a `cursorDiskKV` composer row's recency directly in SQLite, in
/// epoch milliseconds (or `NULL` when unrankable), so a query can
/// `ORDER BY` **actual last-activity time** instead of `rowid`. `rowid` is
/// only ever insertion order: Cursor UPSERTs an existing composer row in
/// place when a conversation updates, which never changes that row's
/// `rowid`, so `ORDER BY rowid DESC` alone would treat a freshly-updated
/// *old* conversation as permanently stale.
///
/// References the composer row's value as `cursorDiskKV.value` (table-
/// qualified), never a bare `value` — the header-max subquery below
/// aliases a `json_each(...)` call as `headerEntry` in the very same
/// query, and `json_each` itself declares an output column named `value`;
/// confirmed empirically that SQLite's table-valued-function binder
/// resolves an unqualified `value` reference against that colliding alias
/// instead of correlating to the outer row, silently yielding zero header
/// rows rather than an error. A table-qualified reference sidesteps the
/// collision entirely.
///
/// Evaluation order matters, matching the byte/JSON-validity guards this
/// scan already enforces, now pushed into SQL so an oversized or malformed
/// row can never reach `ORDER BY` as anything but a (naturally last-sorted)
/// `NULL`:
///  1. `octet_length(cursorDiskKV.value) > cursorMaximumValueBytes`
///     short-circuits to `NULL` before `json_valid`/`json_extract` ever
///     run against it.
///  2. `json_valid(cursorDiskKV.value)` gates everything else — malformed
///     JSON yields `NULL`.
///  3. The composer's recency is `MAX(rootRecency, headerRecency)`:
///     - `rootRecency` mirrors `record.conversationCheckpointLastUpdatedAt
///       ?? record.lastUpdatedAt ?? record.createdAt` exactly — a
///       `COALESCE` over the same 3 fields in the same priority order
///       (never a flat max across them, which would let a lower-priority
///       field's numerically larger value outrank a defined
///       higher-priority field), yielding SQL `NULL` — never a `0`
///       default — when none of the 3 are defined/rankable. A composer
///       with no root timestamp AND no valid header can still be genuinely
///       active in the assessor's own `lastActivityAt` (which separately
///       seeds `0` as an in-memory fallback, never surfaced here), so this
///       SQL expression must not silently assert "this row's real recency
///       is exactly epoch-zero" on its behalf — doing so would let the
///       row-limit sentinel treat it as `isDefinitelyOlderThanWindowLowerBound`
///       and wave truncation through as "safe" even though this SQL
///       projection genuinely cannot rank the row at all.
///       `overallRecency`'s own null-skipping aggregate `MAX` already lets
///       a defined `headerRecency` win over a `NULL` `rootRecency`
///       (header-only recency keeps working); only a composer with
///       *neither* signal now correctly surfaces as the unrankable `NULL`
///       the row-limit sentinel already treats as inconclusive.
///     - `headerRecency` mirrors the unconditional
///       `for header in headers { if createdAt > lastActivityAt { ... } }`
///       loop: the null-skipping aggregate `MAX` of every
///       `fullConversationHeadersOnly[*].createdAt` whose sibling `type`
///       is `1` or `2`. Each `json_each` row is guarded with
///       `headerEntry.type = 'object'` before any `json_extract`/
///       `json_type` call touches its `value` — `json_each`'s per-row
///       `value` column holds a non-object scalar entry's already-decoded
///       form (e.g. an unquoted bare word), which is not valid JSON syntax
///       to re-parse; confirmed empirically that an unguarded call throws
///       `"malformed JSON"` for a plain string/number/bool/null/array
///       entry in the headers array.
///     - Both root and header candidates accept either shape
///       `parseCursorTimestamp` accepts that can make a composer active: a
///       JSON number (seconds when `<= 1e12`, else already milliseconds) or
///       a JSON string matching `parseCanonicalCursorIsoComponents`'s exact
///       `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` grammar *and* full
///       Gregorian range validation (real year/month/day-in-month/hour/
///       minute/second/offset-magnitude bounds — not just the shape) — the
///       one narrow string domain this codebase's TS parser, this SQL
///       expression, and this Swift assessor's own `parseCursorTimestamp`
///       all three independently validate and convert to the exact same
///       millisecond value by construction, via the identical Howard
///       Hinnant `days_from_civil` integer arithmetic formula, invoked
///       through the registered `cursorTimestampSqlFunctionName` scalar
///       function (see `cursorCanonicalIsoToEpochMsXFunc`'s and the
///       function body below's own comments), never `julianday()` /
///       `Date.parse` / `Date.ISO8601FormatStyle`'s own leniency or
///       differing native bounds. Any other string (zone-less, date-only,
///       lower-case `t`/`z`, space-separated, no-seconds, minute/second
///       `60`, an invalid calendar day, an out-of-range year, or an offset
///       beyond `maxOffsetMinutes`) is unrankable here for the same reason
///       it is unparseable to `parseCursorTimestamp` itself: real Cursor
///       data only ever emits epoch-millisecond numbers on disk, so this
///       restriction never under-ranks genuine data, and every one of those
///       shapes is now rejected identically by all three engines instead of
///       silently accepted-but-differently-computed by one of them.
///     - Both also apply the same `ABS(ms) <= maxSupportedTimestampMs`
///       bound as before, so an out-of-range numeric string/number never
///       poisons the `MAX` with a nonsensical magnitude.
///
/// `NULL` always sorts last under `ORDER BY ... DESC` in SQLite, so rows
/// this expression can't rank (oversized, malformed JSON, or no timestamp
/// in any root/header candidate) are naturally deprioritized without any
/// extra branching in the query itself.
let cursorRecencySqlExpression: String = {
    // Converts one already-`json_extract`-ed candidate (`typeExpr` its
    // `json_type(...)`, `rawExpr` its `json_extract(...)`) to epoch
    // milliseconds, or `NULL` if it is neither a supported number nor a
    // supported ISO-8601 string shape. Shared verbatim by every root field
    // and the header `createdAt` so numeric/string support never drifts
    // between the two.
    func numericOrIsoStringToMsExpression(_ typeExpr: String, _ rawExpr: String) -> String {
        let scaledNumeric = "(CASE WHEN \(rawExpr) > 1000000000000 THEN \(rawExpr) ELSE \(rawExpr) * 1000 END)"

        // The ISO-string branch below enforces *exactly* the same grammar
        // and range rules as `parseCanonicalCursorIsoComponents`
        // (`TurnAssessors.swift`) and its TS twin — not just the
        // `YYYY-MM-DDTHH:MM:SS` shape, but real year/month/day(-in-month,
        // honoring leap years)/hour/minute/second range validation plus a
        // bounded timezone-offset magnitude — computed via the identical
        // Howard Hinnant `days_from_civil` integer-arithmetic formula, never
        // `julianday()`. This branch does not re-implement that
        // grammar/arithmetic as inline SQL text at all: it calls
        // `cursorTimestampSqlFunctionName`, a SQLite scalar function
        // registered via `sqlite3_create_function_v2` in
        // `queryCursorComposers` below to run
        // `cursorCanonicalIsoToEpochMsXFunc` → `cursorCanonicalIsoStringToEpochMs`
        // — the *exact* same Swift function the pure-Swift
        // `parseCursorTimestamp` string branch already calls. This is a
        // deliberate strengthening over this expression's earlier version,
        // which shape-guarded the string with `GLOB`/`substr` and then
        // trusted SQLite's own `julianday()` to compute (and implicitly
        // range-validate) the value: `julianday()` independently agrees
        // with `Date.parse` on nearly everything (both roll invalid
        // calendar dates over rather than rejecting them) except its own
        // offset-magnitude cutoff (confirmed empirically: `julianday()`
        // accepts any `±HH:MM` with magnitude strictly less than `15:00`,
        // while `Date.parse` has no cutoff at all, accepting up to
        // `+23:59`) — a genuine, independent three-way divergence this
        // rewrite closes by never delegating to either engine's own
        // leniency for range validation *or* arithmetic. It also silently
        // accepted a leap second (`:60`), minute `60`, and other shapes
        // `Date.ISO8601FormatStyle` itself would separately (and, prior to
        // the Swift-side byte-level parser rewrite, inconsistently)
        // normalize or reject.
        //
        // A registered scalar function call's `prepare()` cost does not
        // scale with this grammar's complexity at all — confirmed
        // empirically to be both *smaller* SQL text and *faster* to
        // prepare/evaluate than the `GLOB`/`substr`/`julianday()` shape
        // guard this replaced, even though Swift's own
        // `sqlite3_progress_handler`-based deadline mechanism (unlike TS's
        // `node:worker_threads` Worker-based one) never carried a large
        // fixed startup tax that made this a *required* rewrite for
        // performance on this platform — it is still strictly better on
        // both counts here. The task's own requirement 3 explicitly permits
        // this design ("register an identical safe conversion function if
        // that is cleaner and available in both SQLite paths") as an
        // alternative to inline component/range guards.
        //
        // `1970`/`9999`/`840` are literal SQL arguments (this codebase's
        // own `cursorTimestampMinYear`/`cursorTimestampMaxYear`/
        // `cursorTimestampMaxOffsetMinutes` defaults — see their own
        // comments in `TurnAssessors.swift`), matching
        // `parseCanonicalCursorIsoComponents`'s own literal defaults so
        // this SQL expression and every zero-argument Swift caller
        // (`parseCursorTimestamp`, `isCanonicalCursorIsoTimestamp`) enforce
        // the identical bounds.
        //
        // Wrapped in a single small `WITH` (not referenced twice directly
        // in the outer `CASE`, the way `scaledNumeric` still is): `ms` is
        // computed *once* per row/field, then range-checked — semantically
        // identical to two direct references (both forms always agree on
        // `NULL` vs. the exact same value) while only ever invoking the
        // scalar function once per row/field.
        let isoMsCall = "\(cursorTimestampSqlFunctionName)(\(rawExpr), 1970, 9999, 840)"
        let branchMs =
            "(WITH msValue AS (SELECT CASE " +
            "WHEN \(typeExpr) IN ('integer', 'real') THEN \(scaledNumeric) " +
            "WHEN \(typeExpr) = 'text' THEN \(isoMsCall) " +
            "ELSE NULL END AS ms) " +
            "SELECT CASE WHEN ABS(ms) <= 8640000000000000 THEN ms ELSE NULL END FROM msValue)"
        return branchMs
    }

    func fieldExpression(_ field: String) -> String {
        let jsonPath = "'$.\(field)'"
        return numericOrIsoStringToMsExpression(
            "json_type(cursorDiskKV.value, \(jsonPath))",
            "json_extract(cursorDiskKV.value, \(jsonPath))"
        )
    }
    let rootRecency = "COALESCE(" + [
        "conversationCheckpointLastUpdatedAt",
        "lastUpdatedAt",
        "createdAt",
    ].map(fieldExpression).joined(separator: ", ") + ")"

    let headerCreatedAtMs = numericOrIsoStringToMsExpression(
        "json_type(headerEntry.value, '$.createdAt')",
        "json_extract(headerEntry.value, '$.createdAt')"
    )
    // `headerEntry.type = 'object'` is `json_each`'s own per-row type
    // marker (guards every subsequent `json_extract`/`json_type` call
    // against the "malformed JSON" throw on non-object entries); the
    // `json_extract(..., '$.type') IN (1, 2)` filter is the *header's own*
    // `type` field, matching Swift's `validateCursorHeaders` rejection of
    // any `type` other than `1`/`2` exactly (Cursor bubble types: 1 =
    // user, 2 = assistant/tool).
    let headerRecency =
        "(SELECT MAX(\(headerCreatedAtMs)) FROM json_each(cursorDiskKV.value, '$.fullConversationHeadersOnly') AS headerEntry " +
        "WHERE headerEntry.type = 'object' AND json_extract(headerEntry.value, '$.type') IN (1, 2))"

    // A 2-row `UNION ALL` + aggregate `MAX` rather than the 2+-arg `max()`
    // scalar function: `max(a, b)` returns `NULL` if *either* is `NULL`,
    // while the aggregate `MAX(v)` over a derived table correctly skips
    // `NULL` rows (a composer with no valid headers still ranks by
    // `rootRecency` alone).
    let overallRecency = "(SELECT MAX(v) FROM (SELECT \(rootRecency) AS v UNION ALL SELECT \(headerRecency) AS v))"

    return "CASE WHEN octet_length(cursorDiskKV.value) > \(cursorMaximumValueBytes) THEN NULL " +
        "WHEN json_valid(cursorDiskKV.value) THEN \(overallRecency) ELSE NULL END"
}()

private final class CursorSQLiteDeadline {
    let uptime: TimeInterval

    init(millisecondsFromNow: Int) {
        uptime = ProcessInfo.processInfo.systemUptime + Double(millisecondsFromNow) / 1_000
    }

    var isExpired: Bool {
        ProcessInfo.processInfo.systemUptime >= uptime
    }
}

/// Every reason a Cursor scan stopped before naturally exhausting the
/// `composerData:*` result set (`SQLITE_DONE`) or hitting the intentional
/// `cursorMaximumValidCandidates` early exit. Any of these means the scan
/// cannot know whether an uninspected row would have been active, so the
/// caller must treat the whole scan as inconclusive rather than trusting
/// whatever partial evidence was gathered.
enum CursorScanIncompleteReason: String, Equatable, Sendable {
    case rowLimit = "row limit"
    case decodedByteLimit = "decoded byte limit"
    case bubbleLookupLimit = "bubble lookup limit"
    case deadline = "deadline"
}

/// Outcome of one bounded, parameterized `bubbleId:<composerId>:<bubbleId>`
/// point lookup performed while scanning Cursor composers.
private enum BubbleLookupOutcome {
    case found(JSONObject)
    case absentOrMalformed
    /// The deadline, global bubble-lookup cap, or cumulative decoded-byte
    /// cap was hit before this lookup could be (re)performed.
    case limitExceeded
}

/// Operational SQLite failures propagate through `AgentDetector` so
/// `AgentMonitor` retains its last good state and publishes a scan diagnostic.
enum CursorSessionScanError: Error, Equatable, Sendable, CustomStringConvertible {
    case databaseBusy(code: Int32)
    case databaseFailure(operation: String, code: Int32)
    /// A hard bound (rows/bytes/bubble lookups/deadline) was exhausted
    /// before the scan could conclusively enumerate every composer, so
    /// whatever partial evidence exists must not be trusted — never
    /// silently reported as "no active Cursor agents."
    case scanIncomplete(reason: CursorScanIncompleteReason)

    var description: String {
        switch self {
        case .databaseBusy(let code):
            return "Cursor session database is busy or locked (SQLite code \(code))"
        case .databaseFailure(let operation, let code):
            return "Cursor session database \(operation) failed (SQLite code \(code))"
        case .scanIncomplete(let reason):
            return "Cursor session scan stopped before completion (\(reason.rawValue)); treating as inconclusive"
        }
    }
}

/// One session/transcript candidate discovered during a bounded directory
/// walk, prior to being opened or assessed.
struct SessionCandidate: Equatable {
    let path: String
    let mtimeMs: Int64
    let label: String
}

struct SessionCandidateScanResult {
    let candidates: [SessionCandidate]
    let inspectedEntries: Int
    let inspectedDirectories: Int
}

private struct SessionTraversalBudget {
    var inspectedEntries = 0
    var inspectedDirectories = 0
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
                evidence.append(contentsOf: try SessionSnapshotSource.cursorEvidence(homeDirectory: homeDirectory, homeCanonical: homeCanonical, now: now))
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
        collectCandidatesWithStats(
            root: root,
            extensions: extensions,
            fileNames: fileNames,
            now: now
        ).candidates
    }

    static func collectCandidatesWithStats(
        root: String,
        extensions: [String],
        fileNames: [String]?,
        now: Int64
    ) -> SessionCandidateScanResult {
        var hits: [SessionCandidate] = []
        var budget = SessionTraversalBudget()
        walk(
            directory: root,
            depth: 0,
            root: root,
            extensions: extensions,
            fileNames: fileNames,
            now: now,
            hits: &hits,
            budget: &budget
        )
        hits.sort { $0.mtimeMs > $1.mtimeMs }
        return SessionCandidateScanResult(
            candidates: hits,
            inspectedEntries: budget.inspectedEntries,
            inspectedDirectories: budget.inspectedDirectories
        )
    }

    private static func walk(
        directory: String,
        depth: Int,
        root: String,
        extensions: [String],
        fileNames: [String]?,
        now: Int64,
        hits: inout [SessionCandidate],
        budget: inout SessionTraversalBudget
    ) {
        guard depth <= sessionMaximumWalkDepth else { return }
        guard budget.inspectedEntries < sessionMaximumInspectedEntriesPerRoot else { return }
        guard budget.inspectedDirectories < sessionMaximumInspectedDirectoriesPerRoot else { return }

        let directoryFD = directory.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { return }
        guard let stream = fdopendir(directoryFD) else {
            close(directoryFD)
            return
        }
        defer { closedir(stream) }
        budget.inspectedDirectories += 1

        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard budget.inspectedEntries < sessionMaximumInspectedEntriesPerRoot else { return }
            budget.inspectedEntries += 1
            let fullPath = directory + "/" + name

            var entryStat = stat()
            guard lstat(fullPath, &entryStat) == 0 else { continue }
            let mode = entryStat.st_mode & S_IFMT

            if mode == S_IFDIR {
                guard !sessionSkippedDirectoryNames.contains(name) else { continue }
                walk(
                    directory: fullPath,
                    depth: depth + 1,
                    root: root,
                    extensions: extensions,
                    fileNames: fileNames,
                    now: now,
                    hits: &hits,
                    budget: &budget
                )
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

            retainRecentCandidate(
                SessionCandidate(path: fullPath, mtimeMs: mtimeMs, label: friendlySessionLabel(fullPath)),
                in: &hits
            )
        }
    }

    private static func retainRecentCandidate(_ candidate: SessionCandidate, in hits: inout [SessionCandidate]) {
        if hits.count < sessionMaximumFilesPerRoot {
            hits.append(candidate)
            return
        }
        guard let oldestIndex = hits.indices.min(by: { hits[$0].mtimeMs < hits[$1].mtimeMs }) else {
            return
        }
        if candidate.mtimeMs > hits[oldestIndex].mtimeMs {
            hits[oldestIndex] = candidate
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
    /// every other transcript before ever touching SQLite. The verified
    /// descriptor remains open while SQLite opens that canonical path in
    /// read-only mode, allowing SQLite to discover a live WAL/SHM pair; the
    /// path inode is then checked against the descriptor again before any
    /// query runs. Never shells out to `sqlite3`.
    static func cursorEvidence(homeDirectory: URL, homeCanonical: String, now: Int64) throws -> [SessionTurnEvidence] {
        let dbURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb", isDirectory: false)

        guard let fd = openVerifiedRegularFile(at: dbURL.path, root: homeCanonical) else { return [] }
        defer { close(fd) }

        guard let canonicalParent = canonicalPath(of: dbURL.deletingLastPathComponent().path) else { return [] }
        let validatedPath = canonicalParent + "/" + dbURL.lastPathComponent
        return try queryCursorComposers(fd: fd, validatedPath: validatedPath, now: now)
    }

    static func queryCursorComposers(
        fd: Int32,
        validatedPath: String,
        now: Int64,
        onSnapshotEstablished: (() -> Void)? = nil,
        onRowInspected: (() -> Void)? = nil,
        onBubbleLookup: (() -> Void)? = nil,
        deadlineMillisecondsOverride: Int? = nil,
        /// Test-only seam: when set, every fresh (non-cached) bubble lookup
        /// treats this as `sqlite3_step(bubbleStatement)`'s result instead
        /// of actually stepping — lets tests assert that BUSY/INTERRUPT/
        /// IOERR/CORRUPT/etc. propagate as a typed `CursorSessionScanError`
        /// rather than being silently swallowed as "bubble missing"
        /// (that conflation was the confirmed defect), without needing to
        /// reproduce those conditions against a real SQLite file. `nil` in
        /// production and every other test: real `sqlite3_step` always runs.
        simulatedBubbleStepResultCode: Int32? = nil
    ) throws -> [SessionTurnEvidence] {
        let uri = URL(fileURLWithPath: validatedPath).absoluteString + "?mode=ro"
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer {
            if let db { sqlite3_close(db) }
        }
        try checkCursorSQLite(openRC, operation: "open")
        guard let db else {
            throw CursorSessionScanError.databaseFailure(operation: "open", code: openRC)
        }

        var verifiedStat = stat()
        var pathStat = stat()
        guard fstat(fd, &verifiedStat) == 0,
              lstat(validatedPath, &pathStat) == 0,
              (pathStat.st_mode & S_IFMT) == S_IFREG,
              verifiedStat.st_dev == pathStat.st_dev,
              verifiedStat.st_ino == pathStat.st_ino else {
            throw CursorSessionScanError.databaseFailure(operation: "identity verification", code: SQLITE_CANTOPEN)
        }

        sqlite3_extended_result_codes(db, 1)
        // Registers the scalar function `cursorRecencySqlExpression`'s
        // generated SQL calls by name (`cursorTimestampSqlFunctionName`) —
        // must happen before that SQL is ever prepared below, on this same
        // `db` handle (a fresh connection is opened per call to this
        // function, so this registration cannot be hoisted or cached
        // across calls). `SQLITE_DETERMINISTIC` is a true, honest claim
        // here (identical arguments always produce the identical result,
        // with no hidden dependency on database state) — unlike
        // `node:sqlite`'s `deterministic: true` option, this flag lets
        // SQLite's own query planner skip re-invoking the function for
        // textually-identical calls with the identical arguments within one
        // statement, though `cursorRecencySqlExpression`'s own single
        // `WITH`-wrapped call site per field never relies on that
        // optimization actually happening (see that expression's own
        // comment).
        try checkCursorSQLite(
            sqlite3_create_function_v2(
                db,
                cursorTimestampSqlFunctionName,
                4,
                SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                nil,
                cursorCanonicalIsoToEpochMsXFunc,
                nil,
                nil,
                nil
            ),
            operation: "register cursor timestamp SQL function"
        )
        try checkCursorSQLite(
            sqlite3_busy_timeout(db, cursorSQLiteBusyTimeoutMilliseconds),
            operation: "busy timeout configuration"
        )
        try executeCursorSQL(db, sql: "BEGIN", operation: "begin read transaction")
        var transactionOpen = true
        defer {
            if transactionOpen {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }

        let deadlineTracker = CursorSQLiteDeadline(
            millisecondsFromNow: deadlineMillisecondsOverride ?? cursorSQLiteQueryDeadlineMilliseconds
        )
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 1 }
            let tracker = Unmanaged<CursorSQLiteDeadline>
                .fromOpaque(context)
                .takeUnretainedValue()
            return tracker.isExpired ? 1 : 0
        }, Unmanaged.passUnretained(deadlineTracker).toOpaque())
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
        }

        // `ORDER BY recencyMs DESC, rowid DESC`: `recencyMs` is
        // `cursorRecencySqlExpression`, a validated JSON timestamp computed
        // directly in SQL (see its doc comment) — the actual last-activity
        // time, not `rowid`. `rowid` is only ever insertion order: Cursor
        // UPSERTs an existing composer row in place when a conversation
        // updates, which never changes that row's `rowid`, so ordering by
        // `rowid` alone would treat a freshly-updated *old* conversation as
        // permanently stale. `rowid` remains a deterministic tiebreaker
        // only, for rows that tie (or both lack) a validated timestamp.
        // Newest-first ordering keeps a bounded scan useful (requirement 5):
        // even if the row/byte/time budget runs out, it already covered the
        // composers most likely to be currently active.
        // `LIMIT ?` is bound to the inspected-row cap **+ 1**: SQL fetches at
        // most that many rows (never the whole table); if the
        // `(cap + 1)`-th row is actually delivered, more matching rows exist
        // beyond what this scan inspected — that row is never assessed as a
        // composer, only peeked at for its own `recencyMs` as a truncation
        // sentinel (see the row-limit branch below).
        //
        // Selects a bounded `boundedValue` CASE projection plus a
        // `valueByteCount` column — never raw `value` — so an oversized
        // row's content never crosses into a `sqlite3_column_text`/`_blob`
        // call: the byte count alone (always safe to read, `octet_length`
        // never materializes the oversized text/blob itself) is enough to
        // reject it below. The byte threshold is bound via
        // `sqlite3_bind_int64` (`?1`), never interpolated into this SQL
        // text.
        let sql = """
        SELECT key,
          CASE WHEN octet_length(value) <= ?1 THEN value ELSE NULL END AS boundedValue,
          octet_length(value) AS valueByteCount,
          (\(cursorRecencySqlExpression)) AS recencyMs
        FROM cursorDiskKV
        WHERE key LIKE ?2
        ORDER BY recencyMs DESC, rowid DESC
        LIMIT ?3
        """

        var statement: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        try checkCursorSQLite(prepareRC, operation: "prepare composer query")
        guard let statement else {
            throw CursorSessionScanError.databaseFailure(operation: "prepare composer query", code: prepareRC)
        }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try checkCursorSQLite(
            sqlite3_bind_int64(statement, 1, Int64(cursorMaximumValueBytes)),
            operation: "bind composer value byte bound"
        )
        try checkCursorSQLite(
            sqlite3_bind_text(statement, 2, "composerData:%", -1, sqliteTransient),
            operation: "bind composer key prefix"
        )
        try checkCursorSQLite(
            sqlite3_bind_int64(statement, 3, Int64(cursorMaximumInspectedRows) + 1),
            operation: "bind composer row limit"
        )

        // Prepared once, reused (bind/step/reset) for every bubble lookup —
        // an exact parameterized point lookup, never string concatenation.
        // Same bounded `boundedValue`/`valueByteCount` projection as the
        // composer query above, never raw `value`.
        var bubbleStatement: OpaquePointer?
        let bubblePrepareRC = sqlite3_prepare_v2(
            db,
            """
            SELECT
              CASE WHEN octet_length(value) <= ?1 THEN value ELSE NULL END AS boundedValue,
              octet_length(value) AS valueByteCount
            FROM cursorDiskKV WHERE key = ?2
            """,
            -1,
            &bubbleStatement,
            nil
        )
        try checkCursorSQLite(bubblePrepareRC, operation: "prepare bubble lookup")
        guard let bubbleStatement else {
            throw CursorSessionScanError.databaseFailure(operation: "prepare bubble lookup", code: bubblePrepareRC)
        }
        defer { sqlite3_finalize(bubbleStatement) }

        var evidence: [SessionTurnEvidence] = []
        var rowsInspected = 0
        var totalDecodedBytes = 0
        var totalBubbleLookups = 0
        var attemptedBubbleKeys = Set<String>()
        var bubbleCache: [String: JSONObject] = [:]
        var stopReason: CursorScanIncompleteReason?

        // Every counter/flag above is charged identically whether the row
        // or bubble turns out to be inactive, malformed, or a duplicate
        // reference — limits count inspected work, not just active results.
        func lookUpBubble(_ bubbleKey: String) throws -> BubbleLookupOutcome {
            if attemptedBubbleKeys.contains(bubbleKey) {
                // Duplicate reference (already attempted this scan): serve
                // from cache without a second round trip or byte charge.
                if let cached = bubbleCache[bubbleKey] { return .found(cached) }
                return .absentOrMalformed
            }
            guard !deadlineTracker.isExpired else {
                stopReason = stopReason ?? .deadline
                return .limitExceeded
            }
            guard totalBubbleLookups < cursorMaximumBubbleLookups else {
                stopReason = stopReason ?? .bubbleLookupLimit
                return .limitExceeded
            }
            attemptedBubbleKeys.insert(bubbleKey)
            totalBubbleLookups += 1
            onBubbleLookup?()

            try checkCursorSQLite(sqlite3_reset(bubbleStatement), operation: "reset bubble lookup")
            try checkCursorSQLite(
                sqlite3_clear_bindings(bubbleStatement),
                operation: "clear bubble lookup bindings"
            )
            // `sqlite3_clear_bindings` resets *every* host parameter to
            // NULL, not just the one about to change — the byte bound must
            // be rebound alongside the key on every lookup, not just once
            // before the loop starts.
            try checkCursorSQLite(
                sqlite3_bind_int64(bubbleStatement, 1, Int64(cursorMaximumValueBytes)),
                operation: "bind bubble lookup value byte bound"
            )
            try checkCursorSQLite(
                sqlite3_bind_text(bubbleStatement, 2, bubbleKey, -1, sqliteTransient),
                operation: "bind bubble lookup key"
            )
            let stepRC = simulatedBubbleStepResultCode ?? sqlite3_step(bubbleStatement)
            guard stepRC != SQLITE_DONE else {
                // Genuinely absent: not every referenced bubble id was ever
                // written (older data, or a tool call that never produced a
                // result row). This is the ONLY outcome allowed to mean
                // "missing" — every other non-`SQLITE_ROW` code below is an
                // operational failure (BUSY/LOCKED/INTERRUPT/IOERR/CORRUPT/
                // ...) and must propagate as a typed, inconclusive scan
                // error instead of silently being treated the same as "this
                // bubble doesn't exist".
                return .absentOrMalformed
            }
            try checkCursorSQLiteRow(stepRC, operation: "read bubble lookup")
            // Byte count first, from its own always-safe-to-read INTEGER
            // column — computed by `octet_length()` in SQL, never by
            // touching `boundedValue`. Rejects an oversized row without
            // ever calling `sqlite3_column_text`/`_blob` on it: the CASE
            // projection already reduced an oversized `boundedValue` to
            // SQL `NULL` server-side, but this guard sequence additionally
            // ensures the Swift accessor calls themselves never run
            // against oversized content.
            let valueByteCount = Int(sqlite3_column_int64(bubbleStatement, 1))
            guard valueByteCount > 0, valueByteCount <= cursorMaximumValueBytes else {
                return .absentOrMalformed
            }
            guard sqlite3_column_type(bubbleStatement, 0) == SQLITE_TEXT,
                  let valueBytes = sqlite3_column_text(bubbleStatement, 0) else {
                return .absentOrMalformed
            }
            guard totalDecodedBytes + valueByteCount <= cursorMaximumTotalDecodedValueBytes else {
                stopReason = stopReason ?? .decodedByteLimit
                return .limitExceeded
            }
            totalDecodedBytes += valueByteCount
            let valueData = Data(bytes: valueBytes, count: valueByteCount)
            guard let bubble = (try? JSONSerialization.jsonObject(with: valueData)) as? JSONObject else {
                return .absentOrMalformed
            }
            bubbleCache[bubbleKey] = bubble
            return .found(bubble)
        }

        var stepRC = sqlite3_step(statement)
        if stepRC != SQLITE_DONE {
            try checkCursorSQLiteRow(stepRC, operation: "establish composer snapshot")
        }
        onSnapshotEstablished?()

        rowLoop: while evidence.count < cursorMaximumValidCandidates {
            if stepRC == SQLITE_DONE { break }
            guard !deadlineTracker.isExpired else {
                stopReason = .deadline
                break
            }
            guard rowsInspected < cursorMaximumInspectedRows else {
                // `stepRC` still points at the un-consumed (cap + 1)-th row
                // (the truncation sentinel), already confirmed above to be
                // neither `SQLITE_DONE` nor unread: peek at its own
                // SQL-computed `recencyMs` without assessing it as a
                // composer (never spends a row/byte/bubble budget on it).
                // Rows are already ordered newest-first by validated JSON
                // recency (rowid only breaks ties), so truncation is only
                // ever safe when this cut-off candidate's own timestamp is
                // *definitively* older than the candidate window's lower
                // bound — every omitted row beyond it is then provably no
                // newer either, so the newest `cursorMaximumInspectedRows`
                // can be accepted instead of permanently failing merely
                // because more history exists. A missing/unrankable
                // (`NULL`, sorting last), recent, OR too-far-future
                // sentinel must all stay inconclusive (`.rowLimit`):
                // `isRecentTimestamp` is deliberately NOT used here — it
                // reports a far-future timestamp as not recent too, which
                // would wrongly bless truncation as safe even though a
                // corrupt/adversarial far-future recency value could rank
                // ahead of, and thereby hide, a genuinely active composer
                // beyond the cap. `isDefinitelyOlderThanWindowLowerBound`
                // requires the sentinel to be on the *old* side of the
                // window's lower bound specifically.
                try checkCursorSQLiteRow(stepRC, operation: "read composer row-limit sentinel")
                let sentinelRecencyMs: Int64? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : saturatingInt64(sqlite3_column_double(statement, 3))
                let sentinelDefinitelyOld = sentinelRecencyMs.map {
                    isDefinitelyOlderThanWindowLowerBound($0, now: now, within: sessionCandidateWindowMs)
                } ?? false
                if !sentinelDefinitelyOld {
                    stopReason = .rowLimit
                }
                break
            }
            try checkCursorSQLiteRow(stepRC, operation: "read composer query")
            rowsInspected += 1
            defer {
                onRowInspected?()
                stepRC = sqlite3_step(statement)
            }

            guard sqlite3_column_type(statement, 0) == SQLITE_TEXT else { continue }
            let keyByteCount = Int(sqlite3_column_bytes(statement, 0))
            guard keyByteCount > 0, keyByteCount <= cursorMaximumKeyBytes,
                  let keyBytes = sqlite3_column_text(statement, 0),
                  let key = String(
                      data: Data(bytes: keyBytes, count: keyByteCount),
                      encoding: .utf8
                  ) else { continue }

            // Byte count first, from its own always-safe-to-read INTEGER
            // column — computed by `octet_length()` in SQL, never by
            // touching `boundedValue`. Rejects an oversized row without
            // ever calling `sqlite3_column_text`/`_blob` on it, matching
            // the bubble lookup above.
            let valueByteCount = Int(sqlite3_column_int64(statement, 2))
            guard valueByteCount > 0, valueByteCount <= cursorMaximumValueBytes else { continue }
            guard sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  let valueBytes = sqlite3_column_text(statement, 1) else { continue }

            guard totalDecodedBytes + valueByteCount <= cursorMaximumTotalDecodedValueBytes else {
                stopReason = .decodedByteLimit
                break rowLoop
            }
            totalDecodedBytes += valueByteCount
            let valueData = Data(bytes: valueBytes, count: valueByteCount)

            guard let record = (try? JSONSerialization.jsonObject(with: valueData)) as? JSONObject else { continue }

            let identity = key.hasPrefix("composerData:") ? String(key.dropFirst("composerData:".count)) : key

            // First pass never touches bubbles (bubbles default to `[:]`);
            // `lastActivityAt` is folded purely from already-decoded,
            // trusted composer/header fields, so it is identical whether or
            // not bubbles are ultimately consulted below.
            let provisional = assessCursorComposerRecord(record, now: now)
            var finalAssessment = provisional

            if !provisional.active
                && isRecentTimestamp(provisional.lastActivityAt, now: now, within: toolTurnGraceMs) {
                // Only a plausibly-recent composer's verdict can change
                // once a hidden bubble tool status is known — this keeps
                // bubble lookups bounded to the small fraction of composers
                // where they could possibly matter, instead of spending
                // budget on every long-completed conversation the scan
                // steps over.
                var bubbles: [String: JSONObject] = [:]
                var truncatedByBubbleLookup = false
                for bubbleId in cursorRelevantBubbleIds(record) {
                    switch try lookUpBubble("bubbleId:\(identity):\(bubbleId)") {
                    case .found(let bubble):
                        bubbles[bubbleId] = bubble
                    case .absentOrMalformed:
                        continue
                    case .limitExceeded:
                        truncatedByBubbleLookup = true
                    }
                    if truncatedByBubbleLookup { break }
                }
                if truncatedByBubbleLookup { break rowLoop }
                finalAssessment = assessCursorComposerRecord(record, bubbles: bubbles, now: now)
            }

            guard finalAssessment.active else { continue }
            evidence.append(SessionTurnEvidence(
                family: .cursor,
                identity: identity,
                label: finalAssessment.label,
                reason: finalAssessment.reason,
                lastActivityAt: finalAssessment.lastActivityAt
            ))
        }

        // Any stop reason other than natural exhaustion (`SQLITE_DONE`) or
        // the intentional `cursorMaximumValidCandidates` early exit means an
        // unseen row/bubble could have been active — never trust the
        // partial evidence gathered so far in that case.
        if let stopReason {
            throw CursorSessionScanError.scanIncomplete(reason: stopReason)
        }

        try executeCursorSQL(db, sql: "COMMIT", operation: "commit read transaction")
        transactionOpen = false
        evidence.sort { $0.lastActivityAt > $1.lastActivityAt }
        return evidence
    }

    private static func executeCursorSQL(_ db: OpaquePointer, sql: String, operation: String) throws {
        try checkCursorSQLite(sqlite3_exec(db, sql, nil, nil, nil), operation: operation)
    }

    private static func checkCursorSQLite(_ code: Int32, operation: String) throws {
        guard code != SQLITE_OK else { return }
        let primaryCode = code & 0xFF
        if primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED {
            throw CursorSessionScanError.databaseBusy(code: code)
        }
        throw CursorSessionScanError.databaseFailure(operation: operation, code: code)
    }

    private static func checkCursorSQLiteRow(_ code: Int32, operation: String) throws {
        guard code == SQLITE_ROW else {
            try checkCursorSQLite(code, operation: operation)
            throw CursorSessionScanError.databaseFailure(operation: operation, code: code)
        }
    }
}
