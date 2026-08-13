import XCTest
@testable import Seer

/// Exercises `AgentDetector`'s process/session merge, strict process-only
/// fallback boundaries, deterministic ordering, and failure propagation —
/// entirely against synthetic `ProcessSnapshotProviding`/
/// `SessionSnapshotProviding` doubles. This suite must never touch a real
/// process table or a real home directory.
final class AgentDetectorTests: XCTestCase {
    private struct TestError: Error, Equatable, Sendable {}

    private struct StubProcesses: ProcessSnapshotProviding {
        let snapshots: [ProcessSnapshot]
        let error: TestError?

        init(_ snapshots: [ProcessSnapshot] = [], error: TestError? = nil) {
            self.snapshots = snapshots
            self.error = error
        }

        func snapshot() async throws -> [ProcessSnapshot] {
            if let error { throw error }
            return snapshots
        }
    }

    private struct StubSessions: SessionSnapshotProviding {
        let evidence: [SessionTurnEvidence]
        let error: TestError?

        init(_ evidence: [SessionTurnEvidence] = [], error: TestError? = nil) {
            self.evidence = evidence
            self.error = error
        }

        func snapshot(now: Int64) async throws -> [SessionTurnEvidence] {
            if let error { throw error }
            return evidence
        }
    }

    private let fixedNow: Int64 = 1_700_000_000_000

    private func turn(
        family: AgentFamily,
        identity: String,
        label: String? = "Fixtures",
        reason: String = "tool_use in progress",
        lastActivityAt: Int64? = nil
    ) -> SessionTurnEvidence {
        SessionTurnEvidence(
            family: family,
            identity: identity,
            label: label,
            reason: reason,
            lastActivityAt: lastActivityAt ?? fixedNow
        )
    }

    private func activeCodexTurn(identity: String, lastActivityAt: Int64? = nil) -> SessionTurnEvidence {
        turn(family: .codex, identity: identity, lastActivityAt: lastActivityAt)
    }

    // MARK: - Merge: process + session -> .both

