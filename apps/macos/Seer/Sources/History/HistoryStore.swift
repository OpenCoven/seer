import Foundation

/// A single agent's all-time accumulated awake time, keyed by agent id in
/// `HistoryDocument.agentTotals`. Distinct from `AgentUsage` (which embeds
/// its own `id` and is used for wire snapshots/per-session totals) because
/// the dictionary key already carries the id here.
public struct HistoryAgentTotal: Codable, Equatable, Sendable {
    public var name: String
    public var durationMs: Int64

    public init(name: String, durationMs: Int64) {
        self.name = name
        self.durationMs = durationMs
    }
}

/// The on-disk shape persisted by `HistoryStore`, mirroring
/// `PersistedHistory` in `main/services/history-store.ts`. All-time totals
/// (`totalAwakeMs`, `sessionCount`, `agentTotals`, `daily`) are stored
/// separately from the length-capped `sessions` timeline so trimming the
/// recent session list never loses historical totals.
public struct HistoryDocument: VersionedDocument {
    public static let currentVersion = 1
    public static let unknownAgentFamilyID = "other"

    public static let defaultValue = HistoryDocument(
        version: HistoryDocument.currentVersion,
        totalAwakeMs: 0,
        sessionCount: 0,
        agentTotals: [:],
        daily: [:],
        sessions: []
    )

    public var version: Int
    public var totalAwakeMs: Int64
    public var sessionCount: Int
    public var agentTotals: [String: HistoryAgentTotal]
    public var daily: [String: Int64]
    public var sessions: [AwakeSession]

    public init(
        version: Int,
        totalAwakeMs: Int64,
        sessionCount: Int,
        agentTotals: [String: HistoryAgentTotal],
        daily: [String: Int64],
        sessions: [AwakeSession]
    ) {
        self.version = version
        self.totalAwakeMs = totalAwakeMs
        self.sessionCount = sessionCount
        self.agentTotals = agentTotals
        self.daily = daily
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case version, totalAwakeMs, sessionCount, agentTotals, daily, sessions
    }

    /// Element-wise-lenient decoding: a single malformed or negative field
    /// (a top-level scalar, one `agentTotals`/`daily` entry, or one
    /// session) is normalized or dropped rather than failing the entire
    /// document — mirroring `normalize()` in the TS reference. Because
    /// every numeric field here is a fixed-width `Int`/`Int64`, decoding
    /// rejects any literal outside that type's finite range outright, so
    /// no NaN or Infinity value can ever reach a decoded field: a
    /// genuinely malformed document (missing `version`, or bytes that
    /// aren't valid JSON at all) still fails this initializer, and
    /// `AtomicJSONStore` quarantines it as corrupt rather than silently
    /// accepting garbage.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        totalAwakeMs = HistoryDocument.lenientNonNegativeInt64(container, .totalAwakeMs)
        sessionCount = HistoryDocument.lenientNonNegativeInt(container, .sessionCount)
        agentTotals = HistoryDocument.decodeAgentTotals(container)
        daily = HistoryDocument.decodeDaily(container)
        sessions = HistoryDocument.decodeSessions(container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(totalAwakeMs, forKey: .totalAwakeMs)
        try container.encode(sessionCount, forKey: .sessionCount)
        try container.encode(agentTotals, forKey: .agentTotals)
        try container.encode(daily, forKey: .daily)
        try container.encode(sessions, forKey: .sessions)
    }

