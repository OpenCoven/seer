import XCTest
import os
@testable import Seer

/// A mutable, injectable `Clock` for `HistoryStore` tests. Unlike the
/// immutable `FixedClock` used by `ModelsTests`, history tests need to
/// advance "now" between ticks within a single test to exercise delta
/// accumulation, tick capping, and day rollover deterministically.
final class MutableClock: Clock, @unchecked Sendable {
    var now: Int64

    init(now: Int64) {
        self.now = now
    }

    func nowMilliseconds() -> Int64 {
        now
    }
}

/// Deterministic `HistorySessionIDGenerator` test double — sequential ids
/// instead of the production generator's `UUID`-based randomness.
final class SequentialHistorySessionIDGenerator: HistorySessionIDGenerator, @unchecked Sendable {
    // `OSAllocatedUnfairLock` (not `NSLock`) because `NSLock.lock()`/
    // `unlock()` are unavailable from `async` contexts under Swift 6's
    // strict concurrency checking, and `nextID(startedAt:)` is `async`.
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    func nextID(startedAt: Int64) async -> String {
        let value = counter.withLock { count in
            count += 1
            return count
        }
        return "test-session-\(value)"
    }
}

/// A manually-driven `HistoryScheduler` test double: `scheduleAfter`
/// records the work item but never runs it on its own; `fireAllPending()`
/// runs every still-pending item (in scheduling order), letting tests
/// deterministically simulate "the debounce window elapsed" without ever
/// sleeping for real. Backed by a plain lock (not an `actor`) so
/// `cancel()` — called synchronously and non-async by `HistoryStore`,
/// exactly like the production `Task.cancel()` it replaces — removes the
/// item immediately, with no ambiguity about whether the cancellation has
/// "taken effect" yet by the time a test calls `fireAllPending()`.
final class ManualHistoryScheduler: HistoryScheduler, @unchecked Sendable {
    private struct State {
        var items: [Int: @Sendable () async -> Void] = [:]
        var nextID = 0
        var scheduleCount = 0
    }

    // `OSAllocatedUnfairLock` (not `NSLock`) because `NSLock.lock()`/
    // `unlock()` are unavailable from `async` contexts under Swift 6's
    // strict concurrency checking, and `scheduleAfter` is `async`.
    private let state = OSAllocatedUnfairLock(initialState: State())

    var scheduleCount: Int {
        state.withLock { $0.scheduleCount }
    }

    func scheduleAfter(
        milliseconds delayMs: Int64,
        _ work: @escaping @Sendable () async -> Void
    ) async -> HistoryScheduledTask {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            state.scheduleCount += 1
            state.items[state.nextID] = work
            return state.nextID
        }
        return HistoryScheduledTask { [weak self] in
            self?.cancelSynchronously(id)
        }
    }

    private func cancelSynchronously(_ id: Int) {
        state.withLock { $0.items.removeValue(forKey: id) }
    }

    var pendingCount: Int {
        state.withLock { $0.items.count }
    }

    func fireAllPending() async {
        let ordered = state.withLock { state -> [@Sendable () async -> Void] in
            let ordered = state.items.sorted { $0.key < $1.key }.map { $0.value }
            state.items.removeAll()
            return ordered
        }
        for work in ordered {
            await work()
        }
    }
}

/// A `HistoryScheduler` double whose returned token's `cancel()` is
/// deliberately a no-op — modeling the narrow real-world race where a
/// timer fires at essentially the same moment `cancel()` is requested, so
/// the scheduled work still runs. Exists solely to prove `HistoryStore`'s
/// own `scheduleGeneration` staleness guard — not the scheduler's
/// cooperative cancellation — is what prevents a stale scheduled save
/// from clobbering a newer `clear()`/`flush(at:)` snapshot.
final class UncancellableHistoryScheduler: HistoryScheduler, @unchecked Sendable {
    private struct State {
        var items: [Int: @Sendable () async -> Void] = [:]
        var nextID = 0
    }

