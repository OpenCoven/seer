import XCTest
@testable import Seer

/// Table-driven parity tests: every case in the shared fixture oracle
/// (`tests/fixtures/agent-detection/expected.json`) is asserted against the
/// Swift turn assessors. TypeScript's `tests/agent-detection-parity.test.mjs`
/// asserts the exact same oracle through
/// `assessDetectionFixture` in `main/services/agent-detection-policy.ts` —
/// this file locates the oracle from `#filePath` rather than copying or
/// restating any expected value, so both languages are proven to agree on
/// the exact same corpus.
final class TurnAssessorsTests: XCTestCase {
    // MARK: - Shared fixture oracle

    private struct FixtureOracle: Decodable {
        let now: String
        let cases: [FixtureCase]
    }

    private struct FixtureCase: Decodable {
        let id: String
        let family: String
        let kind: String
        let format: String?
        let fixtureFile: String
        let identity: String?
        let mtimeMs: String?
        let selector: String?
        let expected: FixtureExpected
    }

    private struct FixtureExpected: Decodable, Equatable {
        let active: Bool
        let source: AgentActivitySource
        let detail: String
        let id: String
    }

    private enum FixtureAssessorError: Error {
        case invalidFixture(String)
        case missingSelector(String)
    }

    /// Walks up from this test file to the repository root and back down to
    /// the shared fixture directory — never a copy of fixture content.
    private func fixturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/Detection
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Seer (apps/macos/Seer project root)
            .deletingLastPathComponent() // apps/macos
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("tests/fixtures/agent-detection", isDirectory: true)
    }

    private func loadOracle() throws -> FixtureOracle {
        let url = fixturesDirectory().appendingPathComponent("expected.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureOracle.self, from: data)
    }

    private func readJSONValue(_ fixtureFile: String) throws -> Any {
        let url = fixturesDirectory().appendingPathComponent(fixtureFile)
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Parses line-delimited JSON tolerating corrupt/partial lines — the same
    /// leniency the production session-tail reader applies.
    private func readJSONLEvents(_ fixtureFile: String) throws -> [JSONObject] {
        let url = fixturesDirectory().appendingPathComponent(fixtureFile)
        let text = try String(contentsOf: url, encoding: .utf8)
        var events: [JSONObject] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? JSONObject else {
                continue
            }
            events.append(object)
        }
        return events
    }

    /// Assesses a single synthetic fixture case using the exact same pure
    /// turn assessors ported to `TurnAssessors.swift`, mirroring
    /// `assessDetectionFixture` in `main/services/agent-detection-policy.ts`.
    private func assessSharedFixture(_ testCase: FixtureCase, now: Int64) throws -> FixtureExpected {
        if testCase.kind == "process" {
            guard let rows = try readJSONValue(testCase.fixtureFile) as? [JSONObject] else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            guard let row = rows.first(where: { ($0["key"] as? String) == testCase.selector }) else {
                throw FixtureAssessorError.missingSelector(testCase.selector ?? "")
            }
            guard
                let family = row["family"] as? String,
                let pidNumber = row["pid"] as? NSNumber,
                let cpuPercent = finiteNumber(row["cpuPercent"])
            else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            let active = cpuPercent >= processOnlyCPUThreshold
            return FixtureExpected(
                active: active,
                source: .process,
                detail: buildFriendlyDetail(projectLabel: nil, processOnly: true),
                id: "\(family):pid:\(pidNumber.intValue)"
            )
        }

        if testCase.format == "cursor" {
            guard
                let data = try readJSONValue(testCase.fixtureFile) as? JSONObject,
                let composerKey = data["composerKey"] as? String,
                let record = asRecord(data["record"])
            else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            let assessment = assessCursorComposerRecord(record, now: now)
            return FixtureExpected(
                active: assessment.active,
                source: .session,
                detail: buildFriendlyDetail(projectLabel: assessment.label, reason: assessment.reason),
                id: "\(testCase.family):\(composerKey)"
            )
        }

        if testCase.format == "generic-mtime" {
            guard let data = try readJSONValue(testCase.fixtureFile) as? JSONObject else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            let selectorKey = testCase.selector ?? "recent"
            guard
                let entry = asRecord(data[selectorKey]),
                let identity = entry["identity"] as? String,
                let mtimeText = entry["mtimeMs"] as? String,
                let mtimeMs = parseISO8601ToMs(mtimeText)
            else {
                throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
            }
            let assessment = assessGenericMtime(mtimeMs: mtimeMs, now: now)
            let label = friendlySessionLabel(identity)
            return FixtureExpected(
                active: assessment.active,
                source: .session,
                detail: buildFriendlyDetail(projectLabel: label, reason: assessment.reason),
                id: "\(testCase.family):\(identity)"
            )
        }

        // claude / codex / grok session transcripts.
        let events = try readJSONLEvents(testCase.fixtureFile)
        let mtimeMs = testCase.mtimeMs.flatMap(parseISO8601ToMs) ?? 0
        let identity = testCase.identity ?? ""

        let assessment: TurnAssessment
        switch testCase.format {
        case "claude":
            assessment = assessClaudeTurn(events, mtimeMs: mtimeMs, now: now)
        case "codex":
            assessment = assessCodexTurn(events, mtimeMs: mtimeMs, now: now)
        case "grok":
            assessment = assessGrokTurn(events, mtimeMs: mtimeMs, now: now)
        default:
            throw FixtureAssessorError.invalidFixture(testCase.fixtureFile)
        }

        let label = assessment.label ?? friendlySessionLabel(identity)
        return FixtureExpected(
            active: assessment.active,
            source: .session,
            detail: buildFriendlyDetail(projectLabel: label, reason: assessment.reason),
            id: "\(testCase.family):\(identity)"
        )
    }

    // MARK: - Oracle-driven tests

    func testFixtureAssessments() throws {
        let oracle = try loadOracle()
        guard let fixedNow = parseISO8601ToMs(oracle.now) else {
            XCTFail("expected.json 'now' did not parse as ISO 8601")
            return
        }

        let coveredFamilies = Set(oracle.cases.map(\.family))
        let approvedFamilies = Set(AgentFamily.allCases.map(\.rawValue))
        XCTAssertEqual(
            coveredFamilies,
            approvedFamilies,
            "expected.json must cover exactly the ten approved families"
        )

        XCTAssertTrue(
            oracle.cases.contains { $0.family == "aider" && $0.kind == "process" && $0.expected.source == .process },
            "expected.json must prove Aider process-only detection"
        )
        XCTAssertTrue(
            oracle.cases.contains { $0.family == "amp" && $0.kind == "process" && $0.expected.source == .process },
            "expected.json must prove Amp process-only detection"
        )
        XCTAssertTrue(
            oracle.cases.contains { $0.family == "cursor" && $0.kind == "process" && $0.expected.source == .process },
            "expected.json must prove Cursor CLI process-only detection"
        )

        for testCase in oracle.cases {
            let result = try assessSharedFixture(testCase, now: fixedNow)
            XCTAssertEqual(result, testCase.expected, testCase.id)
        }
    }

    // MARK: - Direct unit cases beyond the oracle

    func testHumanizeProjectNameStripsLocalAndHexSuffixes() {
        // "my" is a 2-character word that is already lowercase, so it is left
        // untouched (only words longer than 2 characters are capitalized) —
        // this is a faithful, deliberate port of the TS `titleCaseWords` rule.
        XCTAssertEqual(humanizeProjectName("my-project-local-1pwq7g9n"), "my Project")
        XCTAssertEqual(humanizeProjectName("my-project-a1b2c3"), "my Project")
        XCTAssertEqual(humanizeProjectName("seer-project.name"), "Seer Project Name")
        XCTAssertEqual(humanizeProjectName(""), "")
    }

    func testFriendlyActivityMapsReasonsToLabels() {
        XCTAssertEqual(friendlyActivity(nil, processOnly: true), "Busy")
        XCTAssertEqual(friendlyActivity("tool_use in progress", processOnly: false), "Running tools")
        XCTAssertEqual(friendlyActivity("awaiting model after tool", processOnly: false), "Thinking")
        XCTAssertEqual(friendlyActivity("agent_reasoning", processOnly: false), "Thinking")
        XCTAssertEqual(friendlyActivity("agent_message", processOnly: false), "Writing")
        XCTAssertEqual(friendlyActivity("user prompt", processOnly: false), "Started")
        XCTAssertEqual(friendlyActivity("generating bubbles", processOnly: false), "Writing")
        XCTAssertEqual(friendlyActivity("recent session write", processOnly: false), "Active")
        XCTAssertEqual(friendlyActivity("stale session write", processOnly: false), "Wrapping up")
        XCTAssertEqual(friendlyActivity("end_turn", processOnly: false), "Working")
        XCTAssertEqual(friendlyActivity(nil, processOnly: false), "Working")
    }

    func testParseTimestampHandlesSecondsMillisecondsAndFallback() {
        // Seconds-based epoch (below the 1e12 cutoff) is scaled to ms.
        XCTAssertEqual(parseTimestamp(1_700_000_000, fallbackMs: -1), 1_700_000_000_000)
        // Already-ms epoch (above the cutoff) passes through unchanged.
        XCTAssertEqual(parseTimestamp(1_700_000_000_000, fallbackMs: -1), 1_700_000_000_000)
        // ISO 8601 strings parse to the same Unix ms Date.parse would produce.
        XCTAssertEqual(parseTimestamp("2026-08-10T12:00:00.000Z", fallbackMs: -1), 1_786_363_200_000)
        // A JSON boolean must not be treated as a numeric timestamp.
        XCTAssertEqual(parseTimestamp(true, fallbackMs: 42), 42)
        // Unparseable strings and missing values fall back.
        XCTAssertEqual(parseTimestamp("not-a-date", fallbackMs: 7), 7)
        XCTAssertEqual(parseTimestamp(nil, fallbackMs: 7), 7)
    }

    func testGrokProjectLabelDecodesPercentEncodedCwd() {
        let path = "/home/user/.grok/sessions/%2Fhome%2Fuser%2Fmy-app/session-1/events.jsonl"
        // "my" is a 2-character lowercase word left untouched by titleCaseWords.
        XCTAssertEqual(grokProjectLabel(path), "my App")
        XCTAssertEqual(grokProjectLabel("events.jsonl"), "")
    }

    func testAssessGenericMtimeIsExactlyAtTheTwentySecondBoundary() {
        let now: Int64 = 1_786_449_620_000
        let atBoundary = assessGenericMtime(mtimeMs: now - genericMtimeWindowMs, now: now)
        XCTAssertTrue(atBoundary.active, "age == 20s must still be active (inclusive boundary)")

        let pastBoundary = assessGenericMtime(mtimeMs: now - genericMtimeWindowMs - 1, now: now)
        XCTAssertFalse(pastBoundary.active, "age == 20s + 1ms must be stale")
    }

    func testAssessCodexTurnDistinguishesApprovalFromCompletion() {
        let cwdPayload: JSONObject = ["cwd": "/tmp/seer-fixtures/codex-boundary-project"]
        let started: JSONObject = [
            "timestamp": "2026-08-10T12:00:00.000Z",
            "type": "event_msg",
            "payload": ["type": "task_started"].merging(cwdPayload) { _, new in new },
        ]
        let approval: JSONObject = [
            "timestamp": "2026-08-10T12:00:05.000Z",
            "type": "event_msg",
            "payload": ["type": "exec_approval_request"],
        ]
        let now = parseISO8601ToMs("2026-08-10T12:00:06.000Z")!

        let assessment = assessCodexTurn([started, approval], mtimeMs: now, now: now)
        XCTAssertFalse(assessment.active)
        XCTAssertEqual(assessment.reason, "waiting for approval")
        XCTAssertEqual(assessment.label, "Codex Boundary Project")
    }
}