    /// Decodes `key` as `T`, treating a missing key, an explicit `null`,
    /// or a value that fails to decode as `T` all identically as "no
    /// value present" (`nil`) instead of propagating a `DecodingError` —
    /// the single primitive every lenient field decode below is built on.
    private static func lenientDecodeIfPresent<T: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        as type: T.Type
    ) -> T? {
        if let value = try? container.decodeIfPresent(type, forKey: key) {
            return value
        }
        return nil
    }

    private static func lenientNonNegativeInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Int64 {
        let value = lenientDecodeIfPresent(container, key, as: Int64.self) ?? 0
        return value >= 0 ? value : 0
    }

    private static func lenientNonNegativeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Int {
        let value = lenientDecodeIfPresent(container, key, as: Int.self) ?? 0
        return value >= 0 ? value : 0
    }

    /// Wraps a single `agentTotals` value whose `init(from:)` never
    /// throws, so decoding the surrounding dictionary always advances
    /// past every entry — even a malformed one — letting the caller drop
    /// just that one entry instead of failing every agent total.
    private struct FailableAgentTotal: Decodable {
        let total: HistoryAgentTotal?
        init(from decoder: Decoder) throws {
            if let value = try? HistoryAgentTotal(from: decoder), value.durationMs >= 0 {
                total = value
            } else {
                total = nil
            }
        }
    }

    /// Wraps a single `daily` value the same never-throwing way
    /// `FailableAgentTotal` wraps an agent total.
    private struct FailableNonNegativeInt64: Decodable {
        let value: Int64?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let decoded = try? container.decode(Int64.self), decoded >= 0 {
                value = decoded
            } else {
                value = nil
            }
        }
    }

    /// Wraps a single `sessions` element the same never-throwing way, so
    /// one malformed session in the array does not discard every other
    /// (valid) session alongside it.
    private struct FailableSession: Decodable {
        let session: AwakeSession?
        init(from decoder: Decoder) throws {
            if let decoded = try? AwakeSession(from: decoder) {
                session = HistoryDocument.normalized(decoded)
            } else {
                session = nil
            }
        }
    }

    /// Clamps any negative numeric field a decoded session might still
    /// carry (its own `Codable` conformance only enforces shape/type, not
    /// sign) to zero, defensively guarding every value that ultimately
    /// reaches a persisted snapshot.
    private static func normalized(_ session: AwakeSession) -> AwakeSession {
        var normalized = session
        if normalized.durationMs < 0 { normalized.durationMs = 0 }
        if normalized.startedAt < 0 { normalized.startedAt = 0 }
        if let endedAt = normalized.endedAt, endedAt < 0 { normalized.endedAt = 0 }
        normalized.agents = normalized.agents.map { agent in
            var normalizedAgent = agent
            if normalizedAgent.durationMs < 0 { normalizedAgent.durationMs = 0 }
            return normalizedAgent
        }
        return normalized
    }

    private static func decodeAgentTotals(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) -> [String: HistoryAgentTotal] {
        let raw = lenientDecodeIfPresent(container, .agentTotals, as: [String: FailableAgentTotal].self) ?? [:]
        var normalized: [String: HistoryAgentTotal] = [:]
        for sourceID in raw.keys.sorted() {
            guard let sourceTotal = raw[sourceID]?.total else { continue }
            let familyID = aggregateAgentID(sourceID)
            var familyTotal = normalized[familyID] ?? HistoryAgentTotal(
                name: aggregateAgentName(familyID: familyID, fallback: sourceTotal.name),
                durationMs: 0
            )
            familyTotal.durationMs = saturatingAdd(familyTotal.durationMs, sourceTotal.durationMs)
            normalized[familyID] = familyTotal
        }
        return normalized
    }

    static func aggregateAgentID(_ sourceID: String) -> String {
        let prefix = String(sourceID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return AgentFamily(rawValue: prefix) == nil ? unknownAgentFamilyID : prefix
    }

    static func aggregateAgentName(familyID: String, fallback: String) -> String {
        if familyID == unknownAgentFamilyID {
            return "Other"
        }
        return AGENT_KINDS.first(where: { $0.id.rawValue == familyID })?.name ?? fallback
    }

    static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let nonNegativeLeft = max(left, 0)
        let nonNegativeRight = max(right, 0)
        let (sum, overflow) = nonNegativeLeft.addingReportingOverflow(nonNegativeRight)
        return overflow ? Int64.max : sum
    }

    static func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        let nonNegativeLeft = max(left, 0)
        let nonNegativeRight = max(right, 0)
        let (sum, overflow) = nonNegativeLeft.addingReportingOverflow(nonNegativeRight)
        return overflow ? Int.max : sum
    }

    private static func decodeDaily(_ container: KeyedDecodingContainer<CodingKeys>) -> [String: Int64] {
        let raw = lenientDecodeIfPresent(container, .daily, as: [String: FailableNonNegativeInt64].self) ?? [:]
        return raw.compactMapValues { $0.value }
    }

    private static func decodeSessions(_ container: KeyedDecodingContainer<CodingKeys>) -> [AwakeSession] {
        let raw = lenientDecodeIfPresent(container, .sessions, as: [FailableSession].self) ?? []
        let sessions = raw.compactMap { $0.session }
        return Array(sessions.prefix(HistoryStore.maximumSessions))
    }
}