    func testSessionAndProcessEvidenceMergeToBoth() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 42, command: "codex", cpuPercent: 2)]),
            sessions: StubSessions([activeCodexTurn(identity: "/fixtures/codex-active.jsonl")])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertEqual(agents.count, 1)
        let agent = try XCTUnwrap(agents.first)
        XCTAssertEqual(agent.source, .both)
        XCTAssertEqual(agent.id, "codex:/fixtures/codex-active.jsonl")
        XCTAssertEqual(agent.pid, 42)
        XCTAssertEqual(agent.cpuPercent, 2)
        XCTAssertEqual(agent.name, "Codex")
        XCTAssertEqual(agent.lastActivityAt, fixedNow)
    }

    // MARK: - Session-only -> .session, no process metadata

    func testSessionOnlyEvidenceReportsSessionSourceWithNoProcessMetadata() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([]),
            sessions: StubSessions([activeCodexTurn(identity: "/fixtures/codex-active.jsonl")])
        )
        let agents = try await detector.detect(now: fixedNow)
        let agent = try XCTUnwrap(agents.first)
        XCTAssertEqual(agent.source, .session)
        XCTAssertNil(agent.pid)
        XCTAssertNil(agent.cpuPercent)
    }

    /// A process from an *unrelated* family must never bleed process
    /// metadata into a different family's session-only evidence.
    func testUnrelatedFamilyProcessDoesNotLeakIntoSessionOnlyAgent() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 99, command: "aider", cpuPercent: 40)]),
            sessions: StubSessions([activeCodexTurn(identity: "/fixtures/codex-active.jsonl")])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertEqual(agents.count, 2, "the aider process-only fallback and the codex session turn are independent agents")
        let codexAgent = try XCTUnwrap(agents.first { $0.id.hasPrefix("codex:") })
        XCTAssertEqual(codexAgent.source, .session)
        XCTAssertNil(codexAgent.pid)
    }

    // MARK: - Multiple turns: ordering, stable IDs, deterministic ties

    func testMultipleActiveTurnsOrderedByDescendingActivity() async throws {
        let older = activeCodexTurn(identity: "/fixtures/old.jsonl", lastActivityAt: fixedNow - 10_000)
        let newer = activeCodexTurn(identity: "/fixtures/new.jsonl", lastActivityAt: fixedNow)
        let detector = AgentDetector(processes: StubProcesses([]), sessions: StubSessions([older, newer]))

        let agents = try await detector.detect(now: fixedNow)

        XCTAssertEqual(agents.map(\.id), ["codex:/fixtures/new.jsonl", "codex:/fixtures/old.jsonl"])
    }

    func testTiedActivityTimestampsBreakTiesDeterministicallyByIdentity() async throws {
        let a = activeCodexTurn(identity: "/fixtures/b.jsonl")
        let b = activeCodexTurn(identity: "/fixtures/a.jsonl")
        let detector = AgentDetector(processes: StubProcesses([]), sessions: StubSessions([a, b]))

        // Run repeatedly: a non-deterministic tie break would eventually
        // disagree with itself across runs.
        for _ in 0..<5 {
            let agents = try await detector.detect(now: fixedNow)
            XCTAssertEqual(agents.map(\.id), ["codex:/fixtures/a.jsonl", "codex:/fixtures/b.jsonl"])
        }
    }

    func testCrossFamilyTiesAtSameActivityBreakDeterministicallyByID() async throws {
        let codex = activeCodexTurn(identity: "/fixtures/x.jsonl")
        let claude = turn(family: .claudeCode, identity: "/fixtures/x.jsonl")
        let detector = AgentDetector(processes: StubProcesses([]), sessions: StubSessions([codex, claude]))

        for _ in 0..<5 {
            let agents = try await detector.detect(now: fixedNow)
            // "claude-code:..." sorts before "codex:..." lexicographically.
            XCTAssertEqual(agents.map(\.id), ["claude-code:/fixtures/x.jsonl", "codex:/fixtures/x.jsonl"])
        }
    }

    func testNoDuplicateIDsAcrossMergedFamilies() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([
                .init(pid: 1, command: "aider", cpuPercent: 40),
                .init(pid: 2, command: "amp", cpuPercent: 60),
                .init(pid: 3, command: "cursor-agent", cpuPercent: 30),
            ]),
            sessions: StubSessions([
                activeCodexTurn(identity: "/fixtures/codex.jsonl"),
                turn(family: .claudeCode, identity: "/fixtures/claude.jsonl"),
                turn(family: .grok, identity: "/fixtures/events.jsonl"),
            ])
        )

        let agents = try await detector.detect(now: fixedNow)

        let ids = agents.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "every merged agent id must be unique: \(ids)")
        XCTAssertEqual(ids.count, 6)
    }

    // MARK: - Strict process-only fallback boundaries

    func testAiderProcessOnlyAboveThresholdIsActive() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 10, command: "aider", cpuPercent: 30)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        let agent = try XCTUnwrap(agents.first)
        XCTAssertEqual(agent.source, .process)
        XCTAssertEqual(agent.id, "aider:pid:10")
        XCTAssertEqual(agent.lastActivityAt, fixedNow)
    }

    func testAmpProcessOnlyAboveThresholdIsActive() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 11, command: "amp", cpuPercent: 26)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertEqual(agents.map(\.id), ["amp:pid:11"])
    }

    func testAmpProcessOnlyBelowThresholdIsNotActive() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 11, command: "amp", cpuPercent: 10)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertTrue(agents.isEmpty)
    }

    func testCursorProcessOnlyAtExactThresholdIsActive() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 12, command: "cursor-agent", cpuPercent: 25)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.source, .process)
    }

    func testCursorProcessOnlyJustBelowThresholdIsNotActive() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 12, command: "cursor-agent", cpuPercent: 24.999)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertTrue(agents.isEmpty)
    }

    func testFirstSampleNilCPUNeverTriggersProcessOnlyFallback() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 13, command: "aider", cpuPercent: nil)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertTrue(agents.isEmpty, "a nil cpuPercent (first sample) must never be treated as active")
    }

    func testClaudeNeverProcessOnlyEvenAtHighCPU() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 14, command: "claude", cpuPercent: 90)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertTrue(agents.isEmpty)
    }

    func testCodexNeverProcessOnlyEvenAtHighCPU() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 15, command: "codex", cpuPercent: 90)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertTrue(agents.isEmpty)
    }

    func testGrokNeverProcessOnlyEvenAtHighCPU() async throws {
        let detector = AgentDetector(
            processes: StubProcesses([.init(pid: 16, command: "grok", cpuPercent: 90)]),
            sessions: StubSessions([])
        )
        let agents = try await detector.detect(now: fixedNow)
        XCTAssertTrue(agents.isEmpty)
    }

    /// Generic-mtime families (Gemini, OpenCode, Goose, Continue) have a
    /// session format but no `allowProcessFallback` — bare process CPU must
    /// never activate them.
    func testGenericMtimeFamiliesNeverProcessOnlyEvenAtHighCPU() async throws {
        for command in ["gemini", "opencode", "goose", "continue-cli"] {
            let detector = AgentDetector(
                processes: StubProcesses([.init(pid: 20, command: command, cpuPercent: 95)]),
                sessions: StubSessions([])
            )
            let agents = try await detector.detect(now: fixedNow)
            XCTAssertTrue(agents.isEmpty, "\(command) must never activate from process CPU alone")
        }
    }

    // MARK: - Grouping across all ten families

    func testAllTenFamiliesGroupIndependentlyWithoutCrossContamination() async throws {
        let sessionEvidence: [SessionTurnEvidence] = [
            turn(family: .claudeCode, identity: "/fixtures/claude.jsonl"),
            activeCodexTurn(identity: "/fixtures/codex.jsonl"),
            turn(family: .grok, identity: "/fixtures/events.jsonl"),
            turn(family: .gemini, identity: "/fixtures/gemini.json"),
            turn(family: .opencode, identity: "/fixtures/opencode.json"),
            turn(family: .goose, identity: "/fixtures/goose.json"),
            turn(family: .continueAgent, identity: "/fixtures/continue.json"),
            turn(family: .cursor, identity: "composer-123"),
        ]
        let processEvidence: [ProcessSnapshot] = [
            .init(pid: 1, command: "aider", cpuPercent: 40),
            .init(pid: 2, command: "amp", cpuPercent: 60),
        ]
        let detector = AgentDetector(processes: StubProcesses(processEvidence), sessions: StubSessions(sessionEvidence))

        let agents = try await detector.detect(now: fixedNow)

        let familiesSeen = Set(AGENT_KINDS.map(\.id).filter { family in
            agents.contains { $0.id.hasPrefix("\(family.rawValue):") }
        })
        XCTAssertEqual(familiesSeen.count, 10, "expected exactly the ten approved families, saw: \(familiesSeen)")
        XCTAssertEqual(agents.count, 10)
        let ids = agents.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - Failure propagation

    func testProcessSourceFailurePropagates() async throws {
        let detector = AgentDetector(processes: StubProcesses(error: TestError()), sessions: StubSessions([]))
        do {
            _ = try await detector.detect(now: fixedNow)
            XCTFail("expected process source failure to propagate")
        } catch is TestError {
            // expected
        }
    }

    func testSessionSourceFailurePropagates() async throws {
        let detector = AgentDetector(processes: StubProcesses([]), sessions: StubSessions(error: TestError()))
        do {
            _ = try await detector.detect(now: fixedNow)
            XCTFail("expected session source failure to propagate")
        } catch is TestError {
            // expected
        }
    }

    func testBothSourcesFailingPropagatesAFailure() async throws {
        let detector = AgentDetector(processes: StubProcesses(error: TestError()), sessions: StubSessions(error: TestError()))
        do {
            _ = try await detector.detect(now: fixedNow)
            XCTFail("expected a failure to propagate")
        } catch is TestError {
            // expected — either source's failure is an acceptable outcome.
        }
    }
}
