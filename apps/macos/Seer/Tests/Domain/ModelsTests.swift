import XCTest
@testable import Seer

/// A deterministic `Clock` for tests only — production code uses
/// `SystemClock`. Kept alongside the domain tests since no other test target
/// currently needs it; promote it to a shared test-support module if that
/// changes.
struct FixedClock: Clock {
    let fixedMilliseconds: Int64

    func nowMilliseconds() -> Int64 {
        fixedMilliseconds
    }
}

final class ModelsTests: XCTestCase {
    // MARK: - Fixtures

    private func makeFullSnapshot() -> AppSnapshot {
        AppSnapshot(
            monitor: AgentMonitorState(
                active: true,
                keepingAwake: true,
                keepAwakeMode: .display,
                agents: [
                    ActiveAgent(
                        id: "agent-1",
                        name: "Claude",
                        detail: "running tests",
                        source: .both,
                        pid: 4242,
                        cpuPercent: 12.5,
                        lastActivityAt: 1_700_000_000_123
                    ),
                    ActiveAgent(
                        id: "agent-2",
                        name: "Codex",
                        detail: "idle",
                        source: .process,
                        pid: nil,
                        cpuPercent: nil,
                        lastActivityAt: 1_700_000_001_000
                    ),
                ],
                lastScanAt: 1_700_000_002_000
            ),
            history: HistoryStats(
                totalAwakeMs: 3_600_000,
                todayAwakeMs: 1_200_000,
                sessionCount: 2,
                perAgent: [
                    AgentUsage(id: "agent-1", name: "Claude", durationMs: 900_000)
                ],
                currentSession: AwakeSession(
                    id: "session-1",
                    startedAt: 1_699_999_000_000,
                    endedAt: nil,
                    durationMs: 500_000,
                    mode: .system,
                    agents: [
                        AgentUsage(id: "agent-1", name: "Claude", durationMs: 500_000)
                    ]
                ),
                recentSessions: [
                    AwakeSession(
                        id: "session-0",
                        startedAt: 1_699_990_000_000,
                        endedAt: 1_699_991_000_000,
                        durationMs: 1_000_000,
                        mode: .display,
                        agents: []
                    )
                ]
            ),
            update: UpdateState(
                checking: true,
                availableVersion: "1.2.3",
                releaseURL: "https://example.com/release",
                lastCheckedAt: 1_700_000_003_000
            ),
            diagnostics: [
                Diagnostic(id: "diag-1", message: "boom", occurredAt: 1_700_000_004_000)
            ],
            appVersion: "1.0.0"
        )
    }

    /// Literal JSON shaped exactly like the TS `AppSnapshot` wire contract
    /// (`renderer/bridge/types.ts`), including optional fields present
    /// (`pid`, `cpuPercent`, `endedAt` non-null) and nullable fields present
    /// as JSON `null` (`endedAt`, `currentSession` absent-vs-null cases are
    /// both exercised across the two sessions below).
    private let literalFixtureJSON = """
    {
      "monitor": {
        "active": true,
        "keepingAwake": true,
        "keepAwakeMode": "display",
        "agents": [
          {
            "id": "agent-1",
            "name": "Claude",
            "detail": "running tests",
            "source": "both",
            "pid": 4242,
            "cpuPercent": 12.5,
            "lastActivityAt": 1700000000123
          },
          {
            "id": "agent-2",
            "name": "Codex",
            "detail": "idle",
            "source": "process",
            "lastActivityAt": 1700000001000
          }
        ],
        "lastScanAt": 1700000002000
      },
      "history": {
        "totalAwakeMs": 3600000,
        "todayAwakeMs": 1200000,
        "sessionCount": 2,
        "perAgent": [
          { "id": "agent-1", "name": "Claude", "durationMs": 900000 }
        ],
        "currentSession": {
          "id": "session-1",
          "startedAt": 1699999000000,
          "endedAt": null,
          "durationMs": 500000,
          "mode": "system",
          "agents": [
            { "id": "agent-1", "name": "Claude", "durationMs": 500000 }
          ]
        },
        "recentSessions": [
          {
            "id": "session-0",
            "startedAt": 1699990000000,
            "endedAt": 1699991000000,
            "durationMs": 1000000,
            "mode": "display",
            "agents": []
          }
        ]
      },
      "update": {
        "checking": true,
        "availableVersion": "1.2.3",
        "releaseURL": "https://example.com/release",
        "lastCheckedAt": 1700000003000
      },
      "diagnostics": [
        { "id": "diag-1", "message": "boom", "occurredAt": 1700000004000 }
      ],
      "appVersion": "1.0.0"
    }
    """