    // `OSAllocatedUnfairLock` (not `NSLock`) — see `ManualHistoryScheduler`.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func scheduleAfter(
        milliseconds delayMs: Int64,
        _ work: @escaping @Sendable () async -> Void
    ) async -> HistoryScheduledTask {
        state.withLock { state in
            state.nextID += 1
            state.items[state.nextID] = work
        }
        return HistoryScheduledTask {}
    }

    func fireAllPending() async {
        let ordered = state.withLock { state -> [@Sendable () async -> Void] in
            let ordered = state.items.sorted { $0.key < $1.key }.map { $0.value }
            state.items.removeAll()
            return ordered
        }
        for work in ordered {
            await work()
        }
    }
}

final class HistoryStoreTests: XCTestCase {
    private let historyURL = URL(fileURLWithPath: "/Seer-Test-Root/ai.opencoven.seer/history.json")
    private var clock = MutableClock(now: 1_000)

    override func setUp() {
        super.setUp()
        clock = MutableClock(now: 1_000)
    }

    // MARK: - Fixtures

    private func makeStore(
        fileSystem: InMemorySettingsFileSystem,
        scheduler: HistoryScheduler = ManualHistoryScheduler(),
        idGenerator: HistorySessionIDGenerator = SequentialHistorySessionIDGenerator(),
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> HistoryStore {
        let atomicStore = AtomicJSONStore<HistoryDocument>(fileURL: historyURL, fileSystem: fileSystem, clock: clock)
        return HistoryStore(
            store: atomicStore,
            clock: clock,
            scheduler: scheduler,
            idGenerator: idGenerator,
            timeZone: timeZone
        )
    }

    private func activeState(
        agents: [(id: String, name: String)] = [("codex", "Codex")],
        mode: KeepAwakeMode = .system,
        at timestamp: Int64
    ) -> AgentMonitorState {
        AgentMonitorState(
            active: true,
            keepingAwake: true,
            keepAwakeMode: mode,
            agents: agents.map {
                ActiveAgent(id: $0.id, name: $0.name, detail: "", source: .process, pid: nil, cpuPercent: nil, lastActivityAt: timestamp)
            },
            lastScanAt: timestamp
        )
    }

    private func idleState(at timestamp: Int64) -> AgentMonitorState {
        AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: timestamp)
    }

    // MARK: 1. Delayed tick is capped at the maximum tick delta