/// Resolves the on-disk location of Seer's standalone history file. Always
/// `<Application Support>/ai.opencoven.seer/history.json` — the very same
/// standalone directory `SettingsFileLocation` uses, and never any other
/// application's identifier or path (in particular, never a Glaze path).
public enum HistoryFileLocation {
    /// The history file's name within `SettingsFileLocation.directoryName`.
    public static let fileName = "history.json"

    /// Appends `ai.opencoven.seer/history.json` to
    /// `applicationSupportDirectory`, creating the intermediate
    /// `ai.opencoven.seer` directory if needed, and returns the history
    /// file's URL. `applicationSupportDirectory` is injected so tests can
    /// point at an isolated scratch directory instead of the real
    /// Application Support folder.
    public static func historyFileURL(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = applicationSupportDirectory.appendingPathComponent(
            SettingsFileLocation.directoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

/// Diagnostic ids emitted directly by `HistoryStore` (distinct from the
/// `StorageDiagnosticID` values `AtomicJSONStore` itself emits through
/// `load()`, which `HistoryStore.lastDiagnostic` also surfaces verbatim).
public enum HistoryDiagnosticID {
    /// A `clear()` or debounced/background save attempted to persist but
    /// the underlying `AtomicJSONStore.save` threw. Used instead of
    /// silently reporting success so a persistence failure is always
    /// visible somewhere, even for the non-throwing entry points.
    public static let persistFailed = "history.persist-failed"
}

/// A cancellable handle to one `HistoryScheduler.scheduleAfter(...)` work
/// item. Calling `cancel()` more than once, or after the work has already
/// run, is always safe and a no-op.
public struct HistoryScheduledTask: Sendable {
    private let cancelClosure: @Sendable () -> Void

    public init(cancel: @escaping @Sendable () -> Void) {
        self.cancelClosure = cancel
    }

    public func cancel() {
        cancelClosure()
    }
}

/// Abstraction over "run this after N milliseconds," injected so
/// `HistoryStore`'s five-second save debounce is deterministic and
/// testable without ever sleeping for real wall-clock time. Production
/// code uses `RealTimeHistoryScheduler` (backed by `Task.sleep`); tests use
/// a manually-driven double that only "fires" pending work when the test
/// explicitly tells it to.
public protocol HistoryScheduler: Sendable {
    /// Schedules `work` to run after `delayMs` milliseconds and returns a
    /// token that cancels it. `work` may never run at all if cancelled
    /// before it fires.
    func scheduleAfter(
        milliseconds delayMs: Int64,
        _ work: @escaping @Sendable () async -> Void
    ) async -> HistoryScheduledTask
}

/// Production `HistoryScheduler`, backed by `Task.sleep`. Cancelling the
/// returned token cancels the underlying `Task`; `Task.sleep` throws
/// `CancellationError` when cancelled, which is silently swallowed here
/// without ever invoking `work`.
public struct RealTimeHistoryScheduler: HistoryScheduler {
    public init() {}

    public func scheduleAfter(
        milliseconds delayMs: Int64,
        _ work: @escaping @Sendable () async -> Void
    ) async -> HistoryScheduledTask {
        let task = Task {
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            await work()
        }
        return HistoryScheduledTask { task.cancel() }
    }
}

/// Abstraction over generating a fresh `AwakeSession.id`, injected so tests
/// can use deterministic, sequential ids instead of the production
/// `RandomHistorySessionIDGenerator`'s randomness.
public protocol HistorySessionIDGenerator: Sendable {
    func nextID(startedAt: Int64) async -> String
}

/// Production generator. Shaped like the TS reference's
/// `s_<startedAt>_<random>` ids closely enough to remain
/// human-recognizable in logs, backed by a real `UUID` instead of
/// `Math.random()`.
public struct RandomHistorySessionIDGenerator: HistorySessionIDGenerator {
    public init() {}

    public func nextID(startedAt: Int64) async -> String {
        "s_\(startedAt)_\(UUID().uuidString.prefix(8))"
    }
}

/// Records how long the Mac was kept awake, per-agent working time, and a
/// timeline of recent awake sessions. Fed by the monitor's periodic state
/// ticks; aggregates are accumulated tick-by-tick so trimming the recent
/// session list never loses all-time totals. Ports the semantics of
/// `main/services/history-store.ts`'s `HistoryStore` onto the standalone
/// `AtomicJSONStore<HistoryDocument>` persistence layer.
///
/// Every public entry point that touches `data`/`current` — `record`,
/// `clear`, `flush`, and the internal debounced-save callback — runs
/// through `gate`, the same `AsyncGate` FIFO pattern `SettingsStore` uses,
/// so a queued call never observes or mutates state mid-operation of an
/// earlier one. On top of that, `scheduleGeneration` guards specifically
/// against a *stale, already-fired* debounced save clobbering a newer
/// `clear()`/`flush(at:)` snapshot: `cancelPendingSave()` bumps the
/// generation synchronously (no `await` in between), and the debounced
/// callback re-checks its captured generation immediately upon resuming on
/// the actor — before it builds or persists anything — so it can never
/// write stale data after being superseded, even if the scheduler's own
/// cancellation somehow failed to prevent it from firing at all.
public actor HistoryStore {
    /// Caps per-tick accumulation so a paused timer (e.g. system sleep)
    /// can't inflate totals.
    public static let maxTickDeltaMs: Int64 = 15_000
    /// Sessions shorter than this are noise (a single scan flip) and are
    /// never recorded.
    public static let minimumSessionMs: Int64 = 1_000
    public static let maximumSessions = 100
    public static let maximumRecentSessions = 40
    public static let maximumDailyKeys = 60
    public static let saveDebounceMs: Int64 = 5_000

    private let store: AtomicJSONStore<HistoryDocument>
    private let clock: Clock
    private let scheduler: HistoryScheduler
    private let idGenerator: HistorySessionIDGenerator
    private let calendar: Calendar

    private var data: HistoryDocument = .defaultValue
    private var current: AwakeSession?
    private var lastTickAt: Int64
    private var isLoaded = false

    /// The most recent diagnostic from either loading (verbatim from
    /// `AtomicJSONStore.load()`) or a failed persistence attempt from
    /// `record()`'s close-session persist, `clear()`, `flush(at:)`, or a
    /// debounced save (`HistoryDiagnosticID.persistFailed`). A
    /// `HistoryDiagnosticID.persistFailed` value here is cleared the next
    /// time any of those persist attempts succeeds (see
    /// `persistLocked()`); a load-time diagnostic is left untouched by a
    /// later successful persist. `AppSnapshotCoordinator` reads this
    /// directly after every `record(_:)` call to reconcile a persist
    /// failure — including one from an earlier, asynchronous debounced
    /// save — into the published snapshot's diagnostics, rather than
    /// leaving it visible only here.
    public private(set) var lastDiagnostic: Diagnostic?

    private var pendingSave: HistoryScheduledTask?
    private var scheduleGeneration = 0

    /// Serializes every public mutator (`record`/`clear`/`flush`) plus the
    /// internal debounced-save callback through its full awaited round
    /// trip, in FIFO invocation order — see the type documentation above.
    private let gate = AsyncGate()

    public init(
        store: AtomicJSONStore<HistoryDocument>,
        clock: Clock,
        scheduler: HistoryScheduler = RealTimeHistoryScheduler(),
        idGenerator: HistorySessionIDGenerator = RandomHistorySessionIDGenerator(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = .current
    ) {
        self.store = store
        self.clock = clock
        self.scheduler = scheduler
        self.idGenerator = idGenerator
        var resolvedCalendar = calendar
        resolvedCalendar.timeZone = timeZone
        self.calendar = resolvedCalendar
        self.lastTickAt = clock.nowMilliseconds()
    }

    // MARK: - Load

    @discardableResult
    public func load() async -> LoadResult<HistoryDocument> {
        await gate.acquire()
        let result = await performLoad()
        await gate.release()
        return result
    }

    private func performLoad() async -> LoadResult<HistoryDocument> {
        let result = await store.load()
        data = result.value
        lastDiagnostic = result.diagnostic
        isLoaded = true
        lastTickAt = clock.nowMilliseconds()
        return result
    }

    /// Performs `load()`'s underlying work exactly once, if it has never
    /// run, *without* acquiring `gate` again — every caller of this is
    /// already running inside a `gate`-guarded operation. Lets a mutator
    /// be called directly with no prior explicit `load()` call.
    private func ensureLoaded() async {
        guard !isLoaded else { return }
        _ = await performLoad()
    }

    // MARK: - Recording

    /// Applies one monitor state tick. Creates a new session on the
    /// active-state transition, accumulates elapsed time (capped at
    /// `maxTickDeltaMs`) into the current session/all-time totals/daily
    /// bucket/per-agent totals while it continues, and closes+persists the
    /// session the moment the state goes idle.
    public func record(_ state: AgentMonitorState) async {
        await gate.acquire()
        await performRecord(state)
        await gate.release()
    }

    private func performRecord(_ state: AgentMonitorState) async {
        await ensureLoaded()
        let now = clock.nowMilliseconds()
        defer { lastTickAt = now }

        if state.keepingAwake {
            if current == nil {
                let id = await idGenerator.nextID(startedAt: now)
                current = AwakeSession(
                    id: id,
                    startedAt: now,
                    endedAt: nil,
                    durationMs: 0,
                    mode: state.keepAwakeMode,
                    agents: []
                )
            } else {
                let delta = cappedTickDelta(now: now)
                if delta > 0 {
                    applyDelta(delta, state: state, now: now)
                    await scheduleSaveIfNeeded()
                }
            }
        } else if current != nil {
            closeCurrentSession(endedAt: now)
            cancelPendingSave()
            _ = await persistLocked()
        }
    }

    private func applyDelta(_ delta: Int64, state: AgentMonitorState, now: Int64) {
        guard var session = current else { return }
        session.durationMs = HistoryDocument.saturatingAdd(session.durationMs, delta)
        session.mode = state.keepAwakeMode
        data.totalAwakeMs = HistoryDocument.saturatingAdd(data.totalAwakeMs, delta)

        let key = dayKey(for: now)
        data.daily[key] = HistoryDocument.saturatingAdd(data.daily[key] ?? 0, delta)

        for agent in state.agents {
            addAgentTime(to: &session.agents, id: agent.id, name: agent.name, delta: delta)
            let familyID = HistoryDocument.aggregateAgentID(agent.id)
            var total = data.agentTotals[familyID] ?? HistoryAgentTotal(
                name: HistoryDocument.aggregateAgentName(familyID: familyID, fallback: agent.name),
                durationMs: 0
            )
            total.durationMs = HistoryDocument.saturatingAdd(total.durationMs, delta)
            data.agentTotals[familyID] = total
        }

        current = session
    }

    private func addAgentTime(to agents: inout [AgentUsage], id: String, name: String, delta: Int64) {
        if let index = agents.firstIndex(where: { $0.id == id }) {
            agents[index].durationMs = HistoryDocument.saturatingAdd(agents[index].durationMs, delta)
            agents[index].name = name
        } else {
            agents.append(AgentUsage(id: id, name: name, durationMs: delta))
        }
    }

    private func cappedTickDelta(now: Int64) -> Int64 {
        guard now > lastTickAt else { return 0 }
        let (elapsed, overflow) = now.subtractingReportingOverflow(lastTickAt)
        return overflow ? Self.maxTickDeltaMs : min(elapsed, Self.maxTickDeltaMs)
    }

    private func closeCurrentSession(endedAt: Int64) {
        guard var session = current else { return }
        session.endedAt = endedAt
        if session.durationMs >= Self.minimumSessionMs {
            data.sessions.insert(session, at: 0)
            if data.sessions.count > Self.maximumSessions {
                data.sessions.removeLast(data.sessions.count - Self.maximumSessions)
            }
            data.sessionCount = HistoryDocument.saturatingAdd(data.sessionCount, 1)
        }
        current = nil
    }

    // MARK: - Reading

    /// A snapshot of the current aggregate/session state. Every field is a
    /// value type (`struct`), so mutating the returned `HistoryStats` can
    /// never affect this store's own internal state.
    public func stats() async -> HistoryStats {
        buildStats()
    }

    /// The exact persisted document as currently held in memory — for
    /// tests/diagnostics that need to inspect the capped `sessions`/`daily`
    /// collections directly, distinct from the further-trimmed
    /// `recentSessions` `stats()` exposes.
    public func persistedDocument() async -> HistoryDocument {
        data
    }

    private func buildStats() -> HistoryStats {
        let perAgent = data.agentTotals
            .map { AgentUsage(id: $0.key, name: $0.value.name, durationMs: $0.value.durationMs) }
            .sorted { lhs, rhs in
                lhs.durationMs != rhs.durationMs ? lhs.durationMs > rhs.durationMs : lhs.id < rhs.id
            }
        let today = dayKey(for: clock.nowMilliseconds())
        return HistoryStats(
            totalAwakeMs: data.totalAwakeMs,
            todayAwakeMs: data.daily[today] ?? 0,
            sessionCount: data.sessionCount,
            perAgent: perAgent,
            currentSession: current,
            recentSessions: Array(data.sessions.prefix(Self.maximumRecentSessions))
        )
    }

    /// Local calendar day key (`yyyy-MM-dd`) for `milliseconds`, using
    /// this store's injected `calendar`/time zone — matching the TS
    /// reference's `dayKey()`, which uses `Date`'s local
    /// year/month/day getters. Attributes an entire cross-midnight tick
    /// delta to the day of the *tick's own timestamp* (`now`), not the day
    /// the delta started in — this is the exact reference semantic
    /// `testDayRolloverCreditsEntireDeltaToTickTimestampsDay` characterizes.
    private func dayKey(for milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    // MARK: - Clear

    /// Resets all-time totals, the session/daily history, and the current
    /// session to empty defaults, then persists that empty document.
    /// Never reports fake success: if the underlying save fails, the
    /// failure is captured in `lastDiagnostic` rather than silently
    /// swallowed (the in-memory reset itself always applies, matching the
    /// TS reference, which never rolls back `clear()`'s in-memory effect
    /// on a failed write either).
    @discardableResult
    public func clear() async -> HistoryStats {
        await gate.acquire()
        let (stats, _) = await performClear()
        await gate.release()
        return stats
    }

    /// Same reset as `clear()`, but — like `flush(at:)` — throws the
    /// underlying `StorageError` instead of only capturing it into
    /// `lastDiagnostic`. Added so `AppSnapshotCoordinator` can await a
    /// clear and react to (or surface) a persistence failure directly,
    /// rather than needing a separate poll of `lastDiagnostic` after an
    /// always-succeeding call. The in-memory reset itself still always
    /// applies before the throw, exactly like `clear()` — a caller must
    /// not assume a thrown error here means nothing changed.
    @discardableResult
    public func clearOrThrow() async throws -> HistoryStats {
        await gate.acquire()
        let (stats, error) = await performClear()
        await gate.release()
        if let error {
            throw error
        }
        return stats
    }

    /// Shared body for `clear()`/`clearOrThrow()`: resets in-memory state
    /// to defaults, persists it, and returns the resulting stats alongside
    /// the persistence failure (if any) so each public entry point can
    /// decide independently whether to surface it as a thrown error.
    private func performClear() async -> (HistoryStats, StorageError?) {
        await ensureLoaded()
        cancelPendingSave()
        data = .defaultValue
        current = nil
        lastTickAt = clock.nowMilliseconds()
        let error = await persistLocked()
        let stats = buildStats()
        return (stats, error)
    }

    // MARK: - Shutdown flush

    /// Closes the current session (if any) as of `now`, cancels any
    /// pending debounced save, trims daily keys, and awaits the atomic
    /// save — an explicit, awaitable alternative to fire-and-forget
    /// shutdown durability. Throws the underlying typed `StorageError`
    /// (rather than silently reporting success) if the final persist
    /// fails, so a caller awaiting app-termination durability can observe
    /// and react to the failure.
    @discardableResult
    public func flush(at now: Int64) async throws -> HistoryStats {
        await gate.acquire()
        await ensureLoaded()
        cancelPendingSave()
        if current != nil {
            closeCurrentSession(endedAt: now)
        }
        lastTickAt = now
        let error = await persistLocked()
        let stats = buildStats()
        await gate.release()
        if let error {
            throw error
        }
        return stats
    }

    // MARK: - Debounced save

    /// Arms a single debounced save `saveDebounceMs` in the future, unless
    /// one is already pending — matching the TS reference's
    /// `saveScheduled` guard, which coalesces any number of ticks within
    /// one debounce window into a single write.
    private func scheduleSaveIfNeeded() async {
        guard pendingSave == nil else { return }
        scheduleGeneration += 1
        let generation = scheduleGeneration
        let token = await scheduler.scheduleAfter(milliseconds: Self.saveDebounceMs) { [weak self] in
            await self?.runScheduledSave(generation: generation)
        }
        pendingSave = token
    }

    /// Runs under `gate` like every other disk-touching operation. Checks
    /// its captured `generation` immediately upon resuming on the actor —
    /// before touching `data` or calling `store.save` — so a save whose
    /// schedule was superseded (a newer tick rescheduled it) or cancelled
    /// (`cancelPendingSave()`, from `clear()`/`flush(at:)`) becomes a
    /// no-op even if the scheduler's own cancellation didn't actually
    /// prevent this closure from running at all.
    private func runScheduledSave(generation: Int) async {
        await gate.acquire()
        guard generation == scheduleGeneration, pendingSave != nil else {
            await gate.release()
            return
        }
        pendingSave = nil
        _ = await persistLocked()
        await gate.release()
    }

    /// Cancels any pending debounced save and immediately invalidates it
    /// via `scheduleGeneration`, synchronously and with no `await` in
    /// between — so no other actor-isolated code (in particular a
    /// concurrently in-flight `runScheduledSave`) can observe the old
    /// generation as still current once this returns.
    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        scheduleGeneration += 1
    }

    /// Trims `data.daily` to `maximumDailyKeys`, then persists `data`
    /// through the underlying `AtomicJSONStore`. Returns the
    /// `StorageError` on failure (captured into `lastDiagnostic`) instead
    /// of throwing, so both non-throwing callers (`clear()`, the
    /// debounced save) and the throwing caller (`flush(at:)`, which
    /// re-throws it) share one implementation.
    ///
    /// On success, clears `lastDiagnostic` *only* if it currently holds a
    /// previous `HistoryDiagnosticID.persistFailed` — i.e. only a prior
    /// failure of this exact same persist operation, never a load-time
    /// diagnostic (`storage.settings.corrupt`/`.unsupported-version`/
    /// `.read-failed`, surfaced verbatim from `AtomicJSONStore.load()`),
    /// which a successful save has no bearing on and must not silently
    /// erase.
    @discardableResult
    private func persistLocked() async -> StorageError? {
        trimDaily()
        do {
            try await store.save(data)
            if lastDiagnostic?.id == HistoryDiagnosticID.persistFailed {
                lastDiagnostic = nil
            }
            return nil
        } catch let error as StorageError {
            lastDiagnostic = Diagnostic(
                id: HistoryDiagnosticID.persistFailed,
                message: "Failed to persist history: \(error)",
                occurredAt: clock.nowMilliseconds()
            )
            return error
        } catch {
            lastDiagnostic = Diagnostic(
                id: HistoryDiagnosticID.persistFailed,
                message: "Failed to persist history: \(error)",
                occurredAt: clock.nowMilliseconds()
            )
            return nil
        }
    }

    private func trimDaily() {
        guard data.daily.count > Self.maximumDailyKeys else { return }
        let keysToKeep = Set(data.daily.keys.sorted().suffix(Self.maximumDailyKeys))
        data.daily = data.daily.filter { keysToKeep.contains($0.key) }
    }
}