    // MARK: - Encoding

    func testEncodingProducesLowercaseEnumsAndIntegerMillisecondTimestamps() throws {
        let snapshot = makeFullSnapshot()
        let data = try JSONEncoder.seer.encode(snapshot)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let monitor = try XCTUnwrap(json?["monitor"] as? [String: Any])

        // Enums encode as their raw lowercase string, matching the TS
        // string-literal unions exactly (not e.g. "Display" or an index).
        XCTAssertEqual(monitor["keepAwakeMode"] as? String, "display")

        let agents = try XCTUnwrap(monitor["agents"] as? [[String: Any]])
        XCTAssertEqual(agents[0]["source"] as? String, "both")
        XCTAssertEqual(agents[1]["source"] as? String, "process")

        // Timestamps encode as plain integer numbers (milliseconds since
        // epoch), never as ISO-8601 strings or floating-point seconds.
        XCTAssertEqual(monitor["lastScanAt"] as? Int64, 1_700_000_002_000)
        XCTAssertEqual(agents[0]["lastActivityAt"] as? Int64, 1_700_000_000_123)

        let update = try XCTUnwrap(json?["update"] as? [String: Any])
        XCTAssertEqual(update["lastCheckedAt"] as? Int64, 1_700_000_003_000)
    }

    // MARK: - Decoding + round-trip

    func testDecodingLiteralFixtureMatchesConstructedSnapshot() throws {
        let data = Data(literalFixtureJSON.utf8)
        let decoded = try JSONDecoder.seer.decode(AppSnapshot.self, from: data)
        XCTAssertEqual(decoded, makeFullSnapshot())
    }

    func testEncodeDecodeRoundTripPreservesEquality() throws {
        let original = makeFullSnapshot()
        let data = try JSONEncoder.seer.encode(original)
        let roundTripped = try JSONDecoder.seer.decode(AppSnapshot.self, from: data)
        XCTAssertEqual(roundTripped, original)
    }

    // MARK: - Empty factory

    func testEmptyFactoryMatchesTSEmptyDefaults() {
        let empty = AppSnapshot.empty(version: "9.9.9")

        // Matches EMPTY_STATE in renderer/lib/agents.ts.
        XCTAssertEqual(empty.monitor.active, false)
        XCTAssertEqual(empty.monitor.keepingAwake, false)
        XCTAssertEqual(empty.monitor.keepAwakeMode, .system)
        XCTAssertEqual(empty.monitor.agents, [])
        XCTAssertEqual(empty.monitor.lastScanAt, 0)

        // Matches EMPTY_STATS in renderer/lib/history.ts.
        XCTAssertEqual(empty.history.totalAwakeMs, 0)
        XCTAssertEqual(empty.history.todayAwakeMs, 0)
        XCTAssertEqual(empty.history.sessionCount, 0)
        XCTAssertEqual(empty.history.perAgent, [])
        XCTAssertNil(empty.history.currentSession)
        XCTAssertEqual(empty.history.recentSessions, [])

        // Matches the bootstrap `update` shape in glaze-renderer-bridge.ts.
        XCTAssertEqual(empty.update.checking, false)
        XCTAssertNil(empty.update.availableVersion)
        XCTAssertNil(empty.update.releaseURL)
        XCTAssertNil(empty.update.lastCheckedAt)

        XCTAssertEqual(empty.diagnostics, [])
        XCTAssertEqual(empty.appVersion, "9.9.9")
    }

    // MARK: - Clock

    func testFixedClockReturnsConfiguredMilliseconds() {
        let clock = FixedClock(fixedMilliseconds: 1_700_000_000_000)
        XCTAssertEqual(clock.nowMilliseconds(), 1_700_000_000_000)
    }
}