    func testDelayedTickIsCappedAtFifteenSeconds() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)

        await store.record(activeState(at: 1_000))
        clock.now = 31_000
        await store.record(activeState(at: 31_000))

        let stats = await store.stats()
        XCTAssertEqual(stats.totalAwakeMs, HistoryStore.maxTickDeltaMs)
    }

    // MARK: 2. Subsecond session is discarded

    func testSubsecondSessionIsDiscarded() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)

        await store.record(activeState(at: 1_000))
        clock.now = 1_500
        await store.record(idleState(at: 1_500))

        let stats = await store.stats()
        XCTAssertEqual(stats.sessionCount, 0)
        XCTAssertTrue(stats.recentSessions.isEmpty)
    }

    // MARK: 3. Session/recent-session/daily-key caps

    func testCapsSessionsRecentSessionsAndDailyKeys() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        // >24h per cycle guarantees a new UTC calendar day every cycle
        // regardless of what time-of-day the cycle starts at.
        let dayMs: Int64 = 25 * 60 * 60 * 1000
        var t = clock.now
        for _ in 0..<101 {
            clock.now = t
            await store.record(activeState(at: t))
            clock.now = t + 2_000
            await store.record(activeState(at: t + 2_000))
            clock.now = t + 3_500
            await store.record(idleState(at: t + 3_500))
            t += dayMs
        }

        let document = await store.persistedDocument()
        XCTAssertEqual(document.sessions.count, HistoryStore.maximumSessions)
        XCTAssertEqual(document.daily.count, HistoryStore.maximumDailyKeys)
        XCTAssertEqual(document.sessionCount, 101, "the cumulative counter is never capped, only the stored session list")

        let stats = await store.stats()
        XCTAssertEqual(stats.recentSessions.count, HistoryStore.maximumRecentSessions)
    }

    // MARK: 4. Per-agent accumulation and descending order

    func testPerAgentAccumulationSortsDescending() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)

        await store.record(activeState(agents: [("codex", "Codex"), ("claude-code", "Claude Code")], at: 1_000))
        clock.now = 4_000
        await store.record(activeState(agents: [("codex", "Codex"), ("claude-code", "Claude Code")], at: 4_000)) // +3000 each
        clock.now = 6_000
        await store.record(activeState(agents: [("codex", "Codex")], at: 6_000)) // +2000 codex only

        let stats = await store.stats()
        XCTAssertEqual(stats.perAgent.map(\.id), ["codex", "claude-code"])
        XCTAssertEqual(stats.perAgent.first?.durationMs, 5_000)
        XCTAssertEqual(stats.perAgent.last?.durationMs, 3_000)
        XCTAssertEqual(stats.currentSession?.agents.map(\.id).sorted(), ["claude-code", "codex"])
    }

    func testAggregateTotalsUseStableFamiliesWhileCurrentSessionRetainsAgentIdentity() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        let agents = [
            ("codex:transcript-a", "Codex"),
            ("codex:transcript-b", "Codex"),
            ("untrusted:session-a", "Unknown"),
            ("another-unknown-session", "Unknown"),
        ]

        await store.record(activeState(agents: agents, at: 1_000))
        clock.now = 3_000
        await store.record(activeState(agents: agents, at: 3_000))

        let stats = await store.stats()
        let document = await store.persistedDocument()
        XCTAssertEqual(Set(document.agentTotals.keys), Set(["codex", "other"]))
        XCTAssertEqual(document.agentTotals["codex"]?.durationMs, 4_000)
        XCTAssertEqual(document.agentTotals["other"]?.durationMs, 4_000)
        XCTAssertEqual(
            Set(stats.currentSession?.agents.map(\.id) ?? []),
            Set(agents.map(\.0)),
            "current/recent session details may retain per-session identity"
        )
    }

    func testLoadMigratesThousandsOfAgentIDsIntoCompactAccurateFamilyTotals() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        var agentTotals: [String: Any] = [:]
        for index in 0..<4_000 {
            agentTotals["codex:transcript-\(index)"] = ["name": "Codex \(index)", "durationMs": 2]
            agentTotals["malicious-family-\(index):transcript"] = ["name": "Unknown \(index)", "durationMs": 3]
        }
        let seeded = try JSONSerialization.data(withJSONObject: [
            "version": HistoryDocument.currentVersion,
            "totalAwakeMs": 20_000,
            "sessionCount": 0,
            "agentTotals": agentTotals,
            "daily": [:],
            "sessions": [],
        ])
        await fileSystem.seedFile(at: historyURL, contents: seeded)
        let store = makeStore(fileSystem: fileSystem)

        _ = await store.load()

        var document = await store.persistedDocument()
        XCTAssertEqual(Set(document.agentTotals.keys), Set(["codex", "other"]))
        XCTAssertEqual(document.agentTotals["codex"]?.durationMs, 8_000)
        XCTAssertEqual(document.agentTotals["other"]?.durationMs, 12_000)

        _ = try await store.flush(at: clock.now)
        let persistedBytes = await fileSystem.contents(at: historyURL)
        let compactBytes = try XCTUnwrap(persistedBytes)
        XCTAssertLessThan(compactBytes.count, 2_000)

        let reloaded = makeStore(fileSystem: fileSystem)
        _ = await reloaded.load()
        document = await reloaded.persistedDocument()
        XCTAssertEqual(document.agentTotals["codex"]?.durationMs, 8_000)
        XCTAssertEqual(document.agentTotals["other"]?.durationMs, 12_000)
    }

    // MARK: 5. Keep-awake mode follows state changes

    func testKeepAwakeModeFollowsStateChanges() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)

        await store.record(activeState(mode: .system, at: 1_000))
        clock.now = 3_000
        await store.record(activeState(mode: .display, at: 3_000))

        let stats = await store.stats()
        XCTAssertEqual(stats.currentSession?.mode, .display)
    }

    // MARK: 6. Local day rollover — explicit reference-semantics test

    func testDayRolloverCreditsEntireDeltaToTickTimestampsDay() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let utc = TimeZone(identifier: "UTC")!
        clock.now = 86_400_000 - 2_000 // 1970-01-01T23:59:58.000Z
        let store = makeStore(fileSystem: fileSystem, timeZone: utc)

        await store.record(activeState(at: clock.now))
        let afterMidnight = clock.now + 4_000 // 1970-01-02T00:00:02.000Z, delta 4s (< 15s cap)
        clock.now = afterMidnight
        await store.record(activeState(at: afterMidnight))

        let document = await store.persistedDocument()
        XCTAssertNil(
            document.daily["1970-01-01"],
            "the whole delta is credited to the tick's own timestamp day, not split across the boundary it crossed"
        )
        XCTAssertEqual(document.daily["1970-01-02"], 4_000)
        XCTAssertEqual(document.totalAwakeMs, 4_000)

        let stats = await store.stats()
        XCTAssertEqual(stats.todayAwakeMs, 4_000)
    }

    // MARK: 7. Clear resets aggregate/current state and persists

    func testClearResetsAggregateStateAndPersists() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        await store.record(activeState(at: 1_000))
        clock.now = 3_000
        await store.record(activeState(at: 3_000))

        let stats = await store.clear()
        XCTAssertEqual(stats.totalAwakeMs, 0)
        XCTAssertEqual(stats.sessionCount, 0)
        XCTAssertNil(stats.currentSession)
        XCTAssertTrue(stats.recentSessions.isEmpty)
        XCTAssertTrue(stats.perAgent.isEmpty)

        let bytes = await fileSystem.contents(at: historyURL)
        XCTAssertNotNil(bytes)
        let decoded = try JSONDecoder().decode(HistoryDocument.self, from: bytes!)
        XCTAssertEqual(decoded, HistoryDocument.defaultValue)
    }

    // MARK: 8. Corrupt history produces a diagnostic and a safe empty state

    func testCorruptHistoryProducesDiagnosticAndSafeEmptyState() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        await fileSystem.seedFile(at: historyURL, contents: Data("{not valid json".utf8))
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.corrupt)
        XCTAssertTrue(result.writesEnabled, "a quarantined corrupt file leaves writes enabled for a fresh document")

        let diagnostic = await store.lastDiagnostic
        XCTAssertEqual(diagnostic?.id, StorageDiagnosticID.corrupt)

        let stats = await store.stats()
        XCTAssertEqual(stats.totalAwakeMs, 0)
        XCTAssertEqual(stats.sessionCount, 0)
        XCTAssertTrue(stats.recentSessions.isEmpty)
        XCTAssertNil(stats.currentSession)

        // Corrupt bytes are quarantined aside (never silently discarded),
        // and this must only ever touch the injected history file's own
        // directory — never a settings or Glaze path.
        let names = await fileSystem.fileNames(inDirectoryOf: historyURL)
        XCTAssertTrue(names.contains { $0.hasPrefix("history.json.corrupt-") })
    }

    // MARK: 9. Five-second debounce is deterministic: coalescing + cancellation

    func testFiveSecondDebounceCoalescesAndCancelsDeterministically() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let scheduler = ManualHistoryScheduler()
        let store = makeStore(fileSystem: fileSystem, scheduler: scheduler)
        _ = await store.load()

        await store.record(activeState(at: 1_000))
        clock.now = 2_000
        await store.record(activeState(at: 2_000)) // delta 1000 -> schedules save #1
        clock.now = 3_000
        await store.record(activeState(at: 3_000)) // delta 1000 -> must coalesce, not reschedule

        XCTAssertEqual(scheduler.scheduleCount, 1, "a tick while a save is already pending must not arm a second debounce timer")
        XCTAssertEqual(scheduler.pendingCount, 1)

        await scheduler.fireAllPending()

        let bytes = await fileSystem.contents(at: historyURL)
        XCTAssertNotNil(bytes, "the debounced save must actually persist once fired")
        let decoded = try JSONDecoder().decode(HistoryDocument.self, from: bytes!)
        XCTAssertEqual(decoded.totalAwakeMs, 2_000) // 1000 (tick 2) + 1000 (tick 3)

        // Cancellation: arm another debounce, then flush before it fires.
        clock.now = 4_000
        await store.record(activeState(at: 4_000)) // delta 1000 -> schedules save #2
        XCTAssertEqual(scheduler.pendingCount, 1)

        _ = try await store.flush(at: 5_000)
        XCTAssertEqual(scheduler.pendingCount, 0, "flush(at:) must cancel the pending debounce timer")
    }

    // MARK: 10. Explicit shutdown flush waits and closes the current session

    func testFlushClosesCurrentSessionAndPersistsSynchronously() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        await store.record(activeState(at: 1_000))
        clock.now = 3_000
        await store.record(activeState(at: 3_000)) // durationMs accumulates to 2000 (>= minimum)

        let stats = try await store.flush(at: 4_000)
        XCTAssertNil(stats.currentSession)
        XCTAssertEqual(stats.recentSessions.count, 1)
        XCTAssertEqual(stats.recentSessions.first?.endedAt, 4_000)
        XCTAssertEqual(stats.recentSessions.first?.durationMs, 2_000)
        XCTAssertEqual(stats.sessionCount, 1)

        let bytes = await fileSystem.contents(at: historyURL)
        XCTAssertNotNil(bytes)
        let decoded = try JSONDecoder().decode(HistoryDocument.self, from: bytes!)
        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions.first?.endedAt, 4_000)
    }

    // MARK: 11. Future version remains read-only/preserved

    func testFutureVersionHistoryRemainsReadOnlyAndPreserved() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let futureBytes = Data(#"{"version":999,"totalAwakeMs":123}"#.utf8)
        await fileSystem.seedFile(at: historyURL, contents: futureBytes)
        let store = makeStore(fileSystem: fileSystem)

        let result = await store.load()
        XCTAssertEqual(result.diagnostic?.id, StorageDiagnosticID.unsupportedVersion)
        XCTAssertFalse(result.writesEnabled)

        let stats = await store.clear()
        XCTAssertEqual(stats.totalAwakeMs, 0, "the in-memory view still resets to empty defaults")

        let preserved = await fileSystem.contents(at: historyURL)
        XCTAssertEqual(preserved, futureBytes, "a future-version history file must never be overwritten by clear()")

        let diagnostic = await store.lastDiagnostic
        XCTAssertEqual(diagnostic?.id, HistoryDiagnosticID.persistFailed)
    }

    // MARK: 12. Persistence failure surfaces via diagnostic/typed error, never fake success

    func testClearSurfacesPersistenceFailureAsDiagnosticNotFakeSuccess() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()
        await store.record(activeState(at: 1_000))

        await fileSystem.setFailNextWrite(SettingsFileSystemError.other("disk full"))
        let stats = await store.clear()

        XCTAssertEqual(stats.totalAwakeMs, 0, "the in-memory reset still applies")
        let diagnostic = await store.lastDiagnostic
        XCTAssertEqual(diagnostic?.id, HistoryDiagnosticID.persistFailed, "a failed disk write must never be reported as a silent success")
    }

    func testFlushThrowsTypedStorageErrorOnPersistenceFailure() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()
        await store.record(activeState(at: 1_000))

        await fileSystem.setFailNextWrite(SettingsFileSystemError.other("disk full"))
        do {
            _ = try await store.flush(at: 5_000)
            XCTFail("expected flush(at:) to throw a typed StorageError rather than report fake success")
        } catch StorageError.writeFailed {
            // expected
        }
    }

    // MARK: 13. Ordering/race: an older delayed save cannot replace a newer clear/flush snapshot

    func testOlderDelayedSaveCannotReplaceNewerClearSnapshot() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let scheduler = UncancellableHistoryScheduler()
        let store = makeStore(fileSystem: fileSystem, scheduler: scheduler)
        _ = await store.load()

        await store.record(activeState(at: 1_000))
        clock.now = 20_000
        await store.record(activeState(at: 20_000)) // arms a debounced save capturing pre-clear totals

        let clearedStats = await store.clear()
        XCTAssertEqual(clearedStats.totalAwakeMs, 0)

        // The scheduler's own cancel() is a deliberate no-op here, so the
        // stale debounced save still actually runs. `HistoryStore`'s own
        // generation guard, not scheduler cooperation, must be what stops
        // it from overwriting the fresh empty snapshot `clear()` already
        // committed.
        await scheduler.fireAllPending()

        let bytes = await fileSystem.contents(at: historyURL)
        XCTAssertNotNil(bytes)
        let decoded = try JSONDecoder().decode(HistoryDocument.self, from: bytes!)
        XCTAssertEqual(decoded, HistoryDocument.defaultValue, "a stale, uncancelled debounced save must never clobber a newer clear() snapshot")

        let stats = await store.stats()
        XCTAssertEqual(stats.totalAwakeMs, 0)
    }

    func testOlderDelayedSaveCannotReplaceNewerFlushSnapshot() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let scheduler = UncancellableHistoryScheduler()
        let store = makeStore(fileSystem: fileSystem, scheduler: scheduler)
        _ = await store.load()

        await store.record(activeState(at: 1_000))
        clock.now = 20_000
        await store.record(activeState(at: 20_000)) // arms a debounced save capturing pre-flush totals

        _ = try await store.flush(at: 21_000)

        let flushedBytes = await fileSystem.contents(at: historyURL)
        let flushedDecoded = try JSONDecoder().decode(HistoryDocument.self, from: flushedBytes!)
        XCTAssertEqual(flushedDecoded.sessionCount, 1)

        await scheduler.fireAllPending()

        let finalBytes = await fileSystem.contents(at: historyURL)
        let finalDecoded = try JSONDecoder().decode(HistoryDocument.self, from: finalBytes!)
        XCTAssertEqual(finalDecoded, flushedDecoded, "a stale, uncancelled debounced save must never clobber a newer flush(at:) snapshot")
    }

    // MARK: 14a. Loaded-data validation and exact schema version behavior

    func testHistoryDocumentDecodeNormalizesMalformedNegativeAndInvalidEntries() throws {
        let json = """
        {
          "version": 1,
          "totalAwakeMs": -50,
          "sessionCount": -3,
          "agentTotals": {
            "codex": {"name": "Codex", "durationMs": 10},
            "negative": {"name": "Bad", "durationMs": -5},
            "malformed": {"name": 123}
          },
          "daily": {
            "2024-01-01": 100,
            "2024-01-02": -10,
            "2024-01-03": "not-a-number"
          },
          "sessions": [
            {"id": "s1", "startedAt": 1, "endedAt": 2, "durationMs": 5, "mode": "system", "agents": []},
            {"id": "s2", "startedAt": "bad"},
            123
          ]
        }
        """
        let decoded = try JSONDecoder().decode(HistoryDocument.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.version, HistoryDocument.currentVersion)
        XCTAssertEqual(decoded.totalAwakeMs, 0, "negative totalAwakeMs must clamp to 0, never propagate as-is")
        XCTAssertEqual(decoded.sessionCount, 0, "negative sessionCount must clamp to 0")
        XCTAssertEqual(decoded.agentTotals, ["codex": HistoryAgentTotal(name: "Codex", durationMs: 10)])
        XCTAssertEqual(decoded.daily, ["2024-01-01": 100])
        XCTAssertEqual(decoded.sessions.map(\.id), ["s1"])
    }

    func testHistoryDocumentDecodeCapsSessionsAtMaximumOnLoad() throws {
        let sessionsJSON = (0..<150).map { index in
            "{\"id\":\"s\(index)\",\"startedAt\":\(index),\"endedAt\":null,\"durationMs\":1000,\"mode\":\"system\",\"agents\":[]}"
        }.joined(separator: ",")
        let json = """
        {"version":1,"totalAwakeMs":0,"sessionCount":150,"agentTotals":{},"daily":{},"sessions":[\(sessionsJSON)]}
        """
        let decoded = try JSONDecoder().decode(HistoryDocument.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sessions.count, HistoryStore.maximumSessions)
    }

    // MARK: 14b. Snapshots do not expose mutable internal state

    func testStatsSnapshotsDoNotExposeMutableInternalState() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)

        await store.record(activeState(agents: [("codex", "Codex")], at: 1_000))
        clock.now = 3_000
        await store.record(activeState(agents: [("codex", "Codex")], at: 3_000))

        var stats = await store.stats()
        stats.perAgent[0].durationMs = 999_999
        stats.totalAwakeMs = 999_999

        let statsAgain = await store.stats()
        XCTAssertNotEqual(statsAgain.perAgent[0].durationMs, 999_999)
        XCTAssertNotEqual(statsAgain.totalAwakeMs, 999_999)
        XCTAssertEqual(statsAgain.totalAwakeMs, 2_000)
    }

    // MARK: 15. Path resolver uses injected base URL exactly (standalone contract)

    /// Mirrors `testSettingsFileURLUsesInjectedBaseURLExactly` in
    /// `AtomicJSONStoreTests`. `HistoryFileLocation` is not yet wired into
    /// production app startup (that's later-task plumbing), but its
    /// resolver is public API today and must already honor the exact same
    /// standalone-path contract `SettingsFileLocation` does: always
    /// `<base>/ai.opencoven.seer/history.json`, creating only that one
    /// product directory, and never touching a Glaze path or the real
    /// Application Support directory.
    func testHistoryFileURLUsesInjectedBaseURLExactly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeerHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let resolved = try HistoryFileLocation.historyFileURL(applicationSupportDirectory: base)

        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            base.appendingPathComponent("ai.opencoven.seer/history.json").standardizedFileURL.path
        )

        var isDirectory: ObjCBool = false
        let productDirectory = base.appendingPathComponent("ai.opencoven.seer")
        let directoryExists = FileManager.default.fileExists(atPath: productDirectory.path, isDirectory: &isDirectory)
        XCTAssertTrue(directoryExists)
        XCTAssertTrue(isDirectory.boolValue)

        // Exactly one directory is created directly under `base` — the
        // shared `ai.opencoven.seer` product directory — never an
        // additional sibling (in particular, never a Glaze directory).
        let baseContents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(baseContents, ["ai.opencoven.seer"])

        XCTAssertFalse(
            resolved.path.lowercased().contains("glaze"),
            "the standalone history path must never resolve into a Glaze path"
        )

        // A scratch base directory must never coincide with, or resolve
        // into, the real (user-domain) Application Support directory.
        if let realApplicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            XCTAssertFalse(
                resolved.standardizedFileURL.path.hasPrefix(realApplicationSupport.standardizedFileURL.path),
                "an injected scratch base directory must never resolve into the real Application Support directory"
            )
        }
    }

    // MARK: 16. Genuine concurrent access — overlapping flush()/clear() Tasks
    // serialize via the actor's own AsyncGate and leave a consistent final
    // in-memory/persisted state.

    /// Unlike `testOlderDelayedSaveCannotReplaceNewer{Clear,Flush}Snapshot`
    /// above (which exercise `scheduleGeneration` staleness guarding via a
    /// manually-driven, single-threaded scheduler double), this test
    /// exercises `HistoryStore`'s `gate` itself with two genuinely
    /// overlapping caller `Task`s and a real filesystem-I/O suspension
    /// point. `flush(at:)` is forced to suspend mid-write (holding the
    /// gate); `clear()` is then launched concurrently while that write is
    /// still in flight, so it must queue behind the gate rather than
    /// interleave its `data = .defaultValue` reset into the middle of
    /// `flush(at:)`'s still-running operation. Without the gate, that
    /// reentrant reset could land while `flush(at:)`'s write is suspended,
    /// so that when `flush(at:)` resumes and builds its own returned
    /// stats, it would read the already-reset (stale/empty) document
    /// instead of the very session it just closed — and/or its
    /// already-captured stale write could still land on disk after
    /// `clear()`'s reset, clobbering it. Every synchronization point below
    /// is an explicit continuation/signal (`waitUntilEntered`/
    /// `resumeSuspension`) — never a wall-clock sleep — so the test is
    /// fully deterministic.
    func testOverlappingFlushAndClearTasksSerializeAndPersistConsistentFinalState() async throws {
        let fileSystem = InMemorySettingsFileSystem()
        let store = makeStore(fileSystem: fileSystem)
        _ = await store.load()

        await store.record(activeState(at: 1_000))
        clock.now = 3_000
        await store.record(activeState(at: 3_000)) // accumulates a 2_000ms open session

        // Force flush()'s underlying persist to genuinely suspend mid-write.
        await fileSystem.armSuspension("writeFileAndSynchronize")

        let flushTask = Task { try await store.flush(at: 4_000) }
        await fileSystem.waitUntilEntered("writeFileAndSynchronize")

        // clear() is launched *while* flush() is suspended inside its own
        // write, still holding `gate`. If `gate` did not serialize whole
        // operations, clear()'s field-level reset could run to completion
        // on the actor during this exact suspension window.
        let clearTask = Task { await store.clear() }

        // Give the scheduler ample opportunity to run clear() if the gate
        // were (incorrectly) not serializing: it must still not have
        // reached the filesystem while flush() holds the gate.
        for _ in 0..<50 {
            await Task.yield()
        }
        let logWhileFlushBlocked = await fileSystem.callLog
        XCTAssertEqual(
            logWhileFlushBlocked.filter { $0.hasPrefix("writeFileAndSynchronize") }.count, 1,
            "a concurrently-launched clear() must not reach the filesystem while flush() still holds the gate"
        )

        await fileSystem.resumeSuspension("writeFileAndSynchronize")

        let flushStats = try await flushTask.value
        let clearStats = await clearTask.value

        // flush() must observe its own, uncorrupted result: the session it
        // itself closed, never a stale/reset view produced by a reentrant
        // clear().
        XCTAssertNil(flushStats.currentSession)
        XCTAssertEqual(flushStats.sessionCount, 1)
        XCTAssertEqual(flushStats.recentSessions.count, 1)
        XCTAssertEqual(flushStats.recentSessions.first?.durationMs, 2_000)
        XCTAssertEqual(flushStats.recentSessions.first?.endedAt, 4_000)
        XCTAssertEqual(flushStats.totalAwakeMs, 2_000)
        XCTAssertEqual(flushStats.perAgent.first?.durationMs, 2_000)

        // clear() must only ever observe/reset state *after* flush() has
        // fully finished — never a half-applied mix of the two operations.
        XCTAssertEqual(
            clearStats,
            HistoryStats(
                totalAwakeMs: 0,
                todayAwakeMs: 0,
                sessionCount: 0,
                perAgent: [],
                currentSession: nil,
                recentSessions: []
            )
        )

        // The gate serializes the two full operations FIFO, so clear()
        // (the second caller to actually acquire the gate) is also the
        // final writer: the persisted file must end up exactly at the
        // reset default — never the closed-session document flush()
        // wrote, and never some corrupted hybrid of the two.
        let finalBytes = await fileSystem.contents(at: historyURL)
        XCTAssertNotNil(finalBytes)
        let finalDecoded = try JSONDecoder().decode(HistoryDocument.self, from: finalBytes!)
        XCTAssertEqual(finalDecoded, HistoryDocument.defaultValue)

        // In-memory final state matches the persisted final state exactly —
        // no divergence between what `stats()` reports and what is on disk.
        let finalStats = await store.stats()
        XCTAssertEqual(finalStats, clearStats)

        // Exactly two writes happened — flush()'s and clear()'s — never an
        // extra write caused by a corrupted/duplicated persist under
        // reentrancy.
        let finalLog = await fileSystem.callLog
        XCTAssertEqual(finalLog.filter { $0.hasPrefix("writeFileAndSynchronize") }.count, 2)
    }
}
