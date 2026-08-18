import XCTest
import SQLite3
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
    private final class LockedCompilationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

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
            var bubbles: [String: JSONObject] = [:]
            if let rawBubbles = asRecord(data["bubbles"]) {
                for (bubbleId, value) in rawBubbles {
                    if let bubble = asRecord(value) {
                        bubbles[bubbleId] = bubble
                    }
                }
            }
            let assessment = assessCursorComposerRecord(record, bubbles: bubbles, now: now)
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

    func testISO8601ParserReusesItsTwoFormatStrategies() {
        let counter = LockedCompilationCounter()
        let parser = ISO8601TimestampParser { includesFractionalSeconds in
            counter.increment()
            return Date.ISO8601FormatStyle(
                includingFractionalSeconds: includesFractionalSeconds
            )
        }

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(parser)
        XCTAssertEqual(counter.value, 2)

        for _ in 0..<100 {
            XCTAssertEqual(parser.parseToMilliseconds("2026-08-10T12:00:00.123Z"), 1_786_363_200_123)
            XCTAssertEqual(parser.parseToMilliseconds("2026-08-10T12:00:00Z"), 1_786_363_200_000)
            XCTAssertEqual(parser.parseToMilliseconds("2026-08-10T14:30:00+02:30"), 1_786_363_200_000)
            XCTAssertNil(parser.parseToMilliseconds("not-a-timestamp"))
        }

        XCTAssertEqual(
            counter.value,
            2,
            "parse calls must reuse the fractional and nonfractional strategies"
        )
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

    func testRecencyHelperEnforcesGraceFutureSkewAndOverflowBoundaries() {
        let now: Int64 = 1_786_449_620_000
        let cases: [(name: String, timestamp: Int64, grace: Int64, expected: Bool)] = [
            ("grace start", now - turnActiveGraceMs, turnActiveGraceMs, true),
            ("past grace", now - turnActiveGraceMs - 1, turnActiveGraceMs, false),
            ("future skew boundary", now + timestampFutureSkewMs, turnActiveGraceMs, true),
            ("past future skew", now + timestampFutureSkewMs + 1, turnActiveGraceMs, false),
            ("extreme future", Int64.max, turnActiveGraceMs, false),
            ("extreme past", Int64.min, turnActiveGraceMs, false),
            ("overflow future", Int64.max, Int64.min, false),
            ("overflow past", Int64.min, Int64.max, false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                isRecentTimestamp(testCase.timestamp, now: now, within: testCase.grace),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testEveryAssessorFamilyRejectsExtremeFutureButAcceptsBoundedClockSkew() {
        let now: Int64 = 1_786_449_620_000
        let assessors: [(String, (Int64) -> TurnAssessment)] = [
            ("claude", { timestamp in
                assessClaudeTurn(
                    [["type": "assistant", "timestamp": timestamp, "message": ["stop_reason": "tool_use"]]],
                    mtimeMs: now,
                    now: now
                )
            }),
            ("codex", { timestamp in
                assessCodexTurn(
                    [["timestamp": timestamp, "type": "event_msg", "payload": ["type": "task_started"]]],
                    mtimeMs: now,
                    now: now
                )
            }),
            ("grok", { timestamp in
                assessGrokTurn([["ts": timestamp, "type": "turn_started"]], mtimeMs: now, now: now)
            }),
            ("generic mtime", { timestamp in
                assessGenericMtime(mtimeMs: timestamp, now: now)
            }),
            ("cursor", { timestamp in
                assessCursorComposerRecord(
                    ["status": "generating", "lastUpdatedAt": timestamp, "fullConversationHeadersOnly": []],
                    now: now
                )
            }),
        ]

        for (name, assess) in assessors {
            XCTAssertTrue(assess(now + timestampFutureSkewMs).active, "\(name) must tolerate the documented skew")
            XCTAssertFalse(assess(Int64.max).active, "\(name) must reject extreme future evidence")
        }
    }

    func testCodexAndGrokQuietTailFallbacksRejectExtremeFutureMtimeButAllowBoundedSkew() {
        let now: Int64 = 1_786_449_620_000
        for (name, assess) in [
            ("codex", { (mtime: Int64) in assessCodexTurn([], mtimeMs: mtime, now: now) }),
            ("grok", { (mtime: Int64) in assessGrokTurn([], mtimeMs: mtime, now: now) }),
        ] {
            XCTAssertTrue(assess(now + timestampFutureSkewMs).active, "\(name) fallback must tolerate bounded skew")
            XCTAssertFalse(assess(Int64.max).active, "\(name) fallback must reject extreme future mtime")
        }
    }

    // MARK: - Timestamp overflow hardening (Finding 1)

    /// A finite JSON number far above `Int64` range (`1e300`) must saturate
    /// to `Int64.max` rather than trapping in `Int64(doubleValue)`. `1e300 >
    /// 1e12`, so this exercises the "already milliseconds" branch directly
    /// (no multiplication involved).
    func testParseTimestampSaturatesAboveInt64RangeInsteadOfTrapping() {
        XCTAssertEqual(parseTimestamp(1e300, fallbackMs: -1), Int64.max)
    }

    /// A finite JSON number far below negative `Int64` range (`-1e300`) must
    /// saturate to `Int64.min`. `-1e300` is not `> 1e12`, so this exercises
    /// the "seconds → ms" branch, i.e. a `Double` multiplication by 1000
    /// (`-1e300 * 1000 == -1e303`) followed by a saturating conversion.
    func testParseTimestampSaturatesBelowInt64RangeInsteadOfTrapping() {
        XCTAssertEqual(parseTimestamp(-1e300, fallbackMs: -1), Int64.min)
    }

    /// Values whose magnitude alone wouldn't overflow `Int64`, but which
    /// cross the boundary only *after* the `* 1000` seconds→ms multiplication,
    /// must also saturate instead of trapping. `-1e16` is well within
    /// `Double`/`Int64` range on its own, but `-1e16 * 1000 == -1e19`, which
    /// exceeds `Int64.min` (~`-9.223e18`).
    func testParseTimestampSaturatesOnMultiplicationBoundaryOverflow() {
        XCTAssertEqual(parseTimestamp(-1e16, fallbackMs: -1), Int64.min)
    }

    /// A value just inside the seconds→ms multiplication range must convert
    /// exactly, proving the saturation logic doesn't clamp values that
    /// legitimately fit — only genuine out-of-range magnitudes.
    func testParseTimestampDoesNotOversaturateInRangeMultiplication() {
        XCTAssertEqual(parseTimestamp(-9.2e12, fallbackMs: -1), Int64(-9.2e12 * 1000))
    }

    /// `finiteNumber`/`parseTimestamp` must reject non-finite `NSNumber`
    /// values (`+inf`, `-inf`, `NaN`) called directly — mirroring TS
    /// `Number.isFinite` — and fall back rather than trapping on the
    /// downstream `Int64` conversion.
    func testParseTimestampFallsBackOnNonfiniteNSNumberCalledDirectly() {
        XCTAssertEqual(parseTimestamp(NSNumber(value: Double.infinity), fallbackMs: 42), 42)
        XCTAssertEqual(parseTimestamp(NSNumber(value: -Double.infinity), fallbackMs: 42), 42)
        XCTAssertEqual(parseTimestamp(NSNumber(value: Double.nan), fallbackMs: 42), 42)
    }

    /// End-to-end: syntactically valid JSON containing `1e300` must parse via
    /// `JSONSerialization`, flow through `assessClaudeTurn` without trapping,
    /// and produce a bounded `lastActivityAt`. A future-huge timestamp must
    /// saturate to `Int64.max` and be rejected as implausibly future-dated.
    func testAssessClaudeTurnSurvivesHugeFutureTimestampJSON() throws {
        let json = #"""
        [{"type":"assistant","timestamp":1e300,"message":{"stop_reason":"tool_use"}}]
        """#
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [JSONObject]
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessClaudeTurn(events, mtimeMs: now, now: now)
        XCTAssertEqual(assessment.lastActivityAt, Int64.max)
        XCTAssertFalse(assessment.active, "a huge future timestamp must be rejected, not active forever")
    }

    /// The past-huge mirror: `-1e300` must saturate to `Int64.min`, and the
    /// resulting astronomically large age must classify as stale rather than
    /// trapping the `now - timestamp` subtraction.
    func testAssessClaudeTurnSurvivesHugeAncientTimestampJSON() throws {
        let json = #"""
        [{"type":"assistant","timestamp":-1e300,"message":{"stop_reason":"tool_use"}}]
        """#
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [JSONObject]
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessClaudeTurn(events, mtimeMs: now, now: now)
        XCTAssertEqual(assessment.lastActivityAt, Int64.min)
        XCTAssertFalse(assessment.active, "a huge ancient timestamp must saturate to stale, not trap")
    }

    func testAssessClaudeTurnTreatsEmptyNestedStopReasonAsAbsent() {
        let now: Int64 = 1_786_449_620_000
        let timestamp = now - 120_000
        let assessment = assessClaudeTurn(
            [[
                "type": "assistant",
                "timestamp": timestamp,
                "message": ["stop_reason": ""],
                "stop_reason": "tool_use",
            ]],
            mtimeMs: now,
            now: now
        )

        XCTAssertTrue(assessment.active, "empty nested stop_reason must fall back to the top-level tool_use grace window")
        XCTAssertEqual(assessment.lastActivityAt, timestamp)
        XCTAssertEqual(assessment.reason, "tool_use in progress")
    }

    func testAssessClaudeTurnPreservesNonEmptyNestedStopReasonPrecedence() {
        let now: Int64 = 1_786_449_620_000
        let timestamp = now - 1_000
        let assessment = assessClaudeTurn(
            [[
                "type": "assistant",
                "timestamp": timestamp,
                "message": ["stop_reason": "end_turn"],
                "stop_reason": "tool_use",
            ]],
            mtimeMs: now,
            now: now
        )

        XCTAssertFalse(assessment.active)
        XCTAssertEqual(assessment.lastActivityAt, timestamp)
        XCTAssertEqual(assessment.reason, "end_turn")
    }

    /// Same JSON-callable trap coverage for the Codex assessor: a huge future
    /// `timestamp` in an `event_msg`/`task_started` record must not trap, and
    /// must be rejected as implausibly future-dated.
    func testAssessCodexTurnSurvivesHugeFutureTimestampJSON() throws {
        let json = #"""
        [{"timestamp":1e300,"type":"event_msg","payload":{"type":"task_started","cwd":"/tmp/x"}}]
        """#
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [JSONObject]
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCodexTurn(events, mtimeMs: now, now: now)
        XCTAssertEqual(assessment.lastActivityAt, Int64.max)
        XCTAssertFalse(assessment.active)
    }

    /// Same JSON-callable trap coverage for the Grok assessor. Grok tracks
    /// `lastActivityAt` via a running max (`if at > lastActivityAt { … }`),
    /// so a huge-ancient timestamp (saturating to `Int64.min`) can never win
    /// that comparison against a real anchor event — this is the exact same
    /// (crash-free) outcome the TS reference produces for identical input,
    /// not a Swift-only quirk: the huge-ancient event is simply ignored by
    /// the max-tracking logic, and the assessment reflects the real anchor
    /// event instead of trapping or corrupting `lastActivityAt`.
    func testAssessGrokTurnSurvivesHugeAncientTimestampJSON() throws {
        let json = #"""
        [
          {"ts": 1786449520000, "type": "turn_started"},
          {"ts": -1e300, "type": "phase_changed", "phase": "streaming_text"}
        ]
        """#
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [JSONObject]
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessGrokTurn(events, mtimeMs: now, now: now)
        XCTAssertEqual(assessment.lastActivityAt, 1_786_449_520_000)
        XCTAssertTrue(assessment.active)
        XCTAssertEqual(assessment.reason, "user prompt")
    }

    /// The generic-mtime assessor takes a bare `Int64` `mtimeMs`, not a
    /// parsed JSON value, but its `now - mtimeMs` age subtraction must still
    /// be overflow-safe against an already-saturated extreme timestamp
    /// (e.g. one that flowed in from `parseTimestamp` upstream).
    func testAssessGenericMtimeSurvivesSaturatedExtremeTimestamps() {
        let now: Int64 = 1_786_449_620_000
        let future = assessGenericMtime(mtimeMs: Int64.max, now: now)
        XCTAssertFalse(future.active)
        let ancient = assessGenericMtime(mtimeMs: Int64.min, now: now)
        XCTAssertFalse(ancient.active)
    }

    /// Cursor activity requires a finite timestamp inside ECMAScript Date's
    /// supported range, so a huge finite JSON number is malformed and stale.
    func testAssessCursorComposerRecordRejectsHugeFutureTimestampJSON() throws {
        let json = #"""
        {"status":"none","lastUpdatedAt":1e300,"fullConversationHeadersOnly":[]}
        """#
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? JSONObject
        )
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorComposerRecord(record, now: now)
        XCTAssertEqual(assessment.lastActivityAt, 0)
        XCTAssertFalse(assessment.active)
        XCTAssertEqual(assessment.reason, "malformed cursor composer")
    }

    /// Direct boundary tests for the saturating subtraction helper backing
    /// every `age = now - timestamp` computation: overflow in either
    /// direction must saturate, not trap, and in-range subtraction must be
    /// exact.
    func testSaturatingSubtractHandlesOverflowInBothDirections() {
        XCTAssertEqual(saturatingSubtract(10, 3), 7)
        XCTAssertEqual(saturatingSubtract(0, Int64.min), Int64.max, "0 - Int64.min overflows positive")
        XCTAssertEqual(saturatingSubtract(Int64.min, Int64.max), Int64.min, "Int64.min - Int64.max overflows negative")
        XCTAssertEqual(saturatingSubtract(Int64.max, Int64.max), 0)
    }

    /// Direct boundary tests for the saturating `Double -> Int64` conversion
    /// backing `parseTimestamp`.
    func testSaturatingInt64ClampsNonfiniteAndOutOfRangeValues() {
        XCTAssertEqual(saturatingInt64(Double.infinity), Int64.max)
        XCTAssertEqual(saturatingInt64(-Double.infinity), Int64.min)
        XCTAssertEqual(saturatingInt64(Double.nan), Int64.min, "NaN has no sign; saturating to a bound must not trap")
        XCTAssertEqual(saturatingInt64(1e300), Int64.max)
        XCTAssertEqual(saturatingInt64(-1e300), Int64.min)
        XCTAssertEqual(saturatingInt64(42.0), 42)
    }

    // MARK: - Process matcher case-sensitivity (Finding 2)

    private struct MatcherFixtureOracle: Decodable {
        let matcherCases: [MatcherFixtureCase]
    }

    private struct MatcherFixtureCase: Decodable {
        let id: String
        let kind: String
        let family: String?
        let patternIndex: Int?
        let command: String
        let expectedFamily: String??
        let expectedMatch: Bool?
    }

    private func loadMatcherOracle() throws -> MatcherFixtureOracle {
        let url = fixturesDirectory().appendingPathComponent("expected.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MatcherFixtureOracle.self, from: data)
    }

    /// Cross-language parity: every `matcherCases` row is asserted here and
    /// in `tests/agent-detection-parity.test.mjs` against the exact same
    /// `command` / `patternIndex` values, proving Swift's `matchAgentKind`
    /// (whole-family) and per-pattern case-sensitivity flags agree with the
    /// TS `RegExp` reference, including the five intentionally
    /// case-sensitive scoped-package patterns TS never applies `/i` to.
    func testProcessMatcherOracle() throws {
        let oracle = try loadMatcherOracle()
        XCTAssertFalse(oracle.matcherCases.isEmpty)

        for testCase in oracle.matcherCases {
            switch testCase.kind {
            case "family":
                let matched = matchAgentKind(command: testCase.command)
                let expected = (testCase.expectedFamily ?? nil).flatMap { $0 }
                XCTAssertEqual(matched?.id.rawValue, expected, testCase.id)

            case "pattern":
                guard
                    let familyRaw = testCase.family,
                    let family = AgentFamily(rawValue: familyRaw),
                    let patternIndex = testCase.patternIndex,
                    let expectedMatch = testCase.expectedMatch,
                    let kind = AGENT_KINDS.first(where: { $0.id == family })
                else {
                    XCTFail("malformed pattern matcher case \(testCase.id)")
                    continue
                }
                XCTAssertTrue(patternIndex >= 0 && patternIndex < kind.processMatchers.count, testCase.id)
                let matcher = kind.processMatchers[patternIndex]
                XCTAssertEqual(matcher.matches(testCase.command), expectedMatch, testCase.id)

            default:
                XCTFail("unknown matcherCases kind \(testCase.kind)")
            }
        }
    }

    func testProcessDefinitionsCompileEachPatternOnceOutsideMatchingHotLoop() {
        let counter = LockedCompilationCounter()
        let definitions = makeAgentKinds(
            regexCompiler: ProcessRegexCompiler(onCompilation: counter.increment)
        )
        let patternCount = definitions.reduce(0) { $0 + $1.processMatchers.count }
        XCTAssertGreaterThan(patternCount, 0)
        XCTAssertEqual(patternCount, AGENT_KINDS.reduce(0) { $0 + $1.processMatchers.count })
        XCTAssertEqual(counter.value, patternCount)

        let commands = [
            "/opt/homebrew/bin/claude",
            "npx @openai/codex",
            "/Users/example/.grok/downloads/grok-1.2.3-macos-arm64",
            "cursor-agent --agent",
            "definitely-not-an-agent",
        ]
        for index in 0..<10_000 {
            _ = matchAgentKind(command: commands[index % commands.count], kinds: definitions)
        }

        XCTAssertEqual(
            counter.value,
            patternCount,
            "matching thousands of processes must reuse the definitions' precompiled regexes"
        )
    }

    /// Structural guard: exactly the five scoped-package patterns
    /// (`@anthropic-ai/claude-code`, `@openai/codex`, `@google/gemini-cli`,
    /// `@sourcegraph/amp`, `@continuedev/cli`) are compiled case-sensitively;
    /// every other pattern stays case-insensitive, mirroring the `/i` flag
    /// (or its absence) on each `RegExp` literal in the TS policy exactly.
    func testExactlyFiveScopedPackagePatternsAreCaseSensitive() {
        let caseSensitivePatterns = AGENT_KINDS.flatMap { kind in
            kind.processMatchers.filter { !$0.caseInsensitive }.map(\.pattern)
        }
        XCTAssertEqual(caseSensitivePatterns.count, 5)
        XCTAssertEqual(Set(caseSensitivePatterns), [
            #"@anthropic-ai/claude-code"#,
            #"@openai/codex"#,
            #"@google/gemini-cli"#,
            #"@sourcegraph/amp"#,
            #"@continuedev/cli"#,
        ])
    }

    // MARK: - Cursor composer header `type` strict-equality hardening (Finding 2)

    /// Builds a Cursor composer record with a single conversation header
    /// whose `type` field is `headerType` and a recent `createdAt`. Status
    /// is `"completed"` (not `"generating"`) so the record only becomes
    /// `active` if the header loop itself recognizes `headerType` as a
    /// user-turn opener (`type == 1`) — an idle `"completed"`/`false` result
    /// proves the header was correctly rejected.
    private func assessCursorHeaderType(_ headerType: Any, now: Int64) -> TurnAssessment {
        let record: JSONObject = [
            "status": "completed",
            "lastUpdatedAt": now - 1_000,
            "fullConversationHeadersOnly": [
                ["type": headerType, "createdAt": now - 1_000] as JSONObject,
            ],
        ]
        return assessCursorComposerRecord(record, now: now)
    }

    /// TS uses strict equality (`header.type === 1`), which a JSON boolean
    /// can never satisfy (`true === 1` is `false` in JS). `JSONSerialization`
    /// represents JSON `true` as an `NSNumber` indistinguishable from `1` by
    /// naive `NSNumber` truncation, so a header of `type: true` must NOT be
    /// treated as a user-turn opener — the turn stays idle/"completed", not
    /// an open active user prompt.
    func testAssessCursorComposerRecordRejectsBooleanHeaderType() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType(true, now: now)
        XCTAssertFalse(assessment.active, "a JSON boolean `type` must never open a user turn")
        XCTAssertEqual(assessment.reason, "malformed cursor composer")
    }

    /// `1.0` is the exact same JS/JSON number as `1` (`1.0 === 1` is `true`
    /// in JS; IEEE-754 doubles don't distinguish integral floats), so this
    /// must still open a user turn — proving the fix isn't over-broad.
    func testAssessCursorComposerRecordAcceptsNumericOneEquivalentToInteger() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType(1.0, now: now)
        XCTAssertTrue(assessment.active, "1.0 == 1 numerically and must open a user turn, matching TS `=== 1`")
        XCTAssertEqual(assessment.reason, "user prompt")
    }

    /// `1.5 !== 1` under strict equality; a non-integral numeric `type` must
    /// not be treated as the user-bubble marker.
    func testAssessCursorComposerRecordRejectsNonIntegralHeaderType() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType(1.5, now: now)
        XCTAssertFalse(assessment.active, "1.5 is not strictly === 1 and must never open a user turn")
        XCTAssertEqual(assessment.reason, "malformed cursor composer")
    }

    /// `"1" !== 1` under strict equality (no numeric coercion); a JSON
    /// string `type` must never be treated as the user-bubble marker even
    /// if the string carries a numerically equivalent value.
    func testAssessCursorComposerRecordRejectsStringHeaderType() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType("1", now: now)
        XCTAssertFalse(assessment.active, "a JSON string \"1\" must never open a user turn")
        XCTAssertEqual(assessment.reason, "malformed cursor composer")
    }

    /// Normal fixture behavior must be unaffected: an integer JSON `type: 1`
    /// header still opens a user turn exactly as before the hardening.
    func testAssessCursorComposerRecordStillAcceptsIntegerHeaderType() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorHeaderType(1, now: now)
        XCTAssertTrue(assessment.active, "a plain integer 1 must still open a user turn")
        XCTAssertEqual(assessment.reason, "user prompt")
    }

    func testCursorContinuationBooleanAcceptsOnlyActualCFBooleanValues() {
        XCTAssertEqual(strictCursorBoolean(true), true)
        XCTAssertEqual(strictCursorBoolean(false), false)
        XCTAssertNil(strictCursorBoolean(NSNumber(value: 1)))
        XCTAssertNil(strictCursorBoolean(NSNumber(value: 0)))
    }

    func testNumericContinuationFlagWithoutTimestampCannotBecomeRecentlyActive() {
        let now: Int64 = 1_786_449_620_000
        let assessment = assessCursorComposerRecord(
            [
                "status": "completed",
                "isContinuationInProgress": NSNumber(value: 1),
                "fullConversationHeadersOnly": [],
            ],
            now: now
        )

        XCTAssertFalse(assessment.active)
        XCTAssertEqual(assessment.reason, "malformed cursor composer")
        XCTAssertNotEqual(assessment.lastActivityAt, now)
    }

    func testCursorRecordPrimitivesAndMissingActivityTimestampsNeverRefreshAcrossScans() {
        let now: Int64 = 1_786_449_620_000
        let malformedRecords: [JSONObject] = [
            [
                "status": NSNull(),
                "lastUpdatedAt": now,
                "fullConversationHeadersOnly": [],
            ],
            [
                "status": NSNumber(value: 1),
                "lastUpdatedAt": now,
                "fullConversationHeadersOnly": [],
            ],
            [
                "status": "generating",
                "lastUpdatedAt": NSNull(),
                "fullConversationHeadersOnly": [],
            ],
            [
                "status": "generating",
                "lastUpdatedAt": true,
                "fullConversationHeadersOnly": [],
            ],
            [
                "status": "generating",
                "fullConversationHeadersOnly": [],
            ],
            [
                "status": "completed",
                "isContinuationInProgress": NSNumber(value: 1),
                "fullConversationHeadersOnly": [],
            ],
            [
                "status": "generating",
                "lastUpdatedAt": now,
                "generatingBubbleIds": [NSNumber(value: 1)],
                "fullConversationHeadersOnly": [],
            ],
        ]

        for scanNow in [now, now + 1_000, now + 60_000] {
            for record in malformedRecords {
                let assessment = assessCursorComposerRecord(record, now: scanNow)
                XCTAssertFalse(assessment.active)
                XCTAssertEqual(assessment.reason, "malformed cursor composer")
                XCTAssertNotEqual(assessment.lastActivityAt, scanNow)
            }
        }
    }

    func testCursorMixedHeadersProcessOnlyValidEntriesWithoutPerpetualFreshness() {
        let now: Int64 = 1_786_449_620_000
        let record: JSONObject = [
            "status": "completed",
            "lastUpdatedAt": now - 60_000,
            "fullConversationHeadersOnly": [
                NSNull(),
                true,
                NSNumber(value: 42),
                "header",
                [],
                ["type": "1", "createdAt": now],
                ["type": 1, "createdAt": NSNull()],
                ["type": 1, "createdAt": now - 1_000],
            ] as [Any],
        ]

        let fresh = assessCursorComposerRecord(record, now: now)
        XCTAssertTrue(fresh.active)
        XCTAssertEqual(fresh.lastActivityAt, now - 1_000)
        XCTAssertEqual(fresh.reason, "user prompt")

        let repeated = assessCursorComposerRecord(record, now: now + turnActiveGraceMs + 1)
        XCTAssertFalse(repeated.active)
        XCTAssertEqual(repeated.lastActivityAt, now - 1_000)
        XCTAssertEqual(repeated.reason, "stale user prompt")
    }

    /// `toolFormerStatus`/`shellStatus` are always lowercased before being
    /// checked against the running-tool allowlist, so the allowlist must
    /// store its "in progress" entry lowercase too. A mixed-case entry like
    /// `"inProgress"` never matches the lowercased field and silently never
    /// classifies a running Cursor tool call as active.
    func testCursorToolStatusInProgressMixedCaseIsActive() {
        let now: Int64 = 1_786_449_620_000
        let record: JSONObject = [
            "status": "completed",
            "lastUpdatedAt": now - 5_000,
            "fullConversationHeadersOnly": [
                ["type": 2, "createdAt": now - 5_000, "grouping": ["toolFormerStatus": "inProgress"]] as JSONObject,
            ],
        ]
        let assessment = assessCursorComposerRecord(record, now: now)
        XCTAssertTrue(assessment.active, "toolFormerStatus \"inProgress\" must classify the tool call as active")
        XCTAssertEqual(assessment.reason, "tool_call in progress")
    }

    /// The field is lowercased before the allowlist check, so every raw case
    /// variant of "in progress" must be normalized to the same active result.
    func testCursorToolStatusInProgressCaseVariantsAreActive() {
        let now: Int64 = 1_786_449_620_000
        for rawStatus in ["inProgress", "INPROGRESS", "InProgress", "inprogress", "in_progress"] {
            let toolRecord: JSONObject = [
                "status": "completed",
                "lastUpdatedAt": now - 5_000,
                "fullConversationHeadersOnly": [
                    ["type": 2, "createdAt": now - 5_000, "grouping": ["toolFormerStatus": rawStatus]] as JSONObject,
                ],
            ]
            let toolAssessment = assessCursorComposerRecord(toolRecord, now: now)
            XCTAssertTrue(toolAssessment.active, "toolFormerStatus \"\(rawStatus)\" should be active")
            XCTAssertEqual(toolAssessment.reason, "tool_call in progress", "toolFormerStatus \"\(rawStatus)\" should report a running tool")

            let shellRecord: JSONObject = [
                "status": "completed",
                "lastUpdatedAt": now - 5_000,
                "fullConversationHeadersOnly": [
                    ["type": 2, "createdAt": now - 5_000, "grouping": ["shellStatus": rawStatus]] as JSONObject,
                ],
            ]
            let shellAssessment = assessCursorComposerRecord(shellRecord, now: now)
            XCTAssertTrue(shellAssessment.active, "shellStatus \"\(rawStatus)\" should be active")
            XCTAssertEqual(shellAssessment.reason, "tool_call in progress", "shellStatus \"\(rawStatus)\" should report a running tool")
        }
    }

    // MARK: - Cursor: realistic bubble-based tool status (issue B)

    /// Real Cursor state never embeds `grouping.toolFormerStatus` — the
    /// header only references a bubble id, and the actual tool status lives
    /// in that bubble's own `bubbleId:<composerId>:<bubbleId>` row under
    /// `toolFormerData.status`. This proves the bubble-derived source alone
    /// (no legacy embedded fields at all) is enough to classify a running
    /// tool call as active, mirroring
    /// `testCursorToolStatusInProgressMixedCaseIsActive` for the legacy path.
    func testCursorBubbleToolFormerDataStatusInProgressIsActive() {
        let now: Int64 = 1_786_449_620_000
        let record: JSONObject = [
            "status": "completed",
            "lastUpdatedAt": now - 5_000,
            "fullConversationHeadersOnly": [
                ["type": 2, "createdAt": now - 5_000, "bubbleId": "bubble-1"] as JSONObject,
            ],
        ]
        let bubbles: [String: JSONObject] = [
            "bubble-1": ["toolFormerData": ["status": "inProgress"]],
        ]

        let withoutBubble = assessCursorComposerRecord(record, now: now)
        XCTAssertFalse(withoutBubble.active, "a bare bubble reference with no bubble content must not itself imply activity")

        let withBubble = assessCursorComposerRecord(record, bubbles: bubbles, now: now)
        XCTAssertTrue(withBubble.active, "toolFormerData.status \"inProgress\" resolved via the referenced bubble must classify the tool call as active")
        XCTAssertEqual(withBubble.reason, "tool_call in progress")
    }

    /// Every raw case variant of "in progress" must normalize identically
    /// whether the status arrives via the legacy embedded header field or
    /// the realistic bubble row — same allowlist, same lowercasing.
    func testCursorBubbleToolFormerDataStatusCaseVariantsAreActive() {
        let now: Int64 = 1_786_449_620_000
        for rawStatus in ["inProgress", "INPROGRESS", "InProgress", "inprogress", "in_progress"] {
            let record: JSONObject = [
                "status": "completed",
                "lastUpdatedAt": now - 5_000,
                "fullConversationHeadersOnly": [
                    ["type": 2, "createdAt": now - 5_000, "bubbleId": "bubble-1"] as JSONObject,
                ],
            ]
            let bubbles: [String: JSONObject] = [
                "bubble-1": ["toolFormerData": ["status": rawStatus]],
            ]
            let assessment = assessCursorComposerRecord(record, bubbles: bubbles, now: now)
            XCTAssertTrue(assessment.active, "bubble toolFormerData.status \"\(rawStatus)\" should be active")
            XCTAssertEqual(assessment.reason, "tool_call in progress", "bubble toolFormerData.status \"\(rawStatus)\" should report a running tool")
        }
    }

    /// A resolved bubble reporting a terminal status (mirroring the legacy
    /// `shellStatus`/`toolFormerStatus` terminal set) marks the turn as
    /// tool-touched/completed rather than running, exactly like the legacy
    /// embedded fields already do.
    func testCursorBubbleToolFormerDataTerminalStatusesAreNotRunning() {
        let now: Int64 = 1_786_449_620_000
        for rawStatus in ["completed", "success", "error", "failed"] {
            let record: JSONObject = [
                "status": "completed",
                "lastUpdatedAt": now - 5_000,
                "fullConversationHeadersOnly": [
                    ["type": 1, "createdAt": now - 10_000] as JSONObject,
                    ["type": 2, "createdAt": now - 5_000, "bubbleId": "bubble-1"] as JSONObject,
                ],
            ]
            let bubbles: [String: JSONObject] = [
                "bubble-1": ["toolFormerData": ["status": rawStatus]],
            ]
            let assessment = assessCursorComposerRecord(record, bubbles: bubbles, now: now)
            XCTAssertNotEqual(assessment.reason, "tool_call in progress", "terminal bubble status \"\(rawStatus)\" must not report a running tool")
        }
    }

    /// A missing bubble (dangling reference), a bubble present but lacking
    /// `toolFormerData`, and a non-object `toolFormerData.status` must all be
    /// treated identically to "no status" rather than crashing or throwing.
    func testCursorBubbleMissingOrMalformedNeverCrashesOrFalselyActivates() {
        let now: Int64 = 1_786_449_620_000
        let record: JSONObject = [
            "status": "completed",
            "lastUpdatedAt": now - 5_000,
            "fullConversationHeadersOnly": [
                ["type": 2, "createdAt": now - 5_000, "bubbleId": "bubble-missing"] as JSONObject,
            ],
        ]
        let malformedBubbleSets: [[String: JSONObject]] = [
            [:], // dangling reference: bubble id not present at all.
            ["bubble-missing": [:]], // bubble present, no toolFormerData at all.
            ["bubble-missing": ["toolFormerData": "not-an-object"]],
            ["bubble-missing": ["toolFormerData": ["status": NSNumber(value: 1)]]],
            ["bubble-missing": ["toolFormerData": ["status": NSNull()]]],
        ]
        for bubbles in malformedBubbleSets {
            let assessment = assessCursorComposerRecord(record, bubbles: bubbles, now: now)
            XCTAssertNotEqual(assessment.reason, "tool_call in progress")
        }
    }

    /// `cursorRelevantBubbleIds` must exclude `type == 1` (user) bubble ids
    /// and deduplicate a repeated reference within the trailing window.
    func testCursorRelevantBubbleIdsExcludesUserBubblesAndDeduplicates() {
        let record: JSONObject = [
            "fullConversationHeadersOnly": [
                ["type": 1, "createdAt": Int64(0), "bubbleId": "user-0"] as JSONObject,
                ["type": 2, "createdAt": Int64(1), "bubbleId": "tool-0"] as JSONObject,
                ["type": 1, "createdAt": Int64(2), "bubbleId": "user-1"] as JSONObject,
                ["type": 2, "createdAt": Int64(3), "bubbleId": "tool-1"] as JSONObject,
                // Duplicate reference to an already-listed bubble id.
                ["type": 2, "createdAt": Int64(4), "bubbleId": "tool-0"] as JSONObject,
            ],
        ]

        XCTAssertEqual(cursorRelevantBubbleIds(record), ["tool-0", "tool-1"])
    }

    /// A conversation with more trailing `type == 2` bubble references than
    /// `cursorMaximumRecentHeadersPerComposer` must be capped to exactly that
    /// many — the most recent ones — never growing unbounded with
    /// conversation length (this is what keeps the global
    /// `cursorMaximumBubbleLookups` scan budget meaningful).
    func testCursorRelevantBubbleIdsBoundedToRecentHeadersPerComposer() {
        var headers: [JSONObject] = []
        for index in 0..<12 {
            headers.append(["type": 2, "createdAt": Int64(index), "bubbleId": "tool-\(index)"])
        }
        let record: JSONObject = ["fullConversationHeadersOnly": headers]

        let ids = cursorRelevantBubbleIds(record)

        XCTAssertEqual(cursorMaximumRecentHeadersPerComposer, 8)
        XCTAssertEqual(ids, ["tool-4", "tool-5", "tool-6", "tool-7", "tool-8", "tool-9", "tool-10", "tool-11"])
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

    // MARK: - Cursor SQL recency vs. assessor-derived recency parity (mirrors
    // tests/agent-detection-parity.test.mjs's "Cursor SQL recency vs.
    // assessor-derived recency parity" section)
    //
    // `cursorRecencySqlExpression` (in `SessionSnapshotSource.swift`) computes
    // a `cursorDiskKV` composer row's recency directly in SQLite so a bounded
    // query can `ORDER BY` real last-activity time instead of `rowid`. These
    // cases execute that *exact* SQL expression through a real SQLite
    // connection and assert it agrees with `assessCursorComposerRecord`'s own
    // `lastActivityAt` for every timestamp shape the assessor can turn into
    // an *active* composer. That agreement is exactly what lets the row-limit
    // sentinel (see `SessionSnapshotSourceTests.swift`'s "row limit
    // recovers"/"still throws" tests) safely treat an unrankable (SQL `NULL`)
    // row as provably never a lost active composer.

    /// Computes `cursorRecencySqlExpression` against a single real, in-memory
    /// SQLite row holding `valueJSON` as `cursorDiskKV.value`. `:memory:` is
    /// enough: this proves a pure SQL-evaluation property, independent of the
    /// filesystem/WAL/symlink hardening `SessionSnapshotSourceTests.swift`
    /// already covers.
    private func sqlRecency(forValueJSON valueJSON: String) -> Int64? {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil),
            SQLITE_OK
        )
        var insert: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES ('row', ?)", -1, &insert, nil),
            SQLITE_OK
        )
        sqlite3_bind_text(insert, 1, valueJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
        sqlite3_finalize(insert)

        var query: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "SELECT (\(cursorRecencySqlExpression)) AS recencyMs FROM cursorDiskKV", -1, &query, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        guard sqlite3_column_type(query, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(query, 0)
    }

    /// `assessCursorComposerRecord`'s own `lastActivityAt`, parsed from the
    /// *exact same* JSON text `sqlRecency(forValueJSON:)` receives — parsing
    /// once from text (rather than authoring a Swift dictionary literal and a
    /// JSON string separately) guarantees both sides see byte-identical
    /// input.
    private func assessedLastActivityAt(forValueJSON valueJSON: String, now: Int64) throws -> Int64 {
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(valueJSON.utf8), options: [.fragmentsAllowed]) as? JSONObject
        )
        return assessCursorComposerRecord(record, now: now).lastActivityAt
    }

    /// Mirrors the TS parity suite's "numeric root timestamp (milliseconds
    /// and seconds)" case.
    func testCursorSQLRecencyMatchesAssessorForNumericRootTimestamp() throws {
        let now: Int64 = 1_786_449_620_000
        for valueJSON in [
            #"{"status":"generating","lastUpdatedAt":\#(now)}"#,
            #"{"status":"generating","lastUpdatedAt":\#(now / 1_000)}"#,
        ] {
            let assessed = try assessedLastActivityAt(forValueJSON: valueJSON, now: now)
            XCTAssertEqual(sqlRecency(forValueJSON: valueJSON), assessed, valueJSON)
            XCTAssertEqual(assessed, now, valueJSON)
        }
    }

    /// Mirrors the TS parity suite's ISO-8601 string root timestamp case:
    /// `toISOString()`'s exact millisecond+`Z` shape is what
    /// `cursorRecencySqlExpression`'s `GLOB` guard requires and what Swift's
    /// `ISO8601FormatStyle` parses to the identical millisecond value.
    func testCursorSQLRecencyMatchesAssessorForISOStringRootTimestamp() throws {
        let now: Int64 = 1_786_449_620_000
        let isoNow = "2026-08-11T12:00:20.000Z"
        XCTAssertEqual(parseISO8601ToMs(isoNow), now, "fixture ISO string must itself parse to `now`")
        let valueJSON = #"{"status":"generating","lastUpdatedAt":"\#(isoNow)"}"#
        let assessed = try assessedLastActivityAt(forValueJSON: valueJSON, now: now)
        XCTAssertEqual(sqlRecency(forValueJSON: valueJSON), assessed)
        XCTAssertEqual(assessed, now)
    }

    /// Mirrors the TS parity suite's "header-only composer" case: no root
    /// `lastUpdatedAt`/`createdAt`/`conversationCheckpointLastUpdatedAt`
    /// field at all — the composer's only recency signal is a conversation
    /// header's own `createdAt`, in both the numeric and ISO-string shapes.
    func testCursorSQLRecencyMatchesAssessorForHeaderOnlyComposer() throws {
        let now: Int64 = 1_786_449_620_000
        let isoNow = "2026-08-11T12:00:20.000Z"
        for createdAtJSON in ["\(now)", "\"\(isoNow)\""] {
            let valueJSON = #"{"fullConversationHeadersOnly":[{"type":1,"createdAt":\#(createdAtJSON)}]}"#
            let assessed = try assessedLastActivityAt(forValueJSON: valueJSON, now: now)
            XCTAssertEqual(sqlRecency(forValueJSON: valueJSON), assessed, valueJSON)
            XCTAssertEqual(assessed, now, valueJSON)
        }
    }

    /// Mirrors the TS parity suite's field-priority-order case: a
    /// higher-priority defined field must win over a numerically-later but
    /// lower-priority one, in SQL exactly as in the assessor's own
    /// `firstNonNull` chain — a `COALESCE`, never a flat `MAX` across all
    /// three fields.
    func testCursorSQLRecencyMatchesAssessorFieldPriorityOrderForUpdatedOldRow() throws {
        let now: Int64 = 1_786_449_620_000
        let oldCreatedAt = now - 86_400_000
        for valueJSON in [
            #"{"status":"completed","createdAt":\#(oldCreatedAt),"lastUpdatedAt":\#(now)}"#,
            #"{"status":"completed","createdAt":\#(oldCreatedAt),"lastUpdatedAt":\#(oldCreatedAt),"conversationCheckpointLastUpdatedAt":\#(now)}"#,
        ] {
            let assessed = try assessedLastActivityAt(forValueJSON: valueJSON, now: now)
            XCTAssertEqual(sqlRecency(forValueJSON: valueJSON), assessed, valueJSON)
            XCTAssertEqual(assessed, now, valueJSON)
        }

        // A lower-priority field's numerically *larger* raw value must never
        // outrank a defined higher-priority field.
        let prioritized = #"{"status":"completed","conversationCheckpointLastUpdatedAt":\#(now / 1_000),"lastUpdatedAt":\#(now + 999_000_000)}"#
        let assessedPrioritized = try assessedLastActivityAt(forValueJSON: prioritized, now: now)
        XCTAssertEqual(sqlRecency(forValueJSON: prioritized), assessedPrioritized)
        XCTAssertEqual(assessedPrioritized, now)
    }

    /// Mirrors the TS parity suite's malformed/unparseable case: both an
    /// assessable-but-unrankable `JSONObject` (which the assessor rejects to
    /// `lastActivityAt: 0`) and genuinely invalid JSON syntax (which never
    /// even reaches the assessor in production — the scan Worker's own parse
    /// fails first and the row is skipped — so only SQL's `NULL` unrankable
    /// verdict is asserted for those; a bare top-level JSON array, the TS
    /// suite's third malformed case, has no Swift equivalent here since
    /// `assessCursorComposerRecord` only ever accepts a `JSONObject`
    /// argument, a distinction TS's structural typing doesn't enforce at
    /// this boundary).
    func testCursorSQLRecencyMatchesAssessorForMalformedOrUnparseableRecords() throws {
        let now: Int64 = 1_786_449_620_000
        for valueJSON in [
            #"{"lastUpdatedAt":"not-a-timestamp"}"#,
            #"{"fullConversationHeadersOnly":[42,null,"x"]}"#,
        ] {
            let assessed = try assessedLastActivityAt(forValueJSON: valueJSON, now: now)
            XCTAssertEqual(sqlRecency(forValueJSON: valueJSON), assessed, valueJSON)
            XCTAssertEqual(assessed, 0, valueJSON)
        }

        XCTAssertNil(sqlRecency(forValueJSON: #"{"status":"#))
        XCTAssertNil(sqlRecency(forValueJSON: ""))
    }

    /// Mirrors the TS parity suite's future-skew case: `lastActivityAt`
    /// itself is never clamped by "is this in the future" — only the
    /// separate active/inactive boolean is — so recency ranking must track
    /// the assessor's raw value exactly, future or not, up to (and rejecting
    /// identically beyond) `maxSupportedTimestampMs`.
    func testCursorSQLRecencyMatchesAssessorForFutureSkewedAndOutOfRangeTimestamps() throws {
        let now: Int64 = 1_786_449_620_000
        // `TurnAssessors.swift`'s own `maxSupportedTimestampMs` is
        // file-private, so this mirrors it verbatim — exactly as
        // `cursorRecencySqlExpression` itself already must, for the same
        // reason (see its doc comment in `SessionSnapshotSource.swift`).
        let maxSupportedTimestampMs: Int64 = 8_640_000_000_000_000
        for futureMs in [now + 60_000, now + 86_400_000, maxSupportedTimestampMs - 1] {
            let valueJSON = #"{"status":"generating","lastUpdatedAt":\#(futureMs)}"#
            let assessed = try assessedLastActivityAt(forValueJSON: valueJSON, now: now)
            XCTAssertEqual(sqlRecency(forValueJSON: valueJSON), assessed, valueJSON)
            XCTAssertEqual(assessed, futureMs, valueJSON)
        }

        // Beyond maxSupportedTimestampMs: both sides reject the whole record
        // identically (validateCursorRecordFields already rejects any
        // defined priority field that fails parseCursorTimestamp's own
        // bound check).
        let outOfRange = #"{"status":"generating","lastUpdatedAt":\#(maxSupportedTimestampMs + 1)}"#
        let assessedOutOfRange = try assessedLastActivityAt(forValueJSON: outOfRange, now: now)
        XCTAssertEqual(sqlRecency(forValueJSON: outOfRange), assessedOutOfRange)
        XCTAssertEqual(assessedOutOfRange, 0)
    }

    /// Swift's `Date.ISO8601FormatStyle` flatly rejects `"2024-01-15"`
    /// (confirmed empirically: both the fractional- and
    /// non-fractional-seconds style variants fail to parse it). TS's
    /// isCanonicalCursorIsoTimestamp grammar guard (see
    /// agent-detection-policy.ts and agent-detection-parity.test.mjs) now
    /// enforces the identical canonical-ISO-8601 grammar ahead of
    /// parseCursorTimestamp, so on both platforms SQL and the assessor agree
    /// with no exception needed: both treat a date-only string as
    /// unrankable/non-activity-bearing.
    func testCursorSQLRecencyAndAssessorAgreeDateOnlyStringsAreUnrankable() throws {
        let now: Int64 = 1_786_449_620_000
        XCTAssertNil(parseISO8601ToMs("2024-01-15"), "Swift's ISO8601FormatStyle must reject a date-only string")
        let valueJSON = #"{"fullConversationHeadersOnly":[{"type":1,"createdAt":"2024-01-15"}]}"#
        let assessed = try assessedLastActivityAt(forValueJSON: valueJSON, now: now)
        XCTAssertEqual(sqlRecency(forValueJSON: valueJSON), 0)
        XCTAssertEqual(assessed, 0)
    }
}
