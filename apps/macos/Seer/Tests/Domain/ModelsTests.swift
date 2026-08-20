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

    // MARK: - Required nullable wire fields

    /// The TS wire contract requires these fields to always be present as a
    /// key, with an explicit JSON `null` standing in for "no value" — never
    /// an omitted key. Swift's synthesized `Optional` `Codable` conformance
    /// does not enforce this (it happily omits `nil` on encode and accepts
    /// a missing key on decode), so these types must implement explicit
    /// `CodingKeys` + `init(from:)`/`encode(to:)`.
    func testEmptySnapshotJSONContainsAllRequiredNullableKeysAsExplicitNull() throws {
        let empty = AppSnapshot.empty(version: "9.9.9")
        let data = try JSONEncoder.seer.encode(empty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let history = try XCTUnwrap(json["history"] as? [String: Any])
        XCTAssertTrue(history.keys.contains("currentSession"))
        XCTAssertTrue(history["currentSession"] is NSNull)

        let update = try XCTUnwrap(json["update"] as? [String: Any])
        XCTAssertTrue(update.keys.contains("availableVersion"))
        XCTAssertTrue(update["availableVersion"] is NSNull)
        XCTAssertTrue(update.keys.contains("releaseURL"))
        XCTAssertTrue(update["releaseURL"] is NSNull)
        XCTAssertTrue(update.keys.contains("lastCheckedAt"))
        XCTAssertTrue(update["lastCheckedAt"] is NSNull)
    }

    func testAwakeSessionEndedAtEncodesExplicitNullWhenNil() throws {
        let session = AwakeSession(
            id: "session-nil",
            startedAt: 1,
            endedAt: nil,
            durationMs: 1,
            mode: .system,
            agents: []
        )
        let data = try JSONEncoder.seer.encode(session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json.keys.contains("endedAt"))
        XCTAssertTrue(json["endedAt"] is NSNull)
    }

    func testLiteralNullRoundTripsForAllRequiredNullableFields() throws {
        let json = """
        {
          "monitor": {
            "active": false,
            "keepingAwake": false,
            "keepAwakeMode": "system",
            "agents": [],
            "lastScanAt": 0
          },
          "history": {
            "totalAwakeMs": 0,
            "todayAwakeMs": 0,
            "sessionCount": 0,
            "perAgent": [],
            "currentSession": null,
            "recentSessions": [
              {
                "id": "session-null-ended",
                "startedAt": 1,
                "endedAt": null,
                "durationMs": 1,
                "mode": "system",
                "agents": []
              }
            ]
          },
          "update": {
            "checking": false,
            "availableVersion": null,
            "releaseURL": null,
            "lastCheckedAt": null
          },
          "diagnostics": [],
          "appVersion": "0.0.0"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder.seer.decode(AppSnapshot.self, from: data)
        XCTAssertNil(decoded.history.currentSession)
        XCTAssertNil(decoded.history.recentSessions[0].endedAt)
        XCTAssertNil(decoded.update.availableVersion)
        XCTAssertNil(decoded.update.releaseURL)
        XCTAssertNil(decoded.update.lastCheckedAt)

        // Round-trip: re-encoding must still emit explicit nulls, not omit
        // the keys.
        let reEncoded = try JSONEncoder.seer.encode(decoded)
        let reJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: reEncoded) as? [String: Any])
        let history = try XCTUnwrap(reJSON["history"] as? [String: Any])
        XCTAssertTrue(history["currentSession"] is NSNull)
        let update = try XCTUnwrap(reJSON["update"] as? [String: Any])
        XCTAssertTrue(update["availableVersion"] is NSNull)
        XCTAssertTrue(update["releaseURL"] is NSNull)
        XCTAssertTrue(update["lastCheckedAt"] is NSNull)
    }

    private func awakeSessionJSONObject(omitting key: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "id": "session-1",
            "startedAt": 1,
            "endedAt": NSNull(),
            "durationMs": 1,
            "mode": "system",
            "agents": [[String: Any]](),
        ]
        if let key {
            object.removeValue(forKey: key)
        }
        return object
    }

    private func updateStateJSONObject(omitting key: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "checking": false,
            "availableVersion": NSNull(),
            "releaseURL": NSNull(),
            "lastCheckedAt": NSNull(),
        ]
        if let key {
            object.removeValue(forKey: key)
        }
        return object
    }

    func testDecodingAwakeSessionFailsWhenEndedAtKeyIsMissing() throws {
        let object = awakeSessionJSONObject(omitting: "endedAt")
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder.seer.decode(AwakeSession.self, from: data)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected DecodingError.keyNotFound, got \(error)")
            }
        }
    }

    func testDecodingHistoryStatsFailsWhenCurrentSessionKeyIsMissing() throws {
        let object: [String: Any] = [
            "totalAwakeMs": 0,
            "todayAwakeMs": 0,
            "sessionCount": 0,
            "perAgent": [[String: Any]](),
            "recentSessions": [[String: Any]](),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder.seer.decode(HistoryStats.self, from: data)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected DecodingError.keyNotFound, got \(error)")
            }
        }
    }

    func testDecodingUpdateStateFailsWhenAvailableVersionKeyIsMissing() throws {
        let object = updateStateJSONObject(omitting: "availableVersion")
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder.seer.decode(UpdateState.self, from: data)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected DecodingError.keyNotFound, got \(error)")
            }
        }
    }

    func testDecodingUpdateStateFailsWhenReleaseURLKeyIsMissing() throws {
        let object = updateStateJSONObject(omitting: "releaseURL")
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder.seer.decode(UpdateState.self, from: data)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected DecodingError.keyNotFound, got \(error)")
            }
        }
    }

    func testDecodingUpdateStateFailsWhenLastCheckedAtKeyIsMissing() throws {
        let object = updateStateJSONObject(omitting: "lastCheckedAt")
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder.seer.decode(UpdateState.self, from: data)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected DecodingError.keyNotFound, got \(error)")
            }
        }
    }

    // MARK: - Genuinely optional ActiveAgent fields remain absent-tolerant

    func testActiveAgentPidAndCpuPercentMayBeAbsent() throws {
        let object: [String: Any] = [
            "id": "agent-2",
            "name": "Codex",
            "detail": "idle",
            "source": "process",
            "lastActivityAt": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder.seer.decode(ActiveAgent.self, from: data)
        XCTAssertNil(decoded.pid)
        XCTAssertNil(decoded.cpuPercent)
    }
}
